# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

table_columns(s::Session,name::String) = with_snapshot(s) do
    record_read!(s,name)
    getfield.(get_table(active_database(s),name).columns,:name)
end

"""Return lazily maintained cardinality, NULL, distinct, and range statistics."""
function table_stats(session::Session,name::String)
    with_snapshot(session) do
        record_read!(session,name)
        table_statistics(get_table(active_database(session),name))
    end
end

"""Read one primary-key row from a pinned MVCC snapshot; caller owns returned data."""
function _lookup_snapshot_info(session::Session,name::String,key)
    with_snapshot(session) do
        tuplekey = key isa Tuple ? key : (key,)
        table = get_table(active_database(session),name)
        # Small and medium snapshots retain a complete immutable logical hash
        # index. Reading it avoids a second cross-process WAL lock merely to
        # consult the derived page sidecar. Large tables keep using the bounded
        # persistent B+Tree path below.
        if length(table.rows) <= LOGICAL_INDEX_ROW_LIMIT
            id,typed = indexed_row(table,tuplekey)
            stamp = id == 0 ? UInt64(0) : table_stamp(table,table.positions[id])
            record_key!(session,name,tuplekey;identity=(id,typed,stamp))
            row = id == 0 ? nothing : copy(table_row(table,table.positions[id]))
            return (row=row,id=id,typed=typed)
        end
        with_page_store_snapshot(session,name) do physical
            if physical !== nothing
                typed = typed_primary_key(table,tuplekey)
                store,snapshot_csn = physical
                info = page_store_lookup_identity(store,table,typed,snapshot_csn)
                id = info === nothing ? UInt128(0) : info.row_id
                stamp = info === nothing ? UInt64(0) : info.begin_csn
                record_key!(session,name,tuplekey;identity=(id,typed,stamp))
                return (row=info === nothing ? nothing : info.row,id=id,typed=typed)
            end
            id,typed = indexed_row(table,tuplekey)
            stamp = id == 0 ? UInt64(0) : table_stamp(table,table.positions[id])
            record_key!(session,name,tuplekey;identity=(id,typed,stamp))
            row = id == 0 ? nothing : copy(table_row(table,table.positions[id]))
            (row=row,id=id,typed=typed)
        end
    end
end
function lookup(session::Session,name::String,key)
    _lookup_snapshot_info(session,name,key).row
end

"""Read a table snapshot and register a predicate read for serializable certification."""
function scan_rows(session::Session,name::String;columns=nothing)
    with_snapshot(session) do
        table = get_table(active_database(session),name)
        record_read!(session,name)
        physical_rows = with_page_store_snapshot(session,name) do physical
            physical === nothing ? nothing : page_store_scan_rows(physical[1],name,physical[2];row_ids=table.row_ids)
        end
        if columns === nothing
            # PageStore decoding already creates caller-owned Row vectors. A
            # second full-table copy doubled the live result graph during a
            # 250k scan. The logical MVCC fallback still copies immutable rows.
            return physical_rows === nothing ? [copy(row) for row in table_rows(table)] : physical_rows
        end
        source = physical_rows === nothing ? table_rows(table) : physical_rows
        positions = [column_index(table,String(c)) for c in columns]
        [Cell[row[i] for i in positions] for row in source]
    end
end

function bulk_insert!(session::Session,name::String,values)
    with_transaction(session) do
        source = get_table(active_database(session),name)
        any(c->c.auto,source.columns) && record_read!(session,name)
        mutate_tables!(session,[name]) do db
            table = db.tables[name]; required = count(c->!c.auto,table.columns); countrows = 0
            for input in values
                length(input) == required || constraint("Tabel '$name' membutuhkan $required nilai non-auto.")
                row = Cell[]; vi = 1
                for c in table.columns
                    if c.auto
                        if table.shared_fields & TABLE_SHARED_NEXT_IDS != 0
                            table.next_ids = copy(table.next_ids)
                            table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_NEXT_IDS)
                        end
                        id = table.next_ids[c.name]
                        id <= typemax(Int64) || constraint("Sequence Auto_ habis.")
                        push!(row,Int64(id)); table.next_ids[c.name] += 1
                    else
                        push!(row,coerce_value(c,input[vi])); vi += 1
                    end
                end
                append_row!(table,row); countrows += 1
            end
            status_result("Data dimasukkan.",countrows)
        end
    end
end

function update_key!(session::Session,name::String,key,updates)
    with_transaction(session) do
        tuplekey = key isa Tuple ? key : (key,)
        info = _lookup_snapshot_info(session,name,tuplekey)
        info.row === nothing && return status_result("Data diperbarui.",0)
        assignments = updates isa Function ? updates(copy(info.row)) : updates
        mutate_tables!(session,[name]) do db
            table = db.tables[name]; id = info.id
            haskey(table.positions,id) || return status_result("Data diperbarui.",0)
            pos = table.positions[id]; row = copy(table_row(table,pos))
            for (column,value) in pairs(assignments)
                i = column_index(table,String(column)); c = table.columns[i]
                row[i] = coerce_value(c,value)
                if c.auto
                    if table.shared_fields & TABLE_SHARED_NEXT_IDS != 0
                        table.next_ids = copy(table.next_ids)
                        table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_NEXT_IDS)
                    end
                    record_read!(session,name)
                    row[i] !== nothing && row[i] >= 1 || constraint("Auto_ membutuhkan integer positif.")
                    table.next_ids[c.name] = max(table.next_ids[c.name],Int128(row[i])+1)
                end
            end
            set_row!(table,pos,row)
            status_result("Data diperbarui.",1)
        end
    end
end

function delete_key!(session::Session,name::String,key)
    with_transaction(session) do
        tuplekey = key isa Tuple ? key : (key,)
        info = _lookup_snapshot_info(session,name,tuplekey)
        info.row === nothing && return status_result("Data dihapus.",0)
        mutate_tables!(session,[name]) do db
            table = db.tables[name]; id = info.id
            haskey(table.positions,id) || return status_result("Data dihapus.",0)
            remove_rows!(table,[table.positions[id]])
            status_result("Data dihapus.",1)
        end
    end
end

function point_key(condition::Union{Nothing,ExprNode},table::Table)
    # A primary-key equality remains a safe point lookup when it is one atom
    # of a conjunction.  The complete WHERE expression is still evaluated by
    # select_rows after the tiny candidate is fetched, so NULL/false residual
    # predicates keep their normal SQL semantics.
    if condition isa LogicalAnd
        left = point_key(condition.left,table)
        left !== nothing && return left
        return point_key(condition.right,table)
    end
    condition isa BinaryExpr && condition.op == :eq || return nothing
    pk = primary_spec(table); length(pk) == 1 || return nothing
    a = condition.left; b = condition.right
    a isa Literal && b isa ColumnRef && ((a,b)=(b,a))
    a isa ColumnRef && b isa Literal && b.value !== nothing || return nothing
    a.name == table.columns[only(pk)].name && (a.table === nothing || a.table == table.name) || return nothing
    try
        typed = coerce_value(table.columns[only(pk)],b.value)
        compare_values(:eq,typed,b.value) === true || return nothing
    catch e
        e isa AiresError || rethrow()
        return nothing
    end
    (b.value,)
end

function select_session(session::Session,query::SelectQuery)
    with_snapshot(session) do
        db = active_database(session)
        validate_query(db,query)
        if length(query.sources) == 1 && haskey(db.tables,only(query.sources))
            name = only(query.sources); table = db.tables[name]; key = point_key(query.condition,table)
            if key !== nothing
                selected_info = _lookup_snapshot_info(session,name,key)
                selected = selected_info.row === nothing ? Row[] : Row[selected_info.row]
                tiny = copy_database(db)
                tiny.tables[name] = Table(name,table.columns,selected,table.next_ids)
                return select_rows(tiny,query)
            end
            record_read!(session,name)
            physical_result = with_page_store_snapshot(session,name) do physical
                if physical === nothing
                    nothing
                else
                    indexed = select_page_store_index_stream(physical[1],db,name,query,physical[2])
                    indexed === nothing ? select_page_store_stream(physical[1],db,name,query,physical[2]) : indexed
                end
            end
            physical_result === nothing || return physical_result
        end
        record_query_reads!(session,query)
        select_rows(db,query)
    end
end
