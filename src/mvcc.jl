# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

"""One committed row version. Values are never mutated after publication."""
mutable struct RowVersion
    begin_csn::UInt64
    end_csn::UInt64
    values::Union{Nothing,Row}
end
const INFINITY_CSN = typemax(UInt64)

mutable struct DatabaseHandle
    path::String
    current::Database
    csn::UInt64
    lsn::UInt64
    offset::Int64
    file_id::Vector{UInt8}
    wal_device::UInt64
    wal_inode::UInt64
    epochs::Dict{String,UInt64}
    schema_epochs::Dict{String,UInt64}
    catalog_epoch::UInt64
    histories::Dict{String,Dict{UInt128,Vector{RowVersion}}}
    snapshots::Dict{UUID,UInt64}
    mutex::ReentrantLock
    poisoned::Bool
    # Installed after WAL recovery.  Kept as `Any` here because PageStore is
    # defined after MVCC types, while all hot row paths retain concrete types.
    page_store::Any
end

mutable struct Engine
    root::String
    handles::Dict{String,DatabaseHandle}
    mutex::ReentrantLock
    active_sessions::Int
end

# Path-based maintenance APIs (restore/compact) must see Engines that were not
# created by the same caller. Weak references keep this process-local registry
# from extending an Engine's lifetime after an application drops it.
const _ENGINE_REGISTRY_LOCK = ReentrantLock()
const _ENGINE_REGISTRY = WeakRef[]
# Opening a database and publishing a restored WAL must be one process-local
# critical section. This closes the check/publish race where a new Session
# could attach to the target after restore validation but before replacement.
const _DATABASE_MAINTENANCE_LOCK = ReentrantLock()

_engine_path_key(path::AbstractString) = _wal_canonical(String(path))

function _register_engine!(engine::Engine)
    lock(_ENGINE_REGISTRY_LOCK) do
        filter!(reference -> reference.value !== nothing, _ENGINE_REGISTRY)
        any(reference -> reference.value === engine, _ENGINE_REGISTRY) || push!(_ENGINE_REGISTRY,WeakRef(engine))
    end
    engine
end

function _engine_uses_path(path::AbstractString)
    target = _engine_path_key(path)
    lock(_ENGINE_REGISTRY_LOCK) do
        for reference in _ENGINE_REGISTRY
            engine = reference.value
            engine === nothing && continue
            in_use = lock(engine.mutex) do
                engine.active_sessions > 0 &&
                    any(handle -> _engine_path_key(handle.path) == target, values(engine.handles))
            end
            in_use && return true
        end
        false
    end
end

function Engine(root::AbstractString=pwd())
    mkpath(root)
    _register_engine!(Engine(realpath(root),Dict{String,DatabaseHandle}(),ReentrantLock(),0))
end

mutable struct TransactionState
    id::UUID
    snapshot::Database
    working::Database
    snapshot_csn::UInt64
    epochs::Dict{String,UInt64}
    schema_epochs::Dict{String,UInt64}
    catalog_epoch::UInt64
    scans::Dict{String,UInt64}
    keys::Dict{Tuple{String,Tuple},Tuple{UInt128,UInt64}}
    dirty::Set{String}
    ddl::Set{String}
    catalog_dirty::Bool
    catalog_read::Bool
    # Explicit multi-statement transactions retain their immutable logical
    # snapshot for reads.  Auto-commit snapshots may use the current page
    # sidecar because their lifetime is bounded by one API operation.
    physical_reads::Bool
end
transaction_conflict(message::String) = throw(AiresError("Transaction Conflict",message))
tx_stage_table(tx::TransactionState,name::String) = tx.working.tables[name]

function initialize_table!(table::Table,stamp::UInt64)
    fill!(table.row_stamps,stamp)
    empty!(table.row_stamp_overrides)
    empty!(table.changes); empty!(table.statement_changes)
    build_indexes!(table)
end

function typed_primary_key(table::Table,key::Tuple)
    pk = primary_spec(table)
    isempty(pk) && fail("Tabel '$(table.name)' tidak memiliki Primary Key untuk lookup.")
    length(key) == length(pk) || fail("Lookup membutuhkan $(length(pk)) bagian Primary Key.")
    Tuple(value_key(coerce_value(table.columns[i],v)) for (i,v) in zip(pk,key))
end

function indexed_row(table::Table,key::Tuple)
    pk = primary_spec(table)
    typed = typed_primary_key(table,key)
    index = get(table.indexes,pk,nothing)
    if index === nothing && length(table.rows) > LOGICAL_INDEX_ROW_LIMIT
        for position in eachindex(table.rows)
            row_key(table_row(table,position),pk) == typed && return table.row_ids[position],typed
        end
        return UInt128(0),typed
    end
    index === nothing && (build_indexes!(table); index = table.indexes[pk])
    id = logical_index_get(table,pk,typed)
    id,typed
end

function set_row!(table::Table,index::Int,row::Row)
    table.statistics = nothing
    if table.shared_fields & TABLE_SHARED_ROWS != 0
        table.row_overrides[index] = row
    else
        table.rows[index] = row
    end
    id = table.row_ids[index]
    table.changes[id] = row
    push!(table.statement_changes,id)
    row
end
function append_row!(table::Table,row::Row; id::UInt128=uuid4().value,stamp::UInt64=UInt64(0))
    table.statistics = nothing
    haskey(table.positions,id) && constraint("Row ID internal duplikat.")
    materialize_table_rows!(table)
    materialize_table_stamps!(table)
    if table.shared_fields & TABLE_SHARED_ROW_IDS != 0
        table.row_ids = copy(table.row_ids)
        table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_ROW_IDS)
    end
    if table.shared_fields & TABLE_SHARED_ROW_STAMPS != 0
        table.row_stamps = copy(table.row_stamps)
        table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_ROW_STAMPS)
    end
    if table.shared_fields & TABLE_SHARED_POSITIONS != 0
        table.positions = copy(table.positions)
        table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_POSITIONS)
    end
    push!(table.rows,row); push!(table.row_ids,id); push!(table.row_stamps,stamp)
    table.positions[id] = length(table.rows)
    table.changes[id] = row; push!(table.statement_changes,id)
    id
end
function remove_rows!(table::Table,positions::Vector{Int})
    isempty(positions) && return
    table.statistics = nothing
    sort!(unique!(positions))
    materialize_table_rows!(table)
    materialize_table_stamps!(table)
    if table.shared_fields & TABLE_SHARED_ROW_IDS != 0
        table.row_ids = copy(table.row_ids)
        table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_ROW_IDS)
    end
    if table.shared_fields & TABLE_SHARED_ROW_STAMPS != 0
        table.row_stamps = copy(table.row_stamps)
        table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_ROW_STAMPS)
    end
    if table.shared_fields & TABLE_SHARED_POSITIONS != 0
        table.positions = copy(table.positions)
        table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_POSITIONS)
    end
    for i in positions
        id = table.row_ids[i]
        table.changes[id] = nothing; push!(table.statement_changes,id)
    end
    deleteat!(table.rows,positions); deleteat!(table.row_ids,positions); deleteat!(table.row_stamps,positions)
    table.positions = Dict(id=>i for (i,id) in enumerate(table.row_ids))
end

function _valid_internal_cell(column::ColumnDef,value)::Bool
    value === nothing && return column.nullable
    kind = column.kind
    valid = kind == :C ? (value isa String && length(value) <= column.max_length) :
        kind == :B ? value isa Bool :
        kind == :F ? (value isa Float64 && isfinite(value)) :
        kind == :I ? value isa Int64 :
        kind == :D ? value isa Decimal :
        kind == :U ? value isa Money :
        kind == :T ? value isa Date :
        kind == :W ? value isa Time :
        kind == :TW ? value isa DateTime : false
    valid || return false
    !column.auto || (value isa Int64 && 1 <= value)
end

function validate_row(table::Table,row::Row)
    length(row) == length(table.columns) || constraint("Jumlah nilai tidak sesuai schema tabel '$(table.name)'.")
    for (i,c) in enumerate(table.columns)
        v = row[i]
        _valid_internal_cell(c,v) || typeerror("Representasi kolom '$(c.name)' tidak sesuai schema.")
        c.auto && !(v < table.next_ids[c.name]) && constraint("Nilai Auto_ tidak sesuai sequence.")
    end
end

"""Validate a large-table write set against its persistent unique indexes."""
function _validate_large_changes!(table::Table,before::Table,physical_store,snapshot_csn::UInt64)
    for id in keys(table.changes)
        position = get(table.positions,id,0)
        position == 0 || validate_row(table,table_row(table,position))
    end
    store_ready = physical_store !== nothing &&
        physical_store.applied_csn == snapshot_csn && haskey(physical_store.tables,table.name)
    store_ready || return _validate_unique_specs_without_indexes!(table)
    entry = physical_store.tables[table.name]
    changed = Set{UInt128}(keys(table.changes))
    # A brand-new table has no physical keys to probe; checking the write set
    # locally avoids one B+Tree request per imported row.
    probe_existing = !isempty(before.rows)
    for spec in unique_specs(table)
        local_keys = Dict{Tuple,UInt128}()
        for (id,value) in table.changes
            position = get(table.positions,id,0)
            position == 0 && continue
            key = row_key(table_row(table,position),spec)
            any(isnothing,key) && continue
            existing = get(local_keys,key,UInt128(0))
            existing == 0 || existing == id ||
                constraint("Nilai $key pada indeks unik harus unik.")
            local_keys[key] = id
        end
        tree = get(entry.indexes,spec,nothing)
        tree === nothing && return _validate_unique_specs_without_indexes!(table)
        probe_existing || continue
        for (key,id) in local_keys
            rid = btree_lookup(physical_store.pool,tree,key)
            rid === nothing && continue
            existing_id = heap_record(physical_store.pool,entry.heap,rid).row_id
            existing_id == id || existing_id in changed ||
                constraint("Nilai $key pada indeks unik harus unik.")
        end
    end
    nothing
end

"""Validate only changed rows/keys. Remove old keys first so atomic key swaps work."""
function validate_changes!(table::Table,before::Table;physical_store=nothing,snapshot_csn::UInt64=UInt64(0))
    length(table.rows) <= 10_000_000 || constraint("Jumlah row melebihi batas format.")
    if length(table.rows) > LOGICAL_INDEX_ROW_LIMIT
        _validate_large_changes!(table,before,physical_store,snapshot_csn)
        table.indexes = Dict{Tuple,Dict{Tuple,UInt128}}()
        table.statement_changes = UInt128[]
        return nothing
    end
    for id in table.statement_changes
        position = get(table.positions,id,0)
        position == 0 || validate_row(table,table_row(table,position))
    end
    for spec in unique_specs(table)
        overlay = get!(table.index_overrides,spec,Dict{Tuple,UInt128}())
        # Remove all old statement keys first so unique-key swaps remain atomic.
        for id in table.statement_changes
            oldpos = get(before.positions,id,0)
            oldpos == 0 && continue
            key = row_key(table_row(before,oldpos),spec)
            logical_index_get(table,spec,key) == id && (overlay[key] = UInt128(0))
        end
        for id in table.statement_changes
            pos = get(table.positions,id,0)
            pos == 0 && continue
            row = table_row(table,pos)
            key = row_key(row,spec)
            any(isnothing,key) && continue
            existing = logical_index_get(table,spec,key)
            label = spec == primary_spec(table) ? "Primary Key" : "kolom"
            existing == 0 || existing == id || constraint("Nilai $key pada $label $(join([table.columns[j].name for j in spec], " + ")) harus unik.")
            overlay[key] = id
        end
    end
    compact_index_overrides!(table)
    # This vector is statement-local. Transaction-wide publication uses the
    # `changes` dictionary, so retaining the largest statement's backing array
    # (250k UInt128 IDs for a bulk load) only inflates the committed snapshot.
    table.statement_changes = UInt128[]
    nothing
end

put_rowid(io::IO,id::UInt128) = write(io,htol(id))
get_rowid(io::IO) = ltoh(read(io,UInt128))
function put_blob(io::IO,bytes::Vector{UInt8})
    put_u32(io,length(bytes)); write(io,bytes)
end
get_blob(io::IO) = read_exact(io,get_u32(io))
function ordered_changes(table::Table)
    # Existing physical order plus append order must survive WAL replay and LIMIT.
    # Sorting only the changed rows by their final position preserves exactly
    # the same order without walking every row in the table.  Commits normally
    # touch a small subset, so this changes publication from O(table rows) to
    # O(changes log changes).  Deleted rows no longer have a position and retain
    # the deterministic row-id ordering used by the WAL format.
    present = Tuple{Int,UInt128}[]
    deleted = UInt128[]
    sizehint!(present,length(table.changes))
    for (id,value) in table.changes
        if value === nothing
            push!(deleted,id)
        else
            position = get(table.positions,id,0)
            position == 0 && storageerror("Perubahan row aktif tidak memiliki posisi.")
            push!(present,(position,id))
        end
    end
    sort!(present;by=first)
    sort!(deleted)
    ids = UInt128[last(entry) for entry in present]
    append!(ids,deleted)
    ids
end

function write_identity(io::IO,table::Table)
    put_u32(io,length(table.rows))
    for i in eachindex(table.rows)
        put_rowid(io,table.row_ids[i]); put_u64(io,table_stamp(table,i))
    end
end
function read_identity!(io::IO,table::Table)
    n = get_u32(io)
    n == length(table.rows) || storageerror("Jumlah identitas MVCC tidak sesuai row.")
    for i in eachindex(table.rows)
        table.row_ids[i] = get_rowid(io); table.row_stamps[i] = get_u64(io)
    end
    empty!(table.row_stamp_overrides)
    build_indexes!(table)
    validate_table(table)
end

function checkpoint_payload(store::BinaryRowStore,db::Database,csn::UInt64,epochs::Dict{String,UInt64},schema_epochs::Dict{String,UInt64},catalog_epoch::UInt64)
    io = IOBuffer(); put_u8(io,1); put_u64(io,csn); put_u64(io,catalog_epoch)
    put_blob(io,encode_database(store,db)); put_u32(io,length(db.tables))
    for name in sort!(collect(keys(db.tables)))
        put_string(io,name); put_u64(io,get(epochs,name,csn)); put_u64(io,get(schema_epochs,name,csn))
        write_identity(io,db.tables[name])
    end
    take!(io)
end

function checkpoint_decode(store::BinaryRowStore,io::IO)
    csn = get_u64(io); catalog_epoch = get_u64(io)
    db = decode_database(store,get_blob(io)); epochs = Dict{String,UInt64}(); schemas = Dict{String,UInt64}()
    n = get_u32(io); n == length(db.tables) || storageerror("Catalog checkpoint MVCC tidak sesuai.")
    for _ in 1:n
        name = get_string(io)
        haskey(db.tables,name) && !haskey(epochs,name) || storageerror("Nama checkpoint MVCC tidak valid.")
        epochs[name] = get_u64(io); schemas[name] = get_u64(io)
        read_identity!(io,db.tables[name])
    end
    eof(io) || storageerror("Byte tambahan pada checkpoint.")
    db,csn,epochs,schemas,catalog_epoch
end

function delta_payload(store::BinaryRowStore,handle::DatabaseHandle,db::Database,tx::TransactionState,csn::UInt64,catalog_epoch::UInt64)
    io = IOBuffer(); put_u8(io,2); put_u64(io,csn); put_rowid(io,tx.id.value); put_u64(io,catalog_epoch)
    put_u32(io,length(tx.dirty))
    for name in sort!(collect(tx.dirty))
        put_string(io,name)
        if !haskey(db.tables,name)
            put_u8(io,0); continue
        end
        table = db.tables[name]
        if name in tx.ddl
            put_u8(io,1)
            mini = Database("WalTable"); mini.tables[name] = table
            put_blob(io,encode_database(store,mini)); write_identity(io,table)
        else
            put_u8(io,2)
            stage = tx_stage_table(tx,name) # implemented by transaction commit context below
            base = tx.snapshot.tables[name]
            change_order = ordered_changes(stage)
            put_u32(io,length(change_order))
            for (change_index,id) in enumerate(change_order)
                value = stage.changes[id]; oldpos = get(base.positions,id,0)
                put_rowid(io,id); put_u64(io,oldpos == 0 ? 0 : table_stamp(base,oldpos))
                put_u8(io,value === nothing ? 0 : 1)
                value === nothing || foreach(c->write_cell(io,table.columns[c],value[c]),eachindex(table.columns))
                length(change_order) > LOGICAL_INDEX_ROW_LIMIT && change_index % 8192 == 0 && GC.gc(false)
            end
            put_u32(io,length(table.next_ids))
            for key in sort!(collect(keys(table.next_ids))); put_string(io,key); put_i128(io,table.next_ids[key]); end
        end
    end
    put_u8(io,tx.catalog_dirty ? 1 : 0)
    if tx.catalog_dirty
        put_u32(io,length(db.views))
        for name in sort!(collect(keys(db.views)))
            put_string(io,name); put_string(io,query_text(db.views[name].query))
        end
    end
    take!(io)
end

function apply_delta!(handle::DatabaseHandle,store::BinaryRowStore,io::IO)
    csn = get_u64(io); get_rowid(io) # transaction UUID is persisted for diagnosis.
    csn == handle.csn+1 || storageerror("Urutan commit MVCC tidak valid.")
    catalog_epoch = get_u64(io); db = copy_database(handle.current)
    changed = Set{String}(); ddl = Set{String}()
    for _ in 1:get_count(io,100_000)
        name = get_string(io); kind = get_u8(io)
        name in changed && storageerror("Operasi tabel duplikat dalam WAL.")
        push!(changed,name)
        if kind == 0
            haskey(db.tables,name) || storageerror("WAL menghapus tabel yang tidak ada.")
            delete!(db.tables,name); push!(ddl,name)
        elseif kind == 1
            mini = decode_database(store,get_blob(io))
            length(mini.tables) == 1 && haskey(mini.tables,name) || storageerror("Replacement tabel WAL tidak valid.")
            table = mini.tables[name]; read_identity!(io,table)
            db.tables[name] = table; push!(ddl,name)
        elseif kind == 2
            before = get_table(db,name); table = copy_table(before); deletions = Int[]
            seen = Set{UInt128}()
            for _ in 1:get_count(io,10_000_000;min_bytes=25)
                id = get_rowid(io); stamp = get_u64(io); present = get_u8(io)
                id in seen && storageerror("Row WAL berulang."); push!(seen,id)
                present <= 1 || storageerror("Flag row WAL invalid.")
                pos = get(table.positions,id,0)
                (pos == 0 ? UInt64(0) : table_stamp(table,pos)) == stamp || storageerror("Versi row WAL tidak cocok.")
                if present == 0
                    pos == 0 || push!(deletions,pos)
                else
                    row = Cell[read_cell(io,c) for c in table.columns]
                    if pos == 0; append_row!(table,row;id,stamp=csn)
                    else; set_row!(table,pos,row); table.row_stamps[pos] = csn
                    end
                end
            end
            remove_rows!(table,deletions)
            nseq = get_count(io,1024); nextids = Dict{String,Int128}()
            for _ in 1:nseq
                key = get_string(io); haskey(nextids,key) && storageerror("Sequence WAL berulang.")
                nextids[key] = get_i128(io)
            end
            table.next_ids = nextids
            validate_changes!(table,before)
            db.tables[name] = table
        else
            storageerror("Jenis operasi WAL tidak valid.")
        end
    end
    viewflag = get_u8(io); viewflag <= 1 || storageerror("Flag catalog WAL tidak valid.")
    if viewflag == 1
        views = Dict{String,ViewDefinition}()
        for _ in 1:get_count(io,100_000)
            name = get_string(io); query = parse_airesql(get_string(io))
            query isa SelectQuery && !haskey(views,name) || storageerror("View WAL invalid.")
            views[name] = ViewDefinition(name,query)
        end
        db.views = views
    end
    eof(io) || storageerror("Byte tambahan pada transaksi WAL.")
    publish_versions!(handle,db,changed,ddl,csn,catalog_epoch)
end

function publish_versions!(handle::DatabaseHandle,db::Database,changed::Set{String},ddl::Set{String},csn::UInt64,catalog_epoch::UInt64;
                           change_tables::Union{Nothing,Dict{String,Table}}=nothing)
    for name in changed
        old = get(handle.current.tables,name,nothing); new = get(db.tables,name,nothing)
        versions = get!(handle.histories,name,Dict{UInt128,Vector{RowVersion}}())
        ids = if name in ddl
            union(Set(old === nothing ? UInt128[] : old.row_ids),Set(new === nothing ? UInt128[] : new.row_ids))
        else
            source = change_tables === nothing ? new : get(change_tables,name,new)
            keys(source.changes)
        end
        for id in ids
            oldpos = old === nothing ? 0 : get(old.positions,id,0)
            chain = get(versions,id,nothing)
            if chain === nothing
                # Current rows already live in the immutable database snapshot;
                # materialize a history chain only when the row first changes.
                oldpos == 0 && continue
                chain = RowVersion[RowVersion(table_stamp(old,oldpos),csn,table_row(old,oldpos))]
                versions[id] = chain
            else
                isempty(chain) || (last(chain).end_csn = csn)
            end
            pos = new === nothing ? 0 : get(new.positions,id,0)
            push!(chain,RowVersion(csn,INFINITY_CSN,pos == 0 ? nothing : table_row(new,pos)))
        end
        handle.epochs[name] = csn
        name in ddl && (handle.schema_epochs[name] = csn)
        if new !== nothing
            # `empty!` retains Dict/Vector bucket capacity. A bulk transaction
            # would otherwise pin its full write-set allocation for the entire
            # lifetime of the committed table.
            new.changes = Dict{UInt128,Union{Nothing,Row}}()
            new.statement_changes = UInt128[]
        end
    end
    handle.current = db; handle.csn = csn; handle.catalog_epoch = catalog_epoch
end

"""Create sparse history maps; unchanged current rows remain in `Database` snapshots."""
initialize_histories(db::Database) =
    Dict(name=>Dict{UInt128,Vector{RowVersion}}() for name in keys(db.tables))

function collect_versions!(handle::DatabaseHandle)
    oldest = isempty(handle.snapshots) ? handle.csn : minimum(values(handle.snapshots))
    removed = 0
    for name in collect(keys(handle.histories))
        versions = handle.histories[name]
        for id in collect(keys(versions))
            chain = versions[id]
            if last(chain).values === nothing && last(chain).begin_csn <= oldest
                removed += length(chain); delete!(versions,id); continue
            end
            keep = findlast(v->v.begin_csn <= oldest,chain)
            if keep !== nothing && keep > 1
                removed += keep-1; deleteat!(chain,1:keep-1)
            end
        end
        isempty(versions) && delete!(handle.histories,name)
    end
    removed
end
