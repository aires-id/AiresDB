module AiresQLLogicalOrderTests

using Test
using AiresDB
using AiresDB.Internal

const LO = AiresDB

q(session, source) = execute!(session, source)
result_rows(session, source) = q(session, source).rows

function with_order_fixture(f::Function)
    mktempdir() do directory
        session = Session(directory)
        try
        q(session, "Buat 'Urut' -:")
        q(session, """
            Buat Tabel 'Karyawan'
            Isi 'ID & Nama & Divisi & Gaji'
            Dengan 'ID = I(P) & Nama = C & Divisi = C & Gaji = I' -:
            """)
        q(session, """
            Isi Tabel 'Karyawan'
            '1 & Deni & Teknik & 600'
            '2 & Budi & Teknik & 700'
            '3 & Cici & Operasi & 500'
            '4 & Aldi & Operasi & 700'
            '5 & Nila & NULL & NULL'
            '6 & Beni & Teknik & 700' -:
            """)
        f(session, directory)
        finally
            close(session)
            LO._close_page_stores_under!(directory)
        end
    end
end

names(rows) = [row[1] for row in rows]

@testset "AiresQL logical conditions and M ordering" begin
    @testset "Lexer, AST, precedence, and separator compatibility" begin
        @test [token.kind for token in LO.tokenize("& && &&& &: O: M: m:")][1:end-1] ==
            [:amp, :doubleamp, :tripleamp, :logicaland, :logicalor, :orderby, :orderby]
        @test LO.parse_expression("A = 1 &: B = 2") isa LO.LogicalAnd
        parsed = LO.parse_expression("A = 1 O: B = 2 &: C = 3")
        @test parsed isa LO.LogicalOr
        @test parsed.right isa LO.LogicalAnd
        parenthesized = LO.parse_expression("(A = 1 O: B = 2) &: C = 3")
        @test parenthesized isa LO.LogicalAnd
        @test parenthesized.left isa LO.LogicalOr
        projected = LO.parse_airesql("Pilih 'A = 1 &: B = 2' Dari 'T' -:")
        @test only(projected.expressions) isa LO.LogicalAnd
        query = LO.parse_airesql("Pilih 'Atas & Bawah' Dari 'T' m: 'Atas atas & Bawah BAWAH' Limit(2) -:")
        @test query isa LO.SelectQuery
        @test length(query.orders) == 2
        @test query.orders[1].direction == LO.SortAscending
        @test query.orders[2].direction == LO.SortDescending
        logical_order = LO.parse_airesql("Pilih 'A' Dari 'T' M: 'A = 1 &: B = 2 Bawah' -:")
        @test only(logical_order.orders).expression isa LO.LogicalAnd
        @test LO.parse_expression("Atas = 1") isa LO.BinaryExpr
        @test_throws AiresError LO.parse_expression("A = 1 &:")
        @test_throws AiresError LO.parse_expression("O: A = 1")
        @test_throws AiresError LO.parse_airesql("Pilih '*' Dari 'T' M: 'A Tengah' -:")
        @test_throws AiresError LO.parse_airesql("Pilih '*' Dari 'T' M: 'A' -:")
        @test_throws AiresError LO.parse_airesql("Pilih '*' Dari 'T' M: 'A ASC' -:")
        @test_throws AiresError LO.parse_airesql("Pilih '*' Dari 'T' M: 'A DESC' -:")
        @test_throws AiresError LO.parse_airesql("Pilih '*' Dari 'T' M: 'A Atas' M: 'B Bawah' -:")
    end

    with_order_fixture() do session, directory
        @testset "AND, OR, precedence, parentheses, and Boolean validation" begin
            @test names(result_rows(session, "Pilih 'Nama' Dari 'Karyawan' Dengan 'ID = 2 &: Gaji = 700' -:")) == ["Budi"]
            @test names(result_rows(session, "Pilih 'Nama' Dari 'Karyawan' Dengan 'ID = 1 O: ID = 3' -:")) == ["Deni", "Cici"]
            @test names(result_rows(session, "Pilih 'Nama' Dari 'Karyawan' Dengan 'ID = 1 o: ID = 3' -:")) == ["Deni", "Cici"]
            @test names(result_rows(session, "Pilih 'Nama' Dari 'Karyawan' Dengan 'ID = 1 O: Divisi = \"Teknik\" &: Gaji = 700' -:")) == ["Deni", "Budi", "Beni"]
            @test names(result_rows(session, "Pilih 'Nama' Dari 'Karyawan' Dengan '(ID = 1 O: Divisi = \"Teknik\") &: Gaji = 700' -:")) == ["Budi", "Beni"]
            @test names(result_rows(session, "Pilih 'Nama' Dari 'Karyawan' Dengan 'Divisi = \"TidakAda\" O: Divisi = NULL' -:")) == String[]
            @test_throws AiresError q(session, "Pilih 'Nama' Dari 'Karyawan' Dengan 'Gaji &: ID = 1' -:")
            @test_throws AiresError q(session, "Pilih 'Nama' Dari 'Karyawan' Dengan 'Gaji O: ID = 1' -:")
            q(session, "Tabel_Upt 'Karyawan' Isi 'Gaji = Gaji + 1' Dengan 'ID = 1 O: ID = 3' -:")
            @test result_rows(session, "Pilih 'Gaji' Dari 'Karyawan' Dengan 'ID = 1 O: ID = 3' M: 'ID Atas' -:") == [LO.Cell[601], LO.Cell[501]]
            q(session, "Tabel_Upt 'Karyawan' Isi 'Gaji = Gaji - 1' Dengan 'ID = 1 O: ID = 3' -:")
        end

        @testset "M sorting, NULL placement, projection independence, and Limit" begin
            @test names(result_rows(session, "Pilih 'Nama & Gaji' Dari 'Karyawan' M: 'Gaji Atas' -:")) ==
                ["Cici", "Deni", "Budi", "Aldi", "Beni", "Nila"]
            @test names(result_rows(session, "Pilih 'Nama' Dari 'Karyawan' M: 'Gaji Bawah' -:")) ==
                ["Nila", "Budi", "Aldi", "Beni", "Deni", "Cici"]
            @test names(result_rows(session, "Pilih 'Nama' Dari 'Karyawan' M: 'Nama Atas' -:")) ==
                ["Aldi", "Beni", "Budi", "Cici", "Deni", "Nila"]
            @test names(result_rows(session, "Pilih 'Nama' Dari 'Karyawan' m: 'Nama bawah' -:")) ==
                ["Nila", "Deni", "Cici", "Budi", "Beni", "Aldi"]
            @test names(result_rows(session, "Pilih 'Nama' Dari 'Karyawan' M: 'Divisi Atas & Gaji Bawah' -:")) ==
                ["Aldi", "Cici", "Budi", "Beni", "Deni", "Nila"]
            @test names(result_rows(session, "Pilih 'Nama' Dari 'Karyawan' M: 'Gaji Bawah' Limit(3) -:")) ==
                ["Nila", "Budi", "Aldi"]
            @test_throws AiresError q(session, "Pilih 'Nama' Dari 'Karyawan' M: 'KolomTidakAda Atas' -:")
            @test_throws AiresError q(session, "Pilih 'Divisi & Sum(Gaji)' Dari 'Karyawan' Grup Dari 'Divisi' M: 'Nama Atas' -:")
        end

        @testset "Aggregate, full combination, and persistent view ordering" begin
            grouped = result_rows(session, "Pilih 'Divisi & Sum(Gaji)' Dari 'Karyawan' Grup Dari 'Divisi' M: 'Sum(Gaji) Bawah' -:")
            @test grouped == [LO.Cell[nothing, nothing], LO.Cell["Teknik", 2000], LO.Cell["Operasi", 1200]]
            q(session, "Buat Tabel 'NamaDivisi' Isi 'Nama' Dengan 'Nama = C' -:")
            q(session, "Isi Tabel 'NamaDivisi' 'Teknik' 'Operasi' -:")
            joined = result_rows(session, """
                Pilih 'Karyawan.Nama && NamaDivisi.Nama'
                Dari 'Karyawan &&& NamaDivisi'
                Gabung Dengan 'Karyawan.Divisi = NamaDivisi.Nama'
                M: 'Karyawan.Gaji Bawah & NamaDivisi.Nama Atas' -:
                """)
            @test [row[1] for row in joined] == ["Aldi", "Budi", "Beni", "Deni", "Cici"]
            combined = result_rows(session, """
                Pilih 'Nama & Gaji & Divisi'
                Dari 'Karyawan'
                Dengan 'Gaji >= 600 &: (Divisi = \"Teknik\" O: Divisi = \"Operasi\")'
                M: 'Gaji Bawah & Nama Atas'
                Limit(3) -:
                """)
            @test [row[1] for row in combined] == ["Aldi", "Beni", "Budi"]
            q(session, """
                Lihat 'GajiTertinggi'
                Pilih 'Nama & Gaji'
                Dari 'Karyawan'
                Dengan 'Gaji > 500 &: (Divisi = \"Teknik\" O: Divisi = \"Operasi\")'
                M: 'Gaji Bawah & Nama Atas' -:
                """)
            @test names(result_rows(session, "Tampilkan 'GajiTertinggi' -:")) == ["Aldi", "Beni", "Budi", "Deni"]
            definition = session.database.views["GajiTertinggi"].query
            @test occursin("M:", LO.query_text(definition))
            @test occursin("&:", LO.query_text(definition))
            @test occursin("O:", LO.query_text(definition))
            reopened = Session(directory)
            q(reopened, "Pilih 'Urut' -:")
            @test names(result_rows(reopened, "Tampilkan 'GajiTertinggi' -:")) == ["Aldi", "Beni", "Budi", "Deni"]
            close(reopened)
        end

        @testset "CLI reports new syntax errors without a stack trace" begin
            for source in (
                "Pilih 'Nama' Dari 'Karyawan' M: 'Gaji Tengah' -:\n",
                "Pilih 'Nama' Dari 'Karyawan' Dengan 'ID = 1 &:' -:\n",
                "Pilih 'Nama' Dari 'Karyawan' Dengan 'O: ID = 1' -:\n",
            )
                error = try
                    execute!(session, source)
                    nothing
                catch caught
                    caught
                end
                @test error isa AiresError
                @test occursin("AiresQL", sprint(showerror, error))
                @test !occursin("Stacktrace", sprint(showerror, error))
            end
        end
    end
end

end
