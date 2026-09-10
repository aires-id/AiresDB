# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

"""Persistent ARSP-4 page-store sidecar.

The existing `.aires` WAL remains the authority for transaction recovery.  This
module stores committed heap/index pages in `<database>.aires.pages`; its catalog
contains the WAL identity and applied LSN.  A valid but stale sidecar is rebuilt
from WAL recovery, while a corrupt sidecar raises a storage error rather than
being treated as an empty database.
"""

const PAGESTORE_SUFFIX = ".pages"
const PAGESTORE_CATALOG_MAGIC = UInt8[0x41,0x49,0x52,0x45,0x53,0x43,0x34,0x31] # AIRESC41
const PAGESTORE_CATALOG_VERSION = UInt16(1)
const PAGESTORE_META_OFFSET = PAGE_HEADER_SIZE + 1
const PAGESTORE_APPLIED_LSN_OFFSET = PAGESTORE_META_OFFSET + 10
const PAGESTORE_APPLIED_CSN_OFFSET = PAGESTORE_META_OFFSET + 18
const PAGESTORE_FILE_ID_OFFSET = PAGESTORE_META_OFFSET + 26

mutable struct PageTableStore
    name::String
    schema_digest::Vector{UInt8}
    heap::HeapFile
    indexes::Dict{Tuple,PersistentBTree}
    # RIDs follow the exact logical `Table.row_ids` order. The table already
    # owns a UInt128=>position directory, so a second UInt128=>RID hash table
    # doubled large-table indexing memory for no additional information.
    row_rids::Vector{RID}
    # True only after a replacement version makes physical heap order diverge
    # from AiresQL's stable logical row order.
    requires_logical_order::Bool
end

mutable struct PageStore
    wal_path::String
    page_path::String
    manager::PageManager
    pool::BufferPool
    catalog_page_id::UInt64
    tables::Dict{String,PageTableStore}
    applied_file_id::Vector{UInt8}
    applied_lsn::UInt64
    applied_csn::UInt64
    base_csn::UInt64
    scheduler::RollingScheduler
    mutex::ReentrantLock
    rebuilds::UInt64
    # Committed heap/index frames may remain dirty after WAL acknowledgement.
    # The catalog marker is published only after those frames are forced by a
    # clean close/checkpoint, making a stale marker a deterministic rebuild
    # signal after a crash (standard WAL no-force policy).
    catalog_dirty::Bool
end

mutable struct PageStoreScanCursor
    store::PageStore
    table::PageTableStore
    heap_cursor::HeapBatchCursor
    snapshot_csn::UInt64
    # The heap remains the physical sequential source. API/executor callers
    # may provide the current logical row order to preserve AiresQL's legacy
    # observable order after an MVCC update appends a new heap version.
    logical_row_ids::Union{Nothing,Vector{UInt128}}
    logical_position::Int
end

mutable struct PageStoreIndexCursor
    store::PageStore
    table::PageTableStore
    tree_cursor::BTreeCursor
    snapshot_csn::UInt64
end

mutable struct _PageCommitPlan
    store::PageStore
    before::Database
    after::Database
    tx::TransactionState
    csn::UInt64
    lsn::UInt64
    file_id::Vector{UInt8}
end

mutable struct _PageLookupPlan
    store::PageStore
    table::Table
    key::Tuple
    snapshot_csn::UInt64
    result::Union{Nothing,Row}
    result_row_id::UInt128
    result_begin_csn::UInt64
end

"""Per-work P2 state.  It lives in `StorageWorkUnit.async_state` while a
background page acquisition owns the disk/buffer wait."""
mutable struct _PageAcquireState
    page_id::UInt64
    status::Symbol
end

function _page_store_acquire_page!(work::StorageWorkUnit,lane::StorageLane,
                                   scheduler::RollingScheduler,pool::BufferPool,page_id::UInt64)
    pending = work.async_state
    if pending !== nothing
        pending isa _PageAcquireState || storageerror("State akuisisi ARSP-4 tidak valid.")
        pending.page_id == page_id || storageerror("Akusisi page ARSP-4 berpindah target.")
        if pending.status === :ready
            work.async_state = nothing
            return phase_advance()
        end
        pending.status === :pending || storageerror("Status akuisisi ARSP-4 tidak valid.")
        return phase_blocked_io()
    end
    # A hit stays entirely in P2.  A miss is delegated before this handler
    # returns, so the scheduler can advance the other three lanes this tick.
    frame = try_fetch_cached_page!(pool,page_id)
    if frame !== nothing
        unpin_page!(pool,frame)
        return phase_advance()
    end
    state = _PageAcquireState(page_id,:pending)
    work.async_state = state
    register_async_wait!(scheduler,lane)
    request_id = work.request_id
    lane_id = lane.id
    Threads.@spawn begin
        try
            acquired = fetch_page_wait!(pool,page_id)
            try
                nothing
            finally
                unpin_page!(pool,acquired)
            end
            lock(scheduler.mutex) do
                state.status = :ready
            end
            resume_async_lane!(scheduler,lane_id,request_id)
        catch error
            fail_async_lane!(scheduler,lane_id,request_id,error)
        end
    end
    phase_blocked_io()
end

# A process can contain many independently constructed `Engine`s for the same
# directory. They must still share one open sidecar on Windows: two managers
# for the same path make a WAL-driven rebuild unable to replace its own file.
# The registry owns no transaction state; it only canonicalizes the page-file
# handle and its bounded buffer pool. WAL locking still serializes recovery
# and publication across processes.
const _PAGE_STORE_REGISTRY_LOCK = ReentrantLock()
const _PAGE_STORE_REGISTRY = Dict{String,PageStore}()

function _page_store_registry_key(path::AbstractString)
    normalized = normpath(abspath(String(path)))
    Sys.iswindows() ? lowercase(normalized) : normalized
end

page_store_path(wal_path::AbstractString) = String(wal_path) * PAGESTORE_SUFFIX

function _page_store_schema_digest(columns::Vector{ColumnDef})
    io = IOBuffer()
    put_u16(io,length(columns))
    for column in columns
        write_column(io,column)
    end
    sha256(take!(io))
end

function _page_store_write_metadata!(page::Page,file_id::Vector{UInt8},lsn::UInt64,csn::UInt64)
    length(file_id) == 16 || storageerror("Identitas WAL untuk page store tidak valid.")
    page_header(page).page_type == PageTypeCatalog || storageerror("Page catalog ARSP-4 tidak valid.")
    copyto!(page.bytes,PAGESTORE_META_OFFSET,PAGESTORE_CATALOG_MAGIC,1,length(PAGESTORE_CATALOG_MAGIC))
    page_put_u16!(page.bytes,PAGESTORE_META_OFFSET+8,PAGESTORE_CATALOG_VERSION)
    page_put_u64!(page.bytes,PAGESTORE_APPLIED_LSN_OFFSET,lsn)
    page_put_u64!(page.bytes,PAGESTORE_APPLIED_CSN_OFFSET,csn)
    copyto!(page.bytes,PAGESTORE_FILE_ID_OFFSET,file_id,1,16)
    page
end

function _page_store_read_metadata(page::Page)
    page_header(page).page_type == PageTypeCatalog || storageerror("Page catalog ARSP-4 tidak valid.")
    page.bytes[PAGESTORE_META_OFFSET:PAGESTORE_META_OFFSET+7] == PAGESTORE_CATALOG_MAGIC ||
        storageerror("Magic catalog ARSP-4 tidak valid.")
    page_get_u16(page.bytes,PAGESTORE_META_OFFSET+8) == PAGESTORE_CATALOG_VERSION ||
        storageerror("Versi catalog ARSP-4 tidak didukung.")
    file_id = copy(@view page.bytes[PAGESTORE_FILE_ID_OFFSET:PAGESTORE_FILE_ID_OFFSET+15])
    (file_id=file_id,lsn=page_get_u64(page.bytes,PAGESTORE_APPLIED_LSN_OFFSET),
     csn=page_get_u64(page.bytes,PAGESTORE_APPLIED_CSN_OFFSET))
end

function _page_store_index_specs(table::Table)
    sort!(collect(unique_specs(table));by=spec->join(string.(collect(spec)),",") )
end

function _page_store_encode_table(entry::PageTableStore)
    io = IOBuffer()
    put_string(io,entry.name)
    length(entry.schema_digest) == 32 || storageerror("Digest schema page store tidak valid.")
    write(io,entry.schema_digest)
    put_u64(io,entry.heap.meta_page_id)
    specs = sort!(collect(keys(entry.indexes));by=spec->join(string.(collect(spec)),","))
    length(specs) <= typemax(UInt16) || storageerror("Jumlah index page store terlalu besar.")
    put_u16(io,length(specs))
    for spec in specs
        length(spec) <= typemax(UInt16) || storageerror("Spec index page store terlalu panjang.")
        put_u16(io,length(spec))
        for column in spec
            1 <= column <= typemax(UInt16) || storageerror("Kolom index page store tidak valid.")
            put_u16(io,column)
        end
        put_u64(io,entry.indexes[spec].meta_page_id)
    end
    take!(io)
end

function _page_store_decode_table(pool::BufferPool,db::Database,payload::Vector{UInt8})
    io = IOBuffer(payload)
    name = get_string(io;max_length=512)
    table = get(db.tables,name,nothing)
    table === nothing && return nothing
    digest = read_exact(io,32)
    digest == _page_store_schema_digest(table.columns) || return nothing
    heap = open_heap(pool,get_u64(io),table.columns)
    nindexes = Int(get_u16(io))
    nindexes <= length(table.columns) + 1 || storageerror("Jumlah index catalog ARSP-4 tidak valid.")
    expected = Set(_page_store_index_specs(table))
    indexes = Dict{Tuple,PersistentBTree}()
    for _ in 1:nindexes
        width = Int(get_u16(io))
        1 <= width <= length(table.columns) || storageerror("Lebar index catalog ARSP-4 tidak valid.")
        spec = Tuple(Int(get_u16(io)) for _ in 1:width)
        spec in expected || return nothing
        haskey(indexes,spec) && storageerror("Index catalog ARSP-4 duplikat.")
        indexes[spec] = open_btree(pool,get_u64(io))
    end
    eof(io) || storageerror("Payload tabel catalog ARSP-4 memiliki byte tambahan.")
    Set(keys(indexes)) == expected || return nothing
    PageTableStore(name,digest,heap,indexes,RID[],false)
end

function _page_store_load_row_rids!(entry::PageTableStore,pool::BufferPool;
                                    logical_table::Union{Nothing,Table}=nothing)
    logical_table === nothing && storageerror("Reopen PageStore membutuhkan urutan row WAL.")
    table = logical_table::Table
    rids = Vector{RID}(undef,length(table.row_ids))
    seen = falses(length(table.row_ids))
    active = 0
    cursor = heap_batch_cursor(entry.heap,pool;batch_size=256)
    while true
        raw = next_heap_batch!(cursor)
        raw === nothing && break
        for (rid,payload) in raw
            record = decode_heap_record(entry.heap.columns,payload)
            record.end_csn == INFINITY_CSN && !record.tombstone || continue
            position = get(table.positions,record.row_id,0)
            position == 0 && storageerror("RID aktif heap tidak terdapat pada tabel WAL.")
            seen[position] && storageerror("Versi heap aktif berulang untuk satu row ID.")
            rids[position] = rid
            seen[position] = true
            active += 1
        end
    end
    active == length(rids) && all(seen) ||
        storageerror("Jumlah RID aktif heap tidak cocok dengan tabel WAL.")
    entry.row_rids = rids
    previous = nothing
    entry.requires_logical_order = false
    for rid in rids
        if previous !== nothing && (rid.page_id < previous.page_id ||
            (rid.page_id == previous.page_id && rid.slot_id <= previous.slot_id))
            entry.requires_logical_order = true
            break
        end
        previous = rid
    end
    entry
end

function _page_store_write_catalog!(store::PageStore,file_id::Vector{UInt8},lsn::UInt64,csn::UInt64)
    frame = fetch_page!(store.pool,store.catalog_page_id)
    lock(frame.latch)
    try
        init_slotted_page!(frame.page,PageTypeCatalog;page_lsn=lsn)
        _page_store_write_metadata!(frame.page,file_id,lsn,csn)
        for name in sort!(collect(keys(store.tables)))
            slotted_insert!(frame.page,_page_store_encode_table(store.tables[name]);finalize=false)
        end
        set_page_lsn!(frame.page,lsn)
        finalize_page!(frame.page)
    finally
        unlock(frame.latch)
        unpin_page!(store.pool,frame;dirty=true,page_lsn=lsn)
    end
    nothing
end

function _page_store_insert_indexes!(store::PageStore,entry::PageTableStore,row::Row,rid::RID;page_lsn::UInt64)
    for (spec,tree) in entry.indexes
        key = row_key(row,spec)
        any(isnothing,key) && continue
        btree_insert!(store.pool,tree,key,rid;page_lsn)
    end
    nothing
end
function _page_store_delete_indexes!(store::PageStore,entry::PageTableStore,row::Row;page_lsn::UInt64)
    for (spec,tree) in entry.indexes
        key = row_key(row,spec)
        any(isnothing,key) && continue
        btree_delete!(store.pool,tree,key;page_lsn)
    end
    nothing
end

"""Fill a newly created heap and its pristine indexes as one packed batch."""
function _page_store_fill_empty_table!(store::PageStore,entry::PageTableStore,table::Table,
                                       csn::UInt64,lsn::UInt64)
    entry.heap.page_count == 0 || storageerror("Bulk fill ARSP-4 membutuhkan heap kosong.")
    isempty(entry.row_rids) || storageerror("Bulk fill ARSP-4 menemukan RID yang sudah ada.")
    # Keep RIDs in a compact isbits vector aligned with Table.row_ids. The
    # table's existing positions map resolves a row identity when needed.
    payloads = (begin
        stamp = table_stamp(table,index)
        begin_csn = stamp == 0 ? csn : stamp
        row = table_row(table,index)
        encode_heap_record(entry.heap.columns,row;row_id=table.row_ids[index],begin_csn,
            end_csn=INFINITY_CSN,previous=nothing,schema_epoch=csn,tombstone=false)
    end for index in eachindex(table.rows))
    physical_rids = heap_insert_raw_batch!(store.pool,entry.heap,payloads;page_lsn=lsn)
    # Heap record payloads are no longer reachable once packed into slotted
    # pages. Reclaim them before allocating sort keys for the first index.
    GC.gc(true)
    # Build one persistent index at a time.  Keeping encoded key batches for
    # all indexes simultaneously made peak RSS proportional to index count.
    for spec in _page_store_index_specs(table)
        if length(spec) == 1 && table.columns[spec[1]].kind == :I
            # Avoid sorting the abstract `Dict{Tuple,...}` key type. Millions
            # of dynamic comparator calls box Int64 values and leave allocator
            # pools committed. A concrete pair vector is small and type-stable.
            ordered = Tuple{Int64,RID}[]
            sizehint!(ordered,length(table.rows))
            for index in eachindex(table.rows)
                value = table_row(table,index)[spec[1]]
                value === nothing || push!(ordered,(value::Int64,physical_rids[index]))
            end
            sort!(ordered;lt=(left,right)->left[1] < right[1])
            stream = ((btree_key((key,)),rid) for (key,rid) in ordered)
            btree_bulk_load_ordered!(store.pool,entry.indexes[spec],stream;page_lsn=lsn)
            empty!(ordered)
        else
            ordered_keys = Tuple{Tuple,RID}[]
            sizehint!(ordered_keys,length(table.rows))
            for index in eachindex(table.rows)
                key = row_key(table_row(table,index),spec)
                any(isnothing,key) || push!(ordered_keys,(key,physical_rids[index]))
            end
            sort!(ordered_keys;lt=(left,right)->_page_store_index_key_less(left[1],right[1]))
            stream = ((btree_key(key),rid) for (key,rid) in ordered_keys)
            btree_bulk_load_ordered!(store.pool,entry.indexes[spec],stream;page_lsn=lsn)
            empty!(ordered_keys)
        end
        # Do not let encoded keys from one persistent index overlap the sort
        # and leaf buffers of the next index during a large bulk publication.
        GC.gc(true)
    end
    entry.row_rids = physical_rids
    entry.requires_logical_order = false
    entry
end

function _page_store_index_key_less(left::Tuple,right::Tuple)::Bool
    @inbounds for index in eachindex(left)
        a,b = left[index],right[index]
        isequal(a,b) && continue
        a === nothing && return true
        b === nothing && return false
        if typeof(a) === typeof(b) && a isa Union{Int64,Float64,String,Date,Time,DateTime}
            return isless(a,b)
        end
        return btree_compare(btree_key(a),btree_key(b)) < 0
    end
    false
end

function _page_store_build_table!(store::PageStore,table::Table,csn::UInt64,lsn::UInt64)
    heap = create_heap!(store.pool,table.columns;page_lsn=lsn)
    indexes = Dict{Tuple,PersistentBTree}()
    for spec in _page_store_index_specs(table)
        indexes[spec] = create_btree!(store.pool;page_lsn=lsn)
    end
    entry = PageTableStore(table.name,_page_store_schema_digest(table.columns),heap,indexes,RID[],false)
    _page_store_fill_empty_table!(store,entry,table,csn,lsn)
end

function _page_store_create(wal_path::String,db::Database,file_id::Vector{UInt8},lsn::UInt64,csn::UInt64;
                            buffer_pages::Integer=64)
    page_path = page_store_path(wal_path)
    manager = open_page_manager(page_path;create=true,page_size=PAGE_SIZE,durable_lsn=lsn)
    pool = BufferPool(manager;capacity=buffer_pages)
    catalog = new_page!(pool,PageTypeCatalog;page_lsn=lsn)
    store = PageStore(wal_path,page_path,manager,pool,catalog.page_id,Dict{String,PageTableStore}(),
        UInt8[],0,0,csn,RollingScheduler(),ReentrantLock(),0,false)
    try
        # A zero-LSN catalog makes an interrupted initial build explicitly stale.
        lock(catalog.latch)
        try
            init_slotted_page!(catalog.page,PageTypeCatalog;page_lsn=0)
            _page_store_write_metadata!(catalog.page,zeros(UInt8,16),UInt64(0),UInt64(0))
            finalize_page!(catalog.page)
        finally
            unlock(catalog.latch)
            unpin_page!(pool,catalog;dirty=true,page_lsn=0)
        end
        for name in sort!(collect(keys(db.tables)))
            store.tables[name] = _page_store_build_table!(store,db.tables[name],csn,lsn)
        end
        # Data pages must reach disk before the catalog advertises the LSN.
        flush_all!(pool;sync=true)
        _page_store_write_catalog!(store,file_id,lsn,csn)
        flush_all!(pool;sync=true)
        store.applied_file_id = copy(file_id)
        store.applied_lsn = lsn
        store.applied_csn = csn
        store
    catch
        close(manager)
        rethrow()
    end
end

function _page_store_open_existing(wal_path::String,db::Database,file_id::Vector{UInt8},lsn::UInt64,csn::UInt64;
                                   buffer_pages::Integer=64)
    page_path = page_store_path(wal_path)
    manager = open_page_manager(page_path;page_size=PAGE_SIZE,durable_lsn=lsn)
    pool = BufferPool(manager;capacity=buffer_pages)
    store = PageStore(wal_path,page_path,manager,pool,UInt64(1),Dict{String,PageTableStore}(),
        UInt8[],0,0,0,RollingScheduler(),ReentrantLock(),0,false)
    try
        catalog = read_page(manager,UInt64(1))
        metadata = _page_store_read_metadata(catalog)
        if !(metadata.file_id == file_id && metadata.lsn == lsn && metadata.csn == csn)
            close(manager)
            return nothing
        end
        frame = fetch_page!(pool,UInt64(1))
        entries = Vector{Vector{UInt8}}()
        lock(frame.latch)
        try
            for slot in slotted_live_slots(frame.page)
                push!(entries,slotted_read(frame.page,slot))
            end
        finally
            unlock(frame.latch)
            unpin_page!(pool,frame)
        end
        for payload in entries
            entry = _page_store_decode_table(pool,db,payload)
            if entry === nothing
                close(manager)
                return nothing
            end
            haskey(store.tables,entry.name) && storageerror("Tabel catalog ARSP-4 duplikat.")
            store.tables[entry.name] = entry
        end
        if Set(keys(store.tables)) != Set(keys(db.tables))
            close(manager)
            return nothing
        end
        for entry in values(store.tables)
            _page_store_load_row_rids!(entry,pool;logical_table=db.tables[entry.name])
        end
        store.applied_file_id = copy(file_id)
        store.applied_lsn = lsn
        store.applied_csn = csn
        store.base_csn = csn
        store
    catch
        close(manager)
        rethrow()
    end
end

"""Open the page sidecar, rebuilding only a valid-but-stale version from WAL state."""
function _open_page_store_unregistered!(wal_path::String,db::Database,file_id::Vector{UInt8},lsn::UInt64,csn::UInt64;
                                         buffer_pages::Integer=64)
    path = page_store_path(wal_path)
    if !isfile(path)
        return _page_store_create(wal_path,db,file_id,lsn,csn;buffer_pages)
    end
    existing = _page_store_open_existing(wal_path,db,file_id,lsn,csn;buffer_pages)
    existing === nothing || return existing
    # A well-formed catalog with another WAL identity/LSN is an old derived
    # image, never user data. Rebuild it from the authoritative WAL recovery.
    try
        rm(path;force=true)
    catch error
        # A second Windows process may own the valid but stale derived image.
        # WAL remains authoritative, so this handle can safely use the logical
        # store until the owner closes. Corruption errors above are not caught.
        Sys.iswindows() && error isa Base.IOError && return nothing
        rethrow()
    end
    _page_store_create(wal_path,db,file_id,lsn,csn;buffer_pages)
end

"""Open the process-canonical WAL-derived page store for one database path."""
function open_page_store!(wal_path::String,db::Database,file_id::Vector{UInt8},lsn::UInt64,csn::UInt64;
                          buffer_pages::Integer=64)
    key = _page_store_registry_key(page_store_path(wal_path))
    lock(_PAGE_STORE_REGISTRY_LOCK) do
        existing = get(_PAGE_STORE_REGISTRY,key,nothing)
        if existing !== nothing && !(existing::PageStore).manager.closed
            page_store_synchronize!(existing::PageStore,db,file_id,lsn,csn)
            return existing::PageStore
        end
        existing === nothing || delete!(_PAGE_STORE_REGISTRY,key)
        store = _open_page_store_unregistered!(wal_path,db,file_id,lsn,csn;buffer_pages)
        store === nothing || (_PAGE_STORE_REGISTRY[key] = store)
        store
    end
end

function rebuild_page_store!(store::PageStore,db::Database,file_id::Vector{UInt8},lsn::UInt64,csn::UInt64)
    lock(store.mutex) do
        capacity = length(store.pool.frames)
        # Another process may have completed the physical P4 publication while
        # this handle was stale. Reopen and validate that durable image first;
        # deleting it is both unnecessary and invalid on Windows while the
        # writer still owns an open manager.
        close(store.manager) # Drop only this stale handle's dirty cache.
        fresh = _page_store_open_existing(store.wal_path,db,file_id,lsn,csn;buffer_pages=capacity)
        if fresh === nothing
            # WAL is authoritative. A sidecar that did not publish its catalog
            # cannot be trusted and is rebuilt only after our manager is closed.
            # If another live process still owns a stale file, surface a clear
            # storage error instead of silently writing around corruption.
            isfile(store.page_path) && rm(store.page_path;force=true)
            fresh = _page_store_create(store.wal_path,db,file_id,lsn,csn;buffer_pages=capacity)
        end
        store.manager = fresh.manager
        store.pool = fresh.pool
        store.catalog_page_id = fresh.catalog_page_id
        store.tables = fresh.tables
        store.applied_file_id = fresh.applied_file_id
        store.applied_lsn = fresh.applied_lsn
        store.applied_csn = fresh.applied_csn
        store.base_csn = fresh.base_csn
        store.scheduler = fresh.scheduler
        store.catalog_dirty = fresh.catalog_dirty
        store.rebuilds += UInt64(1)
        store
    end
end

function page_store_synchronize!(store::PageStore,db::Database,file_id::Vector{UInt8},lsn::UInt64,csn::UInt64)
    (store.applied_file_id == file_id && store.applied_lsn == lsn && store.applied_csn == csn) && return store
    rebuild_page_store!(store,db,file_id,lsn,csn)
end

function _page_store_failpoint(stage::String)
    get(ENV,"AIRESDB_PAGE_FAILPOINT","") == stage || return nothing
    storageerror("Injected ARSP-4 page failure: $stage")
end

function _page_store_end_version!(store::PageStore,entry::PageTableStore,rid::RID,csn::UInt64,lsn::UInt64)
    heap_end_version!(store.pool,rid,csn;page_lsn=lsn)
    nothing
end

function _page_store_apply_table_changes!(store::PageStore,before::Table,after::Table,
                                          stage::Table,csn::UInt64,lsn::UInt64)
    entry = get(store.tables,after.name,nothing)
    entry === nothing && storageerror("Mapping heap ARSP-4 untuk tabel '$(after.name)' hilang.")
    entry.schema_digest == _page_store_schema_digest(after.columns) ||
        storageerror("Schema heap ARSP-4 untuk tabel '$(after.name)' berubah tanpa DDL.")
    # A first bulk insert arrives after DDL has created an empty heap and empty
    # B+Trees.  Pack its final committed table once instead of repeatedly
    # splitting/re-encoding every index leaf per input row.
    if isempty(before.rows) && entry.heap.page_count == 0 && !isempty(after.rows)
        _page_store_fill_empty_table!(store,entry,after,csn,lsn)
        return nothing
    end
    # Delete every old index entry before inserting any new one. A transaction
    # may legally swap two unique/primary keys; row-at-a-time replacement would
    # otherwise see a transient duplicate after the WAL has already committed.
    changes = [(row_id=row_id,value=stage.changes[row_id],
                previous_position=get(before.positions,row_id,0)) for row_id in ordered_changes(stage)]
    length(entry.row_rids) == length(before.row_ids) ||
        storageerror("Direktori RID heap tidak sejajar dengan snapshot WAL.")
    for change in changes
        change.previous_position == 0 && continue
        change.previous_position <= length(entry.row_rids) ||
            storageerror("RID heap ARSP-4 untuk row tidak ditemukan.")
    end
    replacements = Tuple{Row,RID}[]
    deleted_positions = Int[]
    for change in changes
        row_id = change.row_id
        value = change.value
        previous_position = change.previous_position
        if previous_position == 0
            value === nothing && continue
            rid = heap_insert!(store.pool,entry.heap,copy(value);row_id,begin_csn=csn,
                end_csn=INFINITY_CSN,schema_epoch=csn,page_lsn=lsn)
            push!(entry.row_rids,rid)
            push!(replacements,(value,rid))
            continue
        end
        old_rid = entry.row_rids[previous_position]
        _page_store_end_version!(store,entry,old_rid,csn,lsn)
        if value === nothing
            heap_insert!(store.pool,entry.heap,Cell[];row_id,begin_csn=csn,end_csn=INFINITY_CSN,
                previous=old_rid,schema_epoch=csn,tombstone=true,page_lsn=lsn)
            push!(deleted_positions,previous_position)
        else
            # Replacement versions append to the heap. Preserve AiresQL's
            # historical visible row order with the bounded RID cursor only
            # after the first such divergence; append-only inserts remain a
            # true sequential heap scan.
            entry.requires_logical_order = true
            rid = heap_insert!(store.pool,entry.heap,copy(value);row_id,begin_csn=csn,
                end_csn=INFINITY_CSN,previous=old_rid,schema_epoch=csn,page_lsn=lsn)
            entry.row_rids[previous_position] = rid
            push!(replacements,(value,rid))
        end
    end
    isempty(deleted_positions) || deleteat!(entry.row_rids,sort!(unique!(deleted_positions)))
    length(entry.row_rids) == length(after.row_ids) ||
        storageerror("Direktori RID heap tidak cocok dengan hasil transaksi WAL.")
    # Index state is transaction-local while the store mutex is held.  Apply
    # the certified final key set once per leaf instead of rewriting the same
    # page for every changed row.
    for (spec,tree) in entry.indexes
        delete_keys = Vector{Vector{UInt8}}()
        insert_entries = Tuple{Vector{UInt8},RID}[]
        for change in changes
            change.previous_position == 0 && continue
            key = row_key(table_row(before,change.previous_position),spec)
            any(isnothing,key) || push!(delete_keys,btree_key(key))
        end
        for (row,rid) in replacements
            key = row_key(row,spec)
            any(isnothing,key) || push!(insert_entries,(btree_key(key),rid))
        end
        btree_apply_batch!(store.pool,tree,delete_keys,insert_entries;page_lsn=lsn)
    end
    nothing
end

function _page_store_apply_plan!(plan::_PageCommitPlan)
    store = plan.store
    set_wal_durable_lsn!(store.manager,plan.lsn)
    for name in sort!(collect(plan.tx.dirty))
        if name in plan.tx.ddl
            if haskey(plan.after.tables,name)
                store.tables[name] = _page_store_build_table!(store,plan.after.tables[name],plan.csn,plan.lsn)
            else
                delete!(store.tables,name)
            end
            continue
        end
        before = get(plan.before.tables,name,nothing)
        after = get(plan.after.tables,name,nothing)
        (before === nothing || after === nothing) && storageerror("Tabel ARSP-4 berubah tanpa DDL.")
        _page_store_apply_table_changes!(store,before,after,plan.tx.working.tables[name],plan.csn,plan.lsn)
    end
    _page_store_failpoint("before_catalog_publish")
    nothing
end

function _page_store_publish_plan!(plan::_PageCommitPlan)
    store = plan.store
    store.applied_file_id = copy(plan.file_id)
    store.applied_lsn = plan.lsn
    store.applied_csn = plan.csn
    store.catalog_dirty = true
    _page_store_failpoint("after_catalog_publish")
    nothing
end

const _PAGE_COMMIT_HANDLERS = StoragePhaseHandlers(
    (work,lane,scheduler)->phase_advance(),
    (work,lane,scheduler)->begin
        plan = work.context::_PageCommitPlan
        set_wal_durable_lsn!(plan.store.manager,plan.lsn)
        phase_advance()
    end,
    (work,lane,scheduler)->begin _page_store_apply_plan!(work.context::_PageCommitPlan); phase_advance() end,
    (work,lane,scheduler)->begin _page_store_publish_plan!(work.context::_PageCommitPlan); phase_complete() end,
)

"""Apply a WAL-durable transaction through P1/P2/P3/P4, then publish page LSN."""
function page_store_apply_commit!(store::PageStore,before::Database,after::Database,tx::TransactionState,
                                  csn::UInt64,lsn::UInt64,file_id::Vector{UInt8})
    lock(store.mutex) do
        plan = _PageCommitPlan(store,before,after,tx,csn,lsn,copy(file_id))
        work = StorageWorkUnit(StorageWrite,after.name,"";snapshot_csn=tx.snapshot_csn,
            transaction_id=tx.id,handlers=_PAGE_COMMIT_HANDLERS,context=plan)
        request_id = submit!(store.scheduler,work)
        run_until_complete!(store.scheduler,request_id)
        store
    end
end

const _PAGE_SCAN_HANDLERS = StoragePhaseHandlers(
    (work,lane,scheduler)->phase_advance(),
    (work,lane,scheduler)->begin
        cursor = work.context::PageStoreScanCursor
        page_id = _page_store_scan_next_page_id(cursor)
        page_id == 0 && return phase_advance()
        _page_store_acquire_page!(work,lane,scheduler,cursor.store.pool,page_id)
    end,
    (work,lane,scheduler)->begin
        cursor = work.context::PageStoreScanCursor
        phase_advance(_page_store_visible_batch!(cursor))
    end,
    (work,lane,scheduler)->phase_complete(work.result),
)

const _PAGE_INDEX_SCAN_HANDLERS = StoragePhaseHandlers(
    (work,lane,scheduler)->phase_advance(),
    (work,lane,scheduler)->begin
        cursor = work.context::PageStoreIndexCursor
        page_id = cursor.tree_cursor.page_id
        page_id == 0 && return phase_advance()
        _page_store_acquire_page!(work,lane,scheduler,cursor.store.pool,page_id)
    end,
    (work,lane,scheduler)->begin
        cursor = work.context::PageStoreIndexCursor
        entries = next_btree_batch!(cursor.tree_cursor;batch_size=256)
        entries === nothing && return phase_advance(nothing)
        rows = Row[]
        for (_,rid) in entries
            record = heap_record(cursor.store.pool,cursor.table.heap,rid)
            record_visible(record,cursor.snapshot_csn) || continue
            push!(rows,copy(something(record.values,Cell[])))
        end
        phase_advance(rows)
    end,
    (work,lane,scheduler)->phase_complete(work.result),
)

function _page_store_scan_next_page_id(cursor::PageStoreScanCursor)::UInt64
    cursor.logical_row_ids === nothing && return cursor.heap_cursor.page_id
    cursor.logical_position <= length(cursor.table.row_rids) || return UInt64(0)
    cursor.table.row_rids[cursor.logical_position].page_id
end

function _page_store_visible_batch!(cursor::PageStoreScanCursor)
    cursor.logical_row_ids === nothing && return heap_visible_batch(cursor.heap_cursor,cursor.snapshot_csn)
    rows = Vector{Tuple{RID,HeapRecord}}()
    order = cursor.logical_row_ids::Vector{UInt128}
    while length(rows) < cursor.heap_cursor.batch_size && cursor.logical_position <= length(order)
        cursor.logical_position <= length(cursor.table.row_rids) ||
            storageerror("Direktori RID heap lebih pendek dari urutan snapshot.")
        rid = cursor.table.row_rids[cursor.logical_position]
        cursor.logical_position += 1
        record = heap_record(cursor.store.pool,cursor.table.heap,rid)
        record_visible(record,cursor.snapshot_csn) && push!(rows,(rid,record))
    end
    isempty(rows) && cursor.logical_position > length(order) ? nothing : rows
end

function page_store_scan_cursor(store::PageStore,name::String,snapshot_csn::UInt64;
                                batch_size::Integer=256,row_ids::Union{Nothing,AbstractVector{UInt128}}=nothing)
    lock(store.mutex) do
        snapshot_csn >= store.base_csn || return nothing
        entry = get(store.tables,name,nothing)
        entry === nothing && return nothing
        order = row_ids === nothing || !entry.requires_logical_order ? nothing : Vector{UInt128}(row_ids)
        PageStoreScanCursor(store,entry,heap_batch_cursor(entry.heap,store.pool;batch_size),snapshot_csn,order,1)
    end
end

"""Fetch one bounded visible row batch through an ARSP-4 scan work unit."""
function next_page_store_batch!(cursor::PageStoreScanCursor)
    store = cursor.store
    lock(store.mutex) do
        work = StorageWorkUnit(StorageSequentialScan,"",cursor.table.name;snapshot_csn=cursor.snapshot_csn,
            handlers=_PAGE_SCAN_HANDLERS,context=cursor)
        request_id = submit!(store.scheduler,work)
        completed = run_until_complete!(store.scheduler,request_id)
        batch = completed.result
        batch === nothing && return nothing
        Row[copy(something(record.values,Cell[])) for (_,record) in batch]
    end
end

"""Open an index-backed ordered cursor when the latest snapshot can use it safely."""
function page_store_index_cursor(store::PageStore,table::Table,spec::Tuple,snapshot_csn::UInt64;
                                 reverse::Bool=false,lower=nothing,upper=nothing,
                                 lower_inclusive::Bool=true,upper_inclusive::Bool=true)
    lock(store.mutex) do
        snapshot_csn == store.applied_csn || return nothing
        all(index->!table.columns[index].nullable,spec) || return nothing
        entry = get(store.tables,table.name,nothing)
        entry === nothing && return nothing
        tree = get(entry.indexes,spec,nothing)
        tree === nothing && return nothing
        PageStoreIndexCursor(store,entry,btree_range_cursor(store.pool,tree;reverse,lower,upper,
            lower_inclusive,upper_inclusive),snapshot_csn)
    end
end

function next_page_store_index_batch!(cursor::PageStoreIndexCursor)
    store = cursor.store
    lock(store.mutex) do
        work = StorageWorkUnit(StorageIndex,"",cursor.table.name;snapshot_csn=cursor.snapshot_csn,
            handlers=_PAGE_INDEX_SCAN_HANDLERS,context=cursor)
        request_id = submit!(store.scheduler,work)
        completed = run_until_complete!(store.scheduler,request_id)
        completed.result
    end
end

function page_store_scan_rows(store::PageStore,name::String,snapshot_csn::UInt64;
                              batch_size::Integer=256,row_ids::Union{Nothing,AbstractVector{UInt128}}=nothing)
    cursor = page_store_scan_cursor(store,name,snapshot_csn;batch_size,row_ids)
    cursor === nothing && return nothing
    rows = Row[]
    while true
        batch = next_page_store_batch!(cursor)
        batch === nothing && break
        append!(rows,batch)
    end
    rows
end

function _page_store_lookup_direct!(plan::_PageLookupPlan)
    store = plan.store
    plan.snapshot_csn >= store.base_csn || return nothing
    entry = get(store.tables,plan.table.name,nothing)
    entry === nothing && return nothing
    spec = primary_spec(plan.table)
    tree = get(entry.indexes,spec,nothing)
    if tree !== nothing && plan.snapshot_csn == store.applied_csn
        rid = btree_lookup(store.pool,tree,plan.key)
        rid === nothing && return nothing
        record = heap_record(store.pool,entry.heap,rid)
        record_visible(record,plan.snapshot_csn) || return nothing
        plan.result = copy(something(record.values,Cell[]))
        plan.result_row_id = record.row_id
        plan.result_begin_csn = record.begin_csn
        return plan.result
    end
    cursor = heap_batch_cursor(entry.heap,store.pool;batch_size=256)
    while true
        batch = heap_visible_batch(cursor,plan.snapshot_csn)
        batch === nothing && return nothing
        for (_,record) in batch
            values = something(record.values,Cell[])
            row_key(values,spec) == plan.key || continue
            plan.result = copy(values)
            plan.result_row_id = record.row_id
            plan.result_begin_csn = record.begin_csn
            return plan.result
        end
    end
end

const _PAGE_LOOKUP_HANDLERS = StoragePhaseHandlers(
    (work,lane,scheduler)->phase_advance(),
    (work,lane,scheduler)->begin
        plan = work.context::_PageLookupPlan
        entry = get(plan.store.tables,plan.table.name,nothing)
        entry === nothing && return phase_complete()
        tree = get(entry.indexes,primary_spec(plan.table),nothing)
        page_id = tree === nothing ? entry.heap.first_page_id : tree.root_page_id
        page_id == 0 && return phase_advance()
        _page_store_acquire_page!(work,lane,scheduler,plan.store.pool,page_id)
    end,
    (work,lane,scheduler)->begin _page_store_lookup_direct!(work.context::_PageLookupPlan); phase_advance() end,
    (work,lane,scheduler)->phase_complete((work.context::_PageLookupPlan).result),
)

function page_store_lookup(store::PageStore,table::Table,key::Tuple,snapshot_csn::UInt64)
    lock(store.mutex) do
        plan = _PageLookupPlan(store,table,key,snapshot_csn,nothing,UInt128(0),UInt64(0))
        work = StorageWorkUnit(StoragePointLookup,"",table.name;snapshot_csn,
            handlers=_PAGE_LOOKUP_HANDLERS,context=plan)
        request_id = submit!(store.scheduler,work)
        completed = run_until_complete!(store.scheduler,request_id)
        completed.result
    end
end

"""Lookup a row and its MVCC identity through the persistent primary-key tree.

The identity is needed by serializable certification. Keeping it in the same
PageStore request avoids a second logical scan of a large table merely to
register the read.
"""
function page_store_lookup_identity(store::PageStore,table::Table,key::Tuple,snapshot_csn::UInt64)
    lock(store.mutex) do
        plan = _PageLookupPlan(store,table,key,snapshot_csn,nothing,UInt128(0),UInt64(0))
        work = StorageWorkUnit(StoragePointLookup,"",table.name;snapshot_csn,
            handlers=_PAGE_LOOKUP_HANDLERS,context=plan)
        request_id = submit!(store.scheduler,work)
        completed = run_until_complete!(store.scheduler,request_id)
        completed.result === nothing && return nothing
        (row=completed.result,row_id=plan.result_row_id,begin_csn=plan.result_begin_csn)
    end
end

function page_store_stats(store::PageStore)
    lock(store.mutex) do
        (page_path=store.page_path,applied_lsn=store.applied_lsn,applied_csn=store.applied_csn,
         base_csn=store.base_csn,tables=length(store.tables),rebuilds=store.rebuilds,
         catalog_dirty=store.catalog_dirty,
         page_manager=page_manager_stats(store.manager),buffer_pool=buffer_pool_stats(store.pool),
         pipeline=pipeline_stats(store.scheduler))
    end
end

function close_page_store!(store::PageStore)
    key = _page_store_registry_key(store.page_path)
    # Closing while holding the registry lock prevents a simultaneous opener
    # from racing a Windows file handle that has not reached `close` yet.
    lock(_PAGE_STORE_REGISTRY_LOCK) do
        lock(store.mutex) do
            if !store.manager.closed
                if store.catalog_dirty
                    # Data/index pages must be durable before the catalog
                    # advertises their LSN. One file sync also covers dirty
                    # frames previously written by Clock eviction.
                    flush_all!(store.pool;sync=true)
                    _page_store_write_catalog!(store,store.applied_file_id,
                        store.applied_lsn,store.applied_csn)
                    flush_all!(store.pool;sync=true)
                    store.catalog_dirty = false
                end
                close(store.pool)
            end
        end
        get(_PAGE_STORE_REGISTRY,key,nothing) === store && delete!(_PAGE_STORE_REGISTRY,key)
    end
    nothing
end

"""Close process-local page stores rooted below `root`; used by controlled hosts/tests."""
function _close_page_stores_under!(root::AbstractString)
    target = normpath(abspath(String(root)))
    prefix = endswith(target,string(Base.Filesystem.path_separator)) ? target : target * string(Base.Filesystem.path_separator)
    stores = lock(_PAGE_STORE_REGISTRY_LOCK) do
        PageStore[store for store in values(_PAGE_STORE_REGISTRY)
                  if store.wal_path == target || startswith(normpath(abspath(store.wal_path)),prefix)]
    end
    for store in unique(stores)
        close_page_store!(store)
    end
    nothing
end
