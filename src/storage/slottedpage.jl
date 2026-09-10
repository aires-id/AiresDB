# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

"""Slotted-page record layout used by ARSP-4 heaps and B+Tree nodes."""
const SLOT_SIZE = 8
const SLOT_FLAG_LIVE = UInt16(0x0001)
const SLOT_FLAG_TOMBSTONE = UInt16(0x0002)
const SLOT_FLAG_FORWARDED = UInt16(0x0004)
const BTREE_NODE_META_SIZE = 32
const HEAP_PAGE_META_SIZE = 16
const CATALOG_PAGE_META_SIZE = 64

struct SlotEntry
    offset::UInt16
    length::UInt16
    flags::UInt16
    generation::UInt16
end

function page_slot_base(page::Page)::Int
    page_type = page_header(page).page_type
    page_type in (PageTypeBTreeLeaf,PageTypeBTreeInternal) &&
        return PAGE_HEADER_SIZE + BTREE_NODE_META_SIZE + 1
    page_type == PageTypeHeap && return PAGE_HEADER_SIZE + HEAP_PAGE_META_SIZE + 1
    page_type == PageTypeCatalog && return PAGE_HEADER_SIZE + CATALOG_PAGE_META_SIZE + 1
    PAGE_HEADER_SIZE + 1
end

@inline function _slot_offset(page::Page,slot_id::UInt16)::Int
    base = page_slot_base(page)
    offset = base + (Int(slot_id) - 1) * SLOT_SIZE
    _page_bounds(page.bytes,offset,SLOT_SIZE)
    offset
end
function slotted_slot(page::Page,slot_id::Integer)::SlotEntry
    1 <= slot_id <= typemax(UInt16) || storageerror("Slot page tidak valid.")
    header = page_header(page)
    slot_id <= header.slot_count || storageerror("Slot page tidak ditemukan.")
    offset = _slot_offset(page,UInt16(slot_id))
    entry = SlotEntry(page_get_u16(page.bytes,offset),page_get_u16(page.bytes,offset+2),
        page_get_u16(page.bytes,offset+4),page_get_u16(page.bytes,offset+6))
    if entry.flags & SLOT_FLAG_LIVE != 0
        entry.length > 0 || storageerror("Slot hidup memiliki panjang nol.")
        Int(entry.offset) >= header.free_end && Int(entry.offset) + Int(entry.length) <= length(page.bytes) + 1 ||
            storageerror("Offset record pada slot tidak valid.")
    end
    entry
end
function _write_slot!(page::Page,slot_id::UInt16,entry::SlotEntry)
    offset = _slot_offset(page,slot_id)
    page_put_u16!(page.bytes,offset,entry.offset)
    page_put_u16!(page.bytes,offset+2,entry.length)
    page_put_u16!(page.bytes,offset+4,entry.flags)
    page_put_u16!(page.bytes,offset+6,entry.generation)
    nothing
end
function _set_slot_count!(page::Page,count::Integer)
    0 <= count <= typemax(UInt16) || storageerror("Jumlah slot page tidak valid.")
    page_put_u16!(page.bytes,29,count)
end
function _set_free_start!(page::Page,offset::Integer)
    PAGE_HEADER_SIZE + 1 <= offset <= length(page.bytes) + 1 || storageerror("Awal ruang bebas page tidak valid.")
    page_put_u16!(page.bytes,31,offset)
end
function _set_free_end!(page::Page,offset::Integer)
    PAGE_HEADER_SIZE + 1 <= offset <= length(page.bytes) + 1 || storageerror("Akhir ruang bebas page tidak valid.")
    page_put_u16!(page.bytes,33,offset)
end

slotted_slot_count(page::Page) = Int(page_header(page).slot_count)
slotted_free_space(page::Page) = begin
    header = page_header(page)
    Int(header.free_end) - Int(header.free_start)
end
slotted_record_capacity(page::Page) = length(page.bytes) + 1 - page_slot_base(page) - SLOT_SIZE

function init_slotted_page!(page::Page,page_type::PageType=PageTypeHeap;page_lsn::Integer=0)
    page_type in (PageTypeHeap,PageTypeCatalog,PageTypeBTreeLeaf,PageTypeBTreeInternal) ||
        storageerror("Tipe page tidak mendukung slot.")
    initialize_page!(page,page_type;page_lsn=UInt64(page_lsn),slot_base=
        page_type in (PageTypeBTreeLeaf,PageTypeBTreeInternal) ? PAGE_HEADER_SIZE + BTREE_NODE_META_SIZE + 1 :
        page_type == PageTypeHeap ? PAGE_HEADER_SIZE + HEAP_PAGE_META_SIZE + 1 :
        page_type == PageTypeCatalog ? PAGE_HEADER_SIZE + CATALOG_PAGE_META_SIZE + 1 : PAGE_HEADER_SIZE + 1)
    page
end

function _reserve_record!(page::Page,length_bytes::Int)
    header = page_header(page)
    length_bytes > 0 || storageerror("Record kosong tidak didukung.")
    length_bytes <= slotted_record_capacity(page) || storageerror("Record melebihi kapasitas satu page.")
    slotted_free_space(page) >= length_bytes || return nothing
    offset = Int(header.free_end) - length_bytes
    _set_free_end!(page,offset)
    UInt16(offset)
end

function slotted_insert!(page::Page,payload::AbstractVector{UInt8};finalize::Bool=true)::UInt16
    # The payload is copied into the page before returning. Reuse an already
    # owned byte vector instead of allocating an identical intermediate copy
    # for every heap/B+Tree record.
    bytes = payload isa Vector{UInt8} ? payload : Vector{UInt8}(payload)
    header = page_header(page)
    header.page_type in (PageTypeHeap,PageTypeCatalog,PageTypeBTreeLeaf,PageTypeBTreeInternal) ||
        storageerror("Page ini tidak menerima record slotted.")
    header.slot_count < typemax(UInt16) || storageerror("Jumlah slot page sudah penuh.")
    required = length(bytes) + SLOT_SIZE
    length(bytes) <= slotted_record_capacity(page) || storageerror("Record melebihi kapasitas satu page.")
    if slotted_free_space(page) < required
        slotted_compact!(page;finalize)
        slotted_free_space(page) >= required || storageerror("Ruang page tidak cukup untuk record.")
    end
    header = page_header(page)
    record_offset = _reserve_record!(page,length(bytes))
    record_offset === nothing && storageerror("Ruang page tidak cukup untuk record.")
    slot_id = UInt16(header.slot_count + 1)
    copyto!(page.bytes,Int(record_offset),bytes,1,length(bytes))
    _write_slot!(page,slot_id,SlotEntry(record_offset,UInt16(length(bytes)),SLOT_FLAG_LIVE,UInt16(0)))
    _set_slot_count!(page,slot_id)
    _set_free_start!(page,page_slot_base(page) + Int(slot_id) * SLOT_SIZE)
    finalize && finalize_page!(page)
    slot_id
end

function slotted_read(page::Page,slot_id::Integer)::Vector{UInt8}
    entry = slotted_slot(page,slot_id)
    entry.flags & SLOT_FLAG_LIVE != 0 || storageerror("RID mengarah ke record yang sudah dihapus.")
    copy(@view(page.bytes[Int(entry.offset):Int(entry.offset)+Int(entry.length)-1]))
end

function slotted_delete!(page::Page,slot_id::Integer;finalize::Bool=true)
    entry = slotted_slot(page,slot_id)
    entry.flags & SLOT_FLAG_LIVE != 0 || storageerror("Record page sudah dihapus.")
    flags = (entry.flags | SLOT_FLAG_TOMBSTONE) & ~SLOT_FLAG_LIVE
    _write_slot!(page,UInt16(slot_id),SlotEntry(entry.offset,entry.length,flags,entry.generation))
    finalize && finalize_page!(page)
    nothing
end

function slotted_compact!(page::Page;finalize::Bool=true)
    header = page_header(page)
    slot_count = Int(header.slot_count)
    live = Vector{Tuple{UInt16,Vector{UInt8},SlotEntry}}()
    for slot_id in UInt16(1):UInt16(slot_count)
        entry = slotted_slot(page,slot_id)
        entry.flags & SLOT_FLAG_LIVE == 0 && continue
        push!(live,(slot_id,slotted_read(page,slot_id),entry))
    end
    base = page_slot_base(page)
    next_slot = base + slot_count * SLOT_SIZE
    next_slot <= length(page.bytes) + 1 || storageerror("Direktori slot page rusak.")
    fill!(@view(page.bytes[next_slot:end]),0x00)
    cursor = length(page.bytes) + 1
    for (slot_id,payload,entry) in live
        cursor -= length(payload)
        cursor >= next_slot || storageerror("Compact page kekurangan ruang.")
        copyto!(page.bytes,cursor,payload,1,length(payload))
        _write_slot!(page,slot_id,SlotEntry(UInt16(cursor),UInt16(length(payload)),entry.flags,entry.generation))
    end
    _set_free_start!(page,next_slot)
    _set_free_end!(page,cursor)
    finalize && finalize_page!(page)
    page
end

function slotted_update!(page::Page,slot_id::Integer,payload::AbstractVector{UInt8};finalize::Bool=true)
    bytes = payload isa Vector{UInt8} ? payload : Vector{UInt8}(payload)
    entry = slotted_slot(page,slot_id)
    entry.flags & SLOT_FLAG_LIVE != 0 || storageerror("Record page sudah dihapus.")
    length(bytes) > 0 || storageerror("Record kosong tidak didukung.")
    length(bytes) <= slotted_record_capacity(page) || storageerror("Record melebihi kapasitas satu page.")
    if length(bytes) <= Int(entry.length)
        copyto!(page.bytes,Int(entry.offset),bytes,1,length(bytes))
        if length(bytes) < Int(entry.length)
            fill!(@view(page.bytes[Int(entry.offset)+length(bytes):Int(entry.offset)+Int(entry.length)-1]),0x00)
        end
        _write_slot!(page,UInt16(slot_id),SlotEntry(entry.offset,UInt16(length(bytes)),entry.flags,entry.generation))
        finalize && finalize_page!(page)
        return page
    end
    if slotted_free_space(page) < length(bytes)
        slotted_compact!(page;finalize)
    end
    record_offset = _reserve_record!(page,length(bytes))
    record_offset === nothing && storageerror("Ruang page tidak cukup untuk update record.")
    copyto!(page.bytes,Int(record_offset),bytes,1,length(bytes))
    _write_slot!(page,UInt16(slot_id),SlotEntry(record_offset,UInt16(length(bytes)),entry.flags,entry.generation))
    finalize && finalize_page!(page)
    page
end

function slotted_live_slots(page::Page)
    ids = UInt16[]
    for slot_id in UInt16(1):UInt16(slotted_slot_count(page))
        slotted_slot(page,slot_id).flags & SLOT_FLAG_LIVE != 0 && push!(ids,slot_id)
    end
    ids
end
