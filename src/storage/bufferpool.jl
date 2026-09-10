# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

"""Bounded shared buffer pool with deterministic Clock replacement."""
mutable struct BufferFrame
    page_id::UInt64
    page::Page
    pin_count::Int
    dirty::Bool
    reference::Bool
    latch::ReentrantLock
end

mutable struct BufferPool
    manager::PageManager
    frames::Vector{Union{Nothing,BufferFrame}}
    lookup::Dict{UInt64,Int}
    clock_hand::Int
    mutex::ReentrantLock
    changed::Threads.Condition
    hits::UInt64
    misses::UInt64
    evictions::UInt64
    dirty_flushes::UInt64
    buffer_waits::UInt64
    prefetches::UInt64
end

function BufferPool(manager::PageManager; capacity::Integer=64)
    capacity >= 1 || storageerror("Kapasitas buffer pool minimal satu frame.")
    mutex = ReentrantLock()
    BufferPool(manager,fill(nothing,Int(capacity)),Dict{UInt64,Int}(),1,mutex,Threads.Condition(mutex),
        0,0,0,0,0,0)
end

function _buffer_frame_slot_locked(pool::BufferPool)::Int
    capacity = length(pool.frames)
    for _ in 1:(2 * capacity)
        index = pool.clock_hand
        pool.clock_hand = index == capacity ? 1 : index + 1
        frame = pool.frames[index]
        frame === nothing && return index
        frame.pin_count > 0 && continue
        if frame.reference
            frame.reference = false
            continue
        end
        return index
    end
    0
end

function _flush_frame_locked!(pool::BufferPool,frame::BufferFrame; sync::Bool=false)
    frame.dirty || return nothing
    lock(frame.latch)
    try
        # PageManager checks page_lsn against its durable WAL watermark.
        write_page!(pool.manager,frame.page;sync)
        frame.dirty = false
        pool.dirty_flushes += UInt64(1)
    finally
        unlock(frame.latch)
    end
    nothing
end

function _install_page_locked!(pool::BufferPool,page::Page)::Union{Nothing,BufferFrame}
    index = _buffer_frame_slot_locked(pool)
    index == 0 && return nothing
    old = pool.frames[index]
    if old !== nothing
        old.pin_count == 0 || storageerror("Clock memilih page yang masih dipin.")
        _flush_frame_locked!(pool,old)
        delete!(pool.lookup,old.page_id)
        pool.evictions += UInt64(1)
    end
    frame = BufferFrame(page.id,page,1,false,true,ReentrantLock())
    pool.frames[index] = frame
    pool.lookup[page.id] = index
    frame
end

"""Try to pin a page without waiting. `nothing` means every frame is pinned."""
function try_fetch_page!(pool::BufferPool,page_id::Integer)::Union{Nothing,BufferFrame}
    1 <= page_id <= typemax(UInt64) || storageerror("ID page tidak valid.")
    target = UInt64(page_id)
    initial = lock(pool.mutex) do
        index = get(pool.lookup,target,0)
        if index != 0
            frame = pool.frames[index]::BufferFrame
            frame.pin_count += 1
            frame.reference = true
            pool.hits += UInt64(1)
            return frame
        end
        pool.misses += UInt64(1)
        # Check availability before I/O so a miss does not read a page only to
        # throw it away when all frames are pinned.
        _buffer_frame_slot_locked(pool) == 0 && (pool.buffer_waits += UInt64(1); return :full)
        nothing
    end
    initial isa BufferFrame && return initial
    initial === :full && return nothing
    # Disk acquisition happens outside the pool mutex. A miss therefore does
    # not prevent independent buffer hits from advancing another ARSP lane.
    page = read_page(pool.manager,target)
    lock(pool.mutex) do
        # Another lane may have installed the same page while this lane read it.
        index = get(pool.lookup,target,0)
        if index != 0
            frame = pool.frames[index]::BufferFrame
            frame.pin_count += 1
            frame.reference = true
            pool.hits += UInt64(1)
            return frame
        end
        frame = _install_page_locked!(pool,page)
        frame === nothing && (pool.buffer_waits += UInt64(1); return nothing)
        frame
    end
end

"""Pin a resident frame only; this never performs disk I/O or waits."""
function try_fetch_cached_page!(pool::BufferPool,page_id::Integer)::Union{Nothing,BufferFrame}
    1 <= page_id <= typemax(UInt64) || storageerror("ID page tidak valid.")
    target = UInt64(page_id)
    lock(pool.mutex) do
        index = get(pool.lookup,target,0)
        index == 0 && return nothing
        frame = pool.frames[index]::BufferFrame
        frame.pin_count += 1
        frame.reference = true
        pool.hits += UInt64(1)
        frame
    end
end

function _buffer_may_progress_locked(pool::BufferPool,target::UInt64)::Bool
    haskey(pool.lookup,target) && return true
    for frame in pool.frames
        (frame === nothing || frame.pin_count == 0) && return true
    end
    false
end

"""Wait for a bounded frame and then fetch a page, suitable for an I/O worker."""
function fetch_page_wait!(pool::BufferPool,page_id::Integer)::BufferFrame
    1 <= page_id <= typemax(UInt64) || storageerror("ID page tidak valid.")
    target = UInt64(page_id)
    while true
        frame = try_fetch_page!(pool,target)
        frame === nothing || return frame
        lock(pool.mutex)
        try
            # Avoid a lost notification: if an unpinned frame appeared between
            # the failed attempt and this lock acquisition, retry immediately.
            _buffer_may_progress_locked(pool,target) || wait(pool.changed)
        finally
            unlock(pool.mutex)
        end
    end
end

function fetch_page!(pool::BufferPool,page_id::Integer)::BufferFrame
    frame = try_fetch_page!(pool,page_id)
    frame === nothing && storageerror("Buffer pool penuh; semua page sedang dipin.")
    frame
end

"""Warm one page without retaining a pin; used by sequential heap scans."""
function prefetch_page!(pool::BufferPool,page_id::Integer)::Bool
    frame = try_fetch_page!(pool,page_id)
    frame === nothing && return false
    unpin_page!(pool,frame)
    lock(pool.mutex) do
        pool.prefetches += UInt64(1)
    end
    true
end

function new_page!(pool::BufferPool,page_type::PageType; page_lsn::Integer=0,
                   flags::Integer=0, slot_base::Integer=PAGE_HEADER_SIZE + 1)::BufferFrame
    lock(pool.mutex) do
        _buffer_frame_slot_locked(pool) == 0 && begin
            pool.buffer_waits += UInt64(1)
            storageerror("Buffer pool penuh; semua page sedang dipin.")
        end
        page = allocate_page!(pool.manager,page_type;page_lsn,flags,slot_base)
        frame = _install_page_locked!(pool,page)
        frame === nothing && begin
            free_page!(pool.manager,page.id)
            pool.buffer_waits += UInt64(1)
            storageerror("Buffer pool penuh saat memasang page baru.")
        end
        frame
    end
end

function mark_dirty!(pool::BufferPool,frame::BufferFrame; page_lsn::Union{Nothing,Integer}=nothing)
    lock(frame.latch)
    try
        frame.pin_count > 0 || storageerror("Page harus dipin sebelum ditandai dirty.")
        page_lsn === nothing || set_page_lsn!(frame.page,page_lsn)
        frame.dirty = true
        frame.reference = true
    finally
        unlock(frame.latch)
    end
    frame
end

function unpin_page!(pool::BufferPool,frame::BufferFrame; dirty::Bool=false,
                     page_lsn::Union{Nothing,Integer}=nothing)
    lock(pool.mutex) do
        index = get(pool.lookup,frame.page_id,0)
        index != 0 && pool.frames[index] === frame || storageerror("Frame bukan anggota buffer pool.")
        frame.pin_count > 0 || storageerror("Page di-unpin lebih dari jumlah pin.")
        if dirty
            lock(frame.latch)
            try
                page_lsn === nothing || set_page_lsn!(frame.page,page_lsn)
                frame.dirty = true
                frame.reference = true
            finally
                unlock(frame.latch)
            end
        end
        frame.pin_count -= 1
        frame.pin_count == 0 && notify(pool.changed;all=true)
    end
    nothing
end

function with_pinned_page(f::Function,pool::BufferPool,page_id::Integer)
    frame = fetch_page!(pool,page_id)
    lock(frame.latch)
    try
        f(frame.page)
    finally
        unlock(frame.latch)
        unpin_page!(pool,frame)
    end
end

function flush_frame!(pool::BufferPool,frame::BufferFrame; sync::Bool=false)
    lock(pool.mutex) do
        index = get(pool.lookup,frame.page_id,0)
        index != 0 && pool.frames[index] === frame || storageerror("Frame bukan anggota buffer pool.")
        _flush_frame_locked!(pool,frame;sync)
    end
    nothing
end

function flush_all!(pool::BufferPool; sync::Bool=true)
    frames = lock(pool.mutex) do
        BufferFrame[frame for frame in pool.frames if frame !== nothing]
    end
    for frame in frames
        flush_frame!(pool,frame;sync=false)
    end
    sync && flush_all_pages!(pool.manager)
    nothing
end

function buffer_pool_stats(pool::BufferPool)
    lock(pool.mutex) do
        used = count(!isnothing,pool.frames)
        pinned = sum(frame === nothing ? 0 : frame.pin_count for frame in pool.frames;init=0)
        total = pool.hits + pool.misses
        (capacity=length(pool.frames),used_frames=used,pinned_pages=pinned,hits=pool.hits,
         misses=pool.misses,evictions=pool.evictions,dirty_flushes=pool.dirty_flushes,
         buffer_waits=pool.buffer_waits,prefetches=pool.prefetches,
         hit_ratio=total == 0 ? 0.0 : pool.hits / total)
    end
end

function Base.close(pool::BufferPool)
    flush_all!(pool;sync=true)
    close(pool.manager)
    nothing
end
