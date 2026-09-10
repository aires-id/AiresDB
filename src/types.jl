# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

"""An exact decimal, normalized and bounded to Int128 and 18 fractional digits."""
struct Decimal <: Real
    coefficient::Int128
    scale::UInt8
    function Decimal(c::Integer, s::Integer)
        0 <= s <= 18 || typeerror("Desimal mendukung maksimal 18 digit pecahan.")
        while s > 0 && c % 10 == 0
            c = div(c, 10)
            s -= 1
        end
        typemin(Int128) <= c <= typemax(Int128) || typeerror("Desimal melampaui kapasitas Int128.")
        new(Int128(c), UInt8(s))
    end
end

"""Currency stored as signed Int128 minor units (one unit = 100 minor units)."""
struct Money <: Real
    minor::Int128
end

const Exact = Rational{BigInt}
const Cell = Union{Nothing, Bool, Int64, Float64, String, Date, Time, DateTime, Decimal, Money, Exact}
const Row = Vector{Cell}

function Decimal(text::AbstractString)
    s = strip(text)
    occursin(r"^[+-]?\d+(\.\d+)?$", s) || typeerror("Nilai '$s' bukan desimal valid.")
    parts = split(s, '.')
    scale = length(parts) == 2 ? length(parts[2]) : 0
    Decimal(parse(BigInt, join(parts)), scale)
end
exact(x::Decimal) = BigInt(x.coefficient) // big(10)^Int(x.scale)
exact(x::Money) = BigInt(x.minor) // big(100)
exact(x::Integer) = BigInt(x) // big(1)
exact(x::Exact) = x
isnumber(x) = x isa Union{Integer, Float64, Decimal, Money, Exact} && !(x isa Bool)
# IEEE signed zero compares equal, so all equality-based keys must agree with it.
value_key(x) = x isa Float64 && iszero(x) ? 0.0 : x

Base.:(==)(a::Decimal, b::Decimal) = a.coefficient == b.coefficient && a.scale == b.scale
Base.:(==)(a::Money, b::Money) = a.minor == b.minor
Base.isequal(a::Decimal, b::Decimal) = a == b
Base.isequal(a::Money, b::Money) = a == b
Base.hash(x::Decimal, h::UInt) = hash((x.coefficient, x.scale), h)
Base.hash(x::Money, h::UInt) = hash(x.minor, h)

function decimal_from_exact(q::Exact)
    d = denominator(q)
    twos = fives = 0
    while d % 2 == 0
        twos += 1; d = div(d, 2)
    end
    while d % 5 == 0
        fives += 1; d = div(d, 5)
    end
    d == 1 || typeerror("Hasil tidak dapat disimpan sebagai desimal hingga; bulatkan secara eksplisit di aplikasi.")
    s = max(twos, fives)
    s <= 18 || typeerror("Desimal mendukung maksimal 18 digit pecahan.")
    Decimal(numerator(q) * big(2)^(s-twos) * big(5)^(s-fives), s)
end

function decimal_text(c::Integer, scale::Integer; trimzeros::Bool=true)
    negative = c < 0
    digits = lpad(string(abs(BigInt(c))), Int(scale) + 1, '0')
    if scale > 0
        k = length(digits) - Int(scale)
        digits = digits[1:k] * "." * digits[k+1:end]
        trimzeros && (digits = rstrip(rstrip(digits, '0'), '.'))
    end
    (negative ? "-" : "") * digits
end
Base.show(io::IO, d::Decimal) = print(io, decimal_text(d.coefficient, d.scale))
Base.show(io::IO, m::Money) = print(io, decimal_text(m.minor, 2))

struct ColumnDef
    name::String
    kind::Symbol
    max_length::Int
    unique::Bool
    primary::Bool
    nullable::Bool
    auto::Bool
end

struct QueryResult
    columns::Vector{String}
    rows::Vector{Row}
end
status_result(message::String, affected::Integer=0) = QueryResult(["Status", "Baris"], [Cell[message, Int64(affected)]])

function coerce_value(column::ColumnDef, value)::Cell
    if value === nothing
        column.nullable || constraint("Kolom '$(column.name)' tidak boleh NULL.")
        return nothing
    end
    k = column.kind
    try
        if k == :C
            value isa AbstractString || typeerror("Kolom $(column.name) membutuhkan tipe C.")
            length(value) <= column.max_length || constraint("Panjang kolom '$(column.name)' melebihi $(column.max_length) karakter.")
            return String(value)
        elseif k == :B
            value isa Bool && return value
            if value isa AbstractString
                lowercase(value) in ("true", "benar") && return true
                lowercase(value) in ("false", "salah") && return false
            end
        elseif k == :F
            x = value isa AbstractString ? parse(Float64, value) :
                value isa Float64 ? value : isnumber(value) ? Float64(exact(value)) : NaN
            isfinite(x) && return x
        elseif k in (:I, :D, :U)
            # Common storage hot paths already carry exact fixed-width values.
            # Avoid constructing BigInt/Rational temporaries for every integer
            # cell in a bulk load.
            k == :I && value isa Int64 && return value
            k == :D && value isa Decimal && return value
            k == :D && value isa Integer && !(value isa Bool) &&
                typemin(Int128) <= value <= typemax(Int128) && return Decimal(Int128(value),0)
            k == :U && value isa Money && return value
            if k == :U && value isa Integer && !(value isa Bool)
                cents = Base.checked_mul(Int128(value),Int128(100))
                return Money(cents)
            end
            q = value isa AbstractString ? exact(Decimal(value)) : isnumber(value) && !(value isa Float64) ? exact(value) : nothing
            q === nothing && typeerror("Kolom $(column.name) membutuhkan tipe $k yang presisi.")
            if k == :I
                denominator(q) == 1 && typemin(Int64) <= numerator(q) <= typemax(Int64) && return Int64(numerator(q))
            elseif k == :D
                return decimal_from_exact(q)
            else
                cents = q * 100
                denominator(cents) == 1 || typeerror("Kolom $(column.name) membutuhkan U dengan maksimal dua digit pecahan.")
                typemin(Int128) <= numerator(cents) <= typemax(Int128) && return Money(Int128(numerator(cents)))
            end
        elseif k == :T
            value isa Date && return value
            if value isa AbstractString && occursin(r"^\d{4}-\d{2}-\d{2}$", value)
                return Date(value, dateformat"yyyy-mm-dd")
            end
        elseif k == :W
            value isa Time && return value
            if value isa AbstractString && occursin(r"^\d{2}:\d{2}:\d{2}(\.\d{1,9})?$", value)
                parts = split(value,'.'; limit=2)
                h,m,s = parse.(Int,split(parts[1],':'))
                ns = length(parts) == 2 ? parse(Int,rpad(parts[2],9,'0')) : 0
                return Time(h,m,s,div(ns,1_000_000),div(ns,1000)%1000,ns%1000)
            end
        elseif k == :TW
            value isa DateTime && return value
            if value isa AbstractString && occursin(r"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(\.\d{1,3})?$", value)
                return DateTime(replace(value, ' ' => 'T'))
            end
        end
    catch e
        e isa AiresError && rethrow()
        e isa Union{ArgumentError, InexactError, OverflowError} || rethrow()
    end
    typeerror("Kolom $(column.name) membutuhkan tipe $k; nilai '$(value)' tidak valid.")
end

function literal_field(raw::AbstractString)
    s = strip(raw)
    isempty(s) && return nothing
    lowercase(s) == "null" && return nothing
    if startswith(s, '"')
        ts = tokenize(s)
        length(ts) == 2 && ts[1].kind == :string || syntaxerror("Literal teks tidak valid: $s")
        return ts[1].text
    end
    String(s)
end
