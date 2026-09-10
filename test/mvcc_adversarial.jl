using Test
using AiresDB
using AiresDB.Internal

const ADV = AiresDB

function adv_fixture(f::Function)
    mktempdir() do directory
        engine = ADV.Engine(directory)
        writer = Session(engine)
        execute!(writer, "Buat 'Audit' -:")
        execute!(writer, "Buat Tabel 'T' Isi 'Id & V' Dengan 'Id = I(P) & V = I(Not Null)' -:")
        ADV.bulk_insert!(writer, "T", [(1, 1), (2, 1)])
        reader = Session(engine)
        execute!(reader, "Pilih 'Audit' -:")
        try
            f(writer, reader, directory)
        finally
            close(writer)
            close(reader)
        end
    end
end

function adv_conflict(f::Function)
    outcome = try
        f()
        nothing
    catch error
        error
    end
    @test outcome isa AiresError
    if outcome isa AiresError
        @test outcome.category == "Transaction Conflict"
    end
end

@testset "MVCC independent adversarial audit" begin
    @testset "Pinned snapshots, read-your-writes and detached result rows" begin
        adv_fixture() do a, b, directory
            ADV.begin_transaction!(a)
            initial = ADV.lookup(a, "T", 1)
            @test initial == [1, 1]
            ADV.update_key!(b, "T", 1, Dict("V" => 7))
            @test ADV.lookup(a, "T", 1) == [1, 1]
            initial[2] = 999
            @test ADV.lookup(a, "T", 1) == [1, 1]
            detached = ADV.scan_rows(a, "T")
            detached[1][2] = 998
            push!(detached, ADV.Cell[99, 999])
            @test ADV.lookup(a, "T", 1) == [1, 1]
            @test length(ADV.scan_rows(a, "T")) == 2
            ADV.update_key!(a, "T", 2, Dict("V" => 5))
            @test ADV.lookup(a, "T", 2) == [2, 5]
            adv_conflict(() -> ADV.commit!(a))
            @test ADV.in_transaction(a)
            ADV.rollback!(a)
            @test ADV.lookup(a, "T", 1) == [1, 7]
            @test ADV.lookup(a, "T", 2) == [2, 1]
        end
    end

    @testset "Nonoverlapping keyed writers merge without lost updates" begin
        adv_fixture() do a, b, directory
            ADV.begin_transaction!(a)
            ADV.begin_transaction!(b)
            ADV.update_key!(a, "T", 1, Dict("V" => 11))
            ADV.update_key!(b, "T", 2, Dict("V" => 22))
            ADV.commit!(b)
            ADV.commit!(a)
            @test ADV.lookup(a, "T", 1) == [1, 11]
            @test ADV.lookup(a, "T", 2) == [2, 22]
            reopened = Session(directory)
            execute!(reopened, "Pilih 'Audit' -:")
            @test ADV.lookup(reopened, "T", 1) == [1, 11]
            @test ADV.lookup(reopened, "T", 2) == [2, 22]
            close(reopened)
        end
    end

    @testset "Read dependency certification prevents write skew" begin
        adv_fixture() do a, b, directory
            ADV.begin_transaction!(a)
            ADV.begin_transaction!(b)
            @test ADV.lookup(a, "T", 1)[2] + ADV.lookup(a, "T", 2)[2] == 2
            @test ADV.lookup(b, "T", 1)[2] + ADV.lookup(b, "T", 2)[2] == 2
            ADV.update_key!(a, "T", 1, Dict("V" => 0))
            ADV.update_key!(b, "T", 2, Dict("V" => 0))
            ADV.commit!(a)
            adv_conflict(() -> ADV.commit!(b))
            ADV.rollback!(b)
            @test sum(row[2] for row in ADV.scan_rows(a, "T")) == 1
        end
    end

    @testset "Predicate phantom and absent-key conflicts" begin
        adv_fixture() do a, b, directory
            ADV.begin_transaction!(a)
            @test isempty(filter(row -> row[2] == 99, ADV.scan_rows(a, "T")))
            ADV.bulk_insert!(b, "T", [(3, 99)])
            ADV.update_key!(a, "T", 1, Dict("V" => 5))
            adv_conflict(() -> ADV.commit!(a))
            ADV.rollback!(a)
            ADV.begin_transaction!(a)
            @test ADV.lookup(a, "T", 4) === nothing
            ADV.bulk_insert!(b, "T", [(4, 44)])
            ADV.update_key!(a, "T", 1, Dict("V" => 6))
            adv_conflict(() -> ADV.commit!(a))
            ADV.rollback!(a)
            @test ADV.lookup(a, "T", 1) == [1, 1]
        end
    end

    @testset "Indexes survive key movement, delete-reinsert, and rollback" begin
        adv_fixture() do a, b, directory
            ADV.begin_transaction!(a)
            ADV.delete_key!(a, "T", 1)
            @test ADV.lookup(a, "T", 1) === nothing
            ADV.bulk_insert!(a, "T", [(1, 10)])
            @test ADV.lookup(a, "T", 1) == [1, 10]
            ADV.update_key!(a, "T", 1, Dict("Id" => 4))
            @test ADV.lookup(a, "T", 1) === nothing
            @test ADV.lookup(a, "T", 4) == [4, 10]
            @test_throws AiresError ADV.update_key!(a, "T", 4, Dict("Id" => 2))
            @test ADV.lookup(a, "T", 4) == [4, 10]
            @test ADV.lookup(a, "T", 2) == [2, 1]
            ADV.rollback!(a)
            @test ADV.lookup(a, "T", 1) == [1, 1]
            @test ADV.lookup(a, "T", 4) === nothing
            ADV.update_key!(a, "T", 1, Dict("V" => 10))
            execute!(a, "Tabel_Upt 'T' Isi 'Id = 3 - Id' -:")
            @test ADV.lookup(a, "T", 1) == [1, 1]
            @test ADV.lookup(a, "T", 2) == [2, 10]
            reopened = Session(directory)
            execute!(reopened, "Pilih 'Audit' -:")
            @test ADV.lookup(reopened, "T", 1) == [1, 1]
            @test ADV.lookup(reopened, "T", 2) == [2, 10]
            close(reopened)
        end
    end

    @testset "Schema changes preserve old row objects and statement atomicity" begin
        adv_fixture() do a, b, directory
            ADV.begin_transaction!(a)
            @test ADV.scan_rows(a, "T") == [[1, 1], [2, 1]]
            execute!(b, "Tabel_Upt 'T' + Kolom 'Extra' Dengan 'Extra = C(30&Null)' -:")
            @test ADV.table_columns(a, "T") == ["Id", "V"]
            @test ADV.scan_rows(a, "T") == [[1, 1], [2, 1]]
            @test ADV.table_columns(b, "T") == ["Id", "V", "Extra"]
            execute!(b, "Kolom_Rmv 'T.Extra' -:")
            @test ADV.scan_rows(a, "T") == [[1, 1], [2, 1]]
            ADV.commit!(a)
            ADV.begin_transaction!(a)
            @test_throws AiresError execute!(a, "Tabel_Upt 'T' + Kolom 'Required' Dengan 'Required = I(Not Null)' -:")
            @test ADV.table_columns(a, "T") == ["Id", "V"]
            @test ADV.scan_rows(a, "T") == [[1, 1], [2, 1]]
            ADV.rollback!(a)
            ADV.begin_transaction!(a)
            ADV.update_key!(a, "T", 1, Dict("V" => 8))
            execute!(b, "Tabel_Upt 'T' + Kolom 'Extra' Dengan 'Extra = C(30&Null)' -:")
            adv_conflict(() -> ADV.commit!(a))
            ADV.rollback!(a)
        end
    end

    @testset "Snapshot retention across vacuum and checkpoint" begin
        adv_fixture() do a, b, directory
            ADV.begin_transaction!(a)
            @test ADV.lookup(a, "T", 1) == [1, 1]
            for value in 2:6
                ADV.update_key!(b, "T", 1, Dict("V" => value))
            end
            ADV.vacuum!(b)
            @test ADV.mvcc_stats(b).active_snapshots == 1
            @test ADV.mvcc_stats(b).row_versions >= 7
            @test ADV.lookup(a, "T", 1) == [1, 1]
            ADV.checkpoint!(b)
            @test ADV.lookup(a, "T", 1) == [1, 1]
            @test ADV.lookup(b, "T", 1) == [1, 6]
            ADV.rollback!(a)
            ADV.vacuum!(b)
            @test ADV.mvcc_stats(b).row_versions == 2
            ADV.delete_key!(b, "T", 1)
            ADV.vacuum!(b)
            @test ADV.mvcc_stats(b).row_versions == 1
            reopened = Session(directory)
            execute!(reopened, "Pilih 'Audit' -:")
            @test ADV.lookup(reopened, "T", 1) === nothing
            @test ADV.lookup(reopened, "T", 2) == [2, 1]
            close(reopened)
        end
    end

    @testset "Independent engine checkpoint refresh retains pinned history" begin
        adv_fixture() do a, b, directory
            external = Session(directory)
            execute!(external, "Pilih 'Audit' -:")
            try
                ADV.begin_transaction!(a)
                @test ADV.lookup(a, "T", 1) == [1, 1]
                ADV.update_key!(external, "T", 1, Dict("V" => 42))
                ADV.checkpoint!(external)
                @test ADV.lookup(b, "T", 1) == [1, 42]
                ADV.vacuum!(b)
                @test ADV.lookup(a, "T", 1) == [1, 1]
                @test ADV.mvcc_stats(b).row_versions >= 3
                ADV.rollback!(a)
                ADV.vacuum!(b)
                @test ADV.mvcc_stats(b).row_versions == 2
            finally
                close(external)
            end
        end
    end

    @testset "Relational scans stay coherent with surrounding MVCC snapshot" begin
        adv_fixture() do a, b, directory
            ADV.with_snapshot(a) do
                first = relation(a, "T"; columns=["Id", "V"], prefix="t_")
                @test first.columns == [:t_Id, :t_V]
                ADV.update_key!(b, "T", 1, Dict("V" => 99))
                second = relation(a, "T"; columns=["Id", "V"])
                @test first[1].t_V == second[1].V == 1
            end
            @test relation(a, "T")[1].V == 99
        end
    end

    @testset "Own new-table lookups, no-op DDL, and insertion order recovery" begin
        adv_fixture() do a, b, directory
            ADV.with_transaction(a) do
                execute!(a, "Buat Tabel 'NewTable' Isi 'Id & V' Dengan 'Id = I(P) & V = I' -:")
                ADV.bulk_insert!(a, "NewTable", [(3, 30), (1, 10), (5, 50), (2, 20), (4, 40)])
                @test ADV.lookup(a, "NewTable", 3) == [3, 30]
                ADV.update_key!(a, "NewTable", 3, Dict("V" => 31))
                @test ADV.lookup(a, "NewTable", 3) == [3, 31]
            end
            @test ADV.scan_rows(a, "NewTable") == [[3, 31], [1, 10], [5, 50], [2, 20], [4, 40]]
            ADV.with_transaction(a) do
                execute!(a, "Buat Tabel 'Ephemeral' Isi 'Id' Dengan 'Id = I(P)' -:")
                ADV.bulk_insert!(a, "Ephemeral", [(1,)])
                execute!(a, "Tabel_Rmv 'Ephemeral' -:")
            end
            reopened = Session(directory)
            execute!(reopened, "Pilih 'Audit' -:")
            @test ADV.scan_rows(reopened, "NewTable") == [[3, 31], [1, 10], [5, 50], [2, 20], [4, 40]]
            @test_throws AiresError ADV.scan_rows(reopened, "Ephemeral")
            ADV.bulk_insert!(a, "NewTable", [(8, 80), (6, 60), (7, 70)])
            execute!(reopened, "Pilih 'Audit' -:")
            @test ADV.scan_rows(reopened, "NewTable") == ADV.scan_rows(a, "NewTable")
            @test last.(ADV.scan_rows(reopened, "NewTable")) == [31, 10, 50, 20, 40, 80, 60, 70]
            close(reopened)
        end
    end

    @testset "Schema inspection records a serialization dependency" begin
        adv_fixture() do a, b, directory
            execute!(a, "Buat Tabel 'Other' Isi 'Id & V' Dengan 'Id = I(P) & V = I' -:")
            ADV.bulk_insert!(a, "Other", [(1, 0)])
            ADV.begin_transaction!(a)
            @test length(ADV.table_columns(a, "T")) == 2
            ADV.begin_transaction!(b)
            @test ADV.lookup(b, "Other", 1)[2] == 0
            execute!(b, "Tabel_Upt 'T' + Kolom 'Extra' Dengan 'Extra = C(30&Null)' -:")
            ADV.commit!(b)
            ADV.update_key!(a, "Other", 1, Dict("V" => 2))
            adv_conflict(() -> ADV.commit!(a))
            ADV.rollback!(a)
            @test ADV.lookup(a, "Other", 1) == [1, 0]
        end
    end

    @testset "Drop-recreate can change primary key domain inside a transaction" begin
        adv_fixture() do a, b, directory
            ADV.with_transaction(a) do
                execute!(a, "Tabel_Rmv 'T' -:")
                execute!(a, "Buat Tabel 'T' Isi 'Id & V' Dengan 'Id = C(20&P) & V = I' -:")
                ADV.bulk_insert!(a, "T", [("new", 5)])
                @test ADV.lookup(a, "T", "new") == ["new", 5]
                ADV.update_key!(a, "T", "new", Dict("V" => 6))
                @test ADV.lookup(a, "T", "new") == ["new", 6]
            end
            @test ADV.lookup(b, "T", "new") == ["new", 6]
            reopened = Session(directory)
            execute!(reopened, "Pilih 'Audit' -:")
            @test ADV.lookup(reopened, "T", "new") == ["new", 6]
            close(reopened)
        end
    end

    @testset "Indexed predicates preserve cross-numeric comparison semantics" begin
        adv_fixture() do a, b, directory
            @test isempty(execute!(a, "Pilih '*' Dari 'T' Dengan 'Id = 1.5' -:").rows)
            @test execute!(a, "Tabel_Upt 'T' Isi 'V = 99' Dengan 'Id = 1.5' -:").rows[1][2] == 0
            @test execute!(a, "Baris_Rmv 'T' Dengan 'Id = 1.5' -:").rows[1][2] == 0
            @test ADV.scan_rows(a, "T") == [[1, 1], [2, 1]]
            @test execute!(a, "Pilih '*' Dari 'T' Dengan 'Id = 1.0' -:").rows == [[1, 1]]
        end
    end
end
