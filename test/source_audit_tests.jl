module SourceAuditTests

using Test
using AiresDB
using AiresDB.Internal

const SA = AiresDB

function audit_table!(session)
    SA.mutate_tables!(session,["T"];ddl=true) do db
        columns = [SA.ColumnDef("Id",:I,0,false,true,false,false),
                   SA.ColumnDef("Value",:I,0,false,false,false,false)]
        db.tables["T"] = SA.Table("T",columns,SA.Row[],Dict{String,Int128}())
    end
end

@testset "Source audit regressions" begin
    @testset "Cross-engine checkpoint history has one version per CSN" begin
        mktempdir() do root
            first_engine = Engine(root)
            first_session = Session(first_engine)
            SA.open_database!(first_session,"History";create=true)
            audit_table!(first_session)
            bulk_insert!(first_session,"T",[[1,10]])

            row_id = first_session.handle.current.tables["T"].row_ids[1]
            original_csn = first_session.handle.current.tables["T"].row_stamps[1]

            second_session = Session(Engine(root))
            SA.open_database!(second_session,"History")
            checkpoint!(second_session)
            update_key!(second_session,"T",1,Dict("Value"=>11))
            updated_csn = second_session.handle.csn

            @test lookup(first_session,"T",1) == [1,11]
            chain = first_session.handle.histories["T"][row_id]
            begins = getfield.(chain,:begin_csn)
            @test begins == [original_csn,updated_csn]
            @test all(chain[i].begin_csn < chain[i].end_csn for i in eachindex(chain))
            @test all(chain[i].end_csn == chain[i+1].begin_csn for i in 1:length(chain)-1)
            close(first_session)
            close(second_session)
            SA._close_page_stores_under!(root)
        end
    end

    @testset "Incremental replay publishes a complete batch or nothing" begin
        mktempdir() do root
            stale = Session(Engine(root))
            SA.open_database!(stale,"Replay";create=true)
            audit_table!(stale)
            bulk_insert!(stale,"T",[[1,10]])
            original_csn = stale.handle.csn
            original_offset = stale.handle.offset

            writer = Session(Engine(root))
            SA.open_database!(writer,"Replay")
            update_key!(writer,"T",1,Dict("Value"=>11))
            valid_end = filesize(writer.handle.path)
            valid_lsn = writer.handle.lsn

            # The outer WAL frame is fully checksummed, while its database delta
            # is deliberately truncated. Replay must not expose the valid record
            # immediately before this malformed record as a partial batch.
            SA.with_wal_lock(writer.handle.path) do
                SA.wal_append_locked(writer.handle.path,valid_lsn,UInt8[2])
            end
            @test_throws Exception lookup(stale,"T",1)
            @test stale.handle.csn == original_csn
            @test stale.handle.offset == original_offset
            @test stale.handle.current.tables["T"].rows == [[1,10]]
            @test stale.handle.poisoned

            # Simulate an operator restoring the last semantically valid prefix.
            SA.with_wal_lock(writer.handle.path) do
                open(writer.handle.path,"r+") do io
                    truncate(io,valid_end)
                    SA._wal_sync(io)
                end
            end
            @test lookup(stale,"T",1) == [1,11]
            @test !stale.handle.poisoned
            close(stale)
            close(writer)
            SA._close_page_stores_under!(root)
        end
    end

    @testset "Checkpoint staging failures preserve the database and clean private locks" begin
        for stage in ("before_publish","after_publish")
            mktempdir() do root
                session = Session(Engine(root))
                SA.open_database!(session,"Checkpoint_"*stage;create=true)
                audit_table!(session)
                bulk_insert!(session,"T",[[1,10]])
                original_id = copy(session.handle.file_id)

                error = withenv("AIRESDB_WAL_FAILPOINT"=>stage,
                                "AIRESDB_WAL_FAILMODE"=>"error") do
                    try
                        checkpoint!(session)
                        nothing
                    catch caught
                        caught
                    end
                end
                @test error isa AiresDB.AiresError
                # This failpoint is reached while wal_create publishes the
                # private staging file, before the authoritative file is touched.
                @test !session.handle.poisoned
                @test lookup(session,"T",1) == [1,10]
                @test !session.handle.poisoned
                @test session.handle.file_id == original_id
                @test isempty(filter(name->occursin(".checkpoint.",name),readdir(root)))
                close(session)
                SA._close_page_stores_under!(root)
            end
        end
    end
end

end
