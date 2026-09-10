# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

mutable struct Session
    root::String
    storage::AbstractStorage
    database::Union{Nothing,Database}
    path::Union{Nothing,String}
    revision::UInt64
    staging::Union{Nothing,Database}
    debug::Bool
    mutex::ReentrantLock
    engine::Engine
    handle::Union{Nothing,DatabaseHandle}
    transaction::Union{Nothing,TransactionState}
    closed::Bool
end
function Session(engine::Engine;storage::AbstractStorage=BinaryRowStore(),debug::Bool=false)
    lock(engine.mutex) do
        engine.active_sessions += 1
    end
    Session(engine.root,storage,nothing,nothing,0,nothing,debug,ReentrantLock(),engine,nothing,nothing,false)
end
Session(root::AbstractString=pwd();kwargs...) = Session(Engine(root);kwargs...)
in_transaction(session::Session) = session.transaction !== nothing
function active_database(session::Session)
    session.database === nothing && fail("Belum ada database aktif. Gunakan Buat atau Pilih.")
    something(session.staging,session.database)
end

function read_handle(store::BinaryRowStore,path::String;retain_replayed_history::Bool=false)
    receipt = wal_read_locked(path)
    isempty(receipt.records) && storageerror("Checkpoint WAL tidak ditemukan.")
    io = IOBuffer(first(receipt.records).payload)
    get_u8(io) == 1 || storageerror("Record pertama bukan checkpoint.")
    db,csn,epochs,schemas,catalog = checkpoint_decode(store,io)
    wal_stat = stat(path)
    handle = DatabaseHandle(path,db,csn,receipt.lsn,receipt.end_offset,receipt.file_id,
        UInt64(wal_stat.device),UInt64(wal_stat.inode),epochs,schemas,catalog,
        initialize_histories(db),Dict{UUID,UInt64}(),ReentrantLock(),false,nothing)
    for record in receipt.records[2:end]
        io = IOBuffer(record.payload)
        get_u8(io) == 2 || storageerror("Record perubahan WAL tidak valid.")
        apply_delta!(handle,store,io)
    end
    validate_database(handle.current)
    retain_replayed_history || collect_versions!(handle)
    handle
end

_copy_chain(chain) = RowVersion[RowVersion(v.begin_csn,v.end_csn,v.values) for v in chain]
function copy_histories(histories)
    Dict(name=>Dict(id=>_copy_chain(chain) for (id,chain) in versions)
         for (name,versions) in histories)
end

"""Merge only versions newer than the receiving chain's head.

Checkpoint reloads can describe a prefix already retained for an older pinned
snapshot.  Appending that prefix again creates zero-length duplicate versions.
"""
function merge_history_suffixes!(target,source)
    for (name,versions) in source
        destination = get!(target,name,Dict{UInt128,Vector{RowVersion}}())
        for (id,chain) in versions
            existing = get(destination,id,nothing)
            if existing === nothing || isempty(existing)
                destination[id] = _copy_chain(chain)
                continue
            end
            cutoff = last(existing).begin_csn
            firstnew = findfirst(v->v.begin_csn > cutoff,chain)
            firstnew === nothing && continue
            suffix = chain[firstnew:end]
            last(existing).end_csn = first(suffix).begin_csn
            append!(existing,_copy_chain(suffix))
        end
    end
    target
end

function refresh_locked!(handle::DatabaseHandle,store::BinaryRowStore)
    wal_stat = stat(handle.path)
    wal_stat.size <= store.max_bytes || storageerror("WAL melebihi batas storage; gunakan kapasitas lebih besar atau checkpoint.")
    wal_device = UInt64(wal_stat.device)
    wal_inode = UInt64(wal_stat.inode)
    if !handle.poisoned && Int64(wal_stat.size) == handle.offset &&
       wal_device == handle.wal_device && wal_inode == handle.wal_inode
        state = _wal_require_locked(handle.path)
        state.receipt = WALReceipt(copy(handle.file_id),handle.lsn,handle.offset,handle.offset,
            wal_device,wal_inode)
        state.receipt_epoch = state.epoch
        if handle.page_store !== nothing && (handle.page_store::PageStore).manager.closed
            handle.page_store = nothing
        end
        return nothing
    end
    identity = _wal_file_id(handle.path)
    if handle.poisoned || identity != handle.file_id
        # The receiving handle may own a snapshot older than the replacement
        # checkpoint.  Keep replayed deltas until their chains are merged with
        # that snapshot's history and normal vacuum can apply its horizon.
        replacement = read_handle(store,handle.path;retain_replayed_history=true)
        old_database = handle.current
        histories = copy_histories(handle.histories)
        merge_history_suffixes!(histories,replacement.histories)
        for (name,table) in old_database.tables, id in table.row_ids
            current = get(replacement.current.tables,name,nothing)
            old_position = table.positions[id]
            current_position = current === nothing ? 0 : get(current.positions,id,0)
            replacement_stamp = current_position == 0 ? replacement.csn : table_stamp(current,current_position)
            table_stamp(table,old_position) == replacement_stamp && current_position != 0 && continue
            chain = get!(get!(histories,name,Dict{UInt128,Vector{RowVersion}}()),id,RowVersion[])
            # Incremental WAL replay in `replacement` may already have built
            # the exact transition represented by the old/current stamps.
            !isempty(chain) && last(chain).begin_csn == replacement_stamp && continue
            if isempty(chain)
                push!(chain,RowVersion(table_stamp(table,old_position),replacement_stamp,table_row(table,old_position)))
            elseif last(chain).values !== nothing
                last(chain).end_csn = replacement_stamp
            end
            if current_position == 0
                last(chain).values === nothing ||
                    push!(chain,RowVersion(replacement_stamp,INFINITY_CSN,nothing))
            elseif last(chain).begin_csn < replacement_stamp
                    push!(chain,RowVersion(replacement_stamp,INFINITY_CSN,table_row(current,current_position)))
            end
        end
        handle.current = replacement.current; handle.csn = replacement.csn
        handle.lsn = replacement.lsn; handle.offset = replacement.offset; handle.file_id = replacement.file_id
        handle.wal_device = replacement.wal_device; handle.wal_inode = replacement.wal_inode
        handle.epochs = replacement.epochs; handle.schema_epochs = replacement.schema_epochs
        handle.catalog_epoch = replacement.catalog_epoch; handle.histories = histories
        handle.poisoned = false
        if handle.page_store !== nothing && (handle.page_store::PageStore).manager.closed
            handle.page_store = nothing
        end
        return
    end
    receipt = wal_read_locked(handle.path;from_offset=handle.offset)
    if !isempty(receipt.records)
        # Validate/replay the complete batch against a shadow handle first.  A
        # corrupt later record must not leave the shared handle half advanced.
        shadow = DatabaseHandle(handle.path,handle.current,handle.csn,handle.lsn,handle.offset,
            handle.file_id,handle.wal_device,handle.wal_inode,copy(handle.epochs),copy(handle.schema_epochs),handle.catalog_epoch,
            Dict{String,Dict{UInt128,Vector{RowVersion}}}(),Dict{UUID,UInt64}(),ReentrantLock(),false,nothing)
        try
            for record in receipt.records
                io = IOBuffer(record.payload)
                get_u8(io) == 2 || storageerror("Jenis record perubahan tidak valid.")
                apply_delta!(shadow,store,io)
            end
        catch
            handle.poisoned = true
            rethrow()
        end
        histories = copy_histories(handle.histories)
        merge_history_suffixes!(histories,shadow.histories)
        handle.current = shadow.current; handle.csn = shadow.csn
        handle.epochs = shadow.epochs; handle.schema_epochs = shadow.schema_epochs
        handle.catalog_epoch = shadow.catalog_epoch; handle.histories = histories
    end
    handle.lsn = receipt.lsn; handle.offset = receipt.end_offset
    if handle.page_store !== nothing && (handle.page_store::PageStore).manager.closed
        handle.page_store = nothing
    end
end

"""Refresh only when the durable WAL identity or physical length changed.

Observing the old pair while another process starts publishing is safe: the
snapshot linearizes immediately before that publication, and commit performs
the normal locked refresh plus serializable certification. A changed/torn file
always takes the full locked validation path.
"""
function refresh_snapshot!(handle::DatabaseHandle,store::BinaryRowStore)
    current = !handle.poisoned && try
        wal_stat = stat(handle.path)
        wal_stat.size == handle.offset && UInt64(wal_stat.device) == handle.wal_device &&
            UInt64(wal_stat.inode) == handle.wal_inode
    catch
        false
    end
    current && return nothing
    with_wal_lock(handle.path) do
        refresh_locked!(handle,store)
    end
end

function migrate_legacy_locked!(store::BinaryRowStore,path::String)
    detect_wal(path) && return
    db,_ = load_database(store,path)
    for table in values(db.tables); initialize_table!(table,UInt64(1)); end
    epochs = Dict(name=>UInt64(1) for name in keys(db.tables))
    temporary = joinpath(dirname(path),"."*basename(path)*".migration."*string(uuid4())*".aires")
    try
        wal_create(temporary,checkpoint_payload(store,db,UInt64(1),epochs,epochs,UInt64(1)))
        durable_replace(temporary,path)
    finally
        isfile(temporary) && rm(temporary)
        # wal_create locks its temporary publication name too.  Once it has
        # returned, that private lock identity can never be observed by a DB
        # user and must not accumulate beside the authoritative database.
        isfile(temporary*".lock") && rm(temporary*".lock")
        _wal_forget_private!(temporary)
    end
end

function open_database!(session::Session,raw::String;create::Bool=false)
    in_transaction(session) && fail("Tidak dapat membuat atau mengganti database selama transaksi.")
    name = database_name(raw); path = joinpath(session.root,name*".aires")
    key = Sys.iswindows() ? lowercase(path) : path
    handle = lock(session.engine.mutex) do
        existing = create ? nothing : get(session.engine.handles,key,nothing)
        if existing !== nothing
            # Reuse the shared snapshot directly.  The old path replayed the
            # complete WAL into a temporary handle and then discarded it before
            # refreshing this already registered handle.
            lock(existing.mutex) do
                with_wal_lock(path) do
                    refresh_locked!(existing,session.storage)
                end
            end
            existing
        else
            fresh = with_wal_lock(path) do
                if create
                    db = Database(name)
                    wal_create(path,checkpoint_payload(session.storage,db,UInt64(1),Dict{String,UInt64}(),Dict{String,UInt64}(),UInt64(1)))
                else
                    isfile(path) || storageerror("File '$name.aires' tidak ditemukan.")
                    migrate_legacy_locked!(session.storage,path)
                end
                filesize(path) <= session.storage.max_bytes || storageerror("File melebihi batas ukuran storage.")
                read_handle(session.storage,path)
            end
            session.engine.handles[key] = fresh
            fresh
        end
    end
    # The `.pages` file is a WAL-derived image, so it is opened only after the
    # shared handle has been selected and while the database WAL lock is held.
    lock(handle.mutex) do
        with_wal_lock(path) do
            refresh_locked!(handle,session.storage)
            (handle.page_store === nothing || (handle.page_store::PageStore).manager.closed) && (handle.page_store = open_page_store!(handle.path,handle.current,
                handle.file_id,handle.lsn,handle.csn))
        end
    end
    session.handle = handle; session.path = path; session.database = handle.current; session.revision = handle.csn
    status_result(create ? "Database '$name.aires' dibuat dan dipilih." : "Database '$name.aires' dipilih.")
end

function _begin_transaction!(session::Session;physical_reads::Bool=false)
    lock(session.mutex) do
        active_database(session)
        in_transaction(session) && fail("Transaksi bersarang tidak didukung.")
        handle = session.handle::DatabaseHandle
        lock(handle.mutex) do
            refresh_snapshot!(handle,session.storage)
            stage = copy_database(handle.current)
            tx = TransactionState(uuid4(),handle.current,stage,handle.csn,copy(handle.epochs),copy(handle.schema_epochs),
                handle.catalog_epoch,Dict{String,UInt64}(),Dict{Tuple{String,Tuple},Tuple{UInt128,UInt64}}(),
                Set{String}(),Set{String}(),false,false,physical_reads)
            handle.snapshots[tx.id] = tx.snapshot_csn
            session.database = handle.current; session.revision = handle.csn
            session.staging = stage; session.transaction = tx
        end
        status_result("Transaksi MVCC serializable dimulai.")
    end
end
begin_transaction!(session::Session) = _begin_transaction!(session;physical_reads=false)

function record_read!(session::Session,name::String)
    tx = session.transaction
    tx === nothing && fail("Pembacaan internal membutuhkan snapshot aktif.")
    tx.scans[name] = get(tx.epochs,name,UInt64(0))
    nothing
end

"""Consume a stable current page-store snapshot while holding the WAL lock.

The `.aires.pages` sidecar is a WAL-derived current image shared by processes,
not an independently versioned MVCC store.  A reader therefore validates the
logical snapshot and consumes the physical rows under the same OS lock that
excludes external page publication.  An older pinned transaction deliberately
falls back to its logical MVCC snapshot instead of reading a newer sidecar.
"""
function with_page_store_snapshot(f::Function,session::Session,name::String)
    tx = session.transaction
    # A page snapshot is safe for an explicit transaction only while its CSN
    # is still the handle's current CSN; the equality check below rejects a
    # sidecar that advanced after BEGIN. `physical_reads` controls publication
    # policy, not whether this exact snapshot may use its read index.
    (tx === nothing || name in tx.dirty) && return f(nothing)
    handle = session.handle::DatabaseHandle
    lock(handle.mutex) do
        with_wal_lock(handle.path) do
            refresh_locked!(handle,session.storage)
            physical = nothing
            if tx.snapshot_csn == handle.csn
                if handle.page_store === nothing || (handle.page_store::PageStore).manager.closed
                    handle.page_store = open_page_store!(handle.path,handle.current,handle.file_id,handle.lsn,handle.csn)
                elseif tx.snapshot_csn == handle.csn
                    page_store_synchronize!(handle.page_store::PageStore,handle.current,
                        handle.file_id,handle.lsn,handle.csn)
                end
                store = handle.page_store
                if store !== nothing
                    concrete = store::PageStore
                    if tx.snapshot_csn == concrete.applied_csn && haskey(concrete.tables,name)
                        physical = (concrete,tx.snapshot_csn)
                    end
                end
            end
            f(physical)
        end
    end
end
function session_indexed_row(session::Session,name::String,table::Table,key::Tuple)
    with_page_store_snapshot(session,name) do physical
        physical === nothing && return indexed_row(table,key)
        typed = typed_primary_key(table,key)
        info = page_store_lookup_identity(physical[1],table,typed,physical[2])
        info === nothing ? (UInt128(0),typed) : (info.row_id,typed)
    end
end

function record_key!(session::Session,name::String,key::Tuple;identity=nothing)
    tx = session.transaction::TransactionState
    # A DDL replacement is certified as a whole table/catalog change.  Its key
    # domain may differ from the snapshot table (DROP + CREATE in one txn), so
    # attempting to coerce against the old primary key would be both redundant
    # and semantically wrong.
    name in tx.ddl && return nothing
    base = get(tx.snapshot.tables,name,nothing)
    if identity === nothing
        id,typed = base === nothing ? (UInt128(0),key) : indexed_row(base,key)
            stamp = id == 0 ? UInt64(0) : table_stamp(base,base.positions[id])
    else
        id,typed,stamp = identity
    end
    tx.keys[(name,typed)] = (id,stamp)
    nothing
end

function certify!(handle::DatabaseHandle,tx::TransactionState)
    (tx.catalog_dirty || tx.catalog_read) && handle.catalog_epoch != tx.catalog_epoch && transaction_conflict("Catalog berubah sejak snapshot dimulai; ulangi transaksi.")
    for (name,epoch) in tx.scans
        get(handle.epochs,name,UInt64(0)) == epoch || transaction_conflict("Predicate/table '$name' berubah sejak snapshot; ulangi transaksi.")
    end
    for ((name,key),expected) in tx.keys
        current = get(handle.current.tables,name,nothing)
        current === nothing && transaction_conflict("Tabel '$name' dihapus selama transaksi.")
        get(handle.schema_epochs,name,UInt64(0)) == get(tx.schema_epochs,name,UInt64(0)) || transaction_conflict("Schema '$name' berubah.")
        # Published table objects are immutable. Identity proves every key and
        # row stamp is still the exact snapshot observed by this transaction,
        # avoiding redundant logical-index probes when there was no contender.
        current === get(tx.snapshot.tables,name,nothing) && continue
        if name in tx.dirty && !(name in tx.ddl)
            written = tx.working.tables[name].changes
            expected[1] != 0 && haskey(written,expected[1]) && continue
        end
        id,_ = indexed_row(current,key)
        actual = (id,id == 0 ? UInt64(0) : table_stamp(current,current.positions[id]))
        actual == expected || transaction_conflict("Primary Key $key pada '$name' berubah sejak snapshot.")
    end
    for name in tx.dirty
        get(handle.schema_epochs,name,UInt64(0)) == get(tx.schema_epochs,name,UInt64(0)) || transaction_conflict("Schema '$name' berubah sejak snapshot.")
        name in tx.ddl && continue
        base = tx.snapshot.tables[name]; current = get(handle.current.tables,name,nothing)
        current === nothing && transaction_conflict("Tabel '$name' telah dihapus.")
        for id in keys(tx.working.tables[name].changes)
            oldpos = get(base.positions,id,0); pos = get(current.positions,id,0)
            oldstamp = oldpos == 0 ? UInt64(0) : table_stamp(base,oldpos)
            stamp = pos == 0 ? UInt64(0) : table_stamp(current,pos)
            oldstamp == stamp || transaction_conflict("Row yang ditulis telah berubah; first committer wins.")
        end
        base.next_ids == tx.working.tables[name].next_ids || current.next_ids == base.next_ids || transaction_conflict("Sequence Auto_ berubah sejak snapshot.")
    end
end

function merge_transaction(handle::DatabaseHandle,tx::TransactionState,csn::UInt64)
    db = copy_database(handle.current)
    for name in tx.dirty
        if name in tx.ddl
            if haskey(tx.working.tables,name)
                table = copy_table(tx.working.tables[name]); fill!(table.row_stamps,csn)
                validate_table(table); build_indexes!(table); db.tables[name] = table
            else
                delete!(db.tables,name)
            end
            continue
        end
        before = handle.current.tables[name]; base = tx.snapshot.tables[name]; stage = tx.working.tables[name]
        if before === base
            # Certification proved that this exact table snapshot is still
            # current.  The private transaction table can therefore become the
            # committed table directly instead of cloning its rows, positions,
            # and every logical index a second time.  It is no longer exposed
            # to rollback after the WAL durability point.
            for id in keys(stage.changes)
                position = get(stage.positions,id,0)
                if position != 0
                    if stage.shared_fields & TABLE_SHARED_ROW_STAMPS != 0
                        stage.row_stamp_overrides[position] = csn
                    else
                        stage.row_stamps[position] = csn
                    end
                end
            end
            db.tables[name] = stage
            continue
        end
        table = copy_table(before); deletions = Int[]
        for id in ordered_changes(stage)
            value = stage.changes[id]
            pos = get(table.positions,id,0)
            if value === nothing
                pos == 0 || push!(deletions,pos)
            elseif pos == 0
                append_row!(table,value;id,stamp=csn)
            else
                set_row!(table,pos,value); table.row_stamps[pos] = csn
            end
        end
        remove_rows!(table,deletions)
        stage.next_ids == base.next_ids || (table.next_ids = copy(stage.next_ids))
        validate_changes!(table,before)
        db.tables[name] = table
    end
    tx.catalog_dirty && (db.views = copy(tx.working.views))
    if tx.catalog_dirty || !isempty(tx.ddl)
        for (name,view) in db.views; validate_query(db,view.query,Set([name])); end
    end
    db
end

function finish_transaction!(session::Session)
    tx = session.transaction
    if tx !== nothing
        handle = session.handle::DatabaseHandle
        lock(handle.mutex) do; delete!(handle.snapshots,tx.id); end
    end
    session.transaction = nothing; session.staging = nothing
    nothing
end
function rollback!(session::Session)
    lock(session.mutex) do
        in_transaction(session) || fail("Tidak ada transaksi aktif.")
        finish_transaction!(session)
        status_result("Transaksi dikembalikan.")
    end
end

function commit!(session::Session)
    lock(session.mutex) do
        tx = session.transaction
        tx === nothing && fail("Tidak ada transaksi aktif.")
        handle = session.handle::DatabaseHandle
        # Normalize net no-op DDL before certifying or encoding the transaction.
        for name in collect(tx.ddl)
            if !haskey(tx.snapshot.tables,name) && !haskey(tx.working.tables,name)
                delete!(tx.ddl,name); delete!(tx.dirty,name)
            end
        end
        if isempty(tx.dirty) && !tx.catalog_dirty
            finish_transaction!(session)
            return status_result("Snapshot baca selesai.")
        end
        # Allocate the acknowledgement before crossing the durable write point.
        acknowledgement = status_result("Transaksi digabungkan; durability barrier OS selesai.")
        uncertain = false
        durable = false
        try
            lock(handle.mutex) do
                with_wal_lock(handle.path) do
                    refresh_locked!(handle,session.storage)
                    certify!(handle,tx)
                    handle.csn < typemax(UInt64)-1 || storageerror("Nomor commit MVCC habis.")
                    csn = handle.csn+UInt64(1); catalog = tx.catalog_dirty || !isempty(tx.ddl) ? csn : handle.catalog_epoch
                    db = merge_transaction(handle,tx,csn)
                    large_initial_bulk = any(name->begin
                        name in tx.ddl && return false
                        isempty(handle.current.tables[name].rows) &&
                            length(tx.working.tables[name].rows) > LOGICAL_INDEX_ROW_LIMIT
                    end,tx.dirty)
                    # Validation of a large transaction may leave temporary
                    # sort/coercion pools. Reclaim them before the atomic WAL
                    # payload begins growing so the two phases do not overlap.
                    large_initial_bulk && GC.gc(true)
                    bytes = delta_payload(session.storage,handle,db,tx,csn,catalog)
                    filesize(handle.path)+length(bytes)+WAL_RECORD_HEADER_SIZE+WAL_COMMIT_SIZE <= session.storage.max_bytes || storageerror("WAL penuh; checkpoint atau tambah batas storage sebelum retry.")
                    # GC is maintenance, so perform it before the point after
                    # which every escaping failure must carry unknown outcome.
                    csn % 128 == 0 && collect_versions!(handle)
                    handle.poisoned = true
                    lsn = try
                        wal_append_locked(handle.path,handle.lsn,bytes;cache_handle=true)
                    catch e
                        e isa WALCommitUnknown && (uncertain = true)
                        rethrow()
                    end
                    durable = true
                    # A large initial table load has no old versions to retain,
                    # and its PageStore fast path consumes the final rows rather
                    # than the per-row mutation map. Once WAL is durable, drop
                    # both transient representations before allocating RID and
                    # B+Tree state. This prevents three 250k-row forms from
                    # overlapping at the publication peak.
                    released_large_bulk = false
                    for name in tx.dirty
                        name in tx.ddl && continue
                        before_table = handle.current.tables[name]
                        stage_table = tx.working.tables[name]
                        if isempty(before_table.rows) && length(stage_table.rows) > LOGICAL_INDEX_ROW_LIMIT
                            stage_table.changes = Dict{UInt128,Union{Nothing,Row}}()
                            stage_table.statement_changes = UInt128[]
                            released_large_bulk = true
                        end
                    end
                    if released_large_bulk
                        bytes = UInt8[]
                        GC.gc(true)
                    end
                    # Keep the derived sidecar at the same CSN as the WAL for
                    # every committed transaction.  Deferring this step for an
                    # explicit transaction made its next read rebuild every
                    # heap/index page even though the commit already had the
                    # certified delta in hand.  A multi-statement transaction
                    # still pays one physical apply for the whole commit.
                    if handle.page_store === nothing || (handle.page_store::PageStore).manager.closed
                        handle.page_store = open_page_store!(handle.path,handle.current,handle.file_id,
                            handle.lsn,handle.csn)
                    else
                        page_store_synchronize!(handle.page_store::PageStore,handle.current,
                            handle.file_id,handle.lsn,handle.csn)
                    end
                    handle.page_store === nothing || page_store_apply_commit!(handle.page_store::PageStore,
                        handle.current,db,tx,csn,lsn,handle.file_id)
                    publish_versions!(handle,db,tx.dirty,tx.ddl,csn,catalog;
                        change_tables=tx.working.tables)
                    handle.lsn = lsn; handle.offset = filesize(handle.path); handle.poisoned = false
                    session.database = handle.current; session.revision = handle.csn
                    finish_transaction!(session)
                end
            end
        catch e
            if e isa WALCommitUnknown || uncertain || durable
                handle.poisoned = true
                try
                    in_transaction(session) && finish_transaction!(session)
                catch
                    # Recovery is forced below; transaction state must never be
                    # reused after a write with an uncertain acknowledgement.
                    session.transaction = nothing; session.staging = nothing
                end
                throw(AiresError("Commit Outcome Unknown","Status commit belum pasti setelah kegagalan I/O. Pilih ulang database dan periksa data sebelum mengulang transaksi."))
            end
            rethrow()
        end
        acknowledgement
    end
end

"""Yield and back off after an optimistic certification conflict.

`yield()` alone lets independently started processes re-enter the same
read-modify-write window in lockstep.  The short capped pause with a clock
phase breaks that livelock without affecting uncontended transactions or
weakening first-committer-wins certification.
"""
function _transaction_conflict_backoff!(attempt::Int)
    yield()
    exponent = min(attempt, 5)
    base_seconds = 0.0005 * (1 << exponent)
    phase = Float64(mod(UInt64(time_ns()), UInt64(257))) / 257.0
    sleep(base_seconds * (1.0 + phase))
    nothing
end

function _run_transaction_attempt!(f::Function,session::Session)
    _begin_transaction!(session;physical_reads=true)
    result = f()
    commit!(session)
    result
end

function with_transaction(f::Function,session::Session;retries::Int=0)
    lock(session.mutex) do
        in_transaction(session) && return f()
        for attempt in 0:retries
            try
                result = if attempt == 0
                    _run_transaction_attempt!(f,session)
                else
                    # A transaction that already lost optimistic certification
                    # gets one serialized retry attempt.  The existing WAL
                    # lock is re-entrant in this task, so begin/commit retain
                    # their normal refresh, certification, and durability
                    # paths while competing retry callers cannot livelock.
                    handle = session.handle::DatabaseHandle
                    with_wal_lock(handle.path) do
                        _run_transaction_attempt!(f,session)
                    end
                end
                return result
            catch e
                in_transaction(session) && rollback!(session)
                if e isa AiresError && e.category == "Transaction Conflict" && attempt < retries
                    _transaction_conflict_backoff!(attempt)
                    continue
                end
                rethrow()
            end
        end
    end
end
with_snapshot(f::Function,session::Session) = with_transaction(f,session)

function mutate_tables!(f::Function,session::Session,names::Vector{String};ddl::Bool=false,catalog::Bool=false)
    with_transaction(session) do
        tx = session.transaction::TransactionState
        before = tx.working; candidate = copy_database(before)
        for name in names
            haskey(before.tables,name) && (candidate.tables[name] = copy_table_for_mutation(before.tables[name]))
        end
        result = f(candidate)
        if ddl || catalog
            validate_database(candidate)
            for name in names; haskey(candidate.tables,name) && build_indexes!(candidate.tables[name]); end
        else
            store = nothing
            tx_snapshot = tx.snapshot_csn
            if session.handle !== nothing
                candidate_store = (session.handle::DatabaseHandle).page_store
                if candidate_store !== nothing && !candidate_store.manager.closed &&
                    candidate_store.applied_csn == tx_snapshot
                    store = candidate_store
                end
            end
            if store === nothing
                for name in names
                    validate_changes!(candidate.tables[name],before.tables[name];snapshot_csn=tx_snapshot)
                end
            else
                lock(store.mutex) do
                    for name in names
                        validate_changes!(candidate.tables[name],before.tables[name];
                            physical_store=store,snapshot_csn=tx_snapshot)
                    end
                end
            end
        end
        tx.working = candidate; session.staging = candidate
        union!(tx.dirty,names); ddl && union!(tx.ddl,names)
        tx.catalog_dirty |= catalog || ddl
        result
    end
end

function record_query_reads!(session::Session,q::SelectQuery,seen=Set{String}())
    db = active_database(session)
    for name in q.sources
        name in seen && continue
        push!(seen,name)
        if haskey(db.tables,name); record_read!(session,name)
        elseif haskey(db.views,name); record_query_reads!(session,db.views[name].query,seen)
        end
    end
end

function mutate!(f::Function,session::Session,stmt::Statement)
    with_transaction(session) do
        ddl = stmt isa Union{CreateTable,AddColumn,RemoveColumn,DropTable}
        names = stmt isa CreateView ? String[] : [stmt isa CreateTable ? stmt.name : stmt.table]
        if stmt isa CreateView
            record_query_reads!(session,stmt.query)
        elseif ddl || stmt isa Union{UpdateRows,DeleteRows}
            for name in names; record_read!(session,name); end
        elseif stmt isa InsertRows
            table = get_table(active_database(session),stmt.table)
            any(c->c.auto,table.columns) && record_read!(session,stmt.table)
        end
        mutate_tables!(f,session,names;ddl,catalog=stmt isa CreateView)
    end
end

function execute_transaction!(session::Session,command::TransactionCommand)
    command.action == :begin && return begin_transaction!(session)
    command.action == :commit && return commit!(session)
    command.action == :rollback && return rollback!(session)
    fail("Perintah transaksi tidak dikenal.")
end

function checkpoint!(session::Session)
    lock(session.mutex) do
        active_database(session)
        in_transaction(session) && fail("Checkpoint tidak boleh dijalankan dalam transaksi.")
        handle = session.handle::DatabaseHandle
        lock(handle.mutex) do
            with_wal_lock(handle.path) do
                refresh_locked!(handle,session.storage)
                payload = checkpoint_payload(session.storage,handle.current,handle.csn,handle.epochs,handle.schema_epochs,handle.catalog_epoch)
                temporary = joinpath(dirname(handle.path),"."*basename(handle.path)*".checkpoint."*string(uuid4())*".aires")
                try
                    wal_create(temporary,payload)
                    # If publication succeeds but the following call reports an
                    # error, force the next operation through full recovery.
                    handle.poisoned = true
                    durable_replace(temporary,handle.path)
                    refresh_locked!(handle,session.storage)
                finally
                    isfile(temporary) && rm(temporary)
                    isfile(temporary*".lock") && rm(temporary*".lock")
                    _wal_forget_private!(temporary)
                end
                collect_versions!(handle)
            end
        end
        status_result("Checkpoint durable selesai.")
    end
end
function vacuum!(session::Session)
    active_database(session); handle = session.handle::DatabaseHandle
    lock(handle.mutex) do; collect_versions!(handle); end
end
function mvcc_stats(session::Session)
    active_database(session); h = session.handle::DatabaseHandle
    lock(h.mutex) do
        materialized = sum(length(chain) for table in values(h.histories) for chain in values(table);init=0)
        sparse_current = sum(count(id->!haskey(get(h.histories,name,
            Dict{UInt128,Vector{RowVersion}}()),id),table.row_ids)
            for (name,table) in h.current.tables;init=0)
        (commit_csn=h.csn,wal_lsn=h.lsn,active_snapshots=length(h.snapshots),
         row_versions=materialized+sparse_current,
         wal_bytes=filesize(h.path))
    end
end
function storage_stats(session::Session)
    active_database(session)
    handle = session.handle::DatabaseHandle
    lock(handle.mutex) do
        if handle.page_store === nothing || (handle.page_store::PageStore).manager.closed
            with_wal_lock(handle.path) do
                refresh_locked!(handle,session.storage)
                handle.page_store = open_page_store!(handle.path,handle.current,handle.file_id,handle.lsn,handle.csn)
            end
        else
            with_wal_lock(handle.path) do
                refresh_locked!(handle,session.storage)
                page_store_synchronize!(handle.page_store::PageStore,handle.current,
                    handle.file_id,handle.lsn,handle.csn)
            end
        end
        handle.page_store === nothing ?
            (available=false,reason="Sidecar sedang dimiliki proses lain; logical WAL fallback aktif.") :
            merge((available=true,),page_store_stats(handle.page_store::PageStore))
    end
end
function Base.close(session::Session)
    handles_to_close = DatabaseHandle[]
    lock(session.mutex) do
        session.closed && return nothing
        in_transaction(session) && rollback!(session)
        session.closed = true
        session.handle = nothing
        session.database = nothing
        session.path = nothing
        lock(session.engine.mutex) do
            session.engine.active_sessions = max(0, session.engine.active_sessions - 1)
            session.engine.active_sessions == 0 && append!(handles_to_close, values(session.engine.handles))
        end
    end
    for handle in handles_to_close
        lock(handle.mutex) do
            _wal_close_cached!(handle.path)
            handle.page_store === nothing || close_page_store!(handle.page_store::PageStore)
        end
    end
    nothing
end
