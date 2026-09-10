# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

struct BoundColumn
    source::String
    name::String
    kind::Symbol
end
const AGGREGATES = (:count, :countif, :sum, :avg, :max, :min)
has_aggregate(::Union{Literal,ColumnRef,BoundRef,Wildcard}) = false
has_aggregate(e::UnaryExpr) = has_aggregate(e.operand)
has_aggregate(e::BinaryExpr) = has_aggregate(e.left) || has_aggregate(e.right)
has_aggregate(e::LogicalAnd) = has_aggregate(e.left) || has_aggregate(e.right)
has_aggregate(e::LogicalOr) = has_aggregate(e.left) || has_aggregate(e.right)
has_aggregate(e::CallExpr) = e.name in AGGREGATES || any(has_aggregate, e.args)

function resolve_column(e::ColumnRef, schema::Vector{BoundColumn})
    matches = findall(c -> c.name == e.name && (e.table === nothing || c.source == e.table), schema)
    isempty(matches) && fail("Kolom '$(expr_text(e))' tidak ditemukan pada tabel '$(join(unique(c.source for c in schema), ", "))'.")
    length(matches) == 1 || fail("Kolom '$(e.name)' ambigu; gunakan Tabel.Kolom.")
    only(matches)
end

bind_expression(e::Union{Literal,Wildcard,BoundRef},schema::Vector{BoundColumn}) = e
bind_expression(e::ColumnRef,schema::Vector{BoundColumn}) = BoundRef(resolve_column(e,schema))
bind_expression(e::UnaryExpr,schema::Vector{BoundColumn}) = UnaryExpr(e.op,bind_expression(e.operand,schema))
bind_expression(e::BinaryExpr,schema::Vector{BoundColumn}) = BinaryExpr(e.op,bind_expression(e.left,schema),bind_expression(e.right,schema))
bind_expression(e::LogicalAnd,schema::Vector{BoundColumn}) = LogicalAnd(bind_expression(e.left,schema),bind_expression(e.right,schema))
bind_expression(e::LogicalOr,schema::Vector{BoundColumn}) = LogicalOr(bind_expression(e.left,schema),bind_expression(e.right,schema))
bind_expression(e::CallExpr,schema::Vector{BoundColumn}) = CallExpr(e.name,ExprNode[bind_expression(a,schema) for a in e.args])
bind_condition(e::Nothing,schema::Vector{BoundColumn}) = nothing
bind_condition(e::ExprNode,schema::Vector{BoundColumn}) = bind_expression(e,schema)

function normalized_number(q::Exact)::Cell
    denominator(q) == 1 && typemin(Int64) <= numerator(q) <= typemax(Int64) && return Int64(numerator(q))
    q
end
function arithmetic(op::Symbol, a, b)::Cell
    (a === nothing || b === nothing) && return nothing
    isnumber(a) && isnumber(b) || typeerror("Operator $(OP_TEXT[op]) membutuhkan angka.")
    # Integer cells are by far the common case in predicates, projections, and
    # aggregates.  Keep them as Int64 while the exact result fits, then fall
    # through to Rational{BigInt} for overflow or a fractional division.
    if a isa Int64 && b isa Int64
        if op == :slash
            iszero(b) && fail("Pembagian dengan nol.")
            if !(a == typemin(Int64) && b == -1)
                quotient,remainder = divrem(a,b)
                iszero(remainder) && return quotient
            end
        else
            try
                return op == :plus ? Base.Checked.checked_add(a,b) :
                       op == :minus ? Base.Checked.checked_sub(a,b) :
                       Base.Checked.checked_mul(a,b)
            catch error
                error isa OverflowError || rethrow()
            end
        end
    end
    floating = a isa Float64 || b isa Float64
    x = floating ? (a isa Float64 ? a : Float64(exact(a))) : exact(a)
    y = floating ? (b isa Float64 ? b : Float64(exact(b))) : exact(b)
    op == :slash && iszero(y) && fail("Pembagian dengan nol.")
    value = op == :plus ? x+y : op == :minus ? x-y : op == :star ? x*y : x/y
    if floating
        isfinite(value) || typeerror("Hasil Float tidak hingga.")
        return value
    end
    normalized_number(value)
end

function compare_values(op::Symbol, a, b)::Cell
    (a === nothing || b === nothing) && return nothing
    # AiresQL stores ordinary integer cells as Int64.  Converting both sides
    # through Rational{BigInt} made every WHERE/order comparison allocate.
    if a isa Int64 && b isa Int64
        return op == :eq ? a == b : op == :gt ? a > b : op == :lt ? a < b : op == :ge ? a >= b : a <= b
    end
    if isnumber(a) && isnumber(b)
        floating = a isa Float64 || b isa Float64
        a = floating ? (a isa Float64 ? a : Float64(exact(a))) : exact(a)
        b = floating ? (b isa Float64 ? b : Float64(exact(b))) : exact(b)
    elseif typeof(a) !== typeof(b)
        typeerror("Tidak dapat membandingkan tipe $(typeof(a)) dan $(typeof(b)).")
    end
    op == :eq ? a == b : op == :gt ? a > b : op == :lt ? a < b : op == :ge ? a >= b : a <= b
end

function logical_operand(value, operator::String)::Union{Bool,Nothing}
    value isa Union{Bool,Nothing} || typeerror("Operand '$operator' membutuhkan ekspresi Boolean atau NULL.")
    value
end

function logical_and(left, right)::Cell
    left = logical_operand(left, "&:")
    right = logical_operand(right, "&:")
    (left === false || right === false) && return false
    (left === nothing || right === nothing) && return nothing
    true
end

function logical_or(left, right)::Cell
    left = logical_operand(left, "O:")
    right = logical_operand(right, "O:")
    (left === true || right === true) && return true
    (left === nothing || right === nothing) && return nothing
    false
end

"""Return a stable permutation for multi-key values with explicit NULL placement.

`compare` is injected so AiresQL can retain its comparison rules while the public
relational API retains its own exact numeric comparison semantics.  This is the
single sorting core used by both paths.
"""
function stable_sort_permutation(keys::AbstractVector, directions::AbstractVector{Symbol}, compare;
                                 nulls=:last)
    all(direction -> direction in (:asc, :desc), directions) || fail("Urutan harus :asc atau :desc.")
    all(key -> length(key) == length(directions), keys) || fail("Jumlah nilai kunci urut tidak konsisten.")
    placements = if nulls isa Symbol
        nulls in (:first, :last) || fail("Urutan NULL harus :first atau :last.")
        fill(nulls, length(directions))
    elseif nulls isa AbstractVector
        length(nulls) == length(directions) || fail("Jumlah aturan NULL tidak sesuai kunci urut.")
        values = Symbol.(nulls)
        all(value -> value in (:first, :last), values) || fail("Urutan NULL harus :first atau :last.")
        values
    else
        fail("Urutan NULL harus :first atau :last.")
    end
    function less(left_index, right_index)
        left, right = keys[left_index], keys[right_index]
        for index in eachindex(directions)
            lvalue, rvalue = left[index], right[index]
            lvalue === nothing && rvalue === nothing && continue
            lvalue === nothing && return placements[index] === :first
            rvalue === nothing && return placements[index] === :last
            compare(:eq, lvalue, rvalue) === true && continue
            return compare(directions[index] === :asc ? :lt : :gt, lvalue, rvalue) === true
        end
        false
    end
    sort(collect(eachindex(keys)); lt=less, alg=Base.Sort.MergeSort)
end

function evaluate(e::ExprNode, row::Row, schema::Vector{BoundColumn}, group::Union{Nothing,Vector{Row}}=nothing)::Cell
    if e isa Literal
        return e.value
    elseif e isa ColumnRef
        return row[resolve_column(e, schema)]
    elseif e isa BoundRef
        return row[e.index]
    elseif e isa UnaryExpr
        return arithmetic(e.op, Int64(0), evaluate(e.operand, row, schema, group))
    elseif e isa BinaryExpr
        a = evaluate(e.left, row, schema, group); b = evaluate(e.right, row, schema, group)
        return e.op in (:plus,:minus,:star,:slash) ? arithmetic(e.op,a,b) : compare_values(e.op,a,b)
    elseif e isa LogicalAnd
        return logical_and(evaluate(e.left, row, schema, group), evaluate(e.right, row, schema, group))
    elseif e isa LogicalOr
        return logical_or(evaluate(e.left, row, schema, group), evaluate(e.right, row, schema, group))
    elseif e isa CallExpr
        e.name == :integral && fail("Integral belum tersedia pada AiresDB v0.1.")
        group === nothing && fail("Aggregate hanya boleh digunakan pada hasil SELECT.")
        arg = only(e.args)
        if e.name == :count && arg isa Wildcard
            return Int64(length(group))
        end
        # Aggregate directly over the group.  Materializing one Cell per input
        # row made a simple SUM retain and then filter a second row-sized array.
        if e.name == :count
            count = Int64(0)
            for row in group
                evaluate(arg,row,schema) === nothing || (count += 1)
            end
            return count
        elseif e.name == :countif
            count = Int64(0)
            for row in group
                evaluate(arg,row,schema) === true && (count += 1)
            end
            return count
        elseif e.name in (:sum,:avg)
            total::Cell = Int64(0)
            integer_total = Int64(0)
            integer_mode = true
            count = Int64(0)
            for row in group
                value = evaluate(arg,row,schema)
                value === nothing && continue
                if integer_mode && value isa Int64
                    try
                        integer_total = Base.Checked.checked_add(integer_total,value)
                    catch error
                        error isa OverflowError || rethrow()
                        total = arithmetic(:plus,integer_total,value)
                        integer_mode = false
                    end
                else
                    if integer_mode
                        total = integer_total
                        integer_mode = false
                    end
                    total = arithmetic(:plus,total,value)
                end
                count += 1
            end
            iszero(count) && return nothing
            integer_mode && (total = integer_total)
            return e.name == :avg ? arithmetic(:slash,total,count) : total
        elseif e.name in (:min,:max)
            best::Cell = nothing
            for row in group
                value = evaluate(arg,row,schema)
                value === nothing && continue
                if best === nothing || compare_values(e.name == :min ? :lt : :gt,value,best) === true
                    best = value
                end
            end
            return best
        end
    end
    fail("Ekspresi tidak dapat dieksekusi.")
end

function filter_matches(condition::Union{Nothing,ExprNode}, row::Row, schema::Vector{BoundColumn})
    condition === nothing && return true
    value = evaluate(condition, row, schema)
    value === nothing && return false
    value isa Bool || typeerror("Dengan membutuhkan ekspresi Boolean.")
    value
end
