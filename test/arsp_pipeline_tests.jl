using Test
using AiresDB
using AiresDB.Internal

const PIPE = AiresDB

function recording_handlers!(events::Vector{Tuple{UInt64,Int}};block_acquire::Bool=false)
    StoragePhaseHandlers(
        (work,lane,scheduler)->begin push!(events,(work.request_id,1)); phase_advance() end,
        (work,lane,scheduler)->begin
            push!(events,(work.request_id,2))
            block_acquire && work.context === :block_once && begin
                work.context = :blocked
                return phase_blocked_io()
            end
            phase_advance()
        end,
        (work,lane,scheduler)->begin push!(events,(work.request_id,3)); phase_advance() end,
        (work,lane,scheduler)->begin push!(events,(work.request_id,4)); phase_complete(work.request_id) end,
    )
end

@testset "ARSP-4 rolling scheduler" begin
    @testset "four lanes roll one phase per tick" begin
        scheduler = RollingScheduler(;queue_capacity=8)
        events = Tuple{UInt64,Int}[]
        handlers = recording_handlers!(events)
        ids = UInt64[]
        for name in ("A","B","C","D")
            push!(ids,submit!(scheduler,StorageWorkUnit(StoragePointLookup,"DB",name;handlers)))
            tick!(scheduler)
        end
        states = pipeline_lane_states(scheduler)
        @test [entry.state for entry in states] == [LanePhase4,LanePhase3,LanePhase2,LanePhase1]
        @test [entry.request_id for entry in states] == ids

        fifth = submit!(scheduler,StorageWorkUnit(StorageSequentialScan,"DB","E";handlers))
        tick!(scheduler)
        states = pipeline_lane_states(scheduler)
        @test [entry.state for entry in states] == [LanePhase1,LanePhase4,LanePhase3,LanePhase2]
        @test [entry.request_id for entry in states] == UInt64[fifth,ids[2],ids[3],ids[4]]
        @test request_result(scheduler,ids[1]).result == ids[1]
        @test events == Tuple{UInt64,Int}[(ids[1],1),(ids[1],2),(ids[2],1),
                                           (ids[1],3),(ids[2],2),(ids[3],1),
                                           (ids[1],4),(ids[2],3),(ids[3],2),(ids[4],1)]
    end

    @testset "blocked I/O parks only its own lane" begin
        scheduler = RollingScheduler(;queue_capacity=8)
        events = Tuple{UInt64,Int}[]
        blocking = recording_handlers!(events;block_acquire=true)
        ordinary = recording_handlers!(events)
        a = submit!(scheduler,StorageWorkUnit(StorageSequentialScan,"DB","A";handlers=blocking,context=:block_once))
        tick!(scheduler)
        b = submit!(scheduler,StorageWorkUnit(StoragePointLookup,"DB","B";handlers=ordinary))
        tick!(scheduler)
        c = submit!(scheduler,StorageWorkUnit(StorageWrite,"DB","C";handlers=ordinary))
        tick!(scheduler)
        states = pipeline_lane_states(scheduler)
        @test states[1].request_id == a
        @test states[1].state == LaneBlockedIO
        @test states[2].request_id == b
        @test states[2].state == LanePhase2
        @test states[3].request_id == c
        @test states[3].state == LanePhase1

        d = submit!(scheduler,StorageWorkUnit(StorageIndex,"DB","D";handlers=ordinary))
        tick!(scheduler)
        states = pipeline_lane_states(scheduler)
        @test [entry.state for entry in states] == [LaneBlockedIO,LanePhase3,LanePhase2,LanePhase1]
        @test states[4].request_id == d
        @test pipeline_stats(scheduler).io_waits == 1
        @test resume_lane!(scheduler,0).request_id == a
        tick!(scheduler)
        @test pipeline_lane_states(scheduler)[1].state == LanePhase3
    end

    @testset "bounded queue applies backpressure and completion is retrievable" begin
        scheduler = RollingScheduler(;queue_capacity=1,completion_capacity=2)
        handlers = recording_handlers!(Tuple{UInt64,Int}[])
        for table in ("A","B","C","D")
            submit!(scheduler,StorageWorkUnit(StoragePointLookup,"DB",table;handlers))
            tick!(scheduler)
        end
        queued = submit!(scheduler,StorageWorkUnit(StoragePointLookup,"DB","Queued";handlers))
        @test_throws AiresError submit!(scheduler,StorageWorkUnit(StoragePointLookup,"DB","Overflow";handlers))
        stats = pipeline_stats(scheduler)
        @test stats.active_lanes == 4
        @test stats.queued_work == 1

        single = RollingScheduler()
        id = submit!(single,StorageWorkUnit(StorageWrite,"DB","T"))
        completed = run_until_complete!(single,id)
        @test completed.request_id == id
        @test completed.error === nothing
        @test request_result(single,id) === completed
        @test pipeline_stats(single).completed_work == 1
        @test queued > 0
    end

    @testset "queued work waits for asynchronous lanes without spinning" begin
        scheduler = RollingScheduler(;queue_capacity=4)
        async_handlers = StoragePhaseHandlers(
            (work,lane,scheduler)->phase_advance(),
            (work,lane,scheduler)->begin
                if work.context === :async_once
                    work.context = :waiting
                    PIPE.register_async_wait!(scheduler,lane)
                    @async begin
                        sleep(0.01)
                        PIPE.resume_async_lane!(scheduler,lane.id,work.request_id)
                    end
                    return phase_blocked_io()
                end
                phase_advance()
            end,
            (work,lane,scheduler)->phase_advance(),
            (work,lane,scheduler)->phase_complete(work.request_id),
        )
        for table in ("A","B","C","D")
            submit!(scheduler,StorageWorkUnit(StorageSequentialScan,"DB",table;
                handlers=async_handlers,context=:async_once))
            tick!(scheduler)
        end
        # Drive P1→P2 and P2→blocked for the four admitted requests.
        tick!(scheduler); tick!(scheduler)
        @test pipeline_stats(scheduler).asynchronous_waits == 4
        queued = submit!(scheduler,StorageWorkUnit(StoragePointLookup,"DB","E";handlers=async_handlers))
        completed = run_until_complete!(scheduler,queued;max_ticks=100)
        @test completed.request_id == queued
        @test completed.error === nothing
    end
end
