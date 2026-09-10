# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

const NUMERIC_KINDS = (:I,:F,:D,:U,:NUMBER,:NULL)

function infer_expression(e::ExprNode, schema::Vector{BoundColumn}; allow_aggregate=true, inside_aggregate=false)::Symbol
    if e isa Literal
        v = e.value
        return v === nothing ? :NULL : v isa Bool ? :B : v isa String ? :C : v isa Float64 ? :F : isnumber(v) ? :NUMBER : :UNKNOWN
    elseif e isa ColumnRef
        return schema[resolve_column(e, schema)].kind
    elseif e isa BoundRef
        return schema[e.index].kind
    elseif e isa Wildcard
        fail("Wildcard '*' hanya boleh menjadi proyeksi penuh atau argumen Count(*).")
    elseif e isa UnaryExpr
        kind = infer_expression(e.operand,schema; allow_aggregate,inside_aggregate)
        kind in NUMERIC_KINDS || typeerror("Operator unary membutuhkan angka.")
        return kind == :F ? :F : :NUMBER
    elseif e isa BinaryExpr
        left = infer_expression(e.left,schema; allow_aggregate,inside_aggregate)
        right = infer_expression(e.right,schema; allow_aggregate,inside_aggregate)
        if e.op in (:plus,:minus,:star,:slash)
            left in NUMERIC_KINDS && right in NUMERIC_KINDS || typeerror("Arithmetic membutuhkan kolom atau literal numerik.")
            return left == :F || right == :F ? :F : :NUMBER
        end
        left == :NULL || right == :NULL || left == right || (left in NUMERIC_KINDS && right in NUMERIC_KINDS) || typeerror("Tipe pada perbandingan tidak cocok ($left, $right).")
        return :B
    elseif e isa LogicalAnd || e isa LogicalOr
        left = infer_expression(e.left,schema; allow_aggregate,inside_aggregate)
        right = infer_expression(e.right,schema; allow_aggregate,inside_aggregate)
        left in (:B,:NULL) && right in (:B,:NULL) || typeerror("Operator $(e isa LogicalAnd ? "&:" : "O:") membutuhkan dua ekspresi Boolean.")
        return :B
    elseif e isa CallExpr
        e.name == :integral && fail("Integral belum tersedia pada AiresDB v0.1.")
        e.name in AGGREGATES || fail("Fungsi '$(e.name)' tidak dikenal.")
        allow_aggregate && !inside_aggregate || fail("Aggregate bersarang atau aggregate dalam filter/group tidak diizinkan.")
        length(e.args) == 1 || syntaxerror("$(e.name) membutuhkan tepat satu argumen.")
        arg = only(e.args)
        e.name == :count && arg isa Wildcard && return :I
        kind = infer_expression(arg,schema; allow_aggregate=false,inside_aggregate=true)
        e.name == :count && return :I
        if e.name == :countif
            kind in (:B,:NULL) || typeerror("Countif membutuhkan ekspresi Boolean.")
            return :I
        elseif e.name in (:sum,:avg)
            kind in NUMERIC_KINDS || typeerror("$(e.name) membutuhkan angka.")
            return kind == :F ? :F : :NUMBER
        end
        return kind
    end
    fail("AST ekspresi tidak dikenal.")
end

function source_schema(db::Database, name::String, stack::Set{String})
    if haskey(db.tables,name)
        return [BoundColumn(name,c.name,c.kind) for c in db.tables[name].columns]
    elseif haskey(db.views,name)
        name in stack && fail("Siklus view terdeteksi pada '$name'.")
        length(stack) < 64 || fail("Rantai view terlalu dalam (maksimal 64).")
        nextstack = union(stack, Set([name]))
        schema, exprs, labels = validate_query(db,db.views[name].query,nextstack)
        length(unique(labels)) == length(labels) || fail("View '$name' memiliki nama kolom duplikat.")
        return [BoundColumn(name,label,infer_expression(e,schema)) for (label,e) in zip(labels,exprs)]
    end
    fail("Tabel atau view '$name' tidak ditemukan.")
end

function group_compatible(e::ExprNode, schema::Vector{BoundColumn}, indices::Set{Int})
    e isa Literal && return true
    e isa ColumnRef && return resolve_column(e,schema) in indices
    e isa CallExpr && e.name in AGGREGATES && return true
    e isa UnaryExpr && return group_compatible(e.operand,schema,indices)
    e isa BinaryExpr && return group_compatible(e.left,schema,indices) && group_compatible(e.right,schema,indices)
    e isa LogicalAnd && return group_compatible(e.left,schema,indices) && group_compatible(e.right,schema,indices)
    e isa LogicalOr && return group_compatible(e.left,schema,indices) && group_compatible(e.right,schema,indices)
    false
end

function validate_order_items(q::SelectQuery, schema::Vector{BoundColumn}, indices::Set{Int}, grouped::Bool)
    for item in q.orders
        item.direction in (SortAscending, SortDescending) || fail("Arah M: tidak valid.")
        expression = item.expression
        if grouped
            infer_expression(expression,schema)
            group_compatible(expression,schema,indices) || fail("Ekspresi M: pada hasil Grup Dari harus berupa aggregate atau hanya memakai kolom Grup Dari.")
        else
            # An ORDER key may be absent from the projection, but must still resolve
            # against the source schema and cannot introduce an aggregate by itself.
            infer_expression(expression,schema; allow_aggregate=false)
        end
    end
    nothing
end

function validate_query(db::Database, q::SelectQuery, stack::Set{String}=Set{String}())
    length(q.sources) in (1,2) || fail("v0.1 mendukung satu sumber atau INNER JOIN dua sumber.")
    length(unique(q.sources)) == length(q.sources) || fail("Self join membutuhkan alias dan belum tersedia.")
    schema = reduce(vcat, [source_schema(db,n,stack) for n in q.sources])
    if length(q.sources) == 2
        j = q.join_condition
        j isa BinaryExpr && j.op == :eq && j.left isa ColumnRef && j.right isa ColumnRef || fail("INNER JOIN membutuhkan kesetaraan dua kolom.")
        a = resolve_column(j.left,schema); b = resolve_column(j.right,schema)
        schema[a].source != schema[b].source || fail("Kolom JOIN harus berasal dari dua tabel berbeda.")
        infer_expression(j,schema; allow_aggregate=false)
    elseif q.join_condition !== nothing
        fail("Gabung membutuhkan dua tabel.")
    end
    if q.condition !== nothing
        infer_expression(q.condition,schema; allow_aggregate=false) in (:B,:NULL) || typeerror("Dengan membutuhkan ekspresi Boolean.")
    end
    indices = Set{Int}()
    for e in q.groups
        e isa ColumnRef || fail("Grup Dari v0.1 membutuhkan nama kolom.")
        i = resolve_column(e,schema)
        i in indices && fail("Kolom Grup Dari berulang.")
        push!(indices,i)
    end
    exprs = ExprNode[]; labels = String[]
    for (e,label) in zip(q.expressions,q.labels)
        if e isa Wildcard
            append!(exprs, [ColumnRef(c.source,c.name) for c in schema])
            append!(labels, [length(q.sources)==1 ? c.name : c.source*"."*c.name for c in schema])
        else
            push!(exprs,e); push!(labels,label)
        end
    end
    isempty(exprs) && syntaxerror("SELECT membutuhkan minimal satu kolom.")
    for e in exprs; infer_expression(e,schema); end
    grouped = !isempty(q.groups) || any(has_aggregate,exprs)
    if grouped
        all(e->group_compatible(e,schema,indices),exprs) || fail("Kolom non-aggregate harus tercantum pada Grup Dari.")
    end
    validate_order_items(q,schema,indices,grouped)
    schema,exprs,labels
end
