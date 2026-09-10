# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

"""ARSP-4 fixed-size page manager.

The WAL remains the commit authority.  This manager owns the separately
versioned page file and never opens/closes that file for an individual page I/O.
"""
const PAGE_SIZE = 8 * 1024
const PAGE_FORMAT_VERSION = UInt16(1)
const PAGE_HEADER_SIZE = 80
const PAGE_CHECKSUM_OFFSET = 37
const PAGE_CHECKSUM_LENGTH = 32
const PAGE_MAGIC = UInt8[0x41,0x49,0x52,0x45,0x53,0x50,0x47,0x34] # AIRESPG4
const ARSP_SUPER_MAGIC = UInt8[0x41,0x49,0x52,0x45,0x53,0x41,0x52,0x34] # AIRESAR4
const ARSP_SUPER_VERSION = UInt16(1)
const ARSP_SUPER_CHECKSUM_OFFSET = 35
const ARSP_SUPER_CHECKSUM_LENGTH = 32
const PAGE_FREE_NONE = UInt64(0)

@enum PageType::UInt8 begin
    PageTypeFree = 0
    PageTypeHeap = 1
    PageTypeHeapMeta = 2
    PageTypeCatalog = 3
    PageTypeBTreeMeta = 4
    PageTypeBTreeLeaf = 5
    PageTypeBTreeInternal = 6
end

struct PageHeader
    page_type::PageType
    page_id::UInt64
    page_lsn::UInt64
    flags::UInt8
    slot_count::UInt16
    free_start::UInt16
    free_end::UInt16
end

mutable struct Page
    id::UInt64
    bytes::Vector{UInt8}
end

"""Page-file owner. `durable_lsn` enforces WAL-before-data on page flushes."""
mutable struct PageManager
    path::String
    io::IOStream
    page_size::Int
    next_page_id::UInt64
    free_head::UInt64
    durable_lsn::UInt64
    mutex::ReentrantLock
    closed::Bool
    reads::UInt64
    writes::UInt64
    allocations::UInt64
    frees::UInt64
end

@inline function _page_bounds(bytes::Vector{UInt8}, offset::Int, width::Int)
    1 <= offset && offset + width - 1 <= length(bytes) || storageerror("Offset page di luar batas.")
    nothing
end

@inline function page_get_u16(bytes::Vector{UInt8}, offset::Int)::UInt16
    _page_bounds(bytes,offset,2)
    @inbounds return UInt16(bytes[offset]) | (UInt16(bytes[offset+1]) << 8)
end
@inline function page_get_u32(bytes::Vector{UInt8}, offset::Int)::UInt32
    _page_bounds(bytes,offset,4)
    value = UInt32(0)
    @inbounds for i in 0:3
        value |= UInt32(bytes[offset+i]) << (8 * i)
    end
    value
end
@inline function page_get_u64(bytes::Vector{UInt8}, offset::Int)::UInt64
    _page_bounds(bytes,offset,8)
    value = UInt64(0)
    @inbounds for i in 0:7
        value |= UInt64(bytes[offset+i]) << (8 * i)
    end
    value
end
@inline function page_put_u16!(bytes::Vector{UInt8}, offset::Int, value::Integer)
    _page_bounds(bytes,offset,2)
    x = UInt16(value)
    @inbounds for i in 0:1
        bytes[offset+i] = UInt8((x >> (8 * i)) & 0xff)
    end
    bytes
end
@inline function page_put_u32!(bytes::Vector{UInt8}, offset::Int, value::Integer)
    _page_bounds(bytes,offset,4)
    x = UInt32(value)
    @inbounds for i in 0:3
        bytes[offset+i] = UInt8((x >> (8 * i)) & 0xff)
    end
    bytes
end
@inline function page_put_u64!(bytes::Vector{UInt8}, offset::Int, value::Integer)
    _page_bounds(bytes,offset,8)
    x = UInt64(value)
    @inbounds for i in 0:7
        bytes[offset+i] = UInt8((x >> (8 * i)) & 0xff)
    end
    bytes
end

function _page_checksum(bytes::Vector{UInt8}, offset::Int, width::Int)
    _page_bounds(bytes,offset,width)
    # The checksum field is the only part excluded from the digest.  Copying
    # the complete 8 KiB page for every slot mutation dominated allocator
    # traffic during inserts; preserve only the small field, hash in place,
    # and restore it even if the digest call throws.
    saved = copy(@view bytes[offset:offset+width-1])
    try
        fill!(@view(bytes[offset:offset+width-1]),0x00)
        sha256(bytes)
    finally
        copyto!(bytes,offset,saved,1,width)
    end
end
function _page_store_checksum!(bytes::Vector{UInt8}, offset::Int, width::Int)
    digest = _page_checksum(bytes,offset,width)
    width == length(digest) || storageerror("Panjang checksum page tidak valid.")
    copyto!(bytes,offset,digest,1,width)
    bytes
end
function _page_checksum_valid(bytes::Vector{UInt8}, offset::Int, width::Int)
    _page_bounds(bytes,offset,width)
    @views bytes[offset:offset+width-1] == _page_checksum(bytes,offset,width)
end

function _known_page_type(code::UInt8)::PageType
    code <= UInt8(PageTypeBTreeInternal) || storageerror("Tipe page tidak dikenal.")
    PageType(code)
end

function page_header(page::Page; verify_checksum::Bool=false)::PageHeader
    bytes = page.bytes
    length(bytes) >= PAGE_HEADER_SIZE || storageerror("Page terlalu kecil untuk header.")
    bytes[1:8] == PAGE_MAGIC || storageerror("Magic page tidak valid.")
    page_get_u16(bytes,9) == PAGE_FORMAT_VERSION || storageerror("Versi format page tidak didukung.")
    verify_checksum && !_page_checksum_valid(bytes,PAGE_CHECKSUM_OFFSET,PAGE_CHECKSUM_LENGTH) &&
        storageerror("Checksum page gagal.")
    header = PageHeader(_known_page_type(bytes[11]),page_get_u64(bytes,13),page_get_u64(bytes,21),
        bytes[12],page_get_u16(bytes,29),page_get_u16(bytes,31),page_get_u16(bytes,33))
    header.page_id == page.id || storageerror("ID page pada header tidak konsisten.")
    PAGE_HEADER_SIZE + 1 <= header.free_start <= header.free_end <= length(bytes) + 1 ||
        storageerror("Ruang bebas page tidak valid.")
    header
end

function initialize_page!(page::Page, page_type::PageType;
                          page_lsn::UInt64=UInt64(0), flags::UInt8=UInt8(0),
                          slot_base::Int=PAGE_HEADER_SIZE + 1)
    length(page.bytes) >= PAGE_HEADER_SIZE || storageerror("Ukuran page terlalu kecil.")
    PAGE_HEADER_SIZE + 1 <= slot_base <= length(page.bytes) + 1 || storageerror("Awal slot page tidak valid.")
    fill!(page.bytes,0x00)
    copyto!(page.bytes,1,PAGE_MAGIC,1,length(PAGE_MAGIC))
    page_put_u16!(page.bytes,9,PAGE_FORMAT_VERSION)
    page.bytes[11] = UInt8(page_type)
    page.bytes[12] = flags
    page_put_u64!(page.bytes,13,page.id)
    page_put_u64!(page.bytes,21,page_lsn)
    page_put_u16!(page.bytes,29,0)
    page_put_u16!(page.bytes,31,slot_base)
    page_put_u16!(page.bytes,33,length(page.bytes) + 1)
    _page_store_checksum!(page.bytes,PAGE_CHECKSUM_OFFSET,PAGE_CHECKSUM_LENGTH)
    page
end

function Page(id::Integer, page_type::PageType; page_size::Integer=PAGE_SIZE,
              page_lsn::Integer=0, flags::Integer=0, slot_base::Integer=PAGE_HEADER_SIZE + 1)
    1 <= id <= typemax(UInt64) || storageerror("ID page tidak valid.")
    PAGE_HEADER_SIZE <= page_size < typemax(UInt16) || storageerror("Ukuran page tidak valid.")
    page = Page(UInt64(id),zeros(UInt8,Int(page_size)))
    initialize_page!(page,page_type;page_lsn=UInt64(page_lsn),flags=UInt8(flags),slot_base=Int(slot_base))
end

function set_page_lsn!(page::Page, lsn::Integer)
    page_get_u64(page.bytes,13) == page.id || storageerror("ID page tidak konsisten.")
    page_put_u64!(page.bytes,21,lsn)
    page
end
function set_page_flags!(page::Page, flags::Integer)
    page.bytes[12] = UInt8(flags)
    page
end
function finalize_page!(page::Page)
    page_header(page)
    _page_store_checksum!(page.bytes,PAGE_CHECKSUM_OFFSET,PAGE_CHECKSUM_LENGTH)
    page
end
function verify_page!(page::Page)
    page_header(page;verify_checksum=true)
    page
end

function _page_super_bytes(page_size::Int,next_page_id::UInt64,free_head::UInt64)
    PAGE_HEADER_SIZE <= page_size < typemax(UInt16) || storageerror("Ukuran page manager tidak valid.")
    bytes = zeros(UInt8,page_size)
    copyto!(bytes,1,ARSP_SUPER_MAGIC,1,length(ARSP_SUPER_MAGIC))
    page_put_u16!(bytes,9,ARSP_SUPER_VERSION)
    page_put_u32!(bytes,11,page_size)
    page_put_u64!(bytes,15,next_page_id)
    page_put_u64!(bytes,23,free_head)
    page_put_u32!(bytes,31,0)
    _page_store_checksum!(bytes,ARSP_SUPER_CHECKSUM_OFFSET,ARSP_SUPER_CHECKSUM_LENGTH)
    bytes
end

function _decode_page_super(bytes::Vector{UInt8})
    length(bytes) >= ARSP_SUPER_CHECKSUM_OFFSET + ARSP_SUPER_CHECKSUM_LENGTH - 1 ||
        storageerror("Header ARSP-4 terpotong.")
    bytes[1:8] == ARSP_SUPER_MAGIC || storageerror("Magic storage ARSP-4 tidak valid.")
    page_get_u16(bytes,9) == ARSP_SUPER_VERSION || storageerror("Versi storage ARSP-4 tidak didukung.")
    page_size = Int(page_get_u32(bytes,11))
    PAGE_HEADER_SIZE <= page_size < typemax(UInt16) || storageerror("Ukuran page pada header tidak valid.")
    length(bytes) == page_size || storageerror("Panjang header page manager tidak valid.")
    _page_checksum_valid(bytes,ARSP_SUPER_CHECKSUM_OFFSET,ARSP_SUPER_CHECKSUM_LENGTH) ||
        storageerror("Checksum header storage ARSP-4 gagal.")
    next_page_id = page_get_u64(bytes,15)
    next_page_id >= 1 || storageerror("ID page berikutnya tidak valid.")
    page_size,next_page_id,page_get_u64(bytes,23)
end

function _pm_assert_open(pm::PageManager)
    !pm.closed || storageerror("Page manager sudah ditutup.")
    nothing
end
function _pm_offset(pm::PageManager,page_id::UInt64)
    page_id <= UInt64(div(typemax(Int64),pm.page_size)) || storageerror("Offset page melampaui batas file.")
    Int64(page_id) * Int64(pm.page_size)
end
function _write_super_locked!(pm::PageManager; sync::Bool=false)
    _pm_assert_open(pm)
    seekstart(pm.io)
    write(pm.io,_page_super_bytes(pm.page_size,pm.next_page_id,pm.free_head))
    sync ? _page_sync(pm.io) : Base.flush(pm.io)
    nothing
end

"""Open a persistent ARSP-4 page file.  It is kept open for the manager lifetime."""
function open_page_manager(path::AbstractString; create::Bool=false, page_size::Integer=PAGE_SIZE,
                           durable_lsn::Integer=0)
    target = abspath(String(path))
    requested_size = Int(page_size)
    PAGE_HEADER_SIZE <= requested_size < typemax(UInt16) || storageerror("Ukuran page manager tidak valid.")
    mkpath(dirname(target))
    if create
        ispath(target) && storageerror("File page ARSP-4 sudah ada: $(basename(target)).")
        io = open(target,"w+")
        pm = PageManager(target,io,requested_size,UInt64(1),PAGE_FREE_NONE,UInt64(durable_lsn),
            ReentrantLock(),false,0,0,0,0)
        try
            _write_super_locked!(pm;sync=true)
            return pm
        catch
            close(io)
            rethrow()
        end
    end
    isfile(target) || storageerror("File page ARSP-4 tidak ditemukan: $(basename(target)).")
    io = open(target,"r+")
    try
        filesize(target) >= ARSP_SUPER_CHECKSUM_OFFSET + ARSP_SUPER_CHECKSUM_LENGTH - 1 ||
            storageerror("File page ARSP-4 terpotong.")
        prefix = zeros(UInt8,ARSP_SUPER_CHECKSUM_OFFSET + ARSP_SUPER_CHECKSUM_LENGTH - 1)
        seekstart(io); read!(io,prefix)
        prefix[1:8] == ARSP_SUPER_MAGIC || storageerror("Magic storage ARSP-4 tidak valid.")
        detected_size = Int(page_get_u32(prefix,11))
        PAGE_HEADER_SIZE <= detected_size < typemax(UInt16) || storageerror("Ukuran page pada header tidak valid.")
        filesize(target) >= detected_size || storageerror("Header page ARSP-4 terpotong.")
        bytes = zeros(UInt8,detected_size)
        seekstart(io); read!(io,bytes)
        actual_size,next_page_id,free_head = _decode_page_super(bytes)
        requested_size == PAGE_SIZE || requested_size == actual_size ||
            storageerror("Ukuran page yang diminta tidak cocok dengan file ARSP-4.")
        remainder = filesize(target) - actual_size
        remainder % actual_size == 0 || storageerror("Panjang file page bukan kelipatan page size.")
        highest = UInt64(div(remainder,actual_size))
        next_page_id <= highest + UInt64(1) || storageerror("Header page menunjuk ID yang belum dialokasikan.")
        PageManager(target,io,actual_size,next_page_id,free_head,UInt64(durable_lsn),
            ReentrantLock(),false,0,0,0,0)
    catch
        close(io)
        rethrow()
    end
end

"""Set the highest WAL LSN known durable before a dirty page may be flushed."""
function set_wal_durable_lsn!(pm::PageManager,lsn::Integer)
    lock(pm.mutex) do
        _pm_assert_open(pm)
        pm.durable_lsn = UInt64(lsn)
    end
    pm
end

function _page_sync(io::IO)
    # `_wal_sync` supplies the platform fsync/FlushFileBuffers implementation.
    # It is defined later in module load, but exists before any public call.
    isdefined(@__MODULE__, :_wal_sync) ? _wal_sync(io) : Base.flush(io)
end

function _read_page_locked(pm::PageManager,page_id::UInt64)::Page
    _pm_assert_open(pm)
    1 <= page_id < pm.next_page_id || storageerror("ID page tidak dialokasikan.")
    bytes = zeros(UInt8,pm.page_size)
    seek(pm.io,_pm_offset(pm,page_id))
    read!(pm.io,bytes)
    page = Page(page_id,bytes)
    verify_page!(page)
    pm.reads += UInt64(1)
    page
end
function read_page(pm::PageManager,page_id::Integer)
    1 <= page_id <= typemax(UInt64) || storageerror("ID page tidak valid.")
    lock(pm.mutex) do
        _read_page_locked(pm,UInt64(page_id))
    end
end

function _write_page_locked!(pm::PageManager,page::Page; sync::Bool=false, force::Bool=false)
    _pm_assert_open(pm)
    length(page.bytes) == pm.page_size || storageerror("Ukuran page tidak cocok dengan manager.")
    1 <= page.id < pm.next_page_id || storageerror("ID page belum dialokasikan.")
    header = page_header(page)
    (!force && header.page_lsn > pm.durable_lsn) &&
        storageerror("WAL untuk page $(page.id) belum durable.")
    finalize_page!(page)
    seek(pm.io,_pm_offset(pm,page.id))
    write(pm.io,page.bytes)
    sync ? _page_sync(pm.io) : Base.flush(pm.io)
    pm.writes += UInt64(1)
    page
end
function write_page!(pm::PageManager,page::Page; sync::Bool=false, force::Bool=false)
    lock(pm.mutex) do
        _write_page_locked!(pm,page;sync,force)
    end
end
flush_page!(pm::PageManager,page::Page) = write_page!(pm,page;sync=true)

function allocate_page!(pm::PageManager,page_type::PageType; page_lsn::Integer=0,
                        flags::Integer=0, slot_base::Integer=PAGE_HEADER_SIZE + 1)
    lock(pm.mutex) do
        _pm_assert_open(pm)
        UInt64(page_lsn) <= pm.durable_lsn || storageerror("WAL untuk alokasi page belum durable.")
        page_id = if pm.free_head == PAGE_FREE_NONE
            id = pm.next_page_id
            id < typemax(UInt64) || storageerror("ID page habis.")
            pm.next_page_id += UInt64(1)
            id
        else
            id = pm.free_head
            freed = _read_page_locked(pm,id)
            page_header(freed).page_type == PageTypeFree || storageerror("Free list page tidak valid.")
            pm.free_head = page_get_u64(freed.bytes,PAGE_HEADER_SIZE+1)
            id
        end
        page = Page(page_id,page_type;page_size=pm.page_size,page_lsn,flags,slot_base)
        _write_page_locked!(pm,page;force=true)
        _write_super_locked!(pm)
        pm.allocations += UInt64(1)
        page
    end
end

function free_page!(pm::PageManager,page_id::Integer)
    1 <= page_id <= typemax(UInt64) || storageerror("ID page tidak valid.")
    lock(pm.mutex) do
        id = UInt64(page_id)
        page = _read_page_locked(pm,id)
        page_header(page).page_type != PageTypeFree || storageerror("Page sudah berada pada free list.")
        initialize_page!(page,PageTypeFree;slot_base=PAGE_HEADER_SIZE + 1)
        page_put_u64!(page.bytes,PAGE_HEADER_SIZE+1,pm.free_head)
        _write_page_locked!(pm,page;force=true)
        pm.free_head = id
        _write_super_locked!(pm)
        pm.frees += UInt64(1)
        nothing
    end
end

function flush_all_pages!(pm::PageManager)
    lock(pm.mutex) do
        _pm_assert_open(pm)
        _page_sync(pm.io)
    end
    nothing
end

function page_manager_stats(pm::PageManager)
    lock(pm.mutex) do
        (page_size=pm.page_size,next_page_id=pm.next_page_id,free_head=pm.free_head,
         reads=pm.reads,writes=pm.writes,allocations=pm.allocations,frees=pm.frees,
         durable_lsn=pm.durable_lsn,open=!pm.closed)
    end
end

function Base.close(pm::PageManager)
    lock(pm.mutex) do
        pm.closed && return nothing
        _page_sync(pm.io)
        close(pm.io)
        pm.closed = true
    end
    nothing
end
