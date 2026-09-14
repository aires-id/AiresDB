# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

"""Derived table statistics used by the greedy join planner.

Statistics are intentionally not part of the WAL format.  They are cheap to
rebuild from the authoritative logical snapshot and are invalidated by every
row/schema mutation.  A capped distinct count of `-1` means "unknown" rather
than pretending that a large column has an exact cardinality.
"""
struct TableStatistics
    row_count::Int
    null_counts::Dict{String,Int}
    distinct_counts::Dict{String,Int}
    min_values::Dict{String,Cell}
    max_values::Dict{String,Cell}
end

const TABLE_STATS_DISTINCT_LIMIT = 100_000

function _statistics_key(value)
    value === nothing && return (:null,)
    value isa Bool && return (:boolean,value)
    if isnumber(value)
        value isa Float64 && !isfinite(value) && typeerror("Statistik menerima Float hingga saja.")
        return (:number,value isa Float64 ? Rational{BigInt}(value) : exact(value))
    end
    (typeof(value),value)
end

function table_statistics(table::Table; refresh::Bool=false)::TableStatistics
    !refresh && table.statistics isa TableStatistics && return table.statistics::TableStatistics
    nulls = Dict{String,Int}(column.name=>0 for column in table.columns)
    distinct_sets = [Set{Any}() for _ in table.columns]
    capped = falses(length(table.columns))
    minimums = Dict{String,Cell}()
    maximums = Dict{String,Cell}()
    rows = table_rows(table)
    for row in rows
        _query_budget_tick!()
        for (index,column) in enumerate(table.columns)
            value = row[index]
            if value === nothing
                nulls[column.name] += 1
                continue
            end
            if !capped[index]
                push!(distinct_sets[index],_statistics_key(value))
                length(distinct_sets[index]) >= TABLE_STATS_DISTINCT_LIMIT && (capped[index] = true)
            end
            if !haskey(minimums,column.name) || compare_values(:lt,value,minimums[column.name]) === true
                minimums[column.name] = value
            end
            if !haskey(maximums,column.name) || compare_values(:gt,value,maximums[column.name]) === true
                maximums[column.name] = value
            end
        end
    end
    distincts = Dict{String,Int}()
    for (index,column) in enumerate(table.columns)
        distincts[column.name] = capped[index] ? -1 : length(distinct_sets[index])
    end
    stats = TableStatistics(length(rows),nulls,distincts,minimums,maximums)
    table.statistics = stats
    stats
end

_stats_ndv(stats::TableStatistics,column::String) = begin
    value = get(stats.distinct_counts,column,-1)
    value < 0 ? max(1,stats.row_count) : max(1,value)
end

function _source_statistics(db::Database,name::String,stack::Set{String})
    haskey(db.tables,name) && return table_statistics(db.tables[name])
    nothing
end

function _source_estimate(db::Database,name::String,stack::Set{String})
    stats = _source_statistics(db,name,stack)
    stats === nothing ? 1_000 : stats.row_count
end

"""Flatten the only join predicate form supported by the AiresQL grammar."""
function _join_condition_atoms(condition::Union{Nothing,ExprNode})
    condition === nothing && return ExprNode[]
    condition isa LogicalAnd ? vcat(_join_condition_atoms(condition.left),
        _join_condition_atoms(condition.right)) : ExprNode[condition]
end

"""Return `(left source, left column, right source, right column)` atoms."""
function _join_equality_atoms(condition::Union{Nothing,ExprNode},schema::Vector{BoundColumn})
    atoms = NTuple{4,String}[]
    for atom in _join_condition_atoms(condition)
        atom isa BinaryExpr && atom.op == :eq && atom.left isa ColumnRef && atom.right isa ColumnRef ||
            fail("INNER JOIN membutuhkan kesetaraan kolom; gabungkan beberapa kesetaraan dengan '&:'.")
        left = resolve_column(atom.left,schema); right = resolve_column(atom.right,schema)
        schema[left].source != schema[right].source || fail("Kolom JOIN harus berasal dari dua tabel berbeda.")
        push!(atoms,(schema[left].source,schema[left].name,schema[right].source,schema[right].name))
    end
    atoms
end

function _source_column_index(source_schemas::Dict{String,Vector{BoundColumn}},
                              sources::Vector{String},source::String,column::String)
    offset = 0
    for name in sources
        schema = source_schemas[name]
        if name == source
            index = findfirst(c->c.name == column,schema)
            index === nothing && fail("Kolom '$source.$column' tidak ditemukan.")
            return offset + index
        end
        offset += length(schema)
    end
    fail("Sumber '$source' tidak ditemukan pada rencana join.")
end

function _join_links(source::String,joined::Vector{String},atoms)
    links = NTuple{4,String}[]
    for atom in atoms
        if atom[1] == source && atom[3] in joined
            push!(links,atom)
        elseif atom[3] == source && atom[1] in joined
            push!(links,(atom[3],atom[4],atom[1],atom[2]))
        end
    end
    links
end

function _estimate_join_rows(left::Int,right::Int,links,db::Database,stack::Set{String},joined::Vector{String})
    estimate = BigInt(max(0,left)) * BigInt(max(0,right))
    for link in links
        # The first source in a link is the candidate side after normalization.
        candidate_stats = _source_statistics(db,link[1],stack)
        other_stats = _source_statistics(db,link[3],stack)
        candidate_ndv = candidate_stats === nothing ? max(1,right) : _stats_ndv(candidate_stats,link[2])
        other_ndv = other_stats === nothing ? max(1,left) : _stats_ndv(other_stats,link[4])
        estimate = div(estimate,max(candidate_ndv,other_ndv))
    end
    min(estimate,BigInt(typemax(Int))) |> Int
end

"""Greedy left-deep join order. The two-source path keeps its legacy order."""
function plan_join_order(db::Database,q::SelectQuery,schema::Vector{BoundColumn},stack::Set{String};
                         cardinalities=nothing)
    length(q.sources) <= 1 && return (order=copy(q.sources),steps=NamedTuple[])
    atoms = _join_equality_atoms(q.join_condition,schema)
    estimates = Dict(name=>cardinalities === nothing ? _source_estimate(db,name,stack) : cardinalities[name]
                     for name in q.sources)
    start = if length(q.sources) == 2
        q.sources[1]
    else
        q.sources[argmin([(estimates[name],index) for (index,name) in enumerate(q.sources)])]
    end
    order = String[start]; remaining = setdiff(q.sources,[start]); steps = NamedTuple[]
    current_estimate = estimates[start]
    while !isempty(remaining)
        candidates = NamedTuple[]
        for name in remaining
            links = _join_links(name,order,atoms)
            estimate = _estimate_join_rows(current_estimate,estimates[name],links,db,stack,order)
            push!(candidates,(name=name,links=links,estimate=estimate,base=estimates[name],connected=!isempty(links)))
        end
        connected = filter(c->c.connected,candidates)
        pool = isempty(connected) ? candidates : connected
        sort!(pool,by=c->(c.estimate,c.base,findfirst(==(c.name),q.sources)))
        chosen = first(pool)
        push!(order,chosen.name)
        deleteat!(remaining,findfirst(==(chosen.name),remaining))
        current_estimate = chosen.estimate
        push!(steps,(source=chosen.name,links=chosen.links,estimated_rows=chosen.estimate,
            algorithm=:hash_join))
    end
    (order=order,steps=steps)
end

function _join_row_key(row::Row,indices::Vector{Int},floating::Bool)
    values = Any[]
    for index in indices
        value = row[index]
        value === nothing && return nothing
        push!(values,_join_hash_key(value,floating))
    end
    Tuple(values)
end

function _estimated_rows_bytes(rows::Vector{Row})
    isempty(rows) && return 0
    sample = min(length(rows),128)
    total = sum(Base.summarysize(rows[index]) for index in 1:sample;init=0)
    Int(ceil(length(rows) * max(64,total / sample) * 1.25))
end

function _join_should_spill(leftrows::Vector{Row},rightrows::Vector{Row})
    budget = _current_query_budget()
    budget === nothing && return false
    build = length(leftrows) < length(rightrows) ? leftrows : rightrows
    !isempty(build) && _estimated_rows_bytes(build) > budget.max_memory_bytes
end

function _query_budget_spill!(bytes::Int,runs::Int=1)
    budget = _current_query_budget()
    budget === nothing && return nothing
    budget.spill_bytes <= budget.max_spill_bytes - bytes ||
        throw(AiresError("Resource Limit","Query spill melebihi batas $(budget.max_spill_bytes) byte."))
    budget.spill_bytes += bytes
    budget.spill_runs += runs
    nothing
end

function _spill_partition!(paths::Vector{String},rows::Vector{Row},indices::Vector{Int},floating::Bool)
    streams = IO[]
    try
        for path in paths
            push!(streams,open(path,"w"))
        end
        for (position,row) in enumerate(rows)
            _query_budget_tick!()
            key = _join_row_key(row,indices,floating)
            key === nothing && continue
            partition = Int(mod(hash(key),UInt(length(paths)))) + 1
            serialize(streams[partition],(key,position,row))
        end
    finally
        for stream in streams
            close(stream)
        end
    end
end

function _read_spill_partition(path::String)
    result = Tuple{Any,Int,Row}[]
    open(path,"r") do io
        while !eof(io)
            item = deserialize(io)
            item isa Tuple && length(item) == 3 && item[2] isa Int && item[3] isa Row || storageerror("File spill query tidak valid.")
            push!(result,(item[1],item[2],item[3]))
        end
    end
    result
end

"""Grace hash join used when the configured query memory budget is exceeded."""
function _external_hash_join(leftrows::Vector{Row},rightrows::Vector{Row},left_indices::Vector{Int},
                             right_indices::Vector{Int},floating::Bool)
    budget = _current_query_budget()
    budget === nothing && return nothing
    directory = budget.spill_directory
    isdir(directory) || mkpath(directory)
    build = length(leftrows) < length(rightrows) ? leftrows : rightrows
    partitions = min(256,max(8,cld(max(1,_estimated_rows_bytes(build)),max(1,budget.max_memory_bytes))))
    token = string(uuid4())
    left_paths = [joinpath(directory,"join-$token-left-$index.bin") for index in 1:partitions]
    right_paths = [joinpath(directory,"join-$token-right-$index.bin") for index in 1:partitions]
    try
        _spill_partition!(left_paths,leftrows,left_indices,floating)
        _spill_partition!(right_paths,rightrows,right_indices,floating)
        _query_budget_spill!(sum(filesize(path) for path in left_paths;init=0),1)
        _query_budget_spill!(sum(filesize(path) for path in right_paths;init=0),1)
        result = Tuple{Int,Int,Row}[]
        for partition in 1:partitions
            left = _read_spill_partition(left_paths[partition])
            right = _read_spill_partition(right_paths[partition])
            partition_result = Tuple{Int,Int,Row}[]
            buckets = Dict{Any,Vector{Tuple{Int,Row}}}()
            if length(left) < length(right)
                for (key,left_position,leftrow) in left
                    _query_budget_tick!(); _query_budget_work!()
                    push!(get!(buckets,key,Tuple{Int,Row}[]),(left_position,leftrow))
                end
                for (key,right_position,rightrow) in right
                    _query_budget_tick!()
                    for (left_position,leftrow) in get(buckets,key,Tuple{Int,Row}[])
                        joined = vcat(leftrow,rightrow)
                        _query_budget_work!(joined)
                        push!(partition_result,(left_position,right_position,joined))
                    end
                end
            else
                for (key,right_position,rightrow) in right
                    _query_budget_tick!(); _query_budget_work!()
                    push!(get!(buckets,key,Tuple{Int,Row}[]),(right_position,rightrow))
                end
                for (key,left_position,leftrow) in left
                    _query_budget_tick!()
                    for (right_position,rightrow) in get(buckets,key,Tuple{Int,Row}[])
                        joined = vcat(leftrow,rightrow)
                        _query_budget_work!(joined)
                        push!(partition_result,(left_position,right_position,joined))
                    end
                end
            end
            append!(result,partition_result)
        end
        sort!(result,by=item->(item[1],item[2]))
        Row[item[3] for item in result]
    finally
        for path in [left_paths;right_paths]
            isfile(path) && rm(path;force=true)
        end
    end
end

function _hash_join_preserve_left_keys(leftrows::Vector{Row},rightrows::Vector{Row},left_indices::Vector{Int},
                                       right_indices::Vector{Int},floating::Bool)
    (isempty(leftrows) || isempty(rightrows)) && return Row[]
    _join_should_spill(leftrows,rightrows) && return _external_hash_join(leftrows,rightrows,left_indices,right_indices,floating)
    build_side = _join_build_side(leftrows,rightrows)
    if build_side === :right
        buckets = Dict{Any,Vector{Row}}()
        for row in rightrows
            _query_budget_tick!(); key = _join_row_key(row,right_indices,floating); key === nothing && continue
            _query_budget_work!(); push!(get!(buckets,key,Row[]),row)
        end
        result = Row[]
        for left in leftrows
            _query_budget_tick!(); key = _join_row_key(left,left_indices,floating); key === nothing && continue
            for right in get(buckets,key,Row[])
                joined = vcat(left,right)
                _query_budget_work!(joined); push!(result,joined)
            end
        end
        return result
    end
    left_keys = Set{Any}()
    for left in leftrows
        _query_budget_tick!(); key = _join_row_key(left,left_indices,floating); key === nothing && continue
        _query_budget_work!(); push!(left_keys,key)
    end
    matches = Dict{Any,Vector{Row}}()
    for right in rightrows
        _query_budget_tick!(); key = _join_row_key(right,right_indices,floating); key === nothing || key in left_keys || continue
        _query_budget_work!(); push!(get!(matches,key,Row[]),right)
    end
    result = Row[]
    for left in leftrows
        _query_budget_tick!(); key = _join_row_key(left,left_indices,floating); key === nothing && continue
        for right in get(matches,key,Row[])
            joined = vcat(left,right)
            _query_budget_work!(joined); push!(result,joined)
        end
    end
    result
end

function _cartesian_join(leftrows::Vector{Row},rightrows::Vector{Row})
    result = Row[]
    for left in leftrows, right in rightrows
        joined = vcat(left,right)
        _query_budget_work!(joined)
        push!(result,joined)
    end
    result
end

function explain_query(db::Database,q::SelectQuery,stack::Set{String}=Set{String}())
    schema,exprs,labels = validate_query(db,q,stack)
    lines = String["Query: $(query_text(q))"]
    for source in q.sources
        stats = _source_statistics(db,source,stack)
        stats === nothing ? push!(lines,"Scan $source (estimate unknown)") :
            push!(lines,"Scan $source (rows=$(stats.row_count))")
    end
    if length(q.sources) > 1
        plan = plan_join_order(db,q,schema,stack)
        push!(lines,"Join order: " * join(plan.order," -> "))
        for step in plan.steps
            links = isempty(step.links) ? "Cartesian" : join(["$(link[1]).$(link[2])=$(link[3]).$(link[4])" for link in step.links]," & ")
            push!(lines,"  Hash Join $links (estimated rows=$(step.estimated_rows))")
        end
        push!(lines,"  Build side: smaller cardinality (external spill above query memory budget)")
    end
    q.condition === nothing || push!(lines,"Filter: $(expr_text(q.condition))")
    isempty(q.groups) || push!(lines,"Aggregate: hash group by " * join(expr_text.(q.groups),", "))
    isempty(q.orders) || push!(lines,"Sort: " * join(order_item_text.(q.orders),", "))
    q.limit === nothing || push!(lines,"Limit: $(q.limit)")
    lines
end
