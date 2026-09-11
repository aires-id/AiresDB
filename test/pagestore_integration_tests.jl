using Test
using AiresDB
using AiresDB.Internal

const PST = AiresDB

@testset "ARSP-4 WAL/page-store integration" begin
    mktempdir() do dir
        session = Session(dir)
        execute!(session,"Buat 'Pages' -:")
        path = joinpath(dir,"Pages.aires")
        @test isfile(path * ".pages")
        execute!(session,"Buat Tabel 'Data' Isi 'ID & Nilai' Dengan 'ID = I(P) & Nilai = C' -:")
        execute!(session,"Isi Tabel 'Data' '1 & satu' '2 & dua' -:")
        handle = session.handle::PST.DatabaseHandle
        store = handle.page_store::PST.PageStore
        @test haskey(store.tables,"Data")
        @test PST.page_store_scan_rows(store,"Data",handle.csn) == PST.Row[PST.Cell[1,"satu"],PST.Cell[2,"dua"]]
        @test PST.page_store_lookup(store,handle.current.tables["Data"],(Int64(2),),handle.csn) == PST.Cell[2,"dua"]
        completed_before_lookup = PST.pipeline_stats(store.scheduler).completed_work
        @test lookup(session,"Data",2) == PST.Cell[2,"dua"]
        # Small snapshots retain a complete immutable logical index, so their
        # public point lookup does not need a second PageStore request.
        @test PST.pipeline_stats(store.scheduler).completed_work == completed_before_lookup
        physical = PST.page_store_lookup_identity(
            store,handle.current.tables["Data"],(Int64(2),),handle.csn)
        @test physical !== nothing
        @test physical.row == PST.Cell[2,"dua"]
        @test PST.pipeline_stats(store.scheduler).completed_work > completed_before_lookup
        detached_physical = scan_rows(session,"Data")
        detached_physical[1][2] = "caller mutation"
        @test scan_rows(session,"Data") == PST.Row[PST.Cell[1,"satu"],PST.Cell[2,"dua"]]
        completed_before_order = PST.pipeline_stats(store.scheduler).completed_work
        @test execute!(session,"Pilih 'ID' Dari 'Data' M: 'ID Bawah' -:").rows == PST.Row[PST.Cell[2],PST.Cell[1]]
        @test PST.pipeline_stats(store.scheduler).completed_work > completed_before_order

        # A transaction may swap two unique keys. Page publication removes all
        # old B+Tree entries before it inserts either replacement entry.
        execute!(session,"Buat Tabel 'Swap' Isi 'ID & Nilai' Dengan 'ID = I(P) & Nilai = C' -:")
        execute!(session,"Isi Tabel 'Swap' '1 & satu' '2 & dua' -:")
        begin_transaction!(session)
        PST.mutate_tables!(session,["Swap"]) do db
            table = db.tables["Swap"]
            first_id,second_id = table.row_ids[1:2]
            first_row,second_row = copy(table.rows[1]),copy(table.rows[2])
            first_row[1],second_row[1] = Int64(2),Int64(1)
            PST.set_row!(table,1,first_row)
            PST.set_row!(table,2,second_row)
        end
        commit!(session)
        @test lookup(session,"Swap",1) == PST.Cell[1,"dua"]
        @test lookup(session,"Swap",2) == PST.Cell[2,"satu"]

        execute!(session,"Tabel_Upt 'Data' Isi 'Nilai = \"Dua\"' Dengan 'ID = 2' -:")
        @test PST.page_store_lookup(store,handle.current.tables["Data"],(Int64(2),),handle.csn) == PST.Cell[2,"Dua"]
        execute!(session,"Baris_Rmv 'Data' Dengan 'ID = 1' -:")
        @test PST.page_store_scan_rows(store,"Data",handle.csn) == PST.Row[PST.Cell[2,"Dua"]]
        physical_size_before = filesize(path * ".pages")
        compact_page_store!(session)
        physical_size_after = filesize(path * ".pages")
        @test physical_size_after <= physical_size_before
        @test PST.page_store_stats(store).rebuilds >= 1
        @test execute!(session,"Tampilkan 'Data' -:").rows == PST.Row[PST.Cell[2,"Dua"]]
        checkpoint!(session)

        reopened = Session(dir)
        execute!(reopened,"Pilih 'Pages' -:")
        @test execute!(reopened,"Tampilkan 'Data' -:").rows == PST.Row[PST.Cell[2,"Dua"]]
        reopened_store = (reopened.handle::PST.DatabaseHandle).page_store::PST.PageStore
        @test PST.page_store_stats(reopened_store).applied_lsn == (reopened.handle::PST.DatabaseHandle).lsn
        completed_before = PST.pipeline_stats(reopened_store.scheduler).completed_work
        @test scan_rows(reopened,"Data") == PST.Row[PST.Cell[2,"Dua"]]
        @test PST.pipeline_stats(reopened_store.scheduler).completed_work > completed_before
        close(reopened)
        close(session)
    end

    @testset "WAL-durable page failure is rebuilt on reopen" begin
        mktempdir() do dir
            session = Session(dir)
            execute!(session,"Buat 'RecoverPages' -:")
            execute!(session,"Buat Tabel 'T' Isi 'ID' Dengan 'ID = I(P)' -:")
            ENV["AIRESDB_PAGE_FAILPOINT"] = "before_catalog_publish"
            try
                @test_throws AiresError execute!(session,"Isi Tabel 'T' '1' -:")
            finally
                delete!(ENV,"AIRESDB_PAGE_FAILPOINT")
            end
            close(session)
            reopened = Session(dir)
            execute!(reopened,"Pilih 'RecoverPages' -:")
            @test execute!(reopened,"Tampilkan 'T' -:").rows == PST.Row[PST.Cell[1]]
            @test isfile(joinpath(dir,"RecoverPages.aires.pages"))
            close(reopened)
        end
    end

    @testset "cold reopen advances asynchronous P2 acquisition" begin
        mktempdir() do dir
            session = Session(dir)
            reopened = nothing
            try
                execute!(session,"Buat 'ColdPages' -:")
                execute!(session,"Buat Tabel 'Data' Isi 'ID & Nilai' Dengan 'ID = I(P) & Nilai = C' -:")
                execute!(session,"Isi Tabel 'Data' '1 & satu' '2 & dua' -:")
                close(session)
                reopened = Session(dir)
                execute!(reopened,"Pilih 'ColdPages' -:")
                handle = reopened.handle::PST.DatabaseHandle
                store = handle.page_store::PST.PageStore
                @test lookup(reopened,"Data",2) == PST.Cell[2,"dua"]
                # The B+Tree root is not resident after a genuine reopen. A
                # direct physical lookup exercises P2's page-acquisition race
                # independently of the small-table logical lookup fast path.
                physical = PST.page_store_lookup_identity(
                    store,handle.current.tables["Data"],(Int64(2),),handle.csn)
                @test physical !== nothing
                @test physical.row == PST.Cell[2,"dua"]
                @test scan_rows(reopened,"Data") == PST.Row[PST.Cell[1,"satu"],PST.Cell[2,"dua"]]
                stats = PST.pipeline_stats(store.scheduler)
                @test stats.io_waits >= 1
                @test stats.asynchronous_waits == 0
            finally
                reopened === nothing || close(reopened)
                close(session)
                PST._close_page_stores_under!(dir)
            end
        end
    end
end
