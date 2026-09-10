module WALMVCCIntegrationTests
using Test, AiresDB
using AiresDB.Internal
const A = AiresDB

function make_table!(s,name)
    A.mutate_tables!(s,[name];ddl=true) do db
        cols = [A.ColumnDef("Id",:I,0,false,true,false,false),
                A.ColumnDef("Value",:I,0,false,false,false,false)]
        db.tables[name] = A.Table(name,cols,A.Row[],Dict{String,Int128}())
    end
end
function fresh(root,name)
    s = Session(root); A.open_database!(s,name;create=true); s
end
function reopen(root,name)
    s = Session(root); A.open_database!(s,name); s
end

"""Run this process audit in a temporary directory.

Set `AIRESDB_KEEP_WAL_MVCC_ARTIFACTS=1` while diagnosing a failed external
writer.  The worker scripts and logs then remain available for incident review;
ordinary test runs retain Julia's normal temporary-directory cleanup.
"""
function integration_audit_directory(f::Function)
    keep = get(ENV,"AIRESDB_KEEP_WAL_MVCC_ARTIFACTS","") == "1"
    dir = mktempdir(;cleanup=!keep)
    try
        f(dir)
    finally
        keep && println(stderr,"Preserved WAL/MVCC integration artifacts: ",dir)
    end
end

@testset "Independent WAL/MVCC integration audit" begin
    integration_audit_directory() do dir
        try
        @testset "Net DDL, insertion order, own writes, schema dependency" begin
            s = fresh(dir,"CreateDrop")
            begin_transaction!(s); make_table!(s,"Transient")
            A.mutate_tables!(s,["Transient"];ddl=true) do db
                delete!(db.tables,"Transient")
            end
            commit!(s)
            @test isempty(reopen(dir,"CreateDrop").handle.current.tables)

            s = fresh(dir,"Order"); make_table!(s,"Rows")
            bulk_insert!(s,"Rows",[[id,id] for id in 1:20])
            live = scan_rows(s,"Rows")
            replayed = scan_rows(reopen(dir,"Order"),"Rows")
            @test live == replayed == [[id,id] for id in 1:20]

            s = fresh(dir,"OwnDDL")
            begin_transaction!(s); make_table!(s,"New")
            @test lookup(s,"New",1) === nothing
            bulk_insert!(s,"New",[[1,10]])
            @test lookup(s,"New",1) == [1,10]
            update_key!(s,"New",1,Dict("Value"=>11))
            commit!(s)
            @test lookup(reopen(dir,"OwnDDL"),"New",1) == [1,11]

            s = fresh(dir,"SchemaCycle"); make_table!(s,"A"); make_table!(s,"C")
            bulk_insert!(s,"C",[[1,1]])
            b = Session(s.engine); A.open_database!(b,"SchemaCycle")
            begin_transaction!(s)
            @test table_columns(s,"A") == ["Id","Value"]
            begin_transaction!(b)
            @test lookup(b,"C",1) == [1,1]
            A.mutate_tables!(b,["A"];ddl=true) do db
                push!(db.tables["A"].columns,A.ColumnDef("Extra",:I,0,false,false,true,false))
            end
            commit!(b)
            update_key!(s,"C",1,Dict("Value"=>2))
            err = try commit!(s); nothing catch e; e end
            @test err isa AiresError && err.category == "Transaction Conflict"
            A.in_transaction(s) && rollback!(s)
            @test lookup(reopen(dir,"SchemaCycle"),"C",1) == [1,1]
        end

        @testset "Cross-Engine checkpoint preserves pinned versions" begin
            s = fresh(dir,"Checkpoint"); make_table!(s,"R")
            bulk_insert!(s,"R",[[1,10],[2,20],[3,30]])
            id1,id2 = s.handle.current.tables["R"].row_ids[1:2]
            oldstamp = s.handle.current.tables["R"].row_stamps[1]
            begin_transaction!(s)
            @test lookup(s,"R",1) == [1,10]
            external = reopen(dir,"Checkpoint")
            update_key!(external,"R",1,Dict("Value"=>11))
            delete_key!(external,"R",2)
            checkpoint!(external)
            refreshed = Session(s.engine); A.open_database!(refreshed,"Checkpoint")
            @test lookup(refreshed,"R",1) == [1,11]
            @test lookup(refreshed,"R",2) === nothing
            @test lookup(s,"R",1) == [1,10]
            @test lookup(s,"R",2) == [2,20]
            @test length(s.handle.histories["R"][id1]) == 2
            @test first(s.handle.histories["R"][id1]).begin_csn == oldstamp
            @test last(s.handle.histories["R"][id2]).values === nothing
            vacuum!(refreshed)
            @test length(s.handle.histories["R"][id1]) == 2
            rollback!(s); vacuum!(refreshed)
            @test length(s.handle.histories["R"][id1]) == 1
            @test !haskey(s.handle.histories["R"],id2)
            update_key!(refreshed,"R",3,Dict("Value"=>31))
            @test scan_rows(reopen(dir,"Checkpoint"),"R") == [[1,11],[3,31]]
        end

        @testset "Unknown outcomes poison and recover engine handles" begin
            for stage in ("after_sync","after_header")
                s = fresh(dir,"Unknown_"*stage); make_table!(s,"R")
                bulk_insert!(s,"R",[[1,10]])
                before_csn = s.handle.csn
                withenv("AIRESDB_WAL_FAILPOINT"=>stage,"AIRESDB_WAL_FAILMODE"=>"error") do
                    err = try update_key!(s,"R",1,Dict("Value"=>20)); nothing catch e; e end
                    @test err isa AiresError && err.category == "Commit Outcome Unknown"
                end
                @test !A.in_transaction(s)
                @test s.handle.poisoned
                @test lookup(s,"R",1) == [1,stage == "after_sync" ? 20 : 10]
                @test !s.handle.poisoned
                @test s.handle.csn == before_csn + (stage == "after_sync" ? 1 : 0)
                update_key!(s,"R",1,Dict("Value"=>30))
                @test lookup(reopen(dir,"Unknown_"*stage),"R",1) == [1,30]
            end
        end

        project = dirname(@__DIR__)
        worker = joinpath(dir,"mvcc_worker.jl")
        write(worker,"""
        using AiresDB
        using AiresDB.Internal
        s = Session(ARGS[1])
        AiresDB.open_database!(s,ARGS[2])
        mode = ARGS[3]
        function transfer!(s)
            with_transaction(s;retries=100) do
                debit = lookup(s,"Debit",1)
                credit = lookup(s,"Credit",1)
                update_key!(s,"Debit",1,Dict("Value"=>debit[2]-1))
                update_key!(s,"Credit",1,Dict("Value"=>credit[2]+1))
            end
        end
        if mode == "transfer"
            transfer!(s)
            println("ACK")
            flush(stdout)
            AiresDB._wal_failpoint("after_ack")
        elseif mode == "concurrent"
            for _ in 1:parse(Int,ARGS[4]); transfer!(s); end
            println("ACK ",ARGS[4])
        else
            error("Unknown worker mode")
        end
        """)
        julia = Base.julia_cmd()

        @testset "Real process crash: multi-table atomicity and durable ACK" begin
            for stage in ("after_header","after_payload","after_commit","after_sync","after_ack")
                name = "Crash_"*stage
                s = fresh(dir,name); make_table!(s,"Debit"); make_table!(s,"Credit")
                bulk_insert!(s,"Debit",[[1,100]]); bulk_insert!(s,"Credit",[[1,0]])
                logpath = joinpath(dir,stage*".log")
                cmd = addenv(`$julia --startup-file=no --compile=min --project=$project $worker $dir $name transfer`,
                    "AIRESDB_WAL_FAILPOINT"=>stage,"AIRESDB_WAL_FAILMODE"=>"crash")
                process = open(logpath,"w") do io
                    run(pipeline(ignorestatus(cmd);stdout=io,stderr=io))
                end
                @test process.exitcode == 86
                acknowledged = occursin("ACK",read(logpath,String))
                @test acknowledged == (stage == "after_ack")
                recovered = reopen(dir,name)
                balances = (lookup(recovered,"Debit",1)[2],lookup(recovered,"Credit",1)[2])
                @test balances in ((100,0),(99,1))
                @test sum(balances) == 100
                stage in ("after_sync","after_ack") && @test balances == (99,1)
                stage in ("after_header","after_payload") && @test balances == (100,0)
                @test isfile(recovered.path*".lock")
                with_transaction(recovered) do
                    debit = lookup(recovered,"Debit",1); credit = lookup(recovered,"Credit",1)
                    update_key!(recovered,"Debit",1,Dict("Value"=>debit[2]-1))
                    update_key!(recovered,"Credit",1,Dict("Value"=>credit[2]+1))
                end
                checkpoint!(recovered)
                final = reopen(dir,name)
                @test lookup(final,"Debit",1)[2] == balances[1]-1
                @test lookup(final,"Credit",1)[2] == balances[2]+1
            end
        end

        @testset "Concurrent process read-modify-write with retries" begin
            s = fresh(dir,"Concurrent"); make_table!(s,"Debit"); make_table!(s,"Credit")
            bulk_insert!(s,"Debit",[[1,100]]); bulk_insert!(s,"Credit",[[1,0]])
            writers = 3; operations = 12
            outputs = [open(joinpath(dir,"writer-$i.log"),"w") for i in 1:writers]
            try
                processes = [run(pipeline(`$julia --startup-file=no --compile=min --project=$project $worker $dir Concurrent concurrent $operations`;
                    stdout=outputs[i],stderr=outputs[i]);wait=false) for i in 1:writers]
                foreach(wait,processes)
                @test all(success,processes)
            finally
                foreach(close,outputs)
            end
            @test all(occursin("ACK $operations",read(joinpath(dir,"writer-$i.log"),String)) for i in 1:writers)
            recovered = reopen(dir,"Concurrent")
            @test lookup(recovered,"Debit",1)[2] == 100-writers*operations
            @test lookup(recovered,"Credit",1)[2] == writers*operations
            before_checkpoint = A.wal_read(recovered.path)
            @test length(before_checkpoint.records) == 5+writers*operations
            checkpoint!(recovered)
            @test length(A.wal_read(recovered.path).records) == 1
            final = reopen(dir,"Concurrent")
            @test lookup(final,"Debit",1)[2]+lookup(final,"Credit",1)[2] == 100
            @test lookup(final,"Credit",1)[2] == writers*operations
        end
        finally
            # This audit deliberately creates many independent Engine objects.
            # Close their shared page sidecars before Windows removes `dir`.
            A._close_page_stores_under!(dir)
        end
    end
end
end # module
