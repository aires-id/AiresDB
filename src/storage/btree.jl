# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

"""Persistent page-based B+Tree.  Nodes live only in slotted ARSP-4 pages."""
const BTREE_META_MAGIC = UInt8[0x41,0x49,0x52,0x45,0x53,0x42,0x50,0x31] # AIRESBP1
const BTREE_META_VERSION = UInt16(1)
const BTREE_META_OFFSET = PAGE_HEADER_SIZE + 1
const BTREE_PARENT_OFFSET = PAGE_HEADER_SIZE + 1
const BTREE_LINK_A_OFFSET = PAGE_HEADER_SIZE + 9
const BTREE_LINK_B_OFFSET = PAGE_HEADER_SIZE + 17
const BTREE_LEVEL_OFFSET = PAGE_HEADER_SIZE + 25

mutable struct PersistentBTree
    meta_page_id::UInt64
    root_page_id::UInt64
    first_leaf_page_id::UInt64
    height::UInt16
    # Structural changes span several pages. Individual page latches protect
    # frames, while this latch makes multi-page split/delete surgery atomic.
    write_latch::ReentrantLock
end
PersistentBTree(meta_page_id::Integer,root_page_id::Integer,first_leaf_page_id::Integer,height::Integer) =
    PersistentBTree(UInt64(meta_page_id),UInt64(root_page_id),UInt64(first_leaf_page_id),UInt16(height),ReentrantLock())

struct BTreeLeafState
    parent::UInt64
    previous::UInt64
    next::UInt64
    entries::Vector{Tuple{Vector{UInt8},RID}}
end

struct BTreeInternalState
    parent::UInt64
    level::UInt16
    keys::Vector{Vector{UInt8}}
    children::Vector{UInt64}
end

"""Bounded ordered traversal state for a persistent B+Tree."""
mutable struct BTreeCursor
    pool::BufferPool
    tree::PersistentBTree
    page_id::UInt64
    entry_index::Int
    lower::Union{Nothing,Vector{UInt8}}
    upper::Union{Nothing,Vector{UInt8}}
    lower_inclusive::Bool
    upper_inclusive::Bool
    reverse::Bool
    seen_pages::Set{UInt64}
    finished::Bool
end

@inline function btree_compare(left::Vector{UInt8},right::Vector{UInt8})::Int
    limit = min(length(left),length(right))
    @inbounds for index in 1:limit
        left[index] == right[index] && continue
        return left[index] < right[index] ? -1 : 1
    end
    length(left) == length(right) ? 0 : length(left) < length(right) ? -1 : 1
end

function _btree_put_be!(bytes::Vector{UInt8},offset::Int,value::UInt64,width::Int)
    1 <= width <= 8 || storageerror("Lebar key B+Tree tidak valid.")
    _page_bounds(bytes,offset,width)
    @inbounds for index in 0:width-1
        bytes[offset+index] = UInt8((value >> (8 * (width-index-1))) & 0xff)
    end
    bytes
end
function _btree_put_be128!(bytes::Vector{UInt8},offset::Int,value::UInt128)
    _page_bounds(bytes,offset,16)
    @inbounds for index in 0:15
        bytes[offset+index] = UInt8((value >> (8 * (15-index))) & 0xff)
    end
    bytes
end

"""Canonical key bytes.  Numeric forms preserve their natural ascending order."""
btree_key(bytes::AbstractVector{UInt8}) = Vector{UInt8}(bytes)
function btree_key(value::Int64)
    bytes = zeros(UInt8,9); bytes[1] = 0x20
    _btree_put_be!(bytes,2,xor(reinterpret(UInt64,value),UInt64(0x8000000000000000)),8)
end
function btree_key(value::UInt64)
    bytes = zeros(UInt8,9); bytes[1] = 0x21
    _btree_put_be!(bytes,2,value,8)
end
function btree_key(value::UInt128)
    bytes = zeros(UInt8,17); bytes[1] = 0x22
    _btree_put_be128!(bytes,2,value)
end
function btree_key(value::Int128)
    bytes = zeros(UInt8,17); bytes[1] = 0x23
    _btree_put_be128!(bytes,2,xor(reinterpret(UInt128,value),UInt128(1) << 127))
end
btree_key(value::Signed) = btree_key(Int64(value))
btree_key(value::Unsigned) = btree_key(UInt64(value))
function btree_key(value::Bool)
    UInt8[0x10,value ? 0x01 : 0x00]
end
function btree_key(value::AbstractString)
    raw = codeunits(String(value)); bytes = UInt8[0x30]
    for byte in raw
        if byte == 0x00
            append!(bytes,UInt8[0x00,0xff])
        else
            push!(bytes,byte)
        end
    end
    append!(bytes,UInt8[0x00,0x00])
    bytes
end
function btree_key(value::Tuple{Vararg{Int64,N}}) where N
    # Hot primary/composite integer keys are encoded straight into their final
    # escaped tuple buffer. The generic path below allocates a component vector
    # and repeatedly grows the tuple vector; at 250k rows and two indexes that
    # allocator churn dominates peak RSS even though the objects are short-lived.
    ordered_values = ntuple(i->xor(reinterpret(UInt64,value[i]),UInt64(0x8000000000000000)),N)
    escaped_zeroes = 0
    for ordered in ordered_values, shift in 0:7
        UInt8((ordered >> (8 * shift)) & 0xff) == 0x00 && (escaped_zeroes += 1)
    end
    bytes = Vector{UInt8}(undef,1 + N * 11 + escaped_zeroes)
    position = 1
    bytes[position] = 0x70; position += 1
    for ordered in ordered_values
        bytes[position] = 0x20; position += 1
        for shift in 7:-1:0
            byte = UInt8((ordered >> (8 * shift)) & 0xff)
            bytes[position] = byte; position += 1
            if byte == 0x00
                bytes[position] = 0xff; position += 1
            end
        end
        bytes[position] = 0x00; bytes[position+1] = 0x00; position += 2
    end
    position == length(bytes)+1 || storageerror("Encoder tuple integer B+Tree tidak konsisten.")
    bytes
end
function btree_key(value::Tuple)
    bytes = UInt8[0x70]
    for item in value
        encoded = btree_key(item)
        # Escape then terminate each component. A fixed-length prefix would
        # break lexicographic tuple order (for example `(\"b\",)` vs
        # `(\"aa\",)`).
        for byte in encoded
            byte == 0x00 ? append!(bytes,UInt8[0x00,0xff]) : push!(bytes,byte)
        end
        append!(bytes,UInt8[0x00,0x00])
    end
    bytes
end

function btree_key(value::Date)
    bytes = zeros(UInt8,9); bytes[1] = 0x50
    days = Int64(Dates.value(value - Date(1970,1,1)))
    _btree_put_be!(bytes,2,xor(reinterpret(UInt64,days),UInt64(0x8000000000000000)),8)
end
function btree_key(value::Time)
    bytes = zeros(UInt8,9); bytes[1] = 0x51
    _btree_put_be!(bytes,2,UInt64(Dates.value(value)),8)
end
function btree_key(value::DateTime)
    bytes = zeros(UInt8,9); bytes[1] = 0x52
    millis = Int64(Dates.value(value - DateTime(1970,1,1)))
    _btree_put_be!(bytes,2,xor(reinterpret(UInt64,millis),UInt64(0x8000000000000000)),8)
end
function btree_key(value::Money)
    bytes = zeros(UInt8,17); bytes[1] = 0x53
    _btree_put_be128!(bytes,2,xor(reinterpret(UInt128,value.minor),UInt128(1) << 127))
end
function btree_key(value::Float64)
    isfinite(value) || storageerror("Key Float64 B+Tree harus terbatas.")
    bytes = zeros(UInt8,9); bytes[1] = 0x54
    bits = reinterpret(UInt64,iszero(value) ? 0.0 : value)
    ordered = (bits & (UInt64(1) << 63)) == 0 ? xor(bits,UInt64(1) << 63) : ~bits
    _btree_put_be!(bytes,2,ordered,8)
end

"""Bytes for a normalized decimal in numerical order without Float64 loss."""
function btree_key(value::Decimal)
    value.coefficient == 0 && return UInt8[0x55,0x01]
    negative = value.coefficient < 0
    digits = codeunits(string(abs(BigInt(value.coefficient))))
    exponent = length(digits) - Int(value.scale)
    -128 <= exponent <= 127 || storageerror("Eksponen key Decimal di luar batas.")
    body = UInt8[UInt8(exponent + 128)]
    append!(body,UInt8[byte for byte in digits])
    push!(body,0x00)
    if negative
        return vcat(UInt8[0x55,0x00],UInt8[xor(byte,0xff) for byte in body])
    end
    vcat(UInt8[0x55,0x02],body)
end

function _btree_meta_write!(page::Page,tree::PersistentBTree)
    page_header(page).page_type == PageTypeBTreeMeta || storageerror("Page metadata B+Tree tidak valid.")
    fill!(@view(page.bytes[BTREE_META_OFFSET:BTREE_META_OFFSET+39]),0x00)
    copyto!(page.bytes,BTREE_META_OFFSET,BTREE_META_MAGIC,1,length(BTREE_META_MAGIC))
    page_put_u16!(page.bytes,BTREE_META_OFFSET+8,BTREE_META_VERSION)
    page_put_u64!(page.bytes,BTREE_META_OFFSET+10,tree.root_page_id)
    page_put_u64!(page.bytes,BTREE_META_OFFSET+18,tree.first_leaf_page_id)
    page_put_u16!(page.bytes,BTREE_META_OFFSET+26,tree.height)
    finalize_page!(page)
    page
end
function _btree_meta_read(page::Page)
    page_header(page).page_type == PageTypeBTreeMeta || storageerror("Page metadata B+Tree tidak valid.")
    page.bytes[BTREE_META_OFFSET:BTREE_META_OFFSET+7] == BTREE_META_MAGIC || storageerror("Magic metadata B+Tree tidak valid.")
    page_get_u16(page.bytes,BTREE_META_OFFSET+8) == BTREE_META_VERSION || storageerror("Versi metadata B+Tree tidak didukung.")
    root = page_get_u64(page.bytes,BTREE_META_OFFSET+10)
    first = page_get_u64(page.bytes,BTREE_META_OFFSET+18)
    height = page_get_u16(page.bytes,BTREE_META_OFFSET+26)
    root != 0 && first != 0 || storageerror("Root B+Tree tidak valid.")
    PersistentBTree(page.id,root,first,height)
end

@inline _btree_parent(page::Page) = page_get_u64(page.bytes,BTREE_PARENT_OFFSET)
@inline _btree_previous(page::Page) = page_get_u64(page.bytes,BTREE_LINK_A_OFFSET)
@inline _btree_next(page::Page) = page_get_u64(page.bytes,BTREE_LINK_B_OFFSET)
@inline _btree_first_child(page::Page) = page_get_u64(page.bytes,BTREE_LINK_A_OFFSET)
@inline _btree_level(page::Page) = page_get_u16(page.bytes,BTREE_LEVEL_OFFSET)
@inline _set_btree_parent!(page::Page,value::Integer) = page_put_u64!(page.bytes,BTREE_PARENT_OFFSET,value)
@inline _set_btree_previous!(page::Page,value::Integer) = page_put_u64!(page.bytes,BTREE_LINK_A_OFFSET,value)
@inline _set_btree_next!(page::Page,value::Integer) = page_put_u64!(page.bytes,BTREE_LINK_B_OFFSET,value)
@inline _set_btree_first_child!(page::Page,value::Integer) = page_put_u64!(page.bytes,BTREE_LINK_A_OFFSET,value)
@inline _set_btree_level!(page::Page,value::Integer) = page_put_u16!(page.bytes,BTREE_LEVEL_OFFSET,value)

function _leaf_payload(key::Vector{UInt8},rid::RID)
    length(key) <= typemax(UInt16) || storageerror("Key B+Tree terlalu panjang.")
    bytes = Vector{UInt8}(undef,12 + length(key))
    page_put_u16!(bytes,1,length(key))
    copyto!(bytes,3,key,1,length(key))
    page_put_u64!(bytes,3 + length(key),rid.page_id)
    page_put_u16!(bytes,11 + length(key),rid.slot_id)
    bytes
end
function _decode_leaf_payload(payload::Vector{UInt8})
    io = IOBuffer(payload); length_key = Int(get_u16(io))
    length_key <= bytesavailable(io) - 10 || storageerror("Payload leaf B+Tree rusak.")
    key = read_exact(io,length_key); rid = RID(get_u64(io),get_u16(io)); eof(io) || storageerror("Byte tambahan leaf B+Tree.")
    key,rid
end
function _internal_payload(key::Vector{UInt8},child::UInt64)
    length(key) <= typemax(UInt16) || storageerror("Key B+Tree terlalu panjang.")
    bytes = Vector{UInt8}(undef,10 + length(key))
    page_put_u16!(bytes,1,length(key))
    copyto!(bytes,3,key,1,length(key))
    page_put_u64!(bytes,3 + length(key),child)
    bytes
end
function _decode_internal_payload(payload::Vector{UInt8})
    io = IOBuffer(payload); length_key = Int(get_u16(io))
    length_key <= bytesavailable(io) - 8 || storageerror("Payload internal B+Tree rusak.")
    key = read_exact(io,length_key); child = get_u64(io); child != 0 || storageerror("Child B+Tree nol.")
    eof(io) || storageerror("Byte tambahan internal B+Tree.")
    key,child
end

function _leaf_state(page::Page)
    page_header(page).page_type == PageTypeBTreeLeaf || storageerror("Node yang diharapkan leaf B+Tree tidak valid.")
    _btree_level(page) == 0 || storageerror("Level leaf B+Tree tidak valid.")
    entries = Tuple{Vector{UInt8},RID}[]
    for slot in slotted_live_slots(page)
        entry = _decode_leaf_payload(slotted_read(page,slot))
        isempty(entries) || btree_compare(entries[end][1],entry[1]) < 0 ||
            storageerror("Key leaf B+Tree tidak terurut atau duplikat.")
        push!(entries,entry)
    end
    BTreeLeafState(_btree_parent(page),_btree_previous(page),_btree_next(page),entries)
end
function _internal_state(page::Page)
    page_header(page).page_type == PageTypeBTreeInternal || storageerror("Node internal B+Tree tidak valid.")
    level = _btree_level(page); level > 0 || storageerror("Level node internal B+Tree tidak valid.")
    first_child = _btree_first_child(page); first_child != 0 || storageerror("Child pertama B+Tree nol.")
    entries = Tuple{Vector{UInt8},UInt64}[]
    for slot in slotted_live_slots(page)
        entry = _decode_internal_payload(slotted_read(page,slot))
        isempty(entries) || btree_compare(entries[end][1],entry[1]) < 0 ||
            storageerror("Separator internal B+Tree tidak urut atau duplikat.")
        push!(entries,entry)
    end
    keys = Vector{UInt8}[entry[1] for entry in entries]
    children = UInt64[first_child]
    append!(children,UInt64[entry[2] for entry in entries])
    for index in 2:length(keys)
        btree_compare(keys[index-1],keys[index]) < 0 || storageerror("Separator internal B+Tree tidak urut.")
    end
    length(children) == length(keys) + 1 || storageerror("Child internal B+Tree tidak konsisten.")
    BTreeInternalState(_btree_parent(page),level,keys,children)
end

@inline _btree_node_capacity(page_size::Integer) = Int(page_size) + 1 - (PAGE_HEADER_SIZE + BTREE_NODE_META_SIZE + 1)
function _leaf_fits_capacity(capacity::Int,entries)
    required = sum(length(entry[1]) + 12 + SLOT_SIZE for entry in entries;init=0)
    required <= capacity
end
_leaf_fits(page::Page,entries) = _leaf_fits_capacity(_btree_node_capacity(length(page.bytes)),entries)
function _internal_fits_capacity(capacity::Int,keys,children)
    length(children) == length(keys) + 1 || return false
    required = sum(length(key) + 10 + SLOT_SIZE for key in keys;init=0)
    required <= capacity
end
_internal_fits(page::Page,keys,children) = _internal_fits_capacity(_btree_node_capacity(length(page.bytes)),keys,children)

function _write_leaf!(page::Page,state::BTreeLeafState;page_lsn::Integer=0)
    _leaf_fits(page,state.entries) || storageerror("Leaf B+Tree penuh.")
    init_slotted_page!(page,PageTypeBTreeLeaf;page_lsn)
    _set_btree_parent!(page,state.parent)
    _set_btree_previous!(page,state.previous)
    _set_btree_next!(page,state.next)
    _set_btree_level!(page,0)
    for (key,rid) in state.entries
        slotted_insert!(page,_leaf_payload(key,rid);finalize=false)
    end
    set_page_lsn!(page,page_lsn)
    finalize_page!(page)
    page
end
function _write_internal!(page::Page,state::BTreeInternalState;page_lsn::Integer=0)
    _internal_fits(page,state.keys,state.children) || storageerror("Node internal B+Tree penuh.")
    init_slotted_page!(page,PageTypeBTreeInternal;page_lsn)
    _set_btree_parent!(page,state.parent)
    _set_btree_first_child!(page,state.children[1])
    _set_btree_level!(page,state.level)
    for (index,key) in enumerate(state.keys)
        slotted_insert!(page,_internal_payload(key,state.children[index+1]);finalize=false)
    end
    set_page_lsn!(page,page_lsn)
    finalize_page!(page)
    page
end

function create_btree!(pool::BufferPool;page_lsn::Integer=0)::PersistentBTree
    meta_frame = new_page!(pool,PageTypeBTreeMeta;page_lsn)
    root_frame = new_page!(pool,PageTypeBTreeLeaf;page_lsn)
    tree = PersistentBTree(meta_frame.page_id,root_frame.page_id,root_frame.page_id,UInt16(0))
    lock(root_frame.latch)
    try
        _write_leaf!(root_frame.page,BTreeLeafState(0,0,0,Tuple{Vector{UInt8},RID}[]);page_lsn)
    finally
        unlock(root_frame.latch)
        unpin_page!(pool,root_frame;dirty=true,page_lsn)
    end
    lock(meta_frame.latch)
    try
        _btree_meta_write!(meta_frame.page,tree)
    finally
        unlock(meta_frame.latch)
        unpin_page!(pool,meta_frame;dirty=true,page_lsn)
    end
    tree
end
function open_btree(pool::BufferPool,meta_page_id::Integer)::PersistentBTree
    frame = fetch_page!(pool,meta_page_id)
    lock(frame.latch)
    try
        _btree_meta_read(frame.page)
    finally
        unlock(frame.latch)
        unpin_page!(pool,frame)
    end
end
function _persist_btree_meta!(pool::BufferPool,tree::PersistentBTree;page_lsn::Integer=0)
    frame = fetch_page!(pool,tree.meta_page_id)
    lock(frame.latch)
    try
        _btree_meta_write!(frame.page,tree)
        set_page_lsn!(frame.page,page_lsn)
        finalize_page!(frame.page)
    finally
        unlock(frame.latch)
        unpin_page!(pool,frame;dirty=true,page_lsn)
    end
    nothing
end

# Bulk loading is deliberately separate from `btree_insert!`.  The ordinary
# writer keeps its split-at-a-time behavior for concurrent transactional
# changes, while a newly-created index can pack a complete, validated batch in
# key order without repeatedly decoding and rewriting the same leaf page.
@inline _btree_leaf_entry_bytes(key::Vector{UInt8}) = length(key) + 12 + SLOT_SIZE
@inline _btree_internal_entry_bytes(key::Vector{UInt8}) = length(key) + 10 + SLOT_SIZE

function _btree_bulk_normalize(entries)
    normalized = Tuple{Vector{UInt8},RID}[]
    entries isa AbstractVector && sizehint!(normalized,length(entries))
    for entry in entries
        key_input = nothing
        rid = nothing
        if entry isa Pair
            key_input,rid = entry.first,entry.second
        elseif entry isa Tuple && length(entry) == 2
            key_input,rid = entry
        else
            storageerror("Entry bulk B+Tree harus berupa pasangan key dan RID.")
        end
        rid isa RID || storageerror("Entry bulk B+Tree harus memiliki RID.")
        # Callers that already encoded a table key may transfer ownership to
        # the loader.  Sorting reorders entries but never mutates key bytes.
        key = key_input isa Vector{UInt8} ? key_input : btree_key(key_input)
        push!(normalized,(key,rid))
    end
    sort!(normalized;lt=(left,right)->btree_compare(left[1],right[1]) < 0)
    for index in 2:length(normalized)
        btree_compare(normalized[index-1][1],normalized[index][1]) != 0 ||
            constraint("Key B+Tree harus unik.")
    end
    normalized
end

function _btree_bulk_leaf_runs(entries::Vector{Tuple{Vector{UInt8},RID}},capacity::Int)
    runs = UnitRange{Int}[]
    isempty(entries) && return runs
    first = 1
    used = 0
    for index in eachindex(entries)
        needed = _btree_leaf_entry_bytes(entries[index][1])
        needed <= capacity || storageerror("Entry leaf B+Tree terlalu besar untuk satu page.")
        if used > 0 && used + needed > capacity
            push!(runs,first:index-1)
            first = index
            used = 0
        end
        used += needed
    end
    push!(runs,first:length(entries))
    runs
end

function _btree_bulk_internal_runs(children::Vector{Tuple{UInt64,Vector{UInt8}}},capacity::Int)
    length(children) >= 2 || storageerror("Node internal bulk B+Tree membutuhkan minimal dua child.")
    runs = UnitRange{Int}[]
    first = 1
    used = 0
    # The first child is recorded in node metadata.  Each later child carries
    # its lower-bound separator as a normal slotted entry.
    for index in 2:length(children)
        needed = _btree_internal_entry_bytes(children[index][2])
        needed <= capacity || storageerror("Separator internal B+Tree terlalu besar untuk satu page.")
        if used > 0 && used + needed > capacity
            push!(runs,first:index-1)
            first = index
            used = 0
        end
        used += needed
    end
    push!(runs,first:length(children))
    runs
end

function _btree_allocate_node_ids!(pool::BufferPool,page_type::PageType,count::Int;page_lsn::Integer=0)
    count >= 0 || storageerror("Jumlah node B+Tree bulk tidak valid.")
    ids = UInt64[]
    sizehint!(ids,count)
    for _ in 1:count
        frame = new_page!(pool,page_type;page_lsn)
        try
            push!(ids,frame.page_id)
        finally
            # `allocate_page!` has already made the blank page durable.  It is
            # rewritten below after all IDs and sibling links are known.
            unpin_page!(pool,frame)
        end
    end
    ids
end

function _btree_write_bulk_leaf!(pool::BufferPool,page_id::UInt64,state::BTreeLeafState;page_lsn::Integer=0)
    frame = fetch_page!(pool,page_id)
    try
        lock(frame.latch)
        try
            _write_leaf!(frame.page,state;page_lsn)
        finally
            unlock(frame.latch)
        end
    finally
        unpin_page!(pool,frame;dirty=true,page_lsn)
    end
    nothing
end

function _btree_write_bulk_internal!(pool::BufferPool,page_id::UInt64,state::BTreeInternalState;page_lsn::Integer=0)
    frame = fetch_page!(pool,page_id)
    try
        lock(frame.latch)
        try
            _write_internal!(frame.page,state;page_lsn)
        finally
            unlock(frame.latch)
        end
    finally
        unpin_page!(pool,frame;dirty=true,page_lsn)
    end
    nothing
end

function _btree_assert_pristine!(pool::BufferPool,tree::PersistentBTree)
    tree.height == 0 && tree.root_page_id == tree.first_leaf_page_id ||
        storageerror("Bulk load hanya dapat digunakan pada B+Tree kosong.")
    frame = fetch_page!(pool,tree.root_page_id)
    try
        lock(frame.latch)
        try
            state = _leaf_state(frame.page)
            isempty(state.entries) && state.parent == 0 && state.previous == 0 && state.next == 0 ||
                storageerror("Bulk load hanya dapat digunakan pada B+Tree kosong.")
        finally
            unlock(frame.latch)
        end
    finally
        unpin_page!(pool,frame)
    end
    nothing
end

"""Pack a fully validated batch into an empty persistent B+Tree.

The loader sorts its input, rejects duplicate keys before touching a node, and
constructs leaf and internal levels bottom-up.  It is intended for initial
index creation during a bulk transaction; incremental writes continue to use
`btree_insert!`.
"""
function btree_bulk_load!(pool::BufferPool,tree::PersistentBTree,entries;page_lsn::Integer=0)
    normalized = _btree_bulk_normalize(entries)
    lock(tree.write_latch) do
        _btree_assert_pristine!(pool,tree)
        isempty(normalized) && return tree
        capacity = _btree_node_capacity(pool.manager.page_size)
        leaf_runs = _btree_bulk_leaf_runs(normalized,capacity)
        # The initial root leaf is reusable.  All later leaves are allocated
        # before their linked contents are written so next/previous pointers
        # are deterministic without retaining every frame pinned.
        leaf_ids = UInt64[tree.root_page_id]
        append!(leaf_ids,_btree_allocate_node_ids!(pool,PageTypeBTreeLeaf,length(leaf_runs)-1;page_lsn))
        for (run_index,run) in enumerate(leaf_runs)
            entries_for_leaf = copy(normalized[run])
            previous = run_index == 1 ? UInt64(0) : leaf_ids[run_index-1]
            next = run_index == length(leaf_runs) ? UInt64(0) : leaf_ids[run_index+1]
            _btree_write_bulk_leaf!(pool,leaf_ids[run_index],
                BTreeLeafState(0,previous,next,entries_for_leaf);page_lsn)
        end

        children = Tuple{UInt64,Vector{UInt8}}[]
        sizehint!(children,length(leaf_runs))
        for (run_index,run) in enumerate(leaf_runs)
            push!(children,(leaf_ids[run_index],normalized[first(run)][1]))
        end
        level = 1
        while length(children) > 1
            runs = _btree_bulk_internal_runs(children,capacity)
            node_ids = _btree_allocate_node_ids!(pool,PageTypeBTreeInternal,length(runs);page_lsn)
            next_children = Tuple{UInt64,Vector{UInt8}}[]
            sizehint!(next_children,length(runs))
            for (run_index,run) in enumerate(runs)
                child_slice = children[run]
                child_ids = UInt64[item[1] for item in child_slice]
                separators = Vector{UInt8}[item[2] for item in child_slice[2:end]]
                node_id = node_ids[run_index]
                _btree_write_bulk_internal!(pool,node_id,
                    BTreeInternalState(0,UInt16(level),separators,child_ids);page_lsn)
                for child_id in child_ids
                    _set_child_parent!(pool,child_id,node_id;page_lsn)
                end
                push!(next_children,(node_id,child_slice[1][2]))
            end
            children = next_children
            level += 1
        end
        tree.root_page_id = children[1][1]
        tree.first_leaf_page_id = leaf_ids[1]
        tree.height = UInt16(level - 1)
        _persist_btree_meta!(pool,tree;page_lsn)
        tree
    end
end

"""Pack a trusted key-ordered iterator into an empty persistent B+Tree.

Only one leaf's encoded entries is resident at a time. This is the bounded
loader used by the PageStore after the logical unique index has already
validated ordering and duplicates; the public bulk loader above retains its
all-input validation/atomicity contract.
"""
function btree_bulk_load_ordered!(pool::BufferPool,tree::PersistentBTree,entries;
                                  page_lsn::Integer=0)
    lock(tree.write_latch) do
        _btree_assert_pristine!(pool,tree)
        capacity = _btree_node_capacity(pool.manager.page_size)
        children = Tuple{UInt64,Vector{UInt8}}[]
        leaf_ids = UInt64[]
        current_id = tree.root_page_id
        previous_id = UInt64(0)
        current_entries = Tuple{Vector{UInt8},RID}[]
        used = 0
        previous_key = nothing

        function finish_leaf!(next_id::UInt64)
            isempty(current_entries) && return
            _btree_write_bulk_leaf!(pool,current_id,
                BTreeLeafState(0,previous_id,next_id,current_entries);page_lsn)
            push!(leaf_ids,current_id)
            push!(children,(current_id,current_entries[1][1]))
        end

        for raw in entries
            raw isa Tuple && length(raw) == 2 ||
                storageerror("Entry ordered B+Tree harus berupa pasangan key dan RID.")
            key_input,rid = raw
            rid isa RID || storageerror("Entry ordered B+Tree harus memiliki RID.")
            key = key_input isa Vector{UInt8} ? key_input : btree_key(key_input)
            if previous_key !== nothing
                btree_compare(previous_key::Vector{UInt8},key) < 0 ||
                    constraint("Key B+Tree harus unik dan terurut.")
            end
            needed = _btree_leaf_entry_bytes(key)
            needed <= capacity || storageerror("Entry leaf B+Tree terlalu besar untuk satu page.")
            if !isempty(current_entries) && used + needed > capacity
                next_frame = new_page!(pool,PageTypeBTreeLeaf;page_lsn)
                next_id = next_frame.page_id
                unpin_page!(pool,next_frame)
                finish_leaf!(next_id)
                previous_id = current_id
                current_id = next_id
                current_entries = Tuple{Vector{UInt8},RID}[]
                used = 0
            end
            push!(current_entries,(key,rid))
            used += needed
            previous_key = key
        end
        isempty(current_entries) && return tree
        finish_leaf!(UInt64(0))

        level = 1
        while length(children) > 1
            runs = _btree_bulk_internal_runs(children,capacity)
            node_ids = _btree_allocate_node_ids!(pool,PageTypeBTreeInternal,length(runs);page_lsn)
            next_children = Tuple{UInt64,Vector{UInt8}}[]
            sizehint!(next_children,length(runs))
            for (run_index,run) in enumerate(runs)
                child_slice = children[run]
                child_ids = UInt64[item[1] for item in child_slice]
                separators = Vector{UInt8}[item[2] for item in child_slice[2:end]]
                node_id = node_ids[run_index]
                _btree_write_bulk_internal!(pool,node_id,
                    BTreeInternalState(0,UInt16(level),separators,child_ids);page_lsn)
                for child_id in child_ids
                    _set_child_parent!(pool,child_id,node_id;page_lsn)
                end
                push!(next_children,(node_id,child_slice[1][2]))
            end
            children = next_children
            level += 1
        end
        tree.root_page_id = children[1][1]
        tree.first_leaf_page_id = leaf_ids[1]
        tree.height = UInt16(level - 1)
        _persist_btree_meta!(pool,tree;page_lsn)
        tree
    end
end

function _btree_child_for(state::BTreeInternalState,key::Vector{UInt8})
    child_index = 1
    for (index,separator) in enumerate(state.keys)
        btree_compare(key,separator) < 0 && break
        child_index = index + 1
    end
    state.children[child_index]
end
function _btree_find_leaf(pool::BufferPool,tree::PersistentBTree,key::Vector{UInt8})::UInt64
    page_id = tree.root_page_id
    for _ in 0:128
        frame = fetch_page!(pool,page_id)
        next_page = UInt64(0)
        is_leaf = false
        lock(frame.latch)
        try
            kind = page_header(frame.page).page_type
            if kind == PageTypeBTreeLeaf
                is_leaf = true
            elseif kind == PageTypeBTreeInternal
                next_page = _btree_child_for(_internal_state(frame.page),key)
            else
                storageerror("Rantai B+Tree memuat tipe page lain.")
            end
        finally
            unlock(frame.latch)
            unpin_page!(pool,frame)
        end
        is_leaf && return page_id
        page_id = next_page
    end
    storageerror("Kedalaman B+Tree melebihi batas.")
end
function _btree_last_leaf(pool::BufferPool,tree::PersistentBTree)::UInt64
    page_id = tree.root_page_id
    for _ in 0:128
        frame = fetch_page!(pool,page_id)
        next_page = UInt64(0); leaf = false
        lock(frame.latch)
        try
            kind = page_header(frame.page).page_type
            if kind == PageTypeBTreeLeaf
                leaf = true
            elseif kind == PageTypeBTreeInternal
                state = _internal_state(frame.page); next_page = state.children[end]
            else
                storageerror("Rantai B+Tree memuat tipe page lain.")
            end
        finally
            unlock(frame.latch)
            unpin_page!(pool,frame)
        end
        leaf && return page_id
        page_id = next_page
    end
    storageerror("Kedalaman B+Tree melebihi batas.")
end

function btree_lookup(pool::BufferPool,tree::PersistentBTree,key_input)::Union{Nothing,RID}
    # Until B-link/latch-coupling is introduced, readers share the structural
    # latch with split/delete surgery. This favors a deterministic correct tree
    # over exposing a half-linked path to a concurrent lookup.
    lock(tree.write_latch) do
        key = btree_key(key_input); leaf_id = _btree_find_leaf(pool,tree,key)
        frame = fetch_page!(pool,leaf_id)
        lock(frame.latch)
        try
            entries = _leaf_state(frame.page).entries
            low = 1; high = length(entries)
            while low <= high
                middle = low + div(high-low,2)
                candidate,rid = entries[middle]
                comparison = btree_compare(candidate,key)
                comparison == 0 && return rid
                if comparison < 0
                    low = middle + 1
                else
                    high = middle - 1
                end
            end
            nothing
        finally
            unlock(frame.latch)
            unpin_page!(pool,frame)
        end
    end
end

function _set_child_parent!(pool::BufferPool,child_id::UInt64,parent_id::UInt64;page_lsn::Integer=0)
    frame = fetch_page!(pool,child_id)
    lock(frame.latch)
    try
        kind = page_header(frame.page).page_type
        kind in (PageTypeBTreeLeaf,PageTypeBTreeInternal) || storageerror("Child B+Tree tidak valid.")
        _set_btree_parent!(frame.page,parent_id)
        set_page_lsn!(frame.page,page_lsn)
        finalize_page!(frame.page)
    finally
        unlock(frame.latch)
        unpin_page!(pool,frame;dirty=true,page_lsn)
    end
    nothing
end

function _split_point_leaf(capacity::Int,entries)
    candidates = sort!(collect(1:length(entries)-1);by=index->abs(index - div(length(entries),2)))
    for point in candidates
        _leaf_fits_capacity(capacity,entries[1:point]) && _leaf_fits_capacity(capacity,entries[point+1:end]) && return point
    end
    storageerror("Entry leaf B+Tree terlalu besar untuk split.")
end
function _split_point_internal(capacity::Int,keys,children)
    candidates = sort!(collect(1:length(keys));by=index->abs(index - cld(length(keys),2)))
    for point in candidates
        _internal_fits_capacity(capacity,keys[1:point-1],children[1:point]) &&
            _internal_fits_capacity(capacity,keys[point+1:end],children[point+1:end]) && return point
    end
    storageerror("Entry internal B+Tree terlalu besar untuk split.")
end

function _insert_into_parent!(pool::BufferPool,tree::PersistentBTree,left_id::UInt64,
                              separator::Vector{UInt8},right_id::UInt64;page_lsn::Integer=0)
    left_frame = fetch_page!(pool,left_id)
    parent_id = UInt64(0)
    lock(left_frame.latch)
    try
        parent_id = _btree_parent(left_frame.page)
    finally
        unlock(left_frame.latch)
        unpin_page!(pool,left_frame)
    end
    if parent_id == 0
        root_frame = new_page!(pool,PageTypeBTreeInternal;page_lsn)
        root_id = root_frame.page_id
        root_state = BTreeInternalState(0,UInt16(tree.height + 1),Vector{UInt8}[separator],UInt64[left_id,right_id])
        lock(root_frame.latch)
        try
            _write_internal!(root_frame.page,root_state;page_lsn)
        finally
            unlock(root_frame.latch)
            unpin_page!(pool,root_frame;dirty=true,page_lsn)
        end
        _set_child_parent!(pool,left_id,root_id;page_lsn)
        _set_child_parent!(pool,right_id,root_id;page_lsn)
        tree.root_page_id = root_id
        tree.height += UInt16(1)
        _persist_btree_meta!(pool,tree;page_lsn)
        return nothing
    end
    parent_frame = fetch_page!(pool,parent_id)
    parent_state = nothing
    parent_capacity = 0
    lock(parent_frame.latch)
    try
        state = _internal_state(parent_frame.page)
        parent_capacity = _btree_node_capacity(length(parent_frame.page.bytes))
        index = findfirst(==(left_id),state.children)
        index === nothing && storageerror("Parent B+Tree tidak memuat child kiri.")
        keys = copy(state.keys); children = copy(state.children)
        insert!(keys,index,separator)
        insert!(children,index+1,right_id)
        candidate = BTreeInternalState(state.parent,state.level,keys,children)
        if _internal_fits(parent_frame.page,keys,children)
            _write_internal!(parent_frame.page,candidate;page_lsn)
            parent_state = :written
        else
            parent_state = candidate
        end
    finally
        unlock(parent_frame.latch)
        unpin_page!(pool,parent_frame;dirty=parent_state === :written,page_lsn)
    end
    parent_state === :written && begin
        _set_child_parent!(pool,right_id,parent_id;page_lsn)
        return nothing
    end
    state = parent_state::BTreeInternalState
    point = _split_point_internal(parent_capacity,state.keys,state.children)
    promoted = state.keys[point]
    left_state = BTreeInternalState(state.parent,state.level,copy(state.keys[1:point-1]),copy(state.children[1:point]))
    right_state = BTreeInternalState(state.parent,state.level,copy(state.keys[point+1:end]),copy(state.children[point+1:end]))
    right_frame = new_page!(pool,PageTypeBTreeInternal;page_lsn)
    right_parent_id = right_frame.page_id
    parent_again = fetch_page!(pool,parent_id)
    lock(parent_again.latch)
    try
        _write_internal!(parent_again.page,left_state;page_lsn)
    finally
        unlock(parent_again.latch)
        unpin_page!(pool,parent_again;dirty=true,page_lsn)
    end
    lock(right_frame.latch)
    try
        _write_internal!(right_frame.page,right_state;page_lsn)
    finally
        unlock(right_frame.latch)
        unpin_page!(pool,right_frame;dirty=true,page_lsn)
    end
    for child in right_state.children
        _set_child_parent!(pool,child,right_parent_id;page_lsn)
    end
    _insert_into_parent!(pool,tree,parent_id,promoted,right_parent_id;page_lsn)
    nothing
end

function _btree_insert_locked!(pool::BufferPool,tree::PersistentBTree,key_input,rid::RID;page_lsn::Integer=0)
    key = btree_key(key_input); leaf_id = _btree_find_leaf(pool,tree,key)
    frame = fetch_page!(pool,leaf_id)
    split_state = nothing
    leaf_capacity = 0
    lock(frame.latch)
    try
        state = _leaf_state(frame.page)
        leaf_capacity = _btree_node_capacity(length(frame.page.bytes))
        entries = copy(state.entries)
        index = findfirst(entry->btree_compare(entry[1],key) == 0,entries)
        index === nothing || constraint("Key B+Tree harus unik.")
        insertion = findfirst(entry->btree_compare(entry[1],key) > 0,entries)
        insertion === nothing ? push!(entries,(key,rid)) : insert!(entries,insertion,(key,rid))
        candidate = BTreeLeafState(state.parent,state.previous,state.next,entries)
        if _leaf_fits(frame.page,entries)
            _write_leaf!(frame.page,candidate;page_lsn)
            split_state = :written
        else
            split_state = candidate
        end
    finally
        unlock(frame.latch)
        unpin_page!(pool,frame;dirty=split_state === :written,page_lsn)
    end
    split_state === :written && return rid
    state = split_state::BTreeLeafState
    point = _split_point_leaf(leaf_capacity,state.entries)
    left_entries = copy(state.entries[1:point])
    right_entries = copy(state.entries[point+1:end])
    right_frame = new_page!(pool,PageTypeBTreeLeaf;page_lsn)
    right_id = right_frame.page_id
    left_state = BTreeLeafState(state.parent,state.previous,right_id,left_entries)
    right_state = BTreeLeafState(state.parent,leaf_id,state.next,right_entries)
    left_again = fetch_page!(pool,leaf_id)
    lock(left_again.latch)
    try
        _write_leaf!(left_again.page,left_state;page_lsn)
    finally
        unlock(left_again.latch)
        unpin_page!(pool,left_again;dirty=true,page_lsn)
    end
    lock(right_frame.latch)
    try
        _write_leaf!(right_frame.page,right_state;page_lsn)
    finally
        unlock(right_frame.latch)
        unpin_page!(pool,right_frame;dirty=true,page_lsn)
    end
    if state.next != 0
        successor = fetch_page!(pool,state.next)
        lock(successor.latch)
        try
            leaf = _leaf_state(successor.page)
            _write_leaf!(successor.page,BTreeLeafState(leaf.parent,right_id,leaf.next,leaf.entries);page_lsn)
        finally
            unlock(successor.latch)
            unpin_page!(pool,successor;dirty=true,page_lsn)
        end
    end
    _insert_into_parent!(pool,tree,leaf_id,copy(right_entries[1][1]),right_id;page_lsn)
    rid
end

function btree_insert!(pool::BufferPool,tree::PersistentBTree,key_input,rid::RID;page_lsn::Integer=0)
    lock(tree.write_latch) do
        _btree_insert_locked!(pool,tree,key_input,rid;page_lsn)
    end
end

function btree_delete!(pool::BufferPool,tree::PersistentBTree,key_input;page_lsn::Integer=0)::Bool
    lock(tree.write_latch) do
        key = btree_key(key_input); leaf_id = _btree_find_leaf(pool,tree,key)
        frame = fetch_page!(pool,leaf_id)
        removed = false
        lock(frame.latch)
        try
            state = _leaf_state(frame.page)
            entries = copy(state.entries)
            index = findfirst(entry->btree_compare(entry[1],key) == 0,entries)
            index === nothing && return false
            deleteat!(entries,index)
            _write_leaf!(frame.page,BTreeLeafState(state.parent,state.previous,state.next,entries);page_lsn)
            removed = true
        finally
            unlock(frame.latch)
            unpin_page!(pool,frame;dirty=removed,page_lsn)
        end
        removed
    end
end

"""Apply a transaction's deletes/inserts with at most one rewrite per leaf.

The fast path is used only when every affected leaf still fits after the full
batch.  A batch requiring structural splits falls back to the established
split-at-a-time implementation before any page is modified.
"""
function btree_apply_batch!(pool::BufferPool,tree::PersistentBTree,deletes,inserts;
                            page_lsn::Integer=0)
    delete_keys = Vector{Vector{UInt8}}()
    insert_entries = Tuple{Vector{UInt8},RID}[]
    for key in deletes
        push!(delete_keys,key isa Vector{UInt8} ? key : btree_key(key))
    end
    for entry in inserts
        key_input,rid = entry
        rid isa RID || storageerror("Entry batch B+Tree harus memiliki RID.")
        key = key_input isa Vector{UInt8} ? key_input : btree_key(key_input)
        push!(insert_entries,(key,rid))
    end
    isempty(delete_keys) && isempty(insert_entries) && return tree
    lock(tree.write_latch) do
        groups = Dict{UInt64,Tuple{Vector{Vector{UInt8}},Vector{Tuple{Vector{UInt8},RID}}}}()
        for key in delete_keys
            leaf_id = _btree_find_leaf(pool,tree,key)
            group = get!(groups,leaf_id) do
                (Vector{Vector{UInt8}}(),Tuple{Vector{UInt8},RID}[])
            end
            push!(group[1],key)
        end
        for entry in insert_entries
            leaf_id = _btree_find_leaf(pool,tree,entry[1])
            group = get!(groups,leaf_id) do
                (Vector{Vector{UInt8}}(),Tuple{Vector{UInt8},RID}[])
            end
            push!(group[2],entry)
        end

        candidates = Dict{UInt64,BTreeLeafState}()
        fast_path = true
        for (leaf_id,(leaf_deletes,leaf_inserts)) in groups
            frame = fetch_page!(pool,leaf_id)
            state = nothing
            try
                lock(frame.latch)
                try
                    state = _leaf_state(frame.page)
                finally
                    unlock(frame.latch)
                end
            finally
                unpin_page!(pool,frame)
            end
            entries = copy((state::BTreeLeafState).entries)
            for key in leaf_deletes
                index = findfirst(entry->btree_compare(entry[1],key) == 0,entries)
                index === nothing || deleteat!(entries,index)
            end
            for entry in leaf_inserts
                any(candidate->btree_compare(candidate[1],entry[1]) == 0,entries) &&
                    constraint("Key B+Tree harus unik.")
                push!(entries,entry)
            end
            sort!(entries;lt=(left,right)->btree_compare(left[1],right[1]) < 0)
            candidate = BTreeLeafState(state.parent,state.previous,state.next,entries)
            candidates[leaf_id] = candidate
            fast_path &= _leaf_fits_capacity(_btree_node_capacity(pool.manager.page_size),entries)
        end
        if !fast_path
            for key in delete_keys
                btree_delete!(pool,tree,key;page_lsn)
            end
            for (key,rid) in insert_entries
                _btree_insert_locked!(pool,tree,key,rid;page_lsn)
            end
            return tree
        end
        for (leaf_id,state) in candidates
            frame = fetch_page!(pool,leaf_id)
            try
                lock(frame.latch)
                try
                    _write_leaf!(frame.page,state;page_lsn)
                finally
                    unlock(frame.latch)
                end
            finally
                unpin_page!(pool,frame;dirty=true,page_lsn)
            end
        end
        tree
    end
end

function btree_range(pool::BufferPool,tree::PersistentBTree;
                     lower=nothing,upper=nothing,reverse::Bool=false,limit::Integer=typemax(Int),
                     lower_inclusive::Bool=true,upper_inclusive::Bool=true)
    lock(tree.write_latch) do
        limit >= 0 || storageerror("Limit range B+Tree tidak valid.")
        lower_key = lower === nothing ? nothing : btree_key(lower)
        upper_key = upper === nothing ? nothing : btree_key(upper)
        page_id = reverse ? (upper_key === nothing ? _btree_last_leaf(pool,tree) : _btree_find_leaf(pool,tree,upper_key)) :
                            (lower_key === nothing ? tree.first_leaf_page_id : _btree_find_leaf(pool,tree,lower_key))
        result = Tuple{Vector{UInt8},RID}[]
        seen = Set{UInt64}()
        while page_id != 0 && length(result) < limit
            page_id in seen && storageerror("Siklus sibling leaf B+Tree.")
            push!(seen,page_id)
            frame = fetch_page!(pool,page_id)
            state = nothing
            lock(frame.latch)
            try
                state = _leaf_state(frame.page)
            finally
                unlock(frame.latch)
                unpin_page!(pool,frame)
            end
            entries = reverse ? Iterators.reverse(state.entries) : state.entries
            stop = false
            for (key,rid) in entries
                lower_comparison = lower_key === nothing ? 1 : btree_compare(key,lower_key)
                if lower_key !== nothing && (lower_comparison < 0 ||
                    (lower_comparison == 0 && !lower_inclusive))
                    reverse && (stop = true; break)
                    continue
                end
                upper_comparison = upper_key === nothing ? -1 : btree_compare(key,upper_key)
                if upper_key !== nothing && (upper_comparison > 0 ||
                    (upper_comparison == 0 && !upper_inclusive))
                    reverse || (stop = true; break)
                    continue
                end
                push!(result,(key,rid))
                length(result) == limit && break
            end
            stop && break
            page_id = reverse ? state.previous : state.next
        end
        result
    end
end

"""Create a cursor that emits bounded key/RID batches in B+Tree order."""
function btree_range_cursor(pool::BufferPool,tree::PersistentBTree;
                            lower=nothing,upper=nothing,reverse::Bool=false,
                            lower_inclusive::Bool=true,upper_inclusive::Bool=true)
    lock(tree.write_latch) do
        lower_key = lower === nothing ? nothing : btree_key(lower)
        upper_key = upper === nothing ? nothing : btree_key(upper)
        page_id = reverse ? (upper_key === nothing ? _btree_last_leaf(pool,tree) : _btree_find_leaf(pool,tree,upper_key)) :
                            (lower_key === nothing ? tree.first_leaf_page_id : _btree_find_leaf(pool,tree,lower_key))
        BTreeCursor(pool,tree,page_id,0,lower_key,upper_key,lower_inclusive,upper_inclusive,
            reverse,Set{UInt64}(),false)
    end
end

"""Read at most `batch_size` ordered entries without materializing the range."""
function next_btree_batch!(cursor::BTreeCursor;batch_size::Integer=256)
    batch_size >= 1 || storageerror("Ukuran batch B+Tree minimal satu.")
    cursor.finished && return nothing
    result = Tuple{Vector{UInt8},RID}[]
    lock(cursor.tree.write_latch) do
        while length(result) < batch_size && cursor.page_id != 0
            if cursor.entry_index == 0
                cursor.page_id in cursor.seen_pages && storageerror("Siklus sibling leaf B+Tree.")
                push!(cursor.seen_pages,cursor.page_id)
            end
            frame = fetch_page!(cursor.pool,cursor.page_id)
            state = nothing
            lock(frame.latch)
            try
                state = _leaf_state(frame.page)
            finally
                unlock(frame.latch)
                unpin_page!(cursor.pool,frame)
            end
            if cursor.entry_index == 0
                cursor.entry_index = cursor.reverse ? length(state.entries) : 1
            end
            while 1 <= cursor.entry_index <= length(state.entries) && length(result) < batch_size
                key,rid = state.entries[cursor.entry_index]
                cursor.entry_index += cursor.reverse ? -1 : 1
                lower_comparison = cursor.lower === nothing ? 1 : btree_compare(key,cursor.lower)
                if cursor.lower !== nothing && (lower_comparison < 0 ||
                    (lower_comparison == 0 && !cursor.lower_inclusive))
                    if cursor.reverse
                        cursor.finished = true
                        break
                    end
                    continue
                end
                upper_comparison = cursor.upper === nothing ? -1 : btree_compare(key,cursor.upper)
                if cursor.upper !== nothing && (upper_comparison > 0 ||
                    (upper_comparison == 0 && !cursor.upper_inclusive))
                    if !cursor.reverse
                        cursor.finished = true
                        break
                    end
                    continue
                end
                push!(result,(key,rid))
            end
            cursor.finished && break
            if cursor.entry_index < 1 || cursor.entry_index > length(state.entries)
                cursor.page_id = cursor.reverse ? state.previous : state.next
                cursor.entry_index = 0
            end
        end
        cursor.page_id == 0 && (cursor.finished = true)
    end
    isempty(result) && cursor.finished ? nothing : result
end

btree_ascending(pool::BufferPool,tree::PersistentBTree;kwargs...) = btree_range(pool,tree;reverse=false,kwargs...)
btree_descending(pool::BufferPool,tree::PersistentBTree;kwargs...) = btree_range(pool,tree;reverse=true,kwargs...)

function btree_stats(pool::BufferPool,tree::PersistentBTree)
    lock(tree.write_latch) do
        leaves = 0; entries = 0; page_id = tree.first_leaf_page_id; seen = Set{UInt64}()
        while page_id != 0
            page_id in seen && storageerror("Siklus sibling leaf B+Tree.")
            push!(seen,page_id)
            frame = fetch_page!(pool,page_id)
            state = nothing
            lock(frame.latch)
            try
                state = _leaf_state(frame.page)
            finally
                unlock(frame.latch)
                unpin_page!(pool,frame)
            end
            leaves += 1; entries += length(state.entries); page_id = state.next
        end
        (root_page_id=tree.root_page_id,first_leaf_page_id=tree.first_leaf_page_id,height=tree.height,
         leaf_pages=leaves,entries=entries)
    end
end
