module WALLowLevelTests
using Test, SHA, UUIDs
include(joinpath(@__DIR__,"..","src","errors.jl"))
include(joinpath(@__DIR__,"..","src","wal.jl"))

const WAL_SOURCE_DIR = normpath(joinpath(@__DIR__,"..","src"))

@testset "WAL framing, durability and process recovery" begin
    mktempdir() do dir
        p = joinpath(dir,"basic.aires")
        @test !detect_wal(p)
        @test wal_create(p,UInt8[1,2,3]) == 1
        @test detect_wal(p)
        @test isfile(p*".lock")
        @test filesize(p*".lock") == 0
        first = wal_read(p)
        @test first.lsn == 1
        @test length(first.records) == 1
        @test first.records[1].payload == [1,2,3]
        @test first.end_offset == filesize(p)
        @test !first.torn_tail
        @test_throws AiresError wal_create(p,UInt8[99])
        @test_throws AiresError wal_read_locked(p)
        @test_throws AiresError wal_append_locked(p,UInt64(1),UInt8[])
        @test_throws AiresError wal_append(p,UInt64(0),UInt8[99])
        with_wal_lock(p) do
            with_wal_lock(p) do
                @test wal_append_locked(p,UInt64(1),UInt8[]) == 2
            end
            @test wal_append_locked(p,UInt64(2),UInt8[4,5,6,7]) == 3
        end
        full = wal_read(p)
        @test length(full.records) == 3
        incremental = wal_read(p;from_offset=first.end_offset)
        @test getfield.(incremental.records,:lsn) == [2,3]
        @test incremental.lsn == full.lsn
        @test incremental.file_id == first.file_id
        @test isempty(wal_read(p;from_offset=full.end_offset).records)
        @test_throws AiresError wal_read(p;from_offset=first.end_offset+1)
        @test_throws AiresError wal_read(p;from_offset=typemax(Int64))
        @test_throws AiresError wal_read(p;from_offset=-1)
        @test_throws AiresError wal_read(p;from_offset=1)

        # Every possible physical truncation of a final frame recovers exactly
        # the preceding commit. No complete damaged frame may be discarded.
        base = joinpath(dir,"tailbase.aires")
        wal_create(base,UInt8[9])
        before = filesize(base)
        wal_append(base,UInt64(1),collect(UInt8(1):UInt8(32)))
        bytes = read(base)
        for cut in before:length(bytes)-1
            q = joinpath(dir,"tail-$cut.aires")
            write(q,bytes[1:cut])
            recovered = wal_read(q)
            @test recovered.lsn == 1
            @test recovered.end_offset == before
            @test recovered.torn_tail == (cut > before)
            @test wal_append(q,UInt64(1),UInt8[42]) == 2
            @test wal_read(q).records[end].payload == [42]
            @test filesize(q) == before+WAL_RECORD_HEADER_SIZE+1+WAL_COMMIT_SIZE
        end
        for index in before+1:length(bytes)
            q = joinpath(dir,"corrupt-$index.aires")
            damaged = copy(bytes); damaged[index] ⊻= 0x01
            write(q,damaged)
            @test_throws AiresError wal_read(q)
        end
        for index in 1:WAL_HEADER_SIZE
            q = joinpath(dir,"header-$index.aires")
            damaged = copy(bytes); damaged[index] ⊻= 0x01
            write(q,damaged)
            @test_throws AiresError wal_read(q)
        end

        q = joinpath(dir,"oversized.aires")
        oversized = copy(bytes)
        lenbuf = IOBuffer(); _wal_put64(lenbuf,typemax(UInt64))
        oversized[before+25:before+32] = take!(lenbuf)
        oversized[before+65:before+96] = sha256(oversized[before+1:before+64])
        write(q,oversized)
        @test_throws AiresError wal_read(q)

        # Recompute cryptographic checksums so these tests reach semantic guards
        # instead of merely exercising checksum mismatch detection.
        for (label,start,replacement) in (
            ("bad-sequence",before+9,UInt8[0x03]),
            ("bad-previous",before+17,UInt8[0x00]),
            ("bad-file-id",before+33,UInt8[bytes[before+33] ⊻ 0x01]),
            ("bad-record-flags",before+49,UInt8[0x01]),
            ("bad-record-reserved",before+57,UInt8[0x01]))
            q = joinpath(dir,"semantic-$label.aires")
            damaged = copy(bytes)
            damaged[start:start+length(replacement)-1] = replacement
            damaged[before+65:before+96] = sha256(damaged[before+1:before+64])
            damaged[end-31:end] = sha256(damaged[before+1:end-WAL_COMMIT_SIZE])
            write(q,damaged)
            @test_throws AiresError wal_read(q)
        end
        for (label,index,value) in (("major",9,0x02),("minor",11,0x01),
                                    ("header-size",13,0x51),("file-flags",33,0x01),
                                    ("file-reserved",41,0x01))
            q = joinpath(dir,"format-$label.aires")
            damaged = copy(bytes); damaged[index] = value
            damaged[49:80] = sha256(damaged[1:48])
            write(q,damaged)
            @test_throws AiresError wal_read(q)
        end
        q = joinpath(dir,"header-only.aires"); write(q,bytes[1:WAL_HEADER_SIZE])
        @test_throws AiresError wal_read(q)
        q = joinpath(dir,"unicode-試験-é.aires")
        @test wal_create(q,UInt8[1]) == 1
        @test wal_append(q,UInt64(1),UInt8[2]) == 2
        @test wal_read(q).lsn == 2

        for stage in ("after_header","mid_payload","after_payload","after_commit","before_sync","after_sync")
            q = joinpath(dir,"failure-$stage.aires")
            wal_create(q,UInt8[1])
            withenv("AIRESDB_WAL_FAILPOINT"=>stage,"AIRESDB_WAL_FAILMODE"=>"error") do
                @test_throws WALCommitUnknown wal_append(q,UInt64(1),UInt8[2,3,4,5])
            end
            r = wal_read(q)
            expected = stage in ("after_commit","before_sync","after_sync") ? 2 : 1
            @test r.lsn == expected
            @test wal_append(q,UInt64(expected),UInt8[8]) == expected+1
        end
        q = joinpath(dir,"before-write.aires")
        wal_create(q,UInt8[1])
        withenv("AIRESDB_WAL_FAILPOINT"=>"before_append","AIRESDB_WAL_FAILMODE"=>"error") do
            @test_throws AiresError wal_append(q,UInt64(1),UInt8[2])
        end
        @test wal_read(q).lsn == 1

        # Migrate/replace under the destination's unchanged lock identity.
        q = joinpath(dir,"replace.aires"); tmp = joinpath(dir,"replacement.aires")
        wal_create(q,UInt8[1]); wal_create(tmp,UInt8[2])
        old_id = wal_read(q).file_id
        with_wal_lock(q) do
            durable_replace(tmp,q)
        end
        @test wal_read(q).file_id != old_id
        @test wal_read(q).records[1].payload == [2]
        @test wal_append(q,UInt64(1),UInt8[3]) == 2

        # All concurrent tasks serialize in-process, including recursive calls.
        q = joinpath(dir,"tasks.aires"); wal_create(q,UInt8[])
        @sync for _ in 1:8
            @async for _ in 1:10
                with_wal_lock(q) do
                    r = wal_read_locked(q)
                    yield()
                    wal_append_locked(q,r.lsn,UInt8[7])
                end
            end
        end
        @test wal_read(q).lsn == 81

        script = joinpath(dir,"worker.jl")
        write(script,"""
        using SHA, UUIDs
        include(joinpath($(repr(WAL_SOURCE_DIR)),"errors.jl"))
        include(joinpath($(repr(WAL_SOURCE_DIR)),"wal.jl"))
        p = ARGS[1]
        mode = ARGS[2]
        if mode == "append"
            offset = 0
            for i in 1:parse(Int,ARGS[3])
                global offset
                with_wal_lock(p) do
                    r = wal_read_locked(p;from_offset=offset)
                    wal_append_locked(p,r.lsn,UInt8[parse(UInt8,ARGS[4])])
                    offset = filesize(p)
                end
            end
        elseif mode == "crash"
            wal_append(p,UInt64(1),UInt8[2,3,4,5])
        elseif mode == "lock-crash"
            with_wal_lock(p) do
                _wal_failpoint("held_lock")
            end
        end
        """)
        julia = Base.julia_cmd()
        q = joinpath(dir,"processes.aires"); wal_create(q,UInt8[])
        processes = [run(`$julia --startup-file=no $script $q append 15 $worker`;wait=false) for worker in 1:4]
        foreach(wait,processes)
        @test all(success,processes)
        r = wal_read(q)
        @test r.lsn == 61
        @test all(count(rec->rec.payload==UInt8[worker],r.records)==15 for worker in 1:4)

        for stage in ("after_header","mid_payload","after_payload","after_commit","before_sync","after_sync")
            q = joinpath(dir,"crash-$stage.aires"); wal_create(q,UInt8[1])
            cmd = addenv(`$julia --startup-file=no $script $q crash`,
                "AIRESDB_WAL_FAILPOINT"=>stage,"AIRESDB_WAL_FAILMODE"=>"crash")
            process = run(ignorestatus(cmd))
            @test process.exitcode == 86
            r = wal_read(q)
            expected = stage in ("after_commit","before_sync","after_sync") ? 2 : 1
            @test r.lsn == expected
            @test wal_append(q,UInt64(expected),UInt8[9]) == expected+1
        end
        q = joinpath(dir,"dead-lock-owner.aires"); wal_create(q,UInt8[1])
        cmd = addenv(`$julia --startup-file=no $script $q lock-crash`,
            "AIRESDB_WAL_FAILPOINT"=>"held_lock","AIRESDB_WAL_FAILMODE"=>"crash")
        process = run(ignorestatus(cmd))
        @test process.exitcode == 86
        @test wal_append(q,UInt64(1),UInt8[2]) == 2
        @test isfile(q*".lock")
    end
end
end # module
