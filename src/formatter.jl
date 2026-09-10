# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

function display_value(value::Cell)
    value === nothing && return "NULL"
    value isa DateTime && return Dates.format(value,dateformat"yyyy-mm-dd HH:MM:SS.sss")
    if value isa Exact
        try
            return string(decimal_from_exact(value))
        catch e
            e isa AiresError || rethrow()
            return string(numerator(value))*"/"*string(denominator(value))
        end
    end
    string(value)
end

function terminal_text(text::AbstractString,max_width::Int)
    buf = IOBuffer()
    for c in text
        if c == '\n'; print(buf,"\\n")
        elseif c == '\r'; print(buf,"\\r")
        elseif c == '\t'; print(buf,"\\t")
        elseif iscntrl(c); print(buf,"\\u",string(UInt32(c); base=16,pad=4))
        else; print(buf,c)
        end
    end
    s = String(take!(buf))
    textwidth(s) <= max_width && return s
    buf = IOBuffer(); width = 0
    for c in s
        width + textwidth(c) <= max_width-1 || break
        print(buf,c); width += textwidth(c)
    end
    String(take!(buf))*"…"
end

"""Render every result as an ASCII-bordered table with Unicode-aware cell widths."""
function format_table(result::QueryResult; max_width::Int=80)
    max_width >= 4 || throw(ArgumentError("max_width must be at least 4"))
    headers = [terminal_text(s,max_width) for s in result.columns]
    data = [[terminal_text(display_value(v),max_width) for v in row] for row in result.rows]
    widths = [maximum([textwidth(headers[i]); [textwidth(row[i]) for row in data]]) for i in eachindex(headers)]
    border = "+"*join([repeat("-",w+2) for w in widths],"+")*"+"
    render(row) = "| "*join([row[i]*repeat(" ",widths[i]-textwidth(row[i])) for i in eachindex(row)]," | ")*" |"
    lines = String[border,render(headers),border]
    append!(lines,[render(row) for row in data]); push!(lines,border)
    push!(lines,"",string(length(data))*" baris.")
    join(lines,"\n")
end
Base.show(io::IO,::MIME"text/plain",result::QueryResult) = print(io,format_table(result))
