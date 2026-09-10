# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

"""Tokenize without executing input. Quoted text uses doubled quotes for escaping."""
function tokenize(source::AbstractString)
    chars = collect(source)
    out = Token[]
    i = 1; line = 1; col = 1
    while i <= length(chars)
        c = chars[i]
        if isspace(c)
            c == '\n' ? (line += 1; col = 1) : (col += 1)
            i += 1
            continue
        elseif c == '#'
            while i <= length(chars) && chars[i] != '\n'
                i += 1; col += 1
            end
            continue
        end
        start = i; startline = line; startcol = col
        if c in ('\'', '"')
            quotechar = c; i += 1; col += 1; buf = IOBuffer(); closed = false
            while i <= length(chars)
                c = chars[i]
                if c == quotechar
                    if i < length(chars) && chars[i+1] == quotechar
                        print(buf, c); i += 2; col += 2
                        continue
                    end
                    i += 1; col += 1; closed = true
                    break
                end
                print(buf, c)
                c == '\n' ? (line += 1; col = 1) : (col += 1)
                i += 1
            end
            closed || syntaxerror("Tanda kutip belum ditutup pada baris $startline, kolom $startcol.")
            push!(out, Token(:string, String(take!(buf)), start, startline, startcol))
        elseif c == '&' && i < length(chars) && chars[i+1] == ':'
            # Keep the legacy ampersand separators distinct from logical AND.
            push!(out, Token(:logicaland, "&:", start, startline, startcol)); i += 2; col += 2
        elseif (c == 'O' || c == 'o') && i < length(chars) && chars[i+1] == ':'
            push!(out, Token(:logicalor, string(c, ':'), start, startline, startcol)); i += 2; col += 2
        elseif (c == 'M' || c == 'm') && i < length(chars) && chars[i+1] == ':'
            push!(out, Token(:orderby, string(c, ':'), start, startline, startcol)); i += 2; col += 2
        elseif isletter(c) || c == '_'
            while i <= length(chars) && (isletter(chars[i]) || isdigit(chars[i]) || chars[i] == '_')
                i += 1; col += 1
            end
            push!(out, Token(:word, String(chars[start:i-1]), start, startline, startcol))
        elseif isdigit(c)
            while i <= length(chars) && isdigit(chars[i])
                i += 1; col += 1
            end
            if i < length(chars) && chars[i] == '.' && isdigit(chars[i+1])
                i += 1; col += 1
                while i <= length(chars) && isdigit(chars[i])
                    i += 1; col += 1
                end
            end
            push!(out, Token(:number, String(chars[start:i-1]), start, startline, startcol))
        elseif c == '&'
            while i <= length(chars) && chars[i] == '&'
                i += 1; col += 1
            end
            n = i - start
            n <= 3 || syntaxerror("Pemisah '&' maksimal tiga pada baris $line.")
            push!(out, Token(n == 1 ? :amp : n == 2 ? :doubleamp : :tripleamp, repeat("&", n), start, startline, startcol))
        elseif c == '-' && i < length(chars) && chars[i+1] == ':'
            push!(out, Token(:endstmt, "-:", start, startline, startcol)); i += 2; col += 2
        elseif c in ('>', '<') && i < length(chars) && chars[i+1] == '='
            push!(out, Token(c == '>' ? :ge : :le, string(c, '='), start, startline, startcol)); i += 2; col += 2
        elseif haskey(PUNCTUATION, c)
            push!(out, Token(PUNCTUATION[c], string(c), start, startline, startcol)); i += 1; col += 1
        else
            syntaxerror("Karakter '$c' tidak dikenal pada baris $line, kolom $col.")
        end
    end
    push!(out, Token(:eof, "", i, line, col))
    out
end

"""Split on legacy top-level ampersand separators, preserving `&:` expressions."""
function split_fields(source::AbstractString; widths=(1,), data::Bool=false)
    chars = collect(source); result = String[]; start = 1; i = 1; depth = 0; quotechar = '\0'
    while i <= length(chars)
        c = chars[i]
        if quotechar != '\0'
            if c == quotechar
                if i < length(chars) && chars[i+1] == quotechar
                    i += 2; continue
                end
                quotechar = '\0'
            end
        elseif c == '"' || (!data && c == '\'')
            quotechar = c
        elseif !data && c == '('
            depth += 1
        elseif !data && c == ')'
            depth -= 1
            depth >= 0 || syntaxerror("Kurung tutup tidak berpasangan.")
        # `&:` is an expression operator, never the legacy `&` field separator.
        elseif c == '&' && depth == 0 && !(i < length(chars) && chars[i+1] == ':')
            j = i
            while j <= length(chars) && chars[j] == '&'; j += 1; end
            j-i in widths || syntaxerror("Pemisah '$(String(chars[i:j-1]))' tidak diizinkan di sini.")
            push!(result, strip(String(chars[start:i-1])))
            i = j; start = j; continue
        end
        i += 1
    end
    quotechar == '\0' || syntaxerror("Tanda kutip pada parameter belum ditutup.")
    depth == 0 || syntaxerror("Kurung pada parameter belum ditutup.")
    push!(result, strip(String(chars[start:end])))
    result
end

"""Find complete CLI statements; terminators inside text/comments are ignored."""
function split_statements(source::AbstractString)
    chars = collect(source); parts = String[]; start = 1; i = 1; quotechar = '\0'; comment = false
    while i <= length(chars)
        c = chars[i]
        if comment
            c == '\n' && (comment = false)
        elseif quotechar != '\0'
            if c == quotechar
                if i < length(chars) && chars[i+1] == quotechar
                    i += 2; continue
                end
                quotechar = '\0'
            end
        elseif c == '#'
            comment = true
        elseif c in ('\'', '"')
            quotechar = c
        elseif c == '-' && i < length(chars) && chars[i+1] == ':'
            push!(parts, String(chars[start:i+1])); i += 2; start = i; continue
        end
        i += 1
    end
    parts, String(chars[start:end])
end
