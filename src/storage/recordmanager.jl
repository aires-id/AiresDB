# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

"""Heap/record manager layered on slotted pages and the bounded buffer pool."""
const HEAP_META_MAGIC = UInt8[0x41,0x49,0x52,0x45,0x53,0x48,0x50,0x31] # AIRESHP1
const HEAP_META_VERSION = UInt16(1)
const HEAP_META_OFFSET = PAGE_HEADER_SIZE + 1
const HEAP_DATA_NEXT_OFFSET = PAGE_HEADER_SIZE + 1
const HEAP_DATA_PREVIOUS_OFFSET = PAGE_HEADER_SIZE + 9
const HEAP_FORWARD_MAGIC = UInt8[0x41,0x52,0x46,0x57] # ARFW

mutable struct HeapFile
    meta_page_id::UInt64
    first_page_id::UInt64
    last_page_id::UInt64
    page_count::UInt32
    columns::Vector{ColumnDef}
end

mutable struct HeapBatchCursor
    heap::HeapFile
    pool::BufferPool
    page_id::UInt64
    slot_id::Int
    batch_size::Int
    finished::Bool
end

@inline _heap_next(page::Page) = page_get_u64(page.bytes,HEAP_DATA_NEXT_OFFSET)
@inline _heap_previous(page::Page) = page_get_u64(page.bytes,HEAP_DATA_PREVIOUS_OFFSET)
@inline function _set_heap_next!(page::Page,id::Integer)
    page_put_u64!(page.bytes,HEAP_DATA_NEXT_OFFSET,id)
    page
end
@inline function _set_heap_previous!(page::Page,id::Integer)
    page_put_u64!(page.bytes,HEAP_DATA_PREVIOUS_OFFSET,id)
    page
end

function _verify_heap_meta_page(page::Page)
    header = page_header(page)
    header.page_type == PageTypeHeapMeta || storageerror("Page metadata heap tidak valid.")
    page.bytes[HEAP_META_OFFSET:HEAP_META_OFFSET+7] == HEAP_META_MAGIC ||
        storageerror("Magic metadata heap tidak valid.")
    page_get_u16(page.bytes,HEAP_META_OFFSET+8) == HEAP_META_VERSION ||
        storageerror("Versi metadata heap tidak didukung.")
    nothing
end
function _read_heap_meta(page::Page,columns::Vector{ColumnDef})
    _verify_heap_meta_page(page)
    first_page = page_get_u64(page.bytes,HEAP_META_OFFSET+10)
    last_page = page_get_u64(page.bytes,HEAP_META_OFFSET+18)
    count = page_get_u32(page.bytes,HEAP_META_OFFSET+26)
    (first_page == 0) == (last_page == 0) || storageerror("Rantai page heap metadata tidak konsisten.")
    (count == 0) == (first_page == 0) || storageerror("Jumlah page heap metadata tidak konsisten.")
    HeapFile(page.id,first_page,last_page,count,copy(columns))
end
function _write_heap_meta!(page::Page,heap::HeapFile)
    page_header(page).page_type == PageTypeHeapMeta || storageerror("Page metadata heap tidak valid.")
    fill!(@view(page.bytes[HEAP_META_OFFSET:HEAP_META_OFFSET+39]),0x00)
    copyto!(page.bytes,HEAP_META_OFFSET,HEAP_META_MAGIC,1,length(HEAP_META_MAGIC))
    page_put_u16!(page.bytes,HEAP_META_OFFSET+8,HEAP_META_VERSION)
    page_put_u64!(page.bytes,HEAP_META_OFFSET+10,heap.first_page_id)
    page_put_u64!(page.bytes,HEAP_META_OFFSET+18,heap.last_page_id)
    page_put_u32!(page.bytes,HEAP_META_OFFSET+26,heap.page_count)
    finalize_page!(page)
    page
end

function create_heap!(pool::BufferPool,columns::Vector{ColumnDef}; page_lsn::Integer=0)::HeapFile
    validate_schema(columns)
    frame = new_page!(pool,PageTypeHeapMeta;page_lsn)
    heap = HeapFile(frame.page_id,0,0,0,copy(columns))
    lock(frame.latch)
    try
        _write_heap_meta!(frame.page,heap)
    finally
        unlock(frame.latch)
        unpin_page!(pool,frame;dirty=true,page_lsn)
    end
    heap
end
function open_heap(pool::BufferPool,meta_page_id::Integer,columns::Vector{ColumnDef})::HeapFile
    frame = fetch_page!(pool,meta_page_id)
    lock(frame.latch)
    try
        _read_heap_meta(frame.page,columns)
    finally
        unlock(frame.latch)
        unpin_page!(pool,frame)
    end
end
function _persist_heap_meta!(pool::BufferPool,heap::HeapFile; page_lsn::Integer=0)
    frame = fetch_page!(pool,heap.meta_page_id)
    lock(frame.latch)
    try
        _write_heap_meta!(frame.page,heap)
    finally
        unlock(frame.latch)
        unpin_page!(pool,frame;dirty=true,page_lsn)
    end
    nothing
end

function _new_heap_data_page!(pool::BufferPool,heap::HeapFile; page_lsn::Integer=0)::UInt64
    frame = new_page!(pool,PageTypeHeap;page_lsn)
    new_page_id = frame.page_id
    lock(frame.latch)
    try
        init_slotted_page!(frame.page,PageTypeHeap;page_lsn)
        _set_heap_previous!(frame.page,heap.last_page_id)
        _set_heap_next!(frame.page,0)
        finalize_page!(frame.page)
    finally
        unlock(frame.latch)
        unpin_page!(pool,frame;dirty=true,page_lsn)
    end
    if heap.last_page_id != 0
        previous = fetch_page!(pool,heap.last_page_id)
        lock(previous.latch)
        try
            page_header(previous.page).page_type == PageTypeHeap || storageerror("Page terakhir heap tidak valid.")
            _set_heap_next!(previous.page,new_page_id)
            finalize_page!(previous.page)
        finally
            unlock(previous.latch)
            unpin_page!(pool,previous;dirty=true,page_lsn)
        end
    else
        heap.first_page_id = new_page_id
    end
    heap.last_page_id = new_page_id
    heap.page_count += UInt32(1)
    _persist_heap_meta!(pool,heap;page_lsn)
    new_page_id
end

function _heap_page_has_room!(page::Page,length_bytes::Int;new_slot::Bool=true)
    length_bytes <= slotted_record_capacity(page) || storageerror("Record melebihi kapasitas satu page.")
    # Do not compact during a mere capacity probe: callers may choose another
    # page, in which case a compacted-but-clean frame could be evicted without
    # persistence. `slotted_insert!` / `slotted_update!` compact only when the
    # mutation is actually accepted and will be marked dirty by the caller.
    slotted_free_space(page) >= length_bytes + (new_slot ? SLOT_SIZE : 0)
end

function heap_insert_raw!(pool::BufferPool,heap::HeapFile,payload::AbstractVector{UInt8};
                          page_lsn::Integer=0)::RID
    bytes = payload isa Vector{UInt8} ? payload : Vector{UInt8}(payload)
    isempty(bytes) && storageerror("Record heap kosong tidak didukung.")
    page_id = heap.last_page_id == 0 ? _new_heap_data_page!(pool,heap;page_lsn) : heap.last_page_id
    while true
        frame = fetch_page!(pool,page_id)
        inserted = nothing
        dirty = false
        lock(frame.latch)
        try
            page_header(frame.page).page_type == PageTypeHeap || storageerror("Page heap tidak valid.")
            if _heap_page_has_room!(frame.page,length(bytes))
                slot_id = slotted_insert!(frame.page,bytes;finalize=false)
                set_page_lsn!(frame.page,page_lsn)
                finalize_page!(frame.page)
                inserted = RID(page_id,slot_id)
                dirty = true
            end
        finally
            unlock(frame.latch)
            unpin_page!(pool,frame;dirty,page_lsn)
        end
        inserted === nothing || return inserted
        page_id = _new_heap_data_page!(pool,heap;page_lsn)
    end
end

"""Append encoded records while checksumming each touched heap page once.

This is reserved for a pristine-table publication where every record is an
append.  Incremental writes keep using `heap_insert_raw!` and retain their
per-record finalized-page boundary.
"""
function heap_insert_raw_batch!(pool::BufferPool,heap::HeapFile,payloads;
                                page_lsn::Integer=0)::Vector{RID}
    results = RID[]
    frame::Union{Nothing,BufferFrame} = nothing
    dirty = false

    function release_page!()
        frame === nothing && return
        current = frame::BufferFrame
        try
            if dirty
                set_page_lsn!(current.page,page_lsn)
                finalize_page!(current.page)
            end
        finally
            unlock(current.latch)
            unpin_page!(pool,current;dirty,page_lsn)
            frame = nothing
            dirty = false
        end
    end

    try
        for payload in payloads
            bytes = payload isa Vector{UInt8} ? payload : Vector{UInt8}(payload)
            isempty(bytes) && storageerror("Record heap kosong tidak didukung.")
            while true
                if frame === nothing
                    page_id = heap.last_page_id == 0 ?
                        _new_heap_data_page!(pool,heap;page_lsn) : heap.last_page_id
                    frame = fetch_page!(pool,page_id)
                    lock((frame::BufferFrame).latch)
                end
                current = frame::BufferFrame
                page_header(current.page).page_type == PageTypeHeap ||
                    storageerror("Page heap tidak valid.")
                if _heap_page_has_room!(current.page,length(bytes))
                    slot_id = slotted_insert!(current.page,bytes;finalize=false)
                    push!(results,RID(current.page_id,slot_id))
                    dirty = true
                    break
                end
                release_page!()
                _new_heap_data_page!(pool,heap;page_lsn)
            end
        end
    finally
        release_page!()
    end
    results
end

function _encode_forward_rid(rid::RID)
    bytes = zeros(UInt8,14)
    copyto!(bytes,1,HEAP_FORWARD_MAGIC,1,length(HEAP_FORWARD_MAGIC))
    page_put_u64!(bytes,5,rid.page_id)
    page_put_u16!(bytes,13,rid.slot_id)
    bytes
end
function _decode_forward_rid(payload::Vector{UInt8})
    length(payload) == 14 && payload[1:4] == HEAP_FORWARD_MAGIC || storageerror("Payload forwarding RID rusak.")
    RID(page_get_u64(payload,5),page_get_u16(payload,13))
end

function _heap_read_raw_once(pool::BufferPool,rid::RID)
    frame = fetch_page!(pool,rid.page_id)
    lock(frame.latch)
    try
        page_header(frame.page).page_type == PageTypeHeap || storageerror("RID tidak mengarah ke page heap.")
        entry = slotted_slot(frame.page,rid.slot_id)
        entry.flags & SLOT_FLAG_LIVE != 0 || storageerror("RID mengarah ke record yang sudah dihapus.")
        payload = slotted_read(frame.page,rid.slot_id)
        payload,entry.flags & SLOT_FLAG_FORWARDED != 0
    finally
        unlock(frame.latch)
        unpin_page!(pool,frame)
    end
end

function heap_read_raw(pool::BufferPool,rid::RID;max_hops::Integer=16)::Vector{UInt8}
    current = rid
    for _ in 0:Int(max_hops)
        payload,forwarded = _heap_read_raw_once(pool,current)
        forwarded || return payload
        current = _decode_forward_rid(payload)
    end
    storageerror("Rantai forwarding RID terlalu panjang atau siklik.")
end

"""Resolve a stable RID to its last physical version without changing identity."""
function _heap_terminal_rid(pool::BufferPool,rid::RID;max_hops::Integer=16)::RID
    current = rid
    seen = Set{RID}()
    for _ in 0:Int(max_hops)
        current in seen && storageerror("Rantai forwarding RID bersiklus.")
        push!(seen,current)
        payload,forwarded = _heap_read_raw_once(pool,current)
        forwarded || return current
        current = _decode_forward_rid(payload)
    end
    storageerror("Rantai forwarding RID terlalu panjang.")
end

function heap_update_raw!(pool::BufferPool,heap::HeapFile,rid::RID,payload::AbstractVector{UInt8};
                          page_lsn::Integer=0,max_hops::Integer=16)::RID
    bytes = payload isa Vector{UInt8} ? payload : Vector{UInt8}(payload)
    isempty(bytes) && storageerror("Record heap kosong tidak didukung.")
    # Update the last physical record in an existing forwarding chain.  The
    # original RID remains stable, and an old target cannot be left visible as
    # an orphan during a later relocation.
    terminal = _heap_terminal_rid(pool,rid;max_hops)
    frame = fetch_page!(pool,terminal.page_id)
    direct = false
    old_length = 0
    lock(frame.latch)
    try
        entry = slotted_slot(frame.page,terminal.slot_id)
        entry.flags & SLOT_FLAG_LIVE != 0 || storageerror("RID mengarah ke record yang sudah dihapus.")
        old_length = Int(entry.length)
        if length(bytes) <= old_length || _heap_page_has_room!(frame.page,length(bytes);new_slot=false)
            slotted_update!(frame.page,terminal.slot_id,bytes;finalize=false)
            set_page_lsn!(frame.page,page_lsn)
            finalize_page!(frame.page)
            direct = true
        end
    finally
        unlock(frame.latch)
        unpin_page!(pool,frame;dirty=direct,page_lsn)
    end
    direct && return rid
    target = heap_insert_raw!(pool,heap,bytes;page_lsn)
    forward = _encode_forward_rid(target)
    length(forward) <= old_length || storageerror("Record terlalu kecil untuk forwarding RID.")
    anchor = fetch_page!(pool,terminal.page_id)
    lock(anchor.latch)
    try
        entry = slotted_slot(anchor.page,terminal.slot_id)
        entry.flags & SLOT_FLAG_LIVE != 0 || storageerror("RID berubah selama update heap.")
        slotted_update!(anchor.page,terminal.slot_id,forward;finalize=false)
        updated = slotted_slot(anchor.page,terminal.slot_id)
        _write_slot!(anchor.page,terminal.slot_id,SlotEntry(updated.offset,updated.length,
            updated.flags | SLOT_FLAG_FORWARDED,updated.generation))
        set_page_lsn!(anchor.page,page_lsn)
        finalize_page!(anchor.page)
    finally
        unlock(anchor.latch)
        unpin_page!(pool,anchor;dirty=true,page_lsn)
    end
    rid
end

function heap_delete!(pool::BufferPool,rid::RID;page_lsn::Integer=0,max_hops::Integer=16)
    current = rid
    for _ in 0:Int(max_hops)
        frame = fetch_page!(pool,current.page_id)
        target = nothing
        lock(frame.latch)
        try
            entry = slotted_slot(frame.page,current.slot_id)
            entry.flags & SLOT_FLAG_LIVE != 0 || return nothing
            payload = slotted_read(frame.page,current.slot_id)
            target = entry.flags & SLOT_FLAG_FORWARDED != 0 ? _decode_forward_rid(payload) : nothing
            slotted_delete!(frame.page,current.slot_id;finalize=false)
            set_page_lsn!(frame.page,page_lsn)
            finalize_page!(frame.page)
        finally
            unlock(frame.latch)
            unpin_page!(pool,frame;dirty=true,page_lsn)
        end
        target === nothing && return nothing
        current = target
    end
    storageerror("Rantai forwarding RID terlalu panjang atau siklik.")
end

function heap_insert!(pool::BufferPool,heap::HeapFile,values::Row;
                      row_id::UInt128,begin_csn::Integer,end_csn::Integer=typemax(UInt64),
                      previous::Union{Nothing,RID}=nothing,schema_epoch::Integer=0,
                      tombstone::Bool=false,page_lsn::Integer=0)::RID
    payload = encode_heap_record(heap.columns,values;row_id,begin_csn,end_csn,previous,schema_epoch,tombstone)
    heap_insert_raw!(pool,heap,payload;page_lsn)
end
function heap_record(pool::BufferPool,heap::HeapFile,rid::RID)::HeapRecord
    decode_heap_record(heap.columns,heap_read_raw(pool,rid))
end
function heap_update_record!(pool::BufferPool,heap::HeapFile,rid::RID,record::HeapRecord;page_lsn::Integer=0)::RID
    payload = encode_heap_record(heap.columns,something(record.values,Cell[]);row_id=record.row_id,
        begin_csn=record.begin_csn,end_csn=record.end_csn,previous=record.previous,
        schema_epoch=record.schema_epoch,tombstone=record.tombstone)
    heap_update_raw!(pool,heap,rid,payload;page_lsn)
end

"""Close one current MVCC heap version without decoding/re-encoding its cells."""
function heap_end_version!(pool::BufferPool,rid::RID,end_csn::Integer;page_lsn::Integer=0)
    target_csn = UInt64(end_csn)
    frame = fetch_page!(pool,rid.page_id)
    dirty = false
    try
        lock(frame.latch)
        try
            page_header(frame.page).page_type == PageTypeHeap || storageerror("RID tidak mengarah ke page heap.")
            entry = slotted_slot(frame.page,rid.slot_id)
            entry.flags & SLOT_FLAG_LIVE != 0 || storageerror("RID mengarah ke record yang sudah dihapus.")
            entry.flags & SLOT_FLAG_FORWARDED == 0 || storageerror("Versi MVCC aktif tidak boleh berupa forwarding RID.")
            payload = slotted_read(frame.page,rid.slot_id)
            length(payload) >= 36 || storageerror("Header record heap terpotong.")
            payload[1] == HEAP_RECORD_FORMAT_VERSION || storageerror("Versi record heap tidak didukung.")
            begin_csn = page_get_u64(payload,21)
            old_end = page_get_u64(payload,29)
            old_end == INFINITY_CSN || storageerror("Versi heap aktif sudah ditutup.")
            begin_csn <= target_csn || storageerror("Rentang CSN record heap tidak valid.")
            page_put_u64!(payload,29,target_csn)
            slotted_update!(frame.page,rid.slot_id,payload;finalize=false)
            set_page_lsn!(frame.page,page_lsn)
            finalize_page!(frame.page)
            dirty = true
        finally
            unlock(frame.latch)
        end
    finally
        unpin_page!(pool,frame;dirty,page_lsn)
    end
    rid
end

function heap_batch_cursor(heap::HeapFile,pool::BufferPool;batch_size::Integer=256)
    batch_size >= 1 || storageerror("Ukuran batch heap minimal satu.")
    HeapBatchCursor(heap,pool,heap.first_page_id,1,Int(batch_size),false)
end

function next_heap_batch!(cursor::HeapBatchCursor)
    cursor.finished && return nothing
    batch = Vector{Tuple{RID,Vector{UInt8}}}()
    while length(batch) < cursor.batch_size && cursor.page_id != 0
        frame = fetch_page!(cursor.pool,cursor.page_id)
        read_ahead = UInt64(0)
        lock(frame.latch)
        try
            page_header(frame.page).page_type == PageTypeHeap || storageerror("Rantai heap memuat tipe page lain.")
            slot_count = slotted_slot_count(frame.page)
            while cursor.slot_id <= slot_count && length(batch) < cursor.batch_size
                slot_id = cursor.slot_id
                cursor.slot_id += 1
                entry = slotted_slot(frame.page,slot_id)
                entry.flags & SLOT_FLAG_LIVE == 0 && continue
                entry.flags & SLOT_FLAG_FORWARDED != 0 && continue
                push!(batch,(RID(frame.page_id,slot_id),slotted_read(frame.page,slot_id)))
            end
            if cursor.slot_id > slot_count
                cursor.page_id = _heap_next(frame.page)
                cursor.slot_id = 1
                read_ahead = cursor.page_id
            end
        finally
            unlock(frame.latch)
            unpin_page!(cursor.pool,frame)
        end
        read_ahead == 0 || prefetch_page!(cursor.pool,read_ahead)
    end
    if isempty(batch) && cursor.page_id == 0
        cursor.finished = true
        return nothing
    end
    batch
end

function Base.iterate(cursor::HeapBatchCursor,state=nothing)
    batch = next_heap_batch!(cursor)
    batch === nothing ? nothing : (batch,nothing)
end
Base.IteratorSize(::Type{HeapBatchCursor}) = Base.SizeUnknown()
Base.IteratorEltype(::Type{HeapBatchCursor}) = Base.EltypeUnknown()

function heap_visible_batch(cursor::HeapBatchCursor,snapshot_csn::Integer)
    raw = next_heap_batch!(cursor)
    raw === nothing && return nothing
    rows = Vector{Tuple{RID,HeapRecord}}()
    for (rid,payload) in raw
        record = decode_heap_record(cursor.heap.columns,payload)
        record_visible(record,snapshot_csn) && push!(rows,(rid,record))
    end
    rows
end

function heap_flush!(pool::BufferPool)
    flush_all!(pool;sync=true)
end
