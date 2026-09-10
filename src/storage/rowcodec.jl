# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

"""Deterministic ARSP-4 heap record codec; never uses Julia serialization."""
const HEAP_RECORD_FORMAT_VERSION = UInt8(1)
const HEAP_RECORD_TOMBSTONE = UInt8(0x01)

struct HeapRecord
    row_id::UInt128
    begin_csn::UInt64
    end_csn::UInt64
    previous::Union{Nothing,RID}
    schema_epoch::UInt64
    tombstone::Bool
    values::Union{Nothing,Row}
end

function _record_put_u128(io::IO,value::UInt128)
    for shift in 0:8:120
        write(io,UInt8((value >> shift) & 0xff))
    end
    nothing
end
function _record_get_u128(io::IO)::UInt128
    bytes = read_exact(io,16)
    value = UInt128(0)
    @inbounds for index in 0:15
        value |= UInt128(bytes[index+1]) << (8 * index)
    end
    value
end

function encode_heap_record(columns::Vector{ColumnDef},values::Row;
                            row_id::UInt128,begin_csn::Integer,end_csn::Integer=typemax(UInt64),
                            previous::Union{Nothing,RID}=nothing,schema_epoch::Integer=0,
                            tombstone::Bool=false)::Vector{UInt8}
    length(columns) <= typemax(UInt16) || storageerror("Jumlah kolom record terlalu besar.")
    tombstone || length(values) == length(columns) || storageerror("Jumlah nilai record tidak sesuai schema.")
    io = IOBuffer()
    put_u8(io,HEAP_RECORD_FORMAT_VERSION)
    put_u8(io,tombstone ? HEAP_RECORD_TOMBSTONE : 0)
    put_u16(io,length(columns))
    _record_put_u128(io,row_id)
    put_u64(io,begin_csn)
    put_u64(io,end_csn)
    put_u64(io,previous === nothing ? 0 : previous.page_id)
    put_u16(io,previous === nothing ? 0 : previous.slot_id)
    put_u16(io,0)
    put_u64(io,schema_epoch)
    if !tombstone
        for (column,value) in zip(columns,values)
            write_cell(io,column,value)
        end
    end
    take!(io)
end

function decode_heap_record(columns::Vector{ColumnDef},payload::Vector{UInt8})::HeapRecord
    io = IOBuffer(payload)
    get_u8(io) == HEAP_RECORD_FORMAT_VERSION || storageerror("Versi record heap tidak didukung.")
    flags = get_u8(io)
    flags & ~HEAP_RECORD_TOMBSTONE == 0 || storageerror("Flag record heap tidak valid.")
    column_count = Int(get_u16(io))
    column_count == length(columns) || storageerror("Schema record heap tidak cocok.")
    row_id = _record_get_u128(io)
    begin_csn = get_u64(io)
    end_csn = get_u64(io)
    begin_csn <= end_csn || storageerror("Rentang CSN record heap tidak valid.")
    previous_page = get_u64(io)
    previous_slot = get_u16(io)
    get_u16(io) == 0 || storageerror("Reserved record heap tidak nol.")
    previous_page == 0 ? previous_slot == 0 || storageerror("RID sebelumnya tidak valid.") : nothing
    previous = previous_page == 0 ? nothing : RID(previous_page,previous_slot)
    schema_epoch = get_u64(io)
    tombstone = flags & HEAP_RECORD_TOMBSTONE != 0
    if tombstone
        eof(io) || storageerror("Tombstone heap memiliki payload tambahan.")
        return HeapRecord(row_id,begin_csn,end_csn,previous,schema_epoch,true,nothing)
    end
    values = Cell[read_cell(io,column) for column in columns]
    eof(io) || storageerror("Byte tambahan pada record heap.")
    HeapRecord(row_id,begin_csn,end_csn,previous,schema_epoch,false,values)
end

record_visible(record::HeapRecord,snapshot_csn::Integer) =
    record.begin_csn <= UInt64(snapshot_csn) < record.end_csn && !record.tombstone
