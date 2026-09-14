module OptimizerTests

using Test
using AiresDB
using AiresDB.Internal

const A = AiresDB

@testset "Optimizer: multi-join, statistics, EXPLAIN and spilling" begin
    @testset "Greedy multi-join preserves source-column order" begin
        mktempdir() do dir
            session = Session(dir)
            try
                execute!(session,"Buat 'Opt' -:")
                execute!(session,"Buat Tabel 'Orders' Isi 'ID & Customer' Dengan 'ID = I & Customer = I' -:")
                execute!(session,"Buat Tabel 'Customers' Isi 'ID & Region' Dengan 'ID = I & Region = I' -:")
                execute!(session,"Buat Tabel 'Regions' Isi 'ID & Name' Dengan 'ID = I & Name = C' -:")
                execute!(session,"Isi Tabel 'Orders' '1 & 10' '2 & 20' '3 & 10' -:")
                execute!(session,"Isi Tabel 'Customers' '10 & 7' '20 & 8' -:")
                execute!(session,"Isi Tabel 'Regions' '7 & West' '8 & East' -:")
                query = "Pilih 'Orders.ID & Customers.ID & Regions.Name' Dari 'Orders &&& Customers &&& Regions' Gabung Dengan 'Orders.Customer = Customers.ID &: Customers.Region = Regions.ID' M: 'Orders.ID Atas' -:"
                result = execute!(session,query)
                @test result.rows == A.Row[A.Cell[1,10,"West"],A.Cell[2,20,"East"],A.Cell[3,10,"West"]]
                @test A.plan_join_order(session.database, A.parse_airesql(query),
                    A.validate_query(session.database,A.parse_airesql(query))[1], Set{String}()).order != ["Orders","Customers","Regions"]
            finally
                close(session)
                A._close_page_stores_under!(dir)
            end
        end
    end

    @testset "Composite join keys use every equality predicate" begin
        mktempdir() do dir
            session = Session(dir)
            try
                execute!(session,"Buat 'CompositeJoin' -:")
                execute!(session,"Buat Tabel 'A' Isi 'K1 & K2 & ValueA' Dengan 'K1 = I & K2 = I & ValueA = C' -:")
                execute!(session,"Buat Tabel 'B' Isi 'K1 & K2 & ValueB' Dengan 'K1 = I & K2 = I & ValueB = C' -:")
                execute!(session,"Isi Tabel 'A' '1 & 10 & A10' '1 & 20 & A20' '2 & 10 & A210' -:")
                execute!(session,"Isi Tabel 'B' '1 & 10 & B10' '1 & 30 & B30' '2 & 10 & B210' -:")
                result = execute!(session,
                    "Pilih 'A.K1 & A.K2 & A.ValueA & B.ValueB' Dari 'A &&& B' Gabung Dengan 'A.K1 = B.K1 &: A.K2 = B.K2' M: 'A.K1 Atas & A.K2 Atas' -:")
                @test result.rows == A.Row[A.Cell[1,10,"A10","B10"],A.Cell[2,10,"A210","B210"]]
            finally
                close(session)
                A._close_page_stores_under!(dir)
            end
        end
    end

    @testset "Statistics are cached and invalidated" begin
        columns = [A.ColumnDef("ID",:I,0,false,true,false,false), A.ColumnDef("Group",:C,20,false,false,true,false)]
        table = A.Table("Stats",columns,A.Row[A.Cell[1,"a"],A.Cell[2,"a"],A.Cell[3,nothing]],Dict{String,Int128}())
        stats = A.table_statistics(table)
        @test stats.row_count == 3
        @test stats.distinct_counts["Group"] == 1
        @test stats.null_counts["Group"] == 1
        @test A.table_statistics(table) === stats
        A.append_row!(table,A.Cell[4,"b"])
        @test table.statistics === nothing
        @test A.table_statistics(table).distinct_counts["Group"] == 2
    end

    @testset "EXPLAIN is a read-only plan result" begin
        mktempdir() do dir
            session = Session(dir)
            try
                execute!(session,"Buat 'Explain' -:")
                execute!(session,"Buat Tabel 'A' Isi 'ID' Dengan 'ID = I' -:")
                execute!(session,"Buat Tabel 'B' Isi 'ID' Dengan 'ID = I' -:")
                execute!(session,"Isi Tabel 'A' '1' -:")
                execute!(session,"Isi Tabel 'B' '1' -:")
                parsed = parse_airesql("EXPLAIN Pilih '*' Dari 'A &&& B' Gabung Dengan 'A.ID = B.ID' -:")
                @test parsed isa A.ExplainQuery
                result = execute!(session,"EXPLAIN Pilih '*' Dari 'A &&& B' Gabung Dengan 'A.ID = B.ID' -:")
                @test result.columns == ["Plan"]
                @test any(row->occursin("Hash Join",row[1]),result.rows)
                @test any(row->occursin("rows=1",row[1]),result.rows)
            finally
                close(session)
                A._close_page_stores_under!(dir)
            end
        end
    end

    @testset "External hash join spills and cleans its run files" begin
        left = A.Row[A.Cell[Int64(i),Int64(i)] for i in 1:32]
        right = A.Row[A.Cell[Int64(i),Int64(i)*2] for i in 32:63]
        directory = mktempdir()
        budget = A.QueryBudget(typemax(UInt64),100_000,100_000,1_000,10_000_000,directory,0,0,0,0,0,0,0)
        try
            result = A._with_query_budget(budget) do
                A._hash_join_preserve_left_keys(left,right,Int[1],Int[1],false)
            end
            @test length(result) == 1
            @test result[1] == A.Cell[32,32,32,64]
            @test budget.spill_runs == 2
            @test isempty(readdir(directory))
        finally
            isdir(directory) && rm(directory;recursive=true,force=true)
        end
    end
end

end
