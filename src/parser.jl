# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

mutable struct Parser
    tokens::Vector{Token}
    index::Int
    depth::Int
end
Parser(tokens::Vector{Token}) = Parser(tokens, 1, 0)
peek(p::Parser) = p.tokens[p.index]
take_token!(p::Parser) = (t = peek(p); p.index += 1; t)
isword(p::Parser, s::AbstractString) = peek(p).kind == :word && lowercase(peek(p).text) == lowercase(s)
function expect!(p::Parser, kind::Symbol)
    t = peek(p)
    t.kind == kind || syntaxerror("Mengharapkan $kind, menemukan '$(t.text)' pada baris $(t.line), kolom $(t.column).")
    take_token!(p)
end
function keyword!(p::Parser, word::String)
    isword(p, word) || syntaxerror("Mengharapkan keyword '$word', menemukan '$(peek(p).text)'.")
    take_token!(p)
end
quoted!(p::Parser) = expect!(p, :string).text

const PRECEDENCE = Dict(:eq=>10, :gt=>10, :lt=>10, :ge=>10, :le=>10,
    :logicaland=>5, :logicalor=>4,
    :plus=>20, :minus=>20, :star=>30, :slash=>30)

function parse_expression!(p::Parser, minprec::Int=0)::ExprNode
    p.depth += 1
    p.depth <= 128 || syntaxerror("Ekspresi terlalu dalam (maksimal 128).")
    t = take_token!(p)
    left = if t.kind == :number
        value = occursin('.', t.text) ? Decimal(t.text) : tryparse(Int64, t.text)
        Literal(value === nothing ? Decimal(t.text) : value)
    elseif t.kind == :string
        Literal(t.text)
    elseif t.kind == :star
        Wildcard()
    elseif t.kind in (:plus, :minus)
        UnaryExpr(t.kind, parse_expression!(p, 40))
    elseif t.kind == :lparen
        e = parse_expression!(p)
        expect!(p, :rparen)
        e
    elseif t.kind == :word
        word = lowercase(t.text)
        if word == "null"
            Literal(nothing)
        elseif word in ("true", "false", "benar", "salah")
            Literal(word in ("true", "benar"))
        elseif peek(p).kind == :lparen
            take_token!(p); args = ExprNode[]
            if peek(p).kind != :rparen
                push!(args, parse_expression!(p))
                while peek(p).kind in (:amp, :comma)
                    take_token!(p); push!(args, parse_expression!(p))
                end
            end
            expect!(p, :rparen)
            CallExpr(Symbol(word), args)
        elseif peek(p).kind == :dot
            take_token!(p)
            ColumnRef(t.text, expect!(p, :word).text)
        else
            ColumnRef(nothing, t.text)
        end
    else
        syntaxerror("Ekspresi tidak valid di dekat '$(t.text)'.")
    end
    while haskey(PRECEDENCE, peek(p).kind) && PRECEDENCE[peek(p).kind] >= minprec
        op = take_token!(p).kind
        right = parse_expression!(p, PRECEDENCE[op]+1)
        left = op == :logicaland ? LogicalAnd(left, right) :
               op == :logicalor ? LogicalOr(left, right) : BinaryExpr(op, left, right)
    end
    p.depth -= 1
    left
end

function parse_expression(text::AbstractString)
    p = Parser(tokenize(text))
    expr = parse_expression!(p)
    expect!(p, :eof)
    pending = Tuple{ExprNode,Int}[(expr,1)]
    while !isempty(pending)
        node,depth = pop!(pending)
        depth <= 128 || syntaxerror("Ekspresi terlalu dalam (maksimal 128).")
        if node isa BinaryExpr
            push!(pending,(node.left,depth+1),(node.right,depth+1))
        elseif node isa LogicalAnd
            push!(pending,(node.left,depth+1),(node.right,depth+1))
        elseif node isa LogicalOr
            push!(pending,(node.left,depth+1),(node.right,depth+1))
        elseif node isa UnaryExpr
            push!(pending,(node.operand,depth+1))
        elseif node isa CallExpr
            append!(pending,[(a,depth+1) for a in node.args])
        end
    end
    expr
end

function parse_order_by_item(source::AbstractString)::OrderByItem
    p = Parser(tokenize(source))
    expression = parse_expression!(p)
    direction_token = peek(p)
    direction_token.kind == :word || syntaxerror("M: membutuhkan arah Atas atau Bawah setelah ekspresi urut.")
    direction_word = lowercase(take_token!(p).text)
    direction = direction_word == "atas" ? SortAscending :
                direction_word == "bawah" ? SortDescending :
                syntaxerror("Arah urut '$(direction_token.text)' tidak dikenal; gunakan Atas atau Bawah.")
    expect!(p, :eof)
    OrderByItem(expression, direction)
end

function parse_order_by_clause(source::AbstractString)::OrderByClause
    fields = split_fields(source)
    any(isempty, fields) && syntaxerror("M: membutuhkan minimal satu kolom dengan arah Atas atau Bawah.")
    OrderByClause(OrderByItem[parse_order_by_item(field) for field in fields])
end

function parse_column_definition(source::AbstractString)
    p = Parser(tokenize(source))
    name = expect!(p, :word).text
    expect!(p, :eq)
    kind = Symbol(uppercase(expect!(p, :word).text))
    kind in (:D,:B,:F,:I,:C,:T,:W,:TW,:U) || typeerror("Tipe '$kind' tidak dikenal.")
    maxlen = kind == :C ? 255 : 0
    unique = false; primary = false; nullable = true; seen = Set{Symbol}()
    if peek(p).kind == :lparen
        take_token!(p)
        while true
            t = take_token!(p)
            flag = if t.kind == :number
                kind == :C || syntaxerror("Panjang hanya berlaku untuk tipe C.")
                maxlen = something(tryparse(Int, t.text), 0)
                1 <= maxlen <= 1_000_000 || typeerror("Panjang C harus 1 sampai 1000000.")
                :length
            elseif t.kind == :word
                word = lowercase(t.text)
                if word == "n"
                    unique = true; :unique
                elseif word == "p"
                    primary = true; :primary
                elseif word == "null"
                    :null
                elseif word == "not"
                    keyword!(p, "null"); nullable = false; :notnull
                else
                    syntaxerror("Constraint '$(t.text)' tidak dikenal.")
                end
            else
                syntaxerror("Parameter tipe tidak valid.")
            end
            flag in seen && syntaxerror("Parameter tipe '$flag' berulang.")
            push!(seen, flag)
            peek(p).kind == :rparen && break
            expect!(p, :amp)
        end
        expect!(p, :rparen)
    end
    expect!(p, :eof)
    :null in seen && (:notnull in seen || primary) && constraint("NULL bertentangan dengan Not Null atau Primary Key.")
    ColumnDef(name, kind, maxlen, unique, primary, primary ? false : nullable, false)
end

function parse_select!(p::Parser)
    keyword!(p, "pilih")
    labels = split_fields(quoted!(p); widths=(1,2))
    expressions = ExprNode[parse_expression(s) for s in labels]
    keyword!(p, "dari")
    sources = split_fields(quoted!(p); widths=(3,))
    condition = join_condition = limit = nothing
    groups = ExprNode[]; orders = OrderByItem[]; seen = Set{String}()
    while peek(p).kind == :word || peek(p).kind == :orderby
        word = peek(p).kind == :orderby ? "m:" : lowercase(peek(p).text)
        word in ("dengan", "gabung", "grup", "m:", "limit") || break
        word in seen && syntaxerror("Klausa '$word' berulang.")
        push!(seen, word); take_token!(p)
        if word == "dengan"
            condition = parse_expression(quoted!(p))
        elseif word == "gabung"
            keyword!(p, "dengan")
            join_condition = parse_expression(quoted!(p))
        elseif word == "grup"
            keyword!(p, "dari")
            groups = ExprNode[parse_expression(s) for s in split_fields(quoted!(p))]
        elseif word == "m:"
            append!(orders, parse_order_by_clause(quoted!(p)).items)
        else
            expect!(p, :lparen)
            limit = tryparse(Int, expect!(p, :number).text)
            limit !== nothing && limit >= 0 || syntaxerror("Limit membutuhkan integer non-negatif.")
            expect!(p, :rparen)
        end
    end
    SelectQuery(expressions, labels, sources, condition, join_condition, groups, orders, limit)
end

function assignment_expression(text::AbstractString)
    s = strip(text)
    isempty(s) && syntaxerror("Nilai assignment tidak boleh kosong; gunakan NULL.")
    if occursin(r"^\d{4}-\d{2}-\d{2}([ T].*)?$", s) || occursin(r"^\d{2}:\d{2}:\d{2}", s)
        return Literal(String(s))
    end
    try
        return parse_expression(s)
    catch e
        e isa AiresError || rethrow()
        # Unquoted text is required by the original multi-column UPDATE syntax.
        occursin(r"^[\p{L}_][\p{L}\p{N}_ @.]*$", s) && return Literal(String(s))
        rethrow()
    end
end

function parse_statement!(p::Parser)::Statement
    word = lowercase(peek(p).text)
    if word == "explain"
        take_token!(p)
        return ExplainQuery(parse_select!(p))
    elseif word == "buat"
        take_token!(p)
        if isword(p, "tabel")
            take_token!(p); name = quoted!(p); keyword!(p, "isi")
            names = split_fields(quoted!(p)); keyword!(p, "dengan")
            columns = [parse_column_definition(s) for s in split_fields(quoted!(p))]
            names == getfield.(columns, :name) || syntaxerror("Jumlah, urutan, dan nama kolom Isi harus sama dengan definisi Dengan.")
            autos = String[]
            while peek(p).kind == :word && startswith(lowercase(peek(p).text), "auto_")
                auto = take_token!(p).text
                nameauto = length(auto) == 5 ? (expect!(p, :lparen); n = expect!(p, :word).text; expect!(p, :rparen); n) : auto[6:end]
                nameauto in autos && syntaxerror("Auto_$nameauto berulang.")
                nameauto in names || fail("Kolom auto '$nameauto' tidak ditemukan.")
                push!(autos, nameauto)
            end
            columns = [ColumnDef(c.name,c.kind,c.max_length,c.unique,c.primary,c.nullable,c.name in autos) for c in columns]
            return CreateTable(name, columns)
        end
        return CreateDatabase(quoted!(p))
    elseif word == "pilih"
        # Database selection and SELECT differ only by the Dari keyword.
        saved = p.index; take_token!(p); name = quoted!(p)
        if isword(p, "dari")
            p.index = saved
            return parse_select!(p)
        end
        return UseDatabase(name)
    elseif word == "isi"
        take_token!(p); keyword!(p, "tabel"); name = quoted!(p)
        rows = Vector{String}[]
        while peek(p).kind == :string; push!(rows, split_fields(quoted!(p); data=true)); end
        isempty(rows) && syntaxerror("Isi Tabel membutuhkan minimal satu baris.")
        return InsertRows(name, rows)
    elseif word == "tampilkan"
        take_token!(p)
        return SelectQuery(ExprNode[Wildcard()], ["*"], [quoted!(p)], nothing, nothing, ExprNode[], OrderByItem[], nothing)
    elseif word == "tabel_upt"
        take_token!(p); table = quoted!(p)
        if peek(p).kind == :plus
            take_token!(p); keyword!(p, "kolom"); name = quoted!(p); keyword!(p, "dengan")
            c = parse_column_definition(quoted!(p))
            c.name == name || syntaxerror("Nama kolom dan definisi tidak sama.")
            return AddColumn(table, c)
        end
        keyword!(p, "isi"); assignments = Assignment[]
        for raw in split_fields(quoted!(p))
            pair = split(raw, '='; limit=2)
            length(pair) == 2 || syntaxerror("Assignment harus berbentuk Kolom = nilai.")
            push!(assignments, Assignment(strip(pair[1]), assignment_expression(pair[2])))
        end
        condition = isword(p, "dengan") ? (take_token!(p); parse_expression(quoted!(p))) : nothing
        return UpdateRows(table, assignments, condition)
    elseif word == "kolom_rmv"
        take_token!(p); pair = split(quoted!(p), '.')
        length(pair) == 2 || syntaxerror("Gunakan Kolom_Rmv 'Tabel.Kolom'.")
        return RemoveColumn(pair[1], pair[2])
    elseif word == "baris_rmv"
        take_token!(p); table = quoted!(p)
        condition = isword(p, "dengan") ? (take_token!(p); parse_expression(quoted!(p))) : nothing
        return DeleteRows(table, condition)
    elseif word == "tabel_rmv"
        take_token!(p); return DropTable(quoted!(p))
    elseif word == "lihat"
        take_token!(p); name = quoted!(p)
        return CreateView(name, parse_select!(p))
    elseif word in ("transaksi", "gabungkan", "kembalikan")
        take_token!(p)
        return TransactionCommand(word == "transaksi" ? :begin : word == "gabungkan" ? :commit : :rollback)
    end
    syntaxerror("Statement '$(peek(p).text)' tidak dikenal.")
end

"""Parse exactly one terminated AiresQL statement into a typed AST."""
function parse_airesql(source::AbstractString)
    tokens = tokenize(source)
    any(t->t.kind == :endstmt, tokens) || syntaxerror("Statement harus diakhiri dengan '-:'.")
    p = Parser(tokens)
    stmt = parse_statement!(p)
    expect!(p, :endstmt)
    expect!(p, :eof)
    stmt
end

sqlquote(s::AbstractString) = "'" * replace(s, "'"=>"''") * "'"
const OP_TEXT = Dict(:plus=>"+", :minus=>"-", :star=>"*", :slash=>"/", :eq=>"=", :gt=>">", :lt=>"<", :ge=>">=", :le=>"<=")
expr_text(e::ColumnRef) = e.table === nothing ? e.name : e.table * "." * e.name
expr_text(::Wildcard) = "*"
expr_text(e::Literal) = e.value === nothing ? "NULL" : e.value isa String ? "\"" * replace(e.value, "\""=>"\"\"") * "\"" : string(e.value)
expr_text(e::UnaryExpr) = OP_TEXT[e.op] * "(" * expr_text(e.operand) * ")"
expr_text(e::BinaryExpr) = "(" * expr_text(e.left) * " " * OP_TEXT[e.op] * " " * expr_text(e.right) * ")"
expr_text(e::LogicalAnd) = "(" * expr_text(e.left) * " &: " * expr_text(e.right) * ")"
expr_text(e::LogicalOr) = "(" * expr_text(e.left) * " O: " * expr_text(e.right) * ")"
expr_text(e::CallExpr) = string(e.name) * "(" * join(expr_text.(e.args), " & ") * ")"
order_item_text(item::OrderByItem) = expr_text(item.expression) * " " * (item.direction == SortAscending ? "Atas" : "Bawah")
function query_text(q::SelectQuery)
    s = "Pilih " * sqlquote(join(q.labels, " & ")) * " Dari " * sqlquote(join(q.sources, " &&& "))
    q.join_condition === nothing || (s *= " Gabung Dengan " * sqlquote(expr_text(q.join_condition)))
    q.condition === nothing || (s *= " Dengan " * sqlquote(expr_text(q.condition)))
    isempty(q.groups) || (s *= " Grup Dari " * sqlquote(join(expr_text.(q.groups), " & ")))
    isempty(q.orders) || (s *= " M: " * sqlquote(join(order_item_text.(q.orders), " & ")))
    q.limit === nothing || (s *= " Limit($(q.limit))")
    s * " -:"
end
