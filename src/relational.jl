# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

"""
    RelTable(columns, rows)

An in-memory relation with ordered, uniquely named columns and immutable NamedTuple
rows. Operators accept ordinary, trusted Julia callbacks; no callback is parsed or
evaluated from AiresQL text. Use `relation(session, name)` to read database tables.
"""
struct RelTable{R<:NamedTuple}
    columns::Vector{Symbol}
    rows::Vector{R}
    function RelTable{R}(columns::Vector{Symbol}, rows::Vector{R}) where {R<:NamedTuple}
        new{R}(columns, rows)
    end
end

function RelTable(columns::AbstractVector, rows::AbstractVector)
    names = Symbol.(columns)
    length(unique(names)) == length(names) || fail("Nama kolom relasi harus unik.")
    NT = NamedTuple{Tuple(names)}
    converted = map(rows) do row
        length(row) == length(names) || fail("Lebar baris relasi tidak sesuai kolom.")
        NT(Tuple(row))
    end
    isempty(converted) && return RelTable{NT}(names, NT[])
    RelTable{eltype(converted)}(names, converted)
end

function RelTable(rows::AbstractVector{R}) where {R<:NamedTuple}
    if isempty(rows)
        isconcretetype(R) || fail("Relasi kosong membutuhkan daftar kolom eksplisit.")
        return RelTable(collect(fieldnames(R)), rows)
    end
    RelTable(collect(keys(first(rows))), rows)
end

Base.length(table::RelTable) = length(table.rows)
Base.isempty(table::RelTable) = isempty(table.rows)
Base.iterate(table::RelTable, state...) = iterate(table.rows, state...)
Base.getindex(table::RelTable, index::Integer) = table.rows[index]

function _rel_columns(table::RelTable, columns)
    names = Symbol.(collect(columns))
    all(name -> name in table.columns, names) || fail("Kolom relasi tidak ditemukan.")
    names
end

"""
    relation(session, name; columns=nothing, prefix="")

Materialize a table through the engine's transaction-aware `scan_rows`. To keep
multiple scans in one coherent version, wrap the entire plan in `with_snapshot`.
The scan records read dependencies for serializable transaction validation.
"""
function relation(session::Session, name::AbstractString; columns=nothing, prefix="")
    with_snapshot(session) do
        table_name = String(name)
        db = active_database(session)
        table = get_table(db, table_name)
        selected = columns === nothing ? [c.name for c in table.columns] : String.(columns)
        # scan_rows owns read registration and detached row materialization.
        scanned = scan_rows(session, table_name; columns=selected)
        RelTable([Symbol(prefix, name) for name in selected], scanned)
    end
end

"""Filter using SQL truth: only a predicate result of `true` retains a row."""
function rfilter(table::RelTable, predicate::F) where F
    result = filter(table.rows) do row
        value = predicate(row)
        value isa Union{Bool,Nothing} || typeerror("Predikat relasi membutuhkan Boolean atau NULL.")
        value === true
    end
    RelTable{eltype(result)}(copy(table.columns), result)
end
rfilter(predicate::Function, table::RelTable) = rfilter(table, predicate)

"""Project or compute columns; `transform(row)` returns a Tuple or NamedTuple."""
rmap(table::RelTable, columns::AbstractVector, transform) = RelTable(columns, map(transform, table.rows))
rmap(transform::Function, table::RelTable, columns::AbstractVector) = rmap(table, columns, transform)

function rproject(table::RelTable, columns)
    selected = _rel_columns(table, columns)
    rmap(table, selected, row -> Tuple(getproperty(row, name) for name in selected))
end

function rrename(table::RelTable, mapping::AbstractVector{<:Pair})
    names = copy(table.columns)
    for pair in mapping
        source, target = Symbol(first(pair)), Symbol(last(pair))
        index = findfirst(==(source), table.columns)
        index === nothing && fail("Kolom relasi '$source' tidak ditemukan.")
        names[index] = target
    end
    RelTable(names, table.rows)
end

# Hash keys deliberately distinguish SQL Boolean from numeric one/zero, and
# normalize every exact numeric representation, including signed floating zero.
# Float64 values use their exact binary value rather than rounding exact money.
function _rel_valuekey(value)
    value === nothing && return (:null,)
    value isa Bool && return (:boolean, value)
    if isnumber(value)
        # Julia's integer/rational hash contract lets integer identifiers avoid
        # allocating BigInts while retaining equality with exact 1.0 / 1//1.
        value isa Integer && return (:number, value)
        if value isa Float64
            isfinite(value) || typeerror("Relasi tidak menerima angka non-finite.")
            return (:number, Rational{BigInt}(value))
        end
        return (:number, exact(value))
    end
    (typeof(value), value)
end
_rel_key(row::NamedTuple, names) = Tuple(_rel_valuekey(getproperty(row, name)) for name in names)
_rel_nullkey(row::NamedTuple, names) = any(name -> getproperty(row, name) === nothing, names)

"""SQL comparison with NULL propagation and exact numeric comparison."""
function sqlcmp(op::Symbol, left, right)
    (left === nothing || right === nothing) && return nothing
    op in (:eq, :ne, :lt, :le, :gt, :ge) || fail("Operator perbandingan '$op' tidak dikenal.")
    if isnumber(left) && isnumber(right)
        if left isa Integer && right isa Integer
            # Integer keys and sort columns dominate most relational plans.
        elseif left isa Money && right isa Money
            left, right = left.minor, right.minor
        elseif left isa Decimal && right isa Decimal && left.scale == right.scale
            left, right = left.coefficient, right.coefficient
        else
            left = left isa Float64 ? Rational{BigInt}(left) : exact(left)
            right = right isa Float64 ? Rational{BigInt}(right) : exact(right)
        end
    elseif typeof(left) !== typeof(right)
        typeerror("Tidak dapat membandingkan tipe $(typeof(left)) dan $(typeof(right)).")
    end
    op === :eq ? left == right : op === :ne ? left != right :
    op === :lt ? left < right : op === :le ? left <= right :
    op === :gt ? left > right : left >= right
end

sqlnot(value::Nothing) = nothing
sqlnot(value::Bool) = !value
function sqland(left::Union{Bool,Nothing}, right::Union{Bool,Nothing})
    (left === false || right === false) && return false
    (left === nothing || right === nothing) && return nothing
    true
end
function sqlor(left::Union{Bool,Nothing}, right::Union{Bool,Nothing})
    (left === true || right === true) && return true
    (left === nothing || right === nothing) && return nothing
    false
end

"""SQL IN: NULL input or an unmatched list containing NULL yields NULL."""
function sqlin(value, candidates)
    value === nothing && return nothing
    unknown = false
    for candidate in candidates
        candidate === nothing && (unknown = true; continue)
        sqlcmp(:eq, value, candidate) === true && return true
    end
    unknown ? nothing : false
end

"""Compile a SQL LIKE pattern once; `%` matches a sequence and `_` one character."""
struct SqlLike
    regex::Regex
end
function SqlLike(pattern::AbstractString; escape::Char='\\')
    buffer = IOBuffer()
    print(buffer, "\\A")
    escaped = false
    for char in pattern
        if !escaped && char == escape
            escaped = true
            continue
        elseif !escaped && char == '%'
            print(buffer, ".*")
        elseif !escaped && char == '_'
            print(buffer, ".")
        else
            char in ('\\', '.', '^', '$', '|', '?', '*', '+', '(', ')', '[', ']', '{', '}') && print(buffer, '\\')
            print(buffer, char)
        end
        escaped = false
    end
    escaped && fail("Pola LIKE berakhir dengan karakter escape.")
    print(buffer, "\\z")
    SqlLike(Regex(String(take!(buffer)), "s"))
end
sqllike(value::Nothing, pattern) = nothing
sqllike(value::AbstractString, pattern::SqlLike) = occursin(pattern.regex, value)
sqllike(value::AbstractString, pattern::AbstractString) = sqllike(value, SqlLike(pattern))
(pattern::SqlLike)(value) = sqllike(value, pattern)

# Fast paths preserve exact cents/decimals rather than converting them to float.
function radd(left, right)
    (left === nothing || right === nothing) && return nothing
    if left isa Int64 && right isa Int64
        try return Base.Checked.checked_add(left, right) catch error
            error isa OverflowError || rethrow()
        end
    elseif left isa Money && right isa Money
        try return Money(Base.Checked.checked_add(left.minor, right.minor)) catch error
            error isa OverflowError || rethrow()
        end
    elseif left isa Decimal && right isa Decimal && left.scale == right.scale
        try return Decimal(Base.Checked.checked_add(left.coefficient, right.coefficient), left.scale) catch error
            error isa OverflowError || rethrow()
        end
    end
    arithmetic(:plus, left, right)
end
rsub(left, right) = arithmetic(:minus, left, right)
function rmul(left, right)
    (left === nothing || right === nothing) && return nothing
    if left isa Int64 && right isa Int64
        try return Base.Checked.checked_mul(left, right) catch error
            error isa OverflowError || rethrow()
        end
    elseif left isa Money && right isa Int64
        try return Money(Base.Checked.checked_mul(left.minor, Int128(right))) catch error
            error isa OverflowError || rethrow()
        end
    elseif right isa Money && left isa Int64
        return rmul(right, left)
    end
    arithmetic(:star, left, right)
end
rdiv(left, right) = arithmetic(:slash, left, right)

function _rel_join_columns(left::RelTable, right::RelTable)
    names = copy(left.columns)
    for name in right.columns
        target = name
        while target in names
            target = Symbol(target, "_right")
        end
        push!(names, target)
    end
    names
end

"""
    hashjoin(left, right; on, kind=:inner, predicate=(left,right)->true)

Hash equijoins support `:inner`, `:left`, `:semi`, and `:anti`. `on` is a list
such as `[:customer_id => :id]`; an empty list gives a Cartesian join. NULL keys
never match. The optional residual predicate uses SQL truth and is evaluated
before deciding whether an outer/semi/anti join has a match. Right-side column
collisions gain `_right` suffixes. Semi/anti joins retain only left columns.
"""
function hashjoin(left::RelTable, right::RelTable;
                  on::AbstractVector{<:Pair}, kind::Symbol=:inner,
                  predicate=(left, right) -> true)
    kind in (:inner, :left, :semi, :anti) || fail("Jenis join '$kind' tidak dikenal.")
    leftkeys = _rel_columns(left, first.(on))
    rightkeys = _rel_columns(right, last.(on))
    buckets = Dict{Any,Vector{Int}}()
    for (index, row) in enumerate(right.rows)
        _rel_nullkey(row, rightkeys) && continue
        key = _rel_key(row, rightkeys)
        push!(get!(() -> Int[], buckets, key), index)
    end
    only_left = kind in (:semi, :anti)
    names = only_left ? copy(left.columns) : _rel_join_columns(left, right)
    NT = NamedTuple{Tuple(names)}
    result = NT[]
    null_right = Tuple(nothing for _ in right.columns)
    for lrow in left.rows
        matches = _rel_nullkey(lrow, leftkeys) ? nothing : get(buckets, _rel_key(lrow, leftkeys), nothing)
        matched = false
        if matches !== nothing
            for index in matches
                rrow = right.rows[index]
                value = predicate(lrow, rrow)
                value isa Union{Bool,Nothing} || typeerror("Predikat join membutuhkan Boolean atau NULL.")
                value === true || continue
                matched = true
                if kind === :semi
                    push!(result, NT(Tuple(lrow)))
                    break
                elseif kind === :anti
                    break
                end
                push!(result, NT((Tuple(lrow)..., Tuple(rrow)...)))
            end
        end
        if !matched
            kind === :left && push!(result, NT((Tuple(lrow)..., null_right...)))
            kind === :anti && push!(result, NT(Tuple(lrow)))
        end
    end
    RelTable{NT}(names, result)
end

abstract type RelAgg end
struct Count{F} <: RelAgg
    selector::F
end
Count() = Count(nothing)
struct Sum{F} <: RelAgg
    selector::F
end
struct Avg{F} <: RelAgg
    selector::F
end
struct Min{F} <: RelAgg
    selector::F
end
struct Max{F} <: RelAgg
    selector::F
end
struct CountDistinct{F} <: RelAgg
    selector::F
end

_rel_select(selector::Symbol, row::NamedTuple) = getproperty(row, selector)
_rel_select(selector::AbstractString, row::NamedTuple) = getproperty(row, Symbol(selector))
_rel_select(selector, row::NamedTuple) = selector(row)

mutable struct _RelAggState
    value::Any
    count::Int64
    seen::Union{Nothing,Set{Any}}
end
_rel_state(aggregate::RelAgg) = _RelAggState(nothing, 0, aggregate isa CountDistinct ? Set{Any}() : nothing)

function _rel_step!(state::_RelAggState, aggregate::RelAgg, row::NamedTuple)
    if aggregate isa Count && aggregate.selector === nothing
        state.count += 1
        return
    end
    value = _rel_select(aggregate.selector, row)
    value === nothing && return
    if aggregate isa Count
        state.count += 1
    elseif aggregate isa CountDistinct
        push!(state.seen, _rel_valuekey(value))
    elseif aggregate isa Union{Sum,Avg}
        isnumber(value) || typeerror("Sum/Avg membutuhkan angka.")
        state.value = state.count == 0 ? value : radd(state.value, value)
        state.count += 1
    elseif aggregate isa Union{Min,Max}
        if state.count == 0 || sqlcmp(aggregate isa Min ? :lt : :gt, value, state.value) === true
            state.value = value
        end
        state.count += 1
    end
    nothing
end

function _rel_finish(state::_RelAggState, aggregate::RelAgg)
    aggregate isa Count && return state.count
    aggregate isa CountDistinct && return Int64(length(state.seen))
    state.count == 0 && return nothing
    aggregate isa Avg ? rdiv(state.value, state.count) : state.value
end

"""
    groupby(table, keys, aggregates)

One-pass hash aggregation. `aggregates` is `[:total => Sum(:amount), :n => Count()]`.
Selectors may be a column name or a row callback. All aggregates except Count()
ignore NULL values. Scalar aggregation (empty `keys`) always emits one row, even
on empty input; SUM/AVG/MIN/MAX then yield NULL and counts zero. Group ordering
follows first occurrence and can be changed with `rsort`.
"""
function groupby(table::RelTable, keys, aggregates::AbstractVector{<:Pair})
    keynames = _rel_columns(table, keys)
    aggregators = RelAgg[last(pair) for pair in aggregates]
    names = [keynames; Symbol[first(pair) for pair in aggregates]]
    length(unique(names)) == length(names) || fail("Nama kolom hasil groupby harus unik.")
    for aggregate in aggregators
        selector = aggregate.selector
        selector isa Union{Symbol,AbstractString} && _rel_columns(table, [selector])
    end
    indices = Dict{Any,Int}()
    groupkeys = Tuple[]
    states = Vector{_RelAggState}[]
    if isempty(keynames)
        indices[()] = 1
        push!(groupkeys, ())
        push!(states, [_rel_state(aggregate) for aggregate in aggregators])
    end
    for row in table.rows
        key = _rel_key(row, keynames)
        index = get(indices, key, 0)
        if index == 0
            push!(groupkeys, Tuple(getproperty(row, name) for name in keynames))
            push!(states, [_rel_state(aggregate) for aggregate in aggregators])
            index = length(states)
            indices[key] = index
        end
        state = states[index]
        for n in eachindex(aggregators)
            _rel_step!(state[n], aggregators[n], row)
        end
    end
    result = map(eachindex(states)) do index
        (groupkeys[index]..., (_rel_finish(states[index][n], aggregators[n]) for n in eachindex(aggregators))...)
    end
    RelTable(names, result)
end

"""Evaluate a scalar aggregate directly without creating an intermediate group."""
function raggregate(table::RelTable, aggregate::RelAgg)
    selector = aggregate.selector
    selector isa Union{Symbol,AbstractString} && _rel_columns(table, [selector])
    state = _rel_state(aggregate)
    for row in table.rows
        _rel_step!(state, aggregate, row)
    end
    _rel_finish(state, aggregate)
end

"""Stable ORDER BY with mixed ascending/descending keys; NULLS LAST by default.

`nulls` accepts one placement for every key, or a vector of placements when a
plan needs per-key NULL semantics.
"""
function rsort(table::RelTable, specs::AbstractVector{<:Pair}; nulls=:last)
    names = _rel_columns(table, first.(specs))
    directions = Symbol.(last.(specs))
    keys = [Tuple(getproperty(row, name) for name in names) for row in table.rows]
    result = table.rows[stable_sort_permutation(keys,directions,sqlcmp;nulls)]
    RelTable{eltype(result)}(copy(table.columns), result)
end

function rlimit(table::RelTable, limit::Integer; offset::Integer=0)
    limit >= 0 && offset >= 0 || fail("Limit dan offset harus nonnegatif.")
    start = min(offset, length(table)) + 1
    stop = min(big(offset) + big(limit), length(table))
    result = table.rows[Int(start):Int(stop)]
    RelTable{eltype(result)}(copy(table.columns), result)
end

"""SQL DISTINCT. NULLs and equal exact numeric representations share a key."""
function rdistinct(table::RelTable; columns=table.columns)
    names = _rel_columns(table, columns)
    seen = Set{Any}()
    result = filter(table.rows) do row
        key = _rel_key(row, names)
        key in seen && return false
        push!(seen, key)
        true
    end
    RelTable{eltype(result)}(copy(table.columns), result)
end

"""UNION ALL by column position; use `all=false` for set union."""
function runion(left::RelTable, right::RelTable; all::Bool=true)
    length(left.columns) == length(right.columns) || fail("UNION membutuhkan lebar relasi yang sama.")
    result = RelTable(left.columns, vcat(Tuple.(left.rows), Tuple.(right.rows)))
    all ? result : rdistinct(result)
end

"""Convert analytical output to the existing AiresDB QueryResult/formatter API."""
function query_result(table::RelTable)
    QueryResult(String.(table.columns), Row[Cell[values(row)...] for row in table.rows])
end
