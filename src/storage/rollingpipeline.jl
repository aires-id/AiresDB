# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

"""ARSP-4: deterministic four-phase, four-lane rolling storage scheduler.

The scheduler is deliberately a pipeline coordinator, not a `@threads` loop.
Each tick advances each ready lane at most one phase, then admits queued work
into empty lanes.  I/O and latch waits park only their own lane until an owner
explicitly resumes it, so callers never busy-spin waiting for storage.
"""

@enum StorageOperation::UInt8 begin
    StoragePointLookup = 1
    StorageSequentialScan = 2
    StorageWrite = 3
    StorageIndex = 4
end

@enum StorageLaneState::UInt8 begin
    LaneEmpty = 0
    LanePhase1 = 1
    LanePhase2 = 2
    LanePhase3 = 3
    LanePhase4 = 4
    LaneBlockedIO = 5
    LaneBlockedLatch = 6
    LaneDone = 7
    LaneError = 8
end

@enum StoragePhaseDisposition::UInt8 begin
    PhaseAdvance = 1
    PhaseBlockedIO = 2
    PhaseBlockedLatch = 3
    PhaseComplete = 4
end

"""A phase hook returns one of these dispositions and may attach a batch/result."""
struct StoragePhaseResult
    disposition::StoragePhaseDisposition
    value::Any
end
StoragePhaseResult(disposition::StoragePhaseDisposition) = StoragePhaseResult(disposition,nothing)
phase_advance(value=nothing) = StoragePhaseResult(PhaseAdvance,value)
phase_blocked_io(value=nothing) = StoragePhaseResult(PhaseBlockedIO,value)
phase_blocked_latch(value=nothing) = StoragePhaseResult(PhaseBlockedLatch,value)
phase_complete(value=nothing) = StoragePhaseResult(PhaseComplete,value)

"""Phase functions receive `(work, lane, scheduler)` and must not block."""
struct StoragePhaseHandlers
    intake::Function
    acquire::Function
    process::Function
    publish::Function
end
const DEFAULT_STORAGE_PHASE_HANDLERS = StoragePhaseHandlers(
    (work,lane,scheduler)->phase_advance(),
    (work,lane,scheduler)->phase_advance(),
    (work,lane,scheduler)->phase_advance(),
    (work,lane,scheduler)->phase_complete(),
)

"""A planned unit of physical storage work; request IDs are assigned on submit."""
mutable struct StorageWorkUnit
    request_id::UInt64
    operation::StorageOperation
    database::String
    table::String
    rid::Union{Nothing,RID}
    key::Union{Nothing,Vector{UInt8}}
    target_page_hint::Union{Nothing,UInt64}
    snapshot_csn::UInt64
    transaction_id::Union{Nothing,UUID}
    handlers::StoragePhaseHandlers
    context::Any
    result::Any
    error::Any
    # Phase handlers may attach a short-lived asynchronous acquisition token.
    # It is owned under the scheduler mutex and never serialized.
    async_state::Any
end

function StorageWorkUnit(operation::StorageOperation,database::AbstractString,table::AbstractString;
                         rid::Union{Nothing,RID}=nothing,
                         key::Union{Nothing,AbstractVector{UInt8}}=nothing,
                         target_page_hint::Union{Nothing,Integer}=nothing,
                         snapshot_csn::Integer=0,
                         transaction_id::Union{Nothing,UUID}=nothing,
                         handlers::StoragePhaseHandlers=DEFAULT_STORAGE_PHASE_HANDLERS,
                         context=nothing)
    snapshot_csn >= 0 || storageerror("Snapshot ARSP-4 tidak valid.")
    target_page_hint === nothing || target_page_hint >= 1 || storageerror("Hint page ARSP-4 tidak valid.")
    StorageWorkUnit(0,operation,String(database),String(table),rid,
        key === nothing ? nothing : Vector{UInt8}(key),
        target_page_hint === nothing ? nothing : UInt64(target_page_hint),UInt64(snapshot_csn),
        transaction_id,handlers,context,nothing,nothing,nothing)
end

mutable struct StorageLane
    id::UInt8
    state::StorageLaneState
    blocked_phase::StorageLaneState
    work::Union{Nothing,StorageWorkUnit}
    entered_tick::UInt64
    transitions::UInt64
end

mutable struct RollingScheduler
    lanes::Vector{StorageLane}
    queue::Vector{Union{Nothing,StorageWorkUnit}}
    queue_head::Int
    queue_tail::Int
    queue_count::Int
    request_sequence::UInt64
    tick_count::UInt64
    active_lane_ticks::UInt64
    completed::Dict{UInt64,StorageWorkUnit}
    completion_order::Vector{UInt64}
    completion_limit::Int
    completed_count::UInt64
    failed_count::UInt64
    buffer_waits::UInt64
    io_waits::UInt64
    latch_waits::UInt64
    mutex::ReentrantLock
    # Sticky event preserves a completion that races the caller's wait.
    # Unlike a lock condition it is never held recursively by a phase hook.
    async_event::Base.Event
    async_requests::Set{UInt64}
end

"""Create a strict four-lane scheduler with an independently bounded ingress queue."""
function RollingScheduler(;queue_capacity::Integer=64,completion_capacity::Integer=256)
    queue_capacity >= 1 || storageerror("Kapasitas antrean ARSP-4 minimal satu.")
    completion_capacity >= 1 || storageerror("Kapasitas hasil ARSP-4 minimal satu.")
    lanes = StorageLane[StorageLane(UInt8(index-1),LaneEmpty,LaneEmpty,nothing,0,0) for index in 1:4]
    mutex = ReentrantLock()
    RollingScheduler(lanes,fill(nothing,Int(queue_capacity)),1,1,0,0,0,0,
        Dict{UInt64,StorageWorkUnit}(),UInt64[],Int(completion_capacity),0,0,0,0,0,mutex,
        Base.Event(),Set{UInt64}())
end

@inline _lane_phase(state::StorageLaneState) = state in (LanePhase1,LanePhase2,LanePhase3,LanePhase4)
@inline function _next_phase(state::StorageLaneState)
    state == LanePhase1 && return LanePhase2
    state == LanePhase2 && return LanePhase3
    state == LanePhase3 && return LanePhase4
    state == LanePhase4 && return LaneDone
    storageerror("State phase ARSP-4 tidak dapat dimajukan.")
end
@inline function _phase_handler(work::StorageWorkUnit,state::StorageLaneState)
    state == LanePhase1 && return work.handlers.intake
    state == LanePhase2 && return work.handlers.acquire
    state == LanePhase3 && return work.handlers.process
    state == LanePhase4 && return work.handlers.publish
    storageerror("State phase ARSP-4 tidak valid.")
end

function _queue_push_locked!(scheduler::RollingScheduler,work::StorageWorkUnit)
    scheduler.queue_count < length(scheduler.queue) || storageerror("Backpressure ARSP-4: antrean work penuh.")
    scheduler.queue[scheduler.queue_tail] = work
    scheduler.queue_tail = scheduler.queue_tail == length(scheduler.queue) ? 1 : scheduler.queue_tail + 1
    scheduler.queue_count += 1
    nothing
end
function _queue_pop_locked!(scheduler::RollingScheduler)::StorageWorkUnit
    scheduler.queue_count > 0 || storageerror("Antrean ARSP-4 kosong.")
    work = scheduler.queue[scheduler.queue_head]::StorageWorkUnit
    scheduler.queue[scheduler.queue_head] = nothing
    scheduler.queue_head = scheduler.queue_head == length(scheduler.queue) ? 1 : scheduler.queue_head + 1
    scheduler.queue_count -= 1
    work
end

"""Queue a generic work unit. It starts in P1 on the next scheduler tick."""
function submit!(scheduler::RollingScheduler,work::StorageWorkUnit)::UInt64
    lock(scheduler.mutex) do
        work.request_id == 0 || storageerror("Work ARSP-4 sudah pernah dikirim.")
        scheduler.request_sequence < typemax(UInt64) || storageerror("Request ID ARSP-4 habis.")
        scheduler.request_sequence += UInt64(1)
        work.request_id = scheduler.request_sequence
        _queue_push_locked!(scheduler,work)
        work.request_id
    end
end

"""Mark a blocked lane as owned by an asynchronous phase handler.

The helper is intentionally internal: a handler calls it before returning
`phase_blocked_io()`, and the owner must later call `resume_async_lane!` or
`fail_async_lane!`.  This lets `run_until_complete!` wait on an event rather
than spin or mistake a live disk read for a permanently parked lane.
"""
function register_async_wait!(scheduler::RollingScheduler,lane::StorageLane)
    lock(scheduler.mutex) do
        work = lane.work::StorageWorkUnit
        push!(scheduler.async_requests,work.request_id)
    end
    nothing
end

function resume_async_lane!(scheduler::RollingScheduler,lane_id::Integer,request_id::Integer)::Bool
    0 <= lane_id <= 3 || return false
    request_id >= 1 || return false
    lock(scheduler.mutex) do
        lane = scheduler.lanes[Int(lane_id)+1]
        work = lane.work
        (work === nothing || work.request_id != UInt64(request_id) || lane.state != LaneBlockedIO) && return false
        lane.state = lane.blocked_phase
        lane.blocked_phase = LaneEmpty
        lane.entered_tick = scheduler.tick_count
        lane.transitions += UInt64(1)
        delete!(scheduler.async_requests,work.request_id)
        notify(scheduler.async_event)
        true
    end
end

function fail_async_lane!(scheduler::RollingScheduler,lane_id::Integer,request_id::Integer,error)::Bool
    0 <= lane_id <= 3 || return false
    request_id >= 1 || return false
    lock(scheduler.mutex) do
        lane = scheduler.lanes[Int(lane_id)+1]
        work = lane.work
        (work === nothing || work.request_id != UInt64(request_id)) && return false
        work.error = error
        lane.state = LaneError
        lane.blocked_phase = LaneEmpty
        lane.transitions += UInt64(1)
        delete!(scheduler.async_requests,work.request_id)
        notify(scheduler.async_event)
        true
    end
end

function _remember_completion_locked!(scheduler::RollingScheduler,work::StorageWorkUnit)
    scheduler.completed[work.request_id] = work
    push!(scheduler.completion_order,work.request_id)
    while length(scheduler.completion_order) > scheduler.completion_limit
        evicted = popfirst!(scheduler.completion_order)
        delete!(scheduler.completed,evicted)
    end
    nothing
end
function _retire_lane_locked!(scheduler::RollingScheduler,lane::StorageLane)
    work = lane.work::StorageWorkUnit
    lane.state == LaneDone ? (scheduler.completed_count += UInt64(1)) : (scheduler.failed_count += UInt64(1))
    _remember_completion_locked!(scheduler,work)
    delete!(scheduler.async_requests,work.request_id)
    lane.work = nothing
    lane.blocked_phase = LaneEmpty
    lane.state = LaneEmpty
    lane.entered_tick = scheduler.tick_count
    nothing
end

function _advance_lane_locked!(scheduler::RollingScheduler,lane::StorageLane)
    _lane_phase(lane.state) || return false
    work = lane.work::StorageWorkUnit
    handler = _phase_handler(work,lane.state)
    outcome = try
        handler(work,lane,scheduler)
    catch error
        work.error = error
        lane.state = LaneError
        delete!(scheduler.async_requests,work.request_id)
        lane.transitions += UInt64(1)
        return true
    end
    outcome isa StoragePhaseResult || storageerror("Hook phase ARSP-4 harus mengembalikan StoragePhaseResult.")
    outcome.value === nothing || (work.result = outcome.value)
    if outcome.disposition == PhaseAdvance
        lane.state = _next_phase(lane.state)
    elseif outcome.disposition == PhaseComplete
        lane.state = LaneDone
    elseif outcome.disposition == PhaseBlockedIO
        lane.blocked_phase = lane.state
        lane.state = LaneBlockedIO
        scheduler.io_waits += UInt64(1)
    elseif outcome.disposition == PhaseBlockedLatch
        lane.blocked_phase = lane.state
        lane.state = LaneBlockedLatch
        scheduler.latch_waits += UInt64(1)
    else
        storageerror("Disposition phase ARSP-4 tidak dikenal.")
    end
    lane.transitions += UInt64(1)
    lane.entered_tick = scheduler.tick_count
    true
end

"""Resume a lane that an async I/O or latch owner has made ready."""
function resume_lane!(scheduler::RollingScheduler,lane_id::Integer)
    0 <= lane_id <= 3 || storageerror("Lane ARSP-4 harus 0 sampai 3.")
    lock(scheduler.mutex) do
        lane = scheduler.lanes[Int(lane_id)+1]
        lane.state in (LaneBlockedIO,LaneBlockedLatch) || storageerror("Lane ARSP-4 tidak sedang diblokir.")
        lane.state = lane.blocked_phase
        lane.blocked_phase = LaneEmpty
        lane.entered_tick = scheduler.tick_count
        lane.transitions += UInt64(1)
        work = lane.work::StorageWorkUnit
        delete!(scheduler.async_requests,work.request_id)
        notify(scheduler.async_event)
        work
    end
end

function record_buffer_wait!(scheduler::RollingScheduler)
    lock(scheduler.mutex) do
        scheduler.buffer_waits += UInt64(1)
    end
    nothing
end

"""Advance each ready lane by one phase and fill newly empty lanes with P1 work."""
function tick!(scheduler::RollingScheduler)
    lock(scheduler.mutex) do
        scheduler.tick_count += UInt64(1)
        for lane in scheduler.lanes
            lane.work === nothing || (scheduler.active_lane_ticks += UInt64(1))
            _advance_lane_locked!(scheduler,lane)
        end
        for lane in scheduler.lanes
            lane.state in (LaneDone,LaneError) && _retire_lane_locked!(scheduler,lane)
        end
        for lane in scheduler.lanes
            scheduler.queue_count == 0 && break
            lane.state == LaneEmpty || continue
            lane.work = _queue_pop_locked!(scheduler)
            lane.state = LanePhase1
            lane.blocked_phase = LaneEmpty
            lane.entered_tick = scheduler.tick_count
            lane.transitions += UInt64(1)
        end
        pipeline_lane_states(scheduler;locked=true)
    end
end

function pipeline_lane_states(scheduler::RollingScheduler;locked::Bool=false)
    inspect = () -> [(lane_id=Int(lane.id),state=lane.state,
                       request_id=lane.work === nothing ? UInt64(0) : lane.work.request_id,
                       operation=lane.work === nothing ? nothing : lane.work.operation,
                       blocked_phase=lane.blocked_phase) for lane in scheduler.lanes]
    locked ? inspect() : lock(scheduler.mutex) do; inspect(); end
end

function request_result(scheduler::RollingScheduler,request_id::Integer)
    request_id >= 1 || storageerror("Request ID ARSP-4 tidak valid.")
    lock(scheduler.mutex) do
        get(scheduler.completed,UInt64(request_id),nothing)
    end
end

function pipeline_stats(scheduler::RollingScheduler)
    lock(scheduler.mutex) do
        active = count(lane->lane.work !== nothing,scheduler.lanes)
        denominator = scheduler.tick_count * UInt64(length(scheduler.lanes))
        (active_lanes=active,queued_work=scheduler.queue_count,completed_work=scheduler.completed_count,
         failed_work=scheduler.failed_count,buffer_waits=scheduler.buffer_waits,io_waits=scheduler.io_waits,
         latch_waits=scheduler.latch_waits,ticks=scheduler.tick_count,
         asynchronous_waits=length(scheduler.async_requests),
         pipeline_utilization=denominator == 0 ? 0.0 : scheduler.active_lane_ticks / denominator,
         lane_states=pipeline_lane_states(scheduler;locked=true))
    end
end

"""Tick until a request completes, without spinning when every lane is blocked."""
function run_until_complete!(scheduler::RollingScheduler,request_id::Integer;max_ticks::Integer=1_000_000)
    request_id >= 1 || storageerror("Request ID ARSP-4 tidak valid.")
    max_ticks >= 1 || storageerror("Batas tick ARSP-4 minimal satu.")
    target = UInt64(request_id)
    for _ in 1:Int(max_ticks)
        completed = request_result(scheduler,target)
        completed === nothing || begin
            completed.error === nothing || throw(completed.error)
            return completed
        end
        before = pipeline_lane_states(scheduler)
        tick!(scheduler)
        after = pipeline_lane_states(scheduler)
        completed = request_result(scheduler,target)
        completed === nothing || begin
            completed.error === nothing || throw(completed.error)
            return completed
        end
        before == after || continue
        # Decide under the scheduler mutex.  A completing I/O owner changes
        # both the lane state and `async_requests` under this same lock.  The
        # single snapshot prevents a fast completion from being observed as a
        # blocked-but-not-async lane (and avoids resetting its notification).
        wait_mode = lock(scheduler.mutex) do
            target_blocked = any(lane->begin
                work = lane.work
                work !== nothing && work.request_id == target && lane.state in (LaneBlockedIO,LaneBlockedLatch)
            end,scheduler.lanes)
            target_queued = any(work->work !== nothing && work.request_id == target,scheduler.queue)
            (!target_blocked && !target_queued) && return :retry
            target_async = target in scheduler.async_requests
            queued_behind_async = target_queued && !isempty(scheduler.async_requests)
            if target_async || queued_behind_async
                # Reset while an owner is excluded; it notifies after this
                # lock is released, so the wakeup cannot be lost.
                reset(scheduler.async_event)
                :wait
            else
                :manual
            end
        end
        wait_mode === :retry && continue
        wait_mode === :manual && storageerror("Work ARSP-4 diblokir; panggil resume_lane! setelah resource siap.")
        wait(scheduler.async_event)
    end
    storageerror("Work ARSP-4 tidak selesai sebelum batas tick.")
end
