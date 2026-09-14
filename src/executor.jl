# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

function source_rows(db::Database,name::String,stack::Set{String})
    if haskey(db.tables,name)
        rows = table_rows(db.tables[name])
        isempty(db.tables[name].row_overrides) || _query_budget_work!(length(rows))
        for _ in rows
            _query_budget_tick!()
        end
        return rows
    end
    name in stack && fail("Siklus view pada '$name'.")
    select_rows(db,db.views[name].query,union(stack,Set([name]))).rows
end

function _condition_sources!(sources::Set{String},expression::ExprNode,schema::Vector{BoundColumn})
    if expression isa ColumnRef
        push!(sources,schema[resolve_column(expression,schema)].source)
    elseif expression isa UnaryExpr
        _condition_sources!(sources,expression.operand,schema)
    elseif expression isa BinaryExpr || expression isa LogicalAnd || expression isa LogicalOr
        _condition_sources!(sources,expression.left,schema)
        _condition_sources!(sources,expression.right,schema)
    elseif expression isa CallExpr
        for argument in expression.args
            _condition_sources!(sources,argument,schema)
        end
    end
    sources
end

function _condition_conjuncts(condition::ExprNode)
    condition isa LogicalAnd ? vcat(_condition_conjuncts(condition.left),
        _condition_conjuncts(condition.right)) : ExprNode[condition]
end

function _push_join_filters(condition::Union{Nothing,ExprNode},schema::Vector{BoundColumn},
                            left_name::String,right_name::String)
    left = ExprNode[]; right = ExprNode[]; residual = ExprNode[]
    condition === nothing && return left,right,residual
    for part in _condition_conjuncts(condition)
        sources = _condition_sources!(Set{String}(),part,schema)
        if isempty(sources) || sources == Set([left_name])
            push!(left,part)
        elseif sources == Set([right_name])
            push!(right,part)
        else
            push!(residual,part)
        end
    end
    left,right,residual
end

function _filter_source_rows(rows::Vector{Row},parts::Vector{ExprNode},schema::Vector{BoundColumn})
    isempty(parts) && return rows
    bound = [bind_condition(part,schema) for part in parts]
    filtered = Row[]
    for row in rows
        _query_budget_tick!()
        if all(filter_matches(part,row,schema) for part in bound)
            _query_budget_work!()
            push!(filtered,row)
        end
    end
    filtered
end

function _push_source_filters(condition::Union{Nothing,ExprNode},schema::Vector{BoundColumn},sources::Vector{String})
    filters = Dict{String,Vector{ExprNode}}(source=>ExprNode[] for source in sources)
    residual = ExprNode[]
    condition === nothing && return filters,residual
    for part in _condition_conjuncts(condition)
        used = _condition_sources!(Set{String}(),part,schema)
        if length(used) == 1 && only(used) in sources
            push!(filters[only(used)],part)
        else
            push!(residual,part)
        end
    end
    filters,residual
end

"""Choose the hash build side after source predicates have reduced both inputs.

Ties keep the right side as the build side because that is the legacy path and
also preserves the lowest-overhead left-major output construction.
"""
function _join_build_side(left_rows::AbstractVector,right_rows::AbstractVector)::Symbol
    length(left_rows) < length(right_rows) ? :left : :right
end

@inline function _join_hash_key(value,floating::Bool)
    value_key(isnumber(value) ? (floating ? (value isa Float64 ? value : Float64(exact(value))) : exact(value)) : value)
end

function _hash_join_preserve_left(leftrows::Vector{Row},rightrows::Vector{Row},left_column::Int,
                                  right_column::Int,floating::Bool)
    build_side = _join_build_side(leftrows,rightrows)
    if build_side === :right
        buckets = Dict{Any,Vector{Row}}()
        for row in rightrows
            _query_budget_tick!()
            value = row[right_column]
            value === nothing && continue
            _query_budget_work!()
            push!(get!(buckets,_join_hash_key(value,floating),Row[]),row)
        end
        rows = Row[]
        for left in leftrows
            _query_budget_tick!()
            value = left[left_column]
            value === nothing && continue
            for right in get(buckets,_join_hash_key(value,floating),Row[])
                joined = vcat(left,right)
                _query_budget_work!(joined)
                push!(rows,joined)
            end
        end
        return rows
    end

    # Build only the smaller left-side key set, then retain matching right rows
    # by key. A final left-major pass preserves the observable no-M: order.
    left_keys = Set{Any}()
    for left in leftrows
        _query_budget_tick!()
        value = left[left_column]
        value === nothing && continue
        key = _join_hash_key(value,floating)
        if !(key in left_keys)
            _query_budget_work!()
            push!(left_keys,key)
        end
    end
    matches = Dict{Any,Vector{Row}}()
    for right in rightrows
        _query_budget_tick!()
        value = right[right_column]
        value === nothing && continue
        key = _join_hash_key(value,floating)
        key in left_keys || continue
        _query_budget_work!()
        push!(get!(matches,key,Row[]),right)
    end
    rows = Row[]
    for left in leftrows
        _query_budget_tick!()
        value = left[left_column]
        value === nothing && continue
        for right in get(matches,_join_hash_key(value,floating),Row[])
            joined = vcat(left,right)
            _query_budget_work!(joined)
            push!(rows,joined)
        end
    end
    rows
end

"""Use a unique logical index when probing the right table is cheaper.

This path is limited to same-kind, source-local table columns so the index key
has exactly the same representation as the catalog key. Nullable keys retain
normal SQL NULL-never-matches semantics. Returning `nothing` means the planner
should use the hash plan instead; an empty `Row[]` is a valid indexed result.
"""
function _join_index_nested_loop_right(leftrows::Vector{Row},rightrows::Vector{Row},
                                        right_table,left_column::Int,right_column::Int,
                                        left_kind::Symbol,right_kind::Symbol)
    right_table === nothing && return nothing
    left_kind == right_kind || return nothing
    length(leftrows) < length(rightrows) || return nothing
    spec = (right_column,)
    haskey(right_table.indexes,spec) || return nothing
    rows = Row[]
    for left in leftrows
        _query_budget_tick!()
        value = left[left_column]
        value === nothing && continue
        id = logical_index_get(right_table,spec,(value_key(value),))
        iszero(id) && continue
        position = get(right_table.positions,id,0)
        position == 0 && continue
        right = table_row(right_table,position)
        joined = vcat(left,right)
        _query_budget_work!(joined)
        push!(rows,joined)
    end
    rows
end

function join_rows(db::Database,q::SelectQuery,schema::Vector{BoundColumn},stack::Set{String})
    length(q.sources) == 1 && return source_rows(db,q.sources[1],stack),q.condition
    source_schemas = Dict{String,Vector{BoundColumn}}()
    offset = 0
    for source in q.sources
        source_columns = source_schema(db,source,stack)
        selected_schema = BoundColumn[schema[index] for index in (offset+1):(offset+length(source_columns))]
        source_schemas[source] = selected_schema
        offset += length(source_columns)
    end
    filters,residual = _push_source_filters(q.condition,schema,q.sources)
    residual_condition = isempty(residual) ? nothing :
        reduce((left,right)->LogicalAnd(left,right),residual)
    # Predicate pushdown is deliberately performed before the join order and
    # build side are selected. Cost decisions therefore see actual candidates.
    rows_by_source = Dict{String,Vector{Row}}()
    for source in q.sources
        rows_by_source[source] = _filter_source_rows(source_rows(db,source,stack),filters[source],source_schemas[source])
    end
    plan = plan_join_order(db,q,schema,stack;
        cardinalities=Dict(source=>length(rows_by_source[source]) for source in q.sources))
    current_source = first(plan.order)
    current_sources = String[current_source]
    current_rows = rows_by_source[current_source]
    atoms = _join_equality_atoms(q.join_condition,schema)
    for source in plan.order[2:end]
        links = _join_links(source,current_sources,atoms)
        right_rows = rows_by_source[source]
        if isempty(links)
            current_rows = _cartesian_join(current_rows,right_rows)
        else
            left_indices = Int[_source_column_index(source_schemas,current_sources,link[3],link[4]) for link in links]
            # The right relation is a single source, so its local index is just
            # the column position in that source schema.
            right_indices = Int[findfirst(c->c.name == link[2],source_schemas[source]) for link in links]
            floating = any(row->any(index->row[index] isa Float64,left_indices),current_rows) ||
                any(row->any(index->row[index] isa Float64,right_indices),right_rows)
            # Preserve the existing unique-index nested-loop fast path for the
            # original two-source shape. Multi-join steps use the generic hash
            # operator because their left side is an intermediate relation.
            indexed = if length(q.sources) == 2 && current_sources == [q.sources[1]] && source == q.sources[2] && length(links) == 1
                first_link = only(links)
                _join_index_nested_loop_right(current_rows,right_rows,get(db.tables,source,nothing),
                    only(left_indices),only(right_indices),
                    schema[resolve_column(ColumnRef(first_link[3],first_link[4]),schema)].kind,
                    schema[resolve_column(ColumnRef(first_link[1],first_link[2]),schema)].kind)
            else
                nothing
            end
            current_rows = indexed === nothing ? _hash_join_preserve_left_keys(current_rows,right_rows,left_indices,right_indices,floating) : indexed
        end
        push!(current_sources,source)
    end
    if current_sources != q.sources
        mapping = Int[]
        for source in q.sources
            start = 0
            for current in current_sources
                current == source && break
                start += length(source_schemas[current])
            end
            append!(mapping,start .+ (1:length(source_schemas[source])))
        end
        current_rows = [Cell[row[index] for index in mapping] for row in current_rows]
    end
    current_rows,residual_condition
end

function query_order_permutation(keys::AbstractVector, orders::Vector{OrderByItem})
    directions = Symbol[]
    nulls = Symbol[]
    for item in orders
        if item.direction == SortAscending
            push!(directions,:asc); push!(nulls,:last)
        elseif item.direction == SortDescending
            push!(directions,:desc); push!(nulls,:first)
        else
            fail("Arah M: tidak valid.")
        end
    end
    stable_sort_permutation(keys,directions,compare_values;nulls)
end

function order_source_rows(rows::Vector{Row}, orders::Vector{OrderByItem}, bound::Vector{ExprNode}, schema::Vector{BoundColumn})
    isempty(orders) && return rows
    keys = Vector{Vector{Cell}}(undef,length(rows))
    for (index,row) in enumerate(rows)
        _query_budget_tick!()
        keys[index] = Cell[evaluate(expression,row,schema) for expression in bound]
        _query_budget_memory!(keys[index])
    end
    rows[query_order_permutation(keys,orders)]
end

function select_rows(db::Database,q::SelectQuery,stack::Set{String}=Set{String}())
    top_level = _query_budget_enter!()
    schema,exprs,labels = validate_query(db,q,stack)
    bound = [bind_expression(e,schema) for e in exprs]
    bound_orders = ExprNode[bind_expression(item.expression,schema) for item in q.orders]
    input,residual_condition = join_rows(db,q,schema,stack)
    # Source-local predicates were already evaluated before the hash join.
    # Only retain cross-source residual predicates here; this avoids evaluating
    # pushed filters once per joined pair.
    condition = bind_condition(residual_condition,schema)
    rows = if condition === nothing
        input
    else
        filtered = Row[]
        for row in input
            _query_budget_tick!()
            if filter_matches(condition,row,schema)
                _query_budget_work!()
                push!(filtered,row)
            end
        end
        filtered
    end
    output = Row[]
    if !isempty(q.groups) || any(has_aggregate,exprs)
        groups = Vector{Row}[]
        order_keys = Vector{Vector{Cell}}()
        if isempty(q.groups)
            push!(groups,rows)
        else
            indices = [resolve_column(e,schema) for e in q.groups]
            positions = Dict{Tuple,Int}()
            for row in rows
                _query_budget_tick!()
                key = Tuple(value_key(row[i]) for i in indices)
                if !haskey(positions,key)
                    _query_budget_work!()
                    push!(groups,Row[]); positions[key] = length(groups)
                end
                _query_budget_work!()
                push!(groups[positions[key]],row)
            end
        end
        for group in groups
            _query_budget_tick!()
            representative = isempty(group) ? Cell[nothing for _ in schema] : first(group)
            projected = Cell[evaluate(e,representative,schema,group) for e in bound]
            _query_budget_work!(projected)
            push!(output,projected)
            if !isempty(q.orders)
                order_key = Cell[evaluate(e,representative,schema,group) for e in bound_orders]
                _query_budget_memory!(order_key)
                push!(order_keys,order_key)
            end
        end
        isempty(q.orders) || (output = output[query_order_permutation(order_keys,q.orders)])
        q.limit === nothing || resize!(output,min(length(output),q.limit))
        top_level ? _query_budget_emit!(length(output)) : nothing
    else
        if isempty(q.orders)
            # Preserve the existing lazy-Limit behavior for queries without M:.
            stop = q.limit === nothing ? length(rows) : min(length(rows),q.limit)
            for i in 1:stop
                _query_budget_tick!()
                projected = Cell[evaluate(e,rows[i],schema) for e in bound]
                top_level ? _query_budget_emit!(projected) : _query_budget_work!(projected)
                push!(output,projected)
            end
        else
            # M: must see the whole filtered source before Limit is applied.
            rows = order_source_rows(rows,q.orders,bound_orders,schema)
            stop = q.limit === nothing ? length(rows) : min(length(rows),q.limit)
            for row in rows[1:stop]
                _query_budget_tick!()
                projected = Cell[evaluate(e,row,schema) for e in bound]
                top_level ? _query_budget_emit!(projected) : _query_budget_work!(projected)
                push!(output,projected)
            end
        end
    end
    if !top_level
        # A view result is an intermediate relation inside the same server
        # request; its rows were already charged as work above.
        _query_budget_leave!()
    end
    result = QueryResult(labels,output)
    top_level && _query_budget_leave!()
    result
end

function explain_session(session::Session,query::SelectQuery)
    with_snapshot(session) do
        db = active_database(session)
        validate_query(db,query)
        record_query_reads!(session,query)
        QueryResult(["Plan"],Row[Cell[line] for line in explain_query(db,query)])
    end
end

"""Stream a simple single-table SELECT from bounded ARSP-4 heap batches.

Grouping, joins, and M: fall back to the relational executor because they need
global state.  The common projection/filter/Limit path evaluates each row as it
arrives and never materializes the source table in a temporary `Vector{Row}`.
"""
function select_page_store_stream(store::PageStore,db::Database,name::String,q::SelectQuery,snapshot_csn::UInt64)
    length(q.sources) == 1 && only(q.sources) == name && isempty(q.groups) && isempty(q.orders) || return nothing
    schema,exprs,labels = validate_query(db,q)
    any(has_aggregate,exprs) && return nothing
    bound = [bind_expression(expression,schema) for expression in exprs]
    condition = bind_condition(q.condition,schema)
    output = Row[]
    q.limit == 0 && return QueryResult(labels,output)
    # Keep legacy row order without materializing the table. The physical heap
    # still provides the rows; stable row IDs select their observable AiresQL
    # order after updates create newer MVCC records.
    cursor = page_store_scan_cursor(store,name,snapshot_csn;batch_size=256,row_ids=db.tables[name].row_ids)
    cursor === nothing && return nothing
    while true
        batch = next_page_store_batch!(cursor)
        batch === nothing && break
        for row in batch
            _query_budget_tick!()
            filter_matches(condition,row,schema) || continue
            projected = Cell[evaluate(expression,row,schema) for expression in bound]
            _query_budget_emit!(projected)
            push!(output,projected)
            q.limit === nothing || length(output) < q.limit || return QueryResult(labels,output)
        end
    end
    QueryResult(labels,output)
end

function _range_condition_atoms(condition::LogicalAnd)
    vcat(_range_condition_atoms(condition.left),_range_condition_atoms(condition.right))
end
_range_condition_atoms(condition) = ExprNode[condition]

"""Extract safe inclusive/exclusive bounds for one indexed column.

The residual predicate is still evaluated for every returned row.  This helper
only narrows the B+Tree walk, and therefore deliberately accepts conjunctions
but never makes assumptions about OR or arithmetic expressions.
"""
function _page_store_index_bounds(condition,table::Table,column::Int)
    condition === nothing && return nothing
    lower = nothing; upper = nothing
    lower_inclusive = true; upper_inclusive = true
    reverse_operator = Dict(:eq=>:eq,:gt=>:lt,:lt=>:gt,:ge=>:le,:le=>:ge)
    for atom in _range_condition_atoms(condition)
        atom isa BinaryExpr && atom.op in keys(reverse_operator) || continue
        left = atom.left; right = atom.right; op = atom.op
        if left isa Literal && right isa ColumnRef
            left,right = right,left
            op = reverse_operator[op]
        end
        left isa ColumnRef && right isa Literal || continue
        left.table === nothing || left.table == table.name || continue
        left.name == table.columns[column].name || continue
        value = coerce_value(table.columns[column],right.value)
        value === nothing && continue
        if op == :eq
            lower = value; upper = value; lower_inclusive = true; upper_inclusive = true
        elseif op in (:gt,:ge)
            if lower === nothing || compare_values(:gt,value,lower) === true
                lower = value; lower_inclusive = op == :ge
            elseif compare_values(:eq,value,lower) === true
                lower_inclusive &= op == :ge
            end
        elseif op in (:lt,:le)
            if upper === nothing || compare_values(:lt,value,upper) === true
                upper = value; upper_inclusive = op == :le
            elseif compare_values(:eq,value,upper) === true
                upper_inclusive &= op == :le
            end
        end
    end
    lower === nothing && upper === nothing && return nothing
    (lower=lower === nothing ? nothing : (lower,),
     upper=upper === nothing ? nothing : (upper,),
     lower_inclusive,upper_inclusive)
end

"""Use a matching persistent unique/primary B+Tree for a simple M: query."""
function select_page_store_index_stream(store::PageStore,db::Database,name::String,q::SelectQuery,snapshot_csn::UInt64)
    length(q.sources) == 1 && only(q.sources) == name && isempty(q.groups) && !isempty(q.orders) || return nothing
    schema,exprs,labels = validate_query(db,q)
    any(has_aggregate,exprs) && return nothing
    all(item->item.expression isa ColumnRef,q.orders) || return nothing
    directions = getfield.(q.orders,:direction)
    all(==(first(directions)),directions) || return nothing
    spec = Tuple(resolve_column(item.expression,schema) for item in q.orders)
    table = db.tables[name]
    all(index->1 <= index <= length(table.columns),spec) || return nothing
    bounds = length(spec) == 1 ? _page_store_index_bounds(q.condition,table,only(spec)) : nothing
    cursor = if bounds === nothing
        page_store_index_cursor(store,table,spec,snapshot_csn;reverse=first(directions) == SortDescending)
    else
        page_store_index_cursor(store,table,spec,snapshot_csn;reverse=first(directions) == SortDescending,
            lower=bounds.lower,upper=bounds.upper,
            lower_inclusive=bounds.lower_inclusive,upper_inclusive=bounds.upper_inclusive)
    end
    cursor === nothing && return nothing
    bound = [bind_expression(expression,schema) for expression in exprs]
    condition = bind_condition(q.condition,schema)
    output = Row[]
    q.limit == 0 && return QueryResult(labels,output)
    # The cursor batch API owns the WAL/store lock for each physical request;
    # do not hold the store latch across a call that reacquires WAL first.
    while true
        batch = next_page_store_index_batch!(cursor)
        batch === nothing && break
        for row in batch
            _query_budget_tick!()
            filter_matches(condition,row,schema) || continue
            projected = Cell[evaluate(expression,row,schema) for expression in bound]
            _query_budget_emit!(projected)
            push!(output,projected)
            q.limit === nothing || length(output) < q.limit || return QueryResult(labels,output)
        end
    end
    QueryResult(labels,output)
end

function execute_statement!(session::Session,stmt::Statement)
    if stmt isa Union{CreateDatabase,UseDatabase}
        return open_database!(session,stmt.name;create=stmt isa CreateDatabase)
    elseif stmt isa TransactionCommand
        return execute_transaction!(session,stmt)
    elseif stmt isa SelectQuery
        return select_session(session,stmt)
    elseif stmt isa ExplainQuery
        return explain_session(session,stmt.query)
    end
    mutate!(session,stmt) do db
        if stmt isa CreateTable
            validate_identifier(stmt.name)
            haskey(db.tables,stmt.name) || haskey(db.views,stmt.name) ? fail("Tabel atau view '$(stmt.name)' sudah ada.") : nothing
            validate_schema(stmt.columns)
            db.tables[stmt.name] = Table(stmt.name,copy(stmt.columns),Row[],Dict(c.name=>Int128(1) for c in stmt.columns if c.auto))
            return status_result("Tabel '$(stmt.name)' dibuat.")
        elseif stmt isa InsertRows
            table = get_table(db,stmt.table)
            required = count(c->!c.auto,table.columns)
            for values in stmt.values
                length(values) == required || constraint("Tabel '$(stmt.table)' membutuhkan $required nilai non-auto, mendapat $(length(values)).")
                row = Cell[]; vi = 1
                for c in table.columns
                    if c.auto
                        if table.shared_fields & TABLE_SHARED_NEXT_IDS != 0
                            table.next_ids = copy(table.next_ids)
                            table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_NEXT_IDS)
                        end
                        value = table.next_ids[c.name]
                        value <= typemax(Int64) || constraint("Auto_ pada kolom '$(c.name)' kehabisan nilai Int64.")
                        push!(row,Int64(value)); table.next_ids[c.name] += 1
                    else
                        push!(row,coerce_value(c,literal_field(values[vi]))); vi += 1
                    end
                end
                append_row!(table,row)
            end
            return status_result("Data dimasukkan.",length(stmt.values))
        elseif stmt isa UpdateRows
            table = get_table(db,stmt.table)
            schema = [BoundColumn(table.name,c.name,c.kind) for c in table.columns]
            names = [a.column for a in stmt.assignments]
            length(unique(names)) == length(names) || syntaxerror("Kolom assignment berulang.")
            assignments = Tuple{Int,ExprNode}[]
            for a in stmt.assignments
                i = column_index(table,a.column); e = a.expression
                if table.columns[i].kind == :C && e isa ColumnRef && e.table === nothing && all(c->c.name != e.name,table.columns)
                    e = Literal(e.name)
                end
                kind = infer_expression(e,schema; allow_aggregate=false)
                c = table.columns[i]
                if e isa Literal
                    coerce_value(c,e.value) # Validate literals even for zero matching rows.
                elseif !(kind == :NULL || kind == c.kind || (kind in NUMERIC_KINDS && c.kind in (:I,:D,:U,:F)))
                    typeerror("Assignment kolom $(c.name) membutuhkan tipe $(c.kind), bukan $kind.")
                end
                push!(assignments,(i,bind_expression(e,schema)))
            end
            if stmt.condition !== nothing
                infer_expression(stmt.condition,schema; allow_aggregate=false) in (:B,:NULL) || typeerror("Dengan membutuhkan Boolean.")
            end
            affected = 0
            condition = bind_condition(stmt.condition,schema)
            key = point_key(stmt.condition,table)
            indices = if key === nothing
                eachindex(table.rows)
            else
                id,_ = session_indexed_row(session,stmt.table,table,key)
                id == 0 ? Int[] : [table.positions[id]]
            end
            for index in indices
                old = table_row(table,index)
                filter_matches(condition,old,schema) || continue
                row = copy(old)
                for (i,e) in assignments
                    c = table.columns[i]
                    row[i] = coerce_value(c,evaluate(e,old,schema))
                    if c.auto
                        if table.shared_fields & TABLE_SHARED_NEXT_IDS != 0
                            table.next_ids = copy(table.next_ids)
                            table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_NEXT_IDS)
                        end
                        row[i] !== nothing && row[i] >= 1 || constraint("Auto_ membutuhkan integer positif.")
                        table.next_ids[c.name] = max(table.next_ids[c.name],Int128(row[i])+1)
                    end
                end
                set_row!(table,index,row); affected += 1
            end
            return status_result("Data diperbarui.",affected)
        elseif stmt isa AddColumn
            table = get_table(db,stmt.table)
            any(c->c.name==stmt.column.name,table.columns) && constraint("Kolom '$(stmt.column.name)' sudah ada.")
            stmt.column.nullable || isempty(table.rows) || constraint("Kolom baru Not Null tidak dapat ditambahkan pada tabel yang berisi data.")
            if table.shared_fields & TABLE_SHARED_COLUMNS != 0
                table.columns = copy(table.columns)
                table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_COLUMNS)
            end
            table.statistics = nothing
            push!(table.columns,stmt.column)
            for i in eachindex(table.rows); set_row!(table,i,vcat(table_row(table,i),Cell[nothing])); end
            return status_result("Kolom '$(stmt.column.name)' ditambahkan.")
        elseif stmt isa RemoveColumn
            table = get_table(db,stmt.table); i = column_index(table,stmt.column)
            table.columns[i].primary && constraint("Kolom Primary Key tidak boleh dihapus.")
            if table.shared_fields & TABLE_SHARED_COLUMNS != 0
                table.columns = copy(table.columns)
                table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_COLUMNS)
            end
            table.statistics = nothing
            if table.columns[i].auto
                table.shared_fields & TABLE_SHARED_NEXT_IDS != 0 && (table.next_ids = copy(table.next_ids);
                    table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_NEXT_IDS))
                delete!(table.next_ids,stmt.column)
            end
            deleteat!(table.columns,i)
            for index in eachindex(table.rows)
                row = copy(table_row(table,index)); deleteat!(row,i); set_row!(table,index,row)
            end
            return status_result("Kolom '$(stmt.column)' dihapus.")
        elseif stmt isa DeleteRows
            table = get_table(db,stmt.table)
            schema = [BoundColumn(table.name,c.name,c.kind) for c in table.columns]
            if stmt.condition !== nothing
                infer_expression(stmt.condition,schema; allow_aggregate=false) in (:B,:NULL) || typeerror("Dengan membutuhkan Boolean.")
            end
            oldcount = length(table.rows)
            condition = bind_condition(stmt.condition,schema)
            remove_rows!(table,findall(r->filter_matches(condition,r,schema),table_rows(table)))
            return status_result("Data dihapus.",oldcount-length(table.rows))
        elseif stmt isa DropTable
            get_table(db,stmt.table); delete!(db.tables,stmt.table)
            return status_result("Tabel '$(stmt.table)' dihapus.")
        elseif stmt isa CreateView
            validate_identifier(stmt.name)
            haskey(db.tables,stmt.name) || haskey(db.views,stmt.name) ? fail("Tabel atau view '$(stmt.name)' sudah ada.") : nothing
            _,_,labels = validate_query(db,stmt.query)
            length(unique(labels)) == length(labels) || fail("View tidak boleh memiliki nama kolom duplikat.")
            db.views[stmt.name] = ViewDefinition(stmt.name,stmt.query)
            return status_result("View '$(stmt.name)' dibuat.")
        end
        fail("Statement belum didukung.")
    end
end

"""Execute one statement. Every write statement is atomic within its session."""
function execute!(session::Session,source::AbstractString)
    lock(session.mutex) do
        execute_statement!(session,parse_airesql(source))
    end
end

"""Run a complete script in order; errors stop execution. Use an explicit transaction
when several statements must commit together. Scripts are plain .txt files."""
function execute_script!(session::Session,source::AbstractString)
    statements,tail = split_statements(source)
    isempty(tokenize(tail)[1:end-1]) || syntaxerror("Statement harus diakhiri dengan '-:'.")
    results = QueryResult[]
    for statement in statements; push!(results,execute!(session,statement)); end
    results
end
