# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

abstract type AbstractStorage end
"""Versioned binary row store. The interface can be replaced by a future page store."""
struct BinaryRowStore <: AbstractStorage
    max_bytes::Int
end
BinaryRowStore() = BinaryRowStore(256 * 1024 * 1024)
const FILE_MAGIC = (0x41,0x49,0x52,0x45,0x53,0x44,0x42,0x00)
const TYPE_CODES = (:D,:B,:F,:I,:C,:T,:W,:TW,:U)

put_u8(io::IO,x::Integer) = write(io,UInt8(x))
put_u16(io::IO,x::Integer) = write(io,htol(UInt16(x)))
put_u32(io::IO,x::Integer) = write(io,htol(UInt32(x)))
put_u64(io::IO,x::Integer) = write(io,htol(UInt64(x)))
put_i64(io::IO,x::Integer) = write(io,htol(Int64(x)))
put_i128(io::IO,x::Integer) = write(io,htol(Int128(x)))
get_u8(io::IO) = read(io,UInt8)
get_u16(io::IO) = ltoh(read(io,UInt16))
get_u32(io::IO) = ltoh(read(io,UInt32))
get_u64(io::IO) = ltoh(read(io,UInt64))
get_i64(io::IO) = ltoh(read(io,Int64))
get_i128(io::IO) = ltoh(read(io,Int128))

function read_exact(io::IO, n::Integer)
    0 <= n <= bytesavailable(io) || storageerror("Panjang data tidak valid atau file terpotong.")
    read(io,Int(n))
end
function put_string(io::IO,s::AbstractString)
    bytes = codeunits(s); put_u32(io,length(bytes)); write(io,bytes)
end
function get_string(io::IO; max_length=4_000_000)
    n = get_u32(io)
    n <= max_length || storageerror("Panjang string melebihi batas format.")
    s = String(read_exact(io,n))
    isvalid(s) || storageerror("String UTF-8 pada file tidak valid.")
    s
end
function get_count(io::IO, max_count::Int; min_bytes::Int=1)
    n = get_u32(io)
    n <= max_count && n <= div(bytesavailable(io),min_bytes) || storageerror("Jumlah record tidak valid.")
    Int(n)
end

function write_column(io::IO,c::ColumnDef)
    put_string(io,c.name)
    put_u8(io,findfirst(==(c.kind),TYPE_CODES))
    put_u32(io,c.max_length)
    flags = UInt8(c.unique) | UInt8(c.primary)<<1 | UInt8(c.nullable)<<2 | UInt8(c.auto)<<3
    put_u8(io,flags)
end
function read_column(io::IO)
    name = get_string(io; max_length=512); code = get_u8(io)
    1 <= code <= length(TYPE_CODES) || storageerror("Kode tipe tidak valid.")
    maxlen = get_u32(io); flags = get_u8(io)
    flags & 0xf0 == 0 || storageerror("Flag schema tidak valid.")
    ColumnDef(name,TYPE_CODES[code],Int(maxlen), flags&1!=0, flags&2!=0, flags&4!=0, flags&8!=0)
end

function write_cell(io::IO,c::ColumnDef,value::Cell)
    put_u8(io,value === nothing ? 0 : 1)
    value === nothing && return
    k = c.kind
    if k == :C
        put_string(io,value)
    elseif k == :I
        put_i64(io,value)
    elseif k == :B
        put_u8(io,value)
    elseif k == :F
        put_u64(io,reinterpret(UInt64,value))
    elseif k == :D
        put_i128(io,value.coefficient); put_u8(io,value.scale)
    elseif k == :U
        put_i128(io,value.minor)
    elseif k == :T
        put_i64(io,Dates.value(value - Date(1970,1,1)))
    elseif k == :W
        put_i64(io,Dates.value(value))
    elseif k == :TW
        put_i64(io,Dates.value(value - DateTime(1970,1,1)))
    end
end
function read_cell(io::IO,c::ColumnDef)::Cell
    present = get_u8(io)
    present <= 1 || storageerror("Flag NULL tidak valid.")
    present == 0 && return nothing
    k = c.kind
    if k == :C
        return get_string(io)
    elseif k == :I
        return get_i64(io)
    elseif k == :B
        value = get_u8(io); value <= 1 || storageerror("Boolean tidak valid."); return value == 1
    elseif k == :F
        return reinterpret(Float64,get_u64(io))
    elseif k == :D
        return Decimal(get_i128(io),get_u8(io))
    elseif k == :U
        return Money(get_i128(io))
    elseif k == :T
        return Date(1970,1,1) + Day(get_i64(io))
    elseif k == :W
        value = get_i64(io)
        0 <= value < 86_400_000_000_000 || storageerror("Waktu tidak valid.")
        return Time(Nanosecond(value))
    elseif k == :TW
        return DateTime(1970,1,1) + Millisecond(get_i64(io))
    end
    storageerror("Tipe record tidak dikenal.")
end

function encode_database(store::BinaryRowStore,db::Database)
    payload = IOBuffer()
    put_string(payload,db.name)
    put_i64(payload,Dates.value(db.created-DateTime(1970,1,1)))
    put_u32(payload,length(db.tables))
    for name in sort!(collect(keys(db.tables)))
        table = db.tables[name]
        put_string(payload,name); put_u32(payload,length(table.columns))
        for c in table.columns
            write_column(payload,c)
            c.auto && put_i128(payload,table.next_ids[c.name])
        end
        put_u32(payload,length(table.rows))
        for row in table_rows(table), (i,c) in enumerate(table.columns)
            write_cell(payload,c,row[i])
        end
    end
    put_u32(payload,length(db.views))
    for name in sort!(collect(keys(db.views)))
        put_string(payload,name); put_string(payload,query_text(db.views[name].query))
    end
    data = take!(payload)
    length(data) + 52 <= store.max_bytes || storageerror("Database melebihi batas $(store.max_bytes) byte.")
    file = IOBuffer()
    write(file,collect(FILE_MAGIC)); put_u16(file,1); put_u16(file,0)
    put_u64(file,length(data)); write(file,sha256(data)); write(file,data)
    take!(file)
end

function decode_database(store::BinaryRowStore,bytes::Vector{UInt8})
    length(bytes) <= store.max_bytes || storageerror("File melebihi batas ukuran storage.")
    io = IOBuffer(bytes)
    read_exact(io,8) == collect(FILE_MAGIC) || storageerror("Magic header bukan AiresDB.")
    major = get_u16(io); minor = get_u16(io)
    major == 1 && minor == 0 || storageerror("Versi format $major.$minor belum didukung.")
    length_payload = get_u64(io); checksum = read_exact(io,32)
    length_payload == bytesavailable(io) || storageerror("Panjang payload salah atau file terpotong.")
    payload = read_exact(io,length_payload)
    sha256(payload) == checksum || storageerror("Checksum gagal; file rusak.")
    io = IOBuffer(payload)
    name = get_string(io; max_length=512)
    created = DateTime(1970,1,1)+Millisecond(get_i64(io))
    db = Database(name,created,Dict{String,Table}(),Dict{String,ViewDefinition}())
    for _ in 1:get_count(io,100_000)
        table_name = get_string(io; max_length=512)
        haskey(db.tables,table_name) && storageerror("Nama tabel duplikat pada catalog.")
        columns = ColumnDef[]; next_ids = Dict{String,Int128}()
        for _ in 1:get_count(io,1024)
            c = read_column(io); push!(columns,c)
            c.auto && (next_ids[c.name] = get_i128(io))
        end
        validate_schema(columns)
        rows = Row[]
        nrows = get_count(io,10_000_000; min_bytes=length(columns))
        for _ in 1:nrows
            push!(rows,Cell[read_cell(io,c) for c in columns])
        end
        db.tables[table_name] = Table(table_name,columns,rows,next_ids)
    end
    for _ in 1:get_count(io,100_000)
        view_name = get_string(io; max_length=512)
        haskey(db.views,view_name) && storageerror("Nama view duplikat pada catalog.")
        query = parse_airesql(get_string(io))
        query isa SelectQuery || storageerror("Definisi view bukan SELECT.")
        db.views[view_name] = ViewDefinition(view_name,query)
    end
    eof(io) || storageerror("Ada byte tambahan pada payload.")
    validate_database(db)
    db
end

function load_database(store::BinaryRowStore,path::String)
    try
        isfile(path) || storageerror("File '$(basename(path))' tidak ditemukan.")
        filesize(path) <= store.max_bytes || storageerror("File melebihi batas ukuran storage.")
        bytes = read(path)
        decode_database(store,bytes), sha256(bytes)
    catch e
        e isa InterruptException && rethrow()
        reason = e isa AiresError ? e.message : sprint(showerror,e)
        storageerror("File '$(basename(path))' bukan file AiresDB yang valid atau tidak dapat dibaca. $reason")
    end
end

"""Replace a snapshot under a short writer lock and an optimistic revision check.

Only rename publishes data. Failure before rename preserves the original file.
No fsync/directory sync guarantee or automatic stale-lock recovery is claimed.
"""
function save_database(store::BinaryRowStore,path::String,db::Database,expected::Union{Nothing,Vector{UInt8}})
    bytes = encode_database(store,db)
    lockdir = joinpath(dirname(path),"."*basename(path)*".lock")
    temporary = joinpath(dirname(path),"."*basename(path)*"."*string(uuid4())*".aires")
    locked = false
    try
        try
            mkdir(lockdir); locked = true
        catch
            storageerror("Database sedang dikunci penulis lain: $(basename(lockdir)).")
        end
        if expected === nothing
            ispath(path) && storageerror("Database '$(basename(path))' sudah ada.")
        else
            isfile(path) && filesize(path) <= store.max_bytes && sha256(read(path)) == expected ||
                storageerror("Database berubah di sesi lain. Kembalikan transaksi jika aktif, lalu Pilih ulang database.")
        end
        open(temporary,"w") do io
            write(io,bytes)
            flush(io)
        end
        Base.Filesystem.rename(temporary,path)
        sha256(bytes)
    catch e
        e isa AiresError && rethrow()
        e isa InterruptException && rethrow()
        storageerror("Gagal menyimpan '$(basename(path))': $(sprint(showerror,e))")
    finally
        isfile(temporary) && rm(temporary)
        locked && isdir(lockdir) && rm(lockdir)
    end
end
