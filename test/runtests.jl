using Test
using AiresDB
using AiresDB.Internal
using Dates
using SHA

const A = AiresDB
q(s,text) = execute!(s,text)
rows(s,text) = q(s,text).rows
allrows(s,table) = rows(s,"Tampilkan '$table' -:")

function fresh(f::Function)
    mktempdir() do dir
        # Windows CI may return an 8.3 spelling while Engine canonicalizes to
        # the long path. Keep fixture expectations and cleanup on one identity.
        dir = realpath(dir)
        session = Session(dir)
        try
            q(session,"Buat 'Perusahaan' -:")
            f(session,dir)
        finally
            close(session)
            # A fixture may switch databases, leaving a prior page sidecar in
            # the process registry. Close all fixture-owned stores before the
            # Windows temporary directory is removed.
            A._close_page_stores_under!(dir)
        end
    end
end

function employees(s)
    q(s,"""
        Buat Tabel 'Karyawan'
        Isi 'No & Nama & Gaji & Email & Divisi'
        Dengan 'No = I(P) & Nama = C(225&Not Null) & Gaji = U & Email = C(225&N) & Divisi = C'
        Auto_No -:
        """)
    q(s,"""
        Isi Tabel 'Karyawan'
        'Aires & 7500000 & aires@email.com & Teknik'
        'Fami & 6500000 & fami@email.com & Teknik'
        'Saki & 5500000 & saki@email.com & Operasi' -:
        """)
end

function error_contains(f::Function,text::String; category=nothing)
    e = try f(); nothing catch e; e end
    @test e isa AiresError
    if e isa AiresError
        @test occursin(text,e.message)
        category === nothing || @test e.category == category
    end
end

@testset "AiresDB v0.1.0" begin
    @testset "Lexer, terminator, multiline, parser, AST" begin
        @test A.parse_airesql("bUaT 'X' -:") isa A.CreateDatabase
        @test A.parse_airesql("Pilih 'X' -:") isa A.UseDatabase
        @test A.parse_airesql("pILih '*'\nDaRi 'X'\n-:") isa A.SelectQuery
        @test A.parse_airesql("Tampilkan 'X' -:") isa A.SelectQuery
        @test_throws AiresError A.parse_airesql("Buat 'X'")
        @test_throws AiresError A.parse_airesql("Buat 'X';")
        @test_throws AiresError A.parse_airesql("Buat 'X' -: Pilih 'X' -:")
        @test_throws AiresError A.parse_airesql("Pilih '*' Dari 'X' Limit(-1) -:")
        @test_throws AiresError A.parse_airesql("Pilih '*' Dari 'X' Limit(1.5) -:")
        @test_throws AiresError A.parse_airesql("Pilih '*' Dari 'X' Limit(1) Limit(2) -:")
        @test_throws AiresError A.parse_airesql("TidakDikenal 'X' -:")
        @test_throws AiresError A.parse_airesql("Pilih 'x +' Dari 'T' -:")
        @test_throws AiresError A.parse_airesql("Pilih '(x' Dari 'T' -:")
        @test_throws AiresError A.tokenize("'belum selesai")
        @test_throws AiresError A.tokenize("&&&&")
        @test_throws AiresError A.tokenize("@")
        @test [t.kind for t in A.tokenize("& && &&& () + - * / = > < >= <= -:")][1:end-1] ==
            [:amp,:doubleamp,:tripleamp,:lparen,:rparen,:plus,:minus,:star,:slash,:eq,:gt,:lt,:ge,:le,:endstmt]
        @test A.tokenize("'O''Brien'")[1].text == "O'Brien"
        @test A.split_fields("A & C(25&Not Null) & \"x & y\"") == ["A","C(25&Not Null)","\"x & y\""]
        @test A.split_fields("a && b"; widths=(1,2)) == ["a","b"]
        @test_throws AiresError A.split_fields("a && b")
        parts,tail = A.split_statements("# ignored -:\nBuat 'A-:B' -:\nPilih 'A' -: tail")
        @test length(parts) == 2
        @test strip(tail) == "tail"
        @test A.parse_expression("2 + 3 * 4") isa A.BinaryExpr
        @test_throws AiresError A.parse_expression(repeat("(",130)*"1"*repeat(")",130))
        @test_throws AiresError A.parse_expression(join(fill("1",130)," + "))
        for bad in ("Pilih '' Dari 'T' -:","Buat Tabel 'T' Isi 'A' Dengan 'B = I' -:",
                    "Buat Tabel 'T' Isi 'A & B' Dengan 'A = I' -:")
            @test_throws AiresError A.parse_airesql(bad)
        end
    end

    @testset "Type and constraint parsing" begin
        for kind in ("D","B","F","I","C","T","W","Tw","U")
            c = A.parse_column_definition("Value = $kind")
            @test c.kind == Symbol(uppercase(kind))
            @test c.nullable
        end
        @test A.parse_column_definition("Nama = C").max_length == 255
        @test A.parse_column_definition("Nama = c(225&n&Not Null)").unique
        @test !A.parse_column_definition("No = i(p)").nullable
        @test A.parse_column_definition("Nama = C(Null)").nullable
        for definition in ("X = Z","X = I(20)","X = C(0)","X = C(2&2)",
            "X = I(P&Null)","X = C(Null&Not Null)","X = C(N&N)","X = C(Required)")
            @test_throws AiresError A.parse_column_definition(definition)
        end
    end

    @testset "Database creation, naming and headers" begin
        fresh() do s,dir
            path = joinpath(dir,"Perusahaan.aires")
            @test isfile(path)
            @test read(path)[1:8] == collect(A.WAL_MAGIC)
            @test_throws AiresError q(s,"Buat 'Perusahaan' -:")
            @test_throws AiresError q(s,"Pilih 'TidakAda' -:")
            @test_throws AiresError q(s,"Buat '../escape' -:")
            @test_throws AiresError q(s,"Buat 'Wrong.ext' -:")
            @test_throws AiresError q(s,"Buat 'CON' -:")
            @test_throws AiresError q(s,"Buat 'NUL' -:")
            q(s,"Pilih 'Perusahaan.aires' -:")
            @test s.path == path
            write(joinpath(dir,"Invalid.aires"),"wrong header")
            error_contains(()->q(s,"Pilih 'Invalid' -:"),"bukan file AiresDB"; category="Storage Error")
            @test s.path == path
            q(s,"Buat 'Keuangan' -:")
            @test isfile(joinpath(dir,"Keuangan.aires"))
            @test isempty(s.database.tables)
            @test all(endswith(n,".aires") || endswith(n,".aires.lock") || endswith(n,".aires.pages") for n in readdir(dir))
            @test all(filesize(joinpath(dir,n)) == 0 for n in readdir(dir) if endswith(n,".aires.lock"))
        end
        mktempdir() do dir
            s = Session(dir)
            @test_throws AiresError q(s,"Tampilkan 'X' -:")
            @test_throws AiresError q(s,"Transaksi -:")
        end
    end

    @testset "Insert, auto increment and statement atomicity" begin
        fresh() do s,dir
            employees(s)
            @test length(allrows(s,"Karyawan")) == 3
            @test [r[1] for r in allrows(s,"Karyawan")] == [1,2,3]
            @test allrows(s,"Karyawan")[1][2] == "Aires"
            @test allrows(s,"Karyawan")[1][3] == Money(Int128(750000000))
            original = read(s.path)
            @test_throws AiresError q(s,"Isi Tabel 'Karyawan' 'Valid & 1 & unique@email.com & X' 'Invalid & 2 & aires@email.com & X' -:")
            @test read(s.path) == original
            @test length(allrows(s,"Karyawan")) == 3
            @test_throws AiresError q(s,"Isi Tabel 'Karyawan' 'A & 3' -:")
            @test_throws AiresError q(s,"Isi Tabel 'Karyawan' '4 & A & 3 & a@b & X' -:")
            q(s,"Isi Tabel 'Karyawan' 'Nana & 1 & NULL & X' -:")
            @test last(allrows(s,"Karyawan"))[1] == 4
            q(s,"Buat Tabel 'Other' Isi 'ID & Nama' Dengan 'ID = I(P) & Nama = C' Auto_(ID) -:")
            q(s,"Isi Tabel 'Other' 'Hello' -:")
            @test allrows(s,"Other")[1][1] == 1
            @test_throws AiresError q(s,"Buat Tabel 'BadAuto' Isi 'ID' Dengan 'ID = C' Auto_ID -:")
            @test_throws AiresError q(s,"Buat Tabel 'BadAuto' Isi 'ID' Dengan 'ID = I' Auto_X -:")
            @test_throws AiresError q(s,"Buat Tabel 'Duplicate' Isi 'A & A' Dengan 'A = I & A = C' -:")
        end
    end

    @testset "All data types, exact money, NULL and length" begin
        fresh() do s,dir
            q(s,"Buat Tabel 'Types' Isi 'ID & Dv & Bv & Fv & Cv & Tv & Wv & TWv & Uv' Dengan 'ID = I(P) & Dv = D & Bv = B & Fv = F & Cv = C(3) & Tv = T & Wv = W & TWv = Tw & Uv = U' -:")
            q(s,"Isi Tabel 'Types' '1 & 0.123456789012345678 & true & 1.5e2 & 猫犬鳥 & 2026-09-02 & 23:30:00.123456789 & 2026-09-02 23:30:00.123 & 90071992547409.91' -:")
            row = only(allrows(s,"Types"))
            @test row == A.Cell[1,Decimal("0.123456789012345678"),true,150.0,"猫犬鳥",Date(2026,9,2),Time(23,30,0,123,456,789),DateTime(2026,9,2,23,30,0,123),Money(Int128(9007199254740991))]
            s2 = Session(dir); q(s2,"Pilih 'Perusahaan' -:")
            @test only(allrows(s2,"Types")) == row
            q(s,"Isi Tabel 'Types' '2 & NULL & NULL & NULL & NULL & NULL & NULL & NULL & NULL' -:")
            @test all(isnothing,allrows(s,"Types")[2][2:end])
            @test_throws AiresError q(s,"Isi Tabel 'Types' '3 & 1 & false & 2 & abcd & 2026-09-02 & 23:00:00 & 2026-09-02 23:00:00 & 3' -:")
            q(s,"Buat Tabel 'Strings' Isi 'S' Dengan 'S = C(10&Not Null)' -:")
            q(s,"Isi Tabel 'Strings' '\"a & b\"' 'O''Brien' '\"NULL\"' '\"\"' -:")
            @test [r[1] for r in allrows(s,"Strings")] == ["a & b","O'Brien","NULL",""]
            @test_throws AiresError q(s,"Isi Tabel 'Strings' 'NULL' -:")
            @test_throws AiresError q(s,"Isi Tabel 'Strings' '' -:")
            q(s,"Buat Tabel 'Defaults' Isi 'S' Dengan 'S = C' -:")
            q(s,"Isi Tabel 'Defaults' '$(repeat("x",255))' -:")
            @test_throws AiresError q(s,"Isi Tabel 'Defaults' '$(repeat("x",256))' -:")
            for (kind,bad) in [("I","1.5"),("I","abc"),("I","9223372036854775808"),("D","0.1234567890123456789"),
                 ("B","maybe"),("F","NaN"),("F","Inf"),("T","2026-02-30"),("W","25:00:00"),
                 ("Tw","2026-02-30 01:00:00"),("U","1.001"),("U","abc")]
                c = A.parse_column_definition("Value = $kind")
                @test_throws AiresError A.coerce_value(c,bad)
            end
            @test string(Decimal("-0.0100")) == "-0.01"
            @test A.coerce_value(A.parse_column_definition("V = U"),"-0.01").minor == -1
        end
    end

    @testset "Primary, composite primary and unique constraints" begin
        fresh() do s,dir
            q(s,"Buat Tabel 'Keys' Isi 'A & B & U' Dengan 'A = I(P) & B = T(P) & U = C(N)' -:")
            q(s,"Isi Tabel 'Keys' '1 & 2026-09-01 & one' '1 & 2026-09-02 & NULL' '2 & 2026-09-01 & NULL' -:")
            @test length(allrows(s,"Keys")) == 3
            error_contains(()->q(s,"Isi Tabel 'Keys' '1 & 2026-09-01 & two' -:"),"Primary Key")
            error_contains(()->q(s,"Isi Tabel 'Keys' '3 & 2026-09-03 & one' -:"),"harus unik")
            error_contains(()->q(s,"Isi Tabel 'Keys' 'NULL & 2026-09-04 & four' -:"),"tidak boleh NULL")
            @test_throws AiresError q(s,"Kolom_Rmv 'Keys.B' -:")
            q(s,"Buat Tabel 'Single' Isi 'ID' Dengan 'ID = I(P)' -:")
            q(s,"Isi Tabel 'Single' '1' -:")
            @test_throws AiresError q(s,"Isi Tabel 'Single' '1' -:")
            @test_throws AiresError q(s,"Isi Tabel 'Single' '2' '2' -:")
            @test length(allrows(s,"Single")) == 1
        end
    end

    @testset "SELECT, comparisons, arithmetic and errors" begin
        fresh() do s,dir
            employees(s)
            @test q(s,"Pilih 'Nama & Gaji' Dari 'Karyawan' -:").columns == ["Nama","Gaji"]
            @test length(rows(s,"Pilih '*' Dari 'Karyawan' Dengan 'Gaji > 6000000' -:")) == 2
            for (op,n) in [("=",1),(">",1),("<",1),(">=",2),("<=",2)]
                @test length(rows(s,"Pilih '*' Dari 'Karyawan' Dengan 'Gaji $op 6500000' -:")) == n
            end
            @test rows(s,"Pilih 'Nama' Dari 'Karyawan' Dengan 'Nama = \"Aires\"' -:") == [A.Cell["Aires"]]
            @test rows(s,"Pilih 'Gaji * 12' Dari 'Karyawan' Dengan 'No = 1' -:")[1][1] == 90000000
            @test rows(s,"Pilih '2 + 3 * 4 & (2 + 3) * 4 & -2 + 5 & 10 / 4' Dari 'Karyawan' Limit(1) -:")[1] == A.Cell[14,20,3,big(5)//big(2)]
            @test A.arithmetic(:plus,typemax(Int64),Int64(1)) == big(typemax(Int64)) + 1
            @test A.arithmetic(:slash,typemin(Int64),Int64(-1)) == -big(typemin(Int64))
            @test A.arithmetic(:plus,typemax(Int64),Int64(1)) == big(typemax(Int64)) + 1
            @test A.arithmetic(:minus,typemin(Int64),Int64(1)) == big(typemin(Int64)) - 1
            @test A.arithmetic(:star,typemax(Int64),Int64(2)) == big(typemax(Int64)) * 2
            @test A.arithmetic(:slash,typemin(Int64),Int64(-1)) == -big(typemin(Int64))
            @test A.arithmetic(:slash,Int64(6),Int64(3)) === Int64(2)
            @test rows(s,"Pilih '0.1 + 0.2 & Gaji + 0.01 - Gaji' Dari 'Karyawan' Limit(1) -:")[1] == A.Cell[big(3)//big(10),big(1)//big(100)]
            @test length(rows(s,"Pilih '*' Dari 'Karyawan' Limit(2) -:")) == 2
            @test isempty(rows(s,"Pilih '*' Dari 'Karyawan' Limit(0) -:"))
            for query in ("Pilih 'Umurr' Dari 'Karyawan' -:","Pilih '*' Dari 'Missing' -:",
                "Pilih '*' Dari 'Karyawan' Dengan 'Missing > 0' -:","Pilih 'Nama + 1' Dari 'Karyawan' -:",
                "Pilih 'Gaji / 0' Dari 'Karyawan' -:","Pilih '*' Dari 'Karyawan' Dengan 'Gaji' -:",
                "Pilih 'Unknown(No)' Dari 'Karyawan' -:","Pilih 'Count(*)' Dari 'Karyawan' Dengan 'Count(*) > 0' -:",
                "Pilih 'Gaji' Dari 'Karyawan' Dengan 'Gaji = \"text\"' -:")
                @test_throws AiresError q(s,query)
            end
            error_contains(()->q(s,"Pilih 'Integral(Gaji)' Dari 'Karyawan' -:"),"Integral belum tersedia pada AiresDB v0.1.")
            q(s,"Buat Tabel 'Empty' Isi 'Value' Dengan 'Value = I' -:")
            @test_throws AiresError q(s,"Pilih 'Missing' Dari 'Empty' -:")
            @test_throws AiresError q(s,"Pilih 'Integral(Value)' Dari 'Empty' -:")
            @test_throws AiresError q(s,"Pilih 'Value + \"bad\"' Dari 'Empty' -:")
            @test_throws AiresError q(s,"Tabel_Upt 'Empty' Isi 'Value = \"text\"' -:")
            q(s,"Isi Tabel 'Empty' 'NULL' -:")
            @test isempty(rows(s,"Pilih '*' Dari 'Empty' Dengan 'Value = NULL' -:"))
            @test rows(s,"Pilih 'Value + 1' Dari 'Empty' -:") == [A.Cell[nothing]]
        end
    end

    @testset "Aggregates and grouping" begin
        fresh() do s,dir
            employees(s)
            result = rows(s,"Pilih 'Count(*) & Countif(Gaji > 6000000) & Sum(Gaji) & Avg(Gaji) & Min(Gaji) & Max(Gaji)' Dari 'Karyawan' -:")
            @test length(result) == 1
            @test result[1][1:4] == A.Cell[3,2,19500000,6500000]
            @test A.exact(result[1][5]) == 5500000
            @test A.exact(result[1][6]) == 7500000
            grouped = rows(s,"Pilih 'Divisi & Count(*) & Sum(Gaji) & Avg(Gaji) & Min(Gaji) & Max(Gaji) & Countif(Gaji > 7000000)' Dari 'Karyawan' Grup Dari 'Divisi' -:")
            @test length(grouped) == 2
            @test grouped[1][1:4] == A.Cell["Teknik",2,14000000,7000000]
            @test grouped[2][1:4] == A.Cell["Operasi",1,5500000,5500000]
            @test grouped[1][7] == 1
            @test length(rows(s,"Pilih 'Divisi & Sum(Gaji)' Dari 'Karyawan' Grup Dari 'Divisi' Limit(1) -:")) == 1
            @test length(rows(s,"Pilih 'Divisi' Dari 'Karyawan' Grup Dari 'Divisi' -:")) == 2
            @test rows(s,"Pilih 'Sum(Gaji) / Count(*)' Dari 'Karyawan' -:")[1][1] == 6500000
            for query in ("Pilih 'Nama & Sum(Gaji)' Dari 'Karyawan' -:","Pilih 'Nama & Sum(Gaji)' Dari 'Karyawan' Grup Dari 'Divisi' -:",
                "Pilih 'Sum(Avg(Gaji))' Dari 'Karyawan' -:","Pilih 'Countif(Gaji)' Dari 'Karyawan' -:",
                "Pilih 'Sum(Nama)' Dari 'Karyawan' -:","Pilih 'Sum(*)' Dari 'Karyawan' -:",
                "Pilih 'Count()' Dari 'Karyawan' -:","Pilih 'Count(Gaji & No)' Dari 'Karyawan' -:",
                "Pilih 'Sum(Gaji)' Dari 'Karyawan' Grup Dari 'Sum(No)' -:")
                @test_throws AiresError q(s,query)
            end
            q(s,"Buat Tabel 'Empty' Isi 'V & K' Dengan 'V = I & K = C' -:")
            @test rows(s,"Pilih 'Count(*) & Sum(V) & Avg(V) & Min(V) & Max(V) & Countif(V > 1)' Dari 'Empty' -:") == [A.Cell[0,nothing,nothing,nothing,nothing,0]]
            @test isempty(rows(s,"Pilih 'K & Sum(V)' Dari 'Empty' Grup Dari 'K' -:"))
            q(s,"Isi Tabel 'Empty' 'NULL & NULL' '3 & NULL' '6 & A' -:")
            @test rows(s,"Pilih 'Count(*) & Count(V) & Sum(V) & Avg(V)' Dari 'Empty' -:") == [A.Cell[3,2,9,big(9)//big(2)]]
            @test length(rows(s,"Pilih 'K & Count(*)' Dari 'Empty' Grup Dari 'K' -:")) == 2
        end
    end

    @testset "Update, add/remove columns, row deletion and drop" begin
        fresh() do s,dir
            employees(s)
            q(s,"Tabel_Upt 'Karyawan' Isi 'Gaji = 9000000 & Nama = Aires Zam' Dengan 'No = 1' -:")
            @test allrows(s,"Karyawan")[1][2] == "Aires Zam"
            @test A.exact(allrows(s,"Karyawan")[1][3]) == 9000000
            q(s,"Tabel_Upt 'Karyawan' Isi 'Gaji = Gaji + 0.01' Dengan 'No = 1' -:")
            @test allrows(s,"Karyawan")[1][3].minor == 900000001
            before = read(s.path)
            for query in ("Tabel_Upt 'Karyawan' Isi 'No = 1' Dengan 'No = 2' -:",
                "Tabel_Upt 'Karyawan' Isi 'Email = \"aires@email.com\"' Dengan 'No = 2' -:",
                "Tabel_Upt 'Karyawan' Isi 'Nama = NULL' Dengan 'No = 1' -:",
                "Tabel_Upt 'Karyawan' Isi 'Gaji = Gaji / 3' Dengan 'No = 1' -:",
                "Tabel_Upt 'Karyawan' Isi 'Missing = 1' -:","Tabel_Upt 'Karyawan' Isi 'Gaji = Missing' -:",
                "Tabel_Upt 'Karyawan' Isi 'Gaji = 1 & Gaji = 2' -:")
                @test_throws AiresError q(s,query)
                @test read(s.path) == before
            end
            q(s,"Tabel_Upt 'Karyawan' + Kolom 'Telepon' Dengan 'Telepon = C(20&Null)' -:")
            @test all(isnothing(r[end]) for r in allrows(s,"Karyawan"))
            @test_throws AiresError q(s,"Tabel_Upt 'Karyawan' + Kolom 'Wajib' Dengan 'Wajib = C(Not Null)' -:")
            @test_throws AiresError q(s,"Tabel_Upt 'Karyawan' + Kolom 'Nama' Dengan 'Nama = C' -:")
            q(s,"Kolom_Rmv 'Karyawan.Telepon' -:")
            @test length(q(s,"Tampilkan 'Karyawan' -:").columns) == 5
            @test_throws AiresError q(s,"Kolom_Rmv 'Karyawan.No' -:")
            @test_throws AiresError q(s,"Kolom_Rmv 'Karyawan.Missing' -:")
            q(s,"Baris_Rmv 'Karyawan' Dengan 'No = 3' -:")
            @test [r[1] for r in allrows(s,"Karyawan")] == [1,2]
            q(s,"Isi Tabel 'Karyawan' 'Next & 1 & next@e.com & X' -:")
            @test last(allrows(s,"Karyawan"))[1] == 4
            q(s,"Tabel_Upt 'Karyawan' Isi 'No = 10' Dengan 'No = 4' -:")
            q(s,"Isi Tabel 'Karyawan' 'After & 1 & after@e.com & X' -:")
            @test last(allrows(s,"Karyawan"))[1] == 11
            q(s,"Baris_Rmv 'Karyawan' -:")
            @test isempty(allrows(s,"Karyawan"))
            q(s,"Tabel_Upt 'Karyawan' + Kolom 'Required' Dengan 'Required = I(Not Null)' -:")
            q(s,"Tabel_Rmv 'Karyawan' -:")
            @test_throws AiresError q(s,"Tampilkan 'Karyawan' -:")
            @test_throws AiresError q(s,"Tabel_Rmv 'Karyawan' -:")
            q(s,"Buat Tabel 'One' Isi 'Value' Dengan 'Value = I' -:")
            @test_throws AiresError q(s,"Kolom_Rmv 'One.Value' -:")
        end
    end

    @testset "Equality inner join and live persistent views" begin
        fresh() do s,dir
            q(s,"Buat Tabel 'Karyawan' Isi 'No & Nama & DivisiID & Gaji' Dengan 'No = I(P) & Nama = C & DivisiID = I & Gaji = U' -:")
            q(s,"Buat Tabel 'Divisi' Isi 'ID & NamaDivisi' Dengan 'ID = I & NamaDivisi = C' -:")
            q(s,"Isi Tabel 'Karyawan' '1 & Aires & 1 & 7500000' '2 & Fami & 2 & 6500000' '3 & Saki & 9 & 5500000' '4 & Null & NULL & 1' -:")
            q(s,"Isi Tabel 'Divisi' '1 & Teknik' '2 & Operasi' '2 & Tambahan' 'NULL & Kosong' -:")
            joined = rows(s,"Pilih 'Karyawan.Nama && Divisi.NamaDivisi' Dari 'Karyawan &&& Divisi' Gabung Dengan 'Karyawan.DivisiID = Divisi.ID' -:")
            @test joined == [A.Cell["Aires","Teknik"],A.Cell["Fami","Operasi"],A.Cell["Fami","Tambahan"]]
            @test A._join_build_side([A.Cell[1]],[A.Cell[1],A.Cell[2]]) == :left
            q(s,"Buat Tabel 'TinyLeft' Isi 'K' Dengan 'K = I' -:")
            q(s,"Buat Tabel 'WideRight' Isi 'K & V' Dengan 'K = I & V = C' -:")
            q(s,"Isi Tabel 'TinyLeft' '2' '1' -:")
            q(s,"Isi Tabel 'WideRight' '1 & satu' '2 & dua' '2 & dua-b' -:")
            planned_join = rows(s,"Pilih 'TinyLeft.K && WideRight.V' Dari 'TinyLeft &&& WideRight' Gabung Dengan 'TinyLeft.K = WideRight.K' -:")
            @test planned_join == [A.Cell[2,"dua"],A.Cell[2,"dua-b"],A.Cell[1,"satu"]]
            q(s,"Buat Tabel 'IndexLeft' Isi 'K' Dengan 'K = I' -:")
            q(s,"Buat Tabel 'IndexRight' Isi 'K & V' Dengan 'K = I(P) & V = C' -:")
            q(s,"Isi Tabel 'IndexLeft' '2' '1' -:")
            q(s,"Isi Tabel 'IndexRight' '1 & satu' '2 & dua' '3 & tiga' -:")
            indexed_join = rows(s,"Pilih 'IndexLeft.K && IndexRight.V' Dari 'IndexLeft &&& IndexRight' Gabung Dengan 'IndexLeft.K = IndexRight.K' -:")
            @test indexed_join == [A.Cell[2,"dua"],A.Cell[1,"satu"]]
            planned = A.parse_airesql("Pilih '*' Dari 'Karyawan &&& Divisi' Gabung Dengan 'Karyawan.DivisiID = Divisi.ID' Dengan 'Karyawan.Gaji > 7000000 &: Divisi.ID = 1' -:")
            planned_schema,_,_ = A.validate_query(s.database,planned)
            left_filters,right_filters,residual = A._push_join_filters(planned.condition,planned_schema,"Karyawan","Divisi")
            @test length(left_filters) == 1
            @test length(right_filters) == 1
            @test isempty(residual)
            @test A.point_key(A.parse_expression("No = 2 &: Gaji > 1"),s.database.tables["Karyawan"]) == (2,)
            @test length(rows(s,"Pilih '*' Dari 'Karyawan &&& Divisi' Gabung Dengan 'Divisi.ID = Karyawan.DivisiID' Dengan 'Karyawan.Gaji > 7000000' -:")) == 1
            @test_throws AiresError q(s,"Pilih '*' Dari 'Karyawan &&& Divisi' -:")
            @test_throws AiresError q(s,"Pilih '*' Dari 'Karyawan &&& Divisi' Gabung Dengan 'Karyawan.DivisiID > Divisi.ID' -:")
            @test_throws AiresError q(s,"Pilih '*' Dari 'Karyawan &&& Divisi' Gabung Dengan 'Karyawan.No = Karyawan.DivisiID' -:")
            @test_throws AiresError q(s,"Pilih '*' Dari 'Karyawan &&& Karyawan' Gabung Dengan 'No = No' -:")
            q(s,"Lihat 'GajiTinggi' Pilih 'Nama & Gaji' Dari 'Karyawan' Dengan 'Gaji > 6000000' -:")
            @test length(allrows(s,"GajiTinggi")) == 2
            q(s,"Tabel_Upt 'Karyawan' Isi 'Gaji = 1' Dengan 'No = 2' -:")
            @test length(allrows(s,"GajiTinggi")) == 1
            q(s,"Lihat 'Nested' Pilih 'Nama' Dari 'GajiTinggi' -:")
            @test allrows(s,"Nested") == [A.Cell["Aires"]]
            @test_throws AiresError q(s,"Kolom_Rmv 'Karyawan.Gaji' -:")
            @test_throws AiresError q(s,"Tabel_Rmv 'Karyawan' -:")
            @test_throws AiresError q(s,"Lihat 'Karyawan' Pilih '*' Dari 'Divisi' -:")
            @test_throws AiresError q(s,"Lihat 'Self' Pilih '*' Dari 'Self' -:")
            @test_throws AiresError q(s,"Lihat 'Bad' Pilih 'Nama & Nama' Dari 'Karyawan' -:")
            s2 = Session(dir); q(s2,"Pilih 'Perusahaan' -:")
            @test allrows(s2,"Nested") == [A.Cell["Aires"]]
            @test length(allrows(s2,"GajiTinggi")) == 1
            q(s,"Buat Tabel 'Ambiguous' Isi 'No' Dengan 'No = I' -:")
            @test_throws AiresError q(s,"Pilih 'No' Dari 'Karyawan &&& Ambiguous' Gabung Dengan 'Karyawan.No = Ambiguous.No' -:")
        end
    end

    @testset "Transactions: commit, rollback, DDL, failures and visibility" begin
        fresh() do s,dir
            q(s,"Buat Tabel 'Rekening' Isi 'No & Saldo' Dengan 'No = I(P) & Saldo = U' -:")
            q(s,"Isi Tabel 'Rekening' '1 & 1000000' '2 & 2000000' -:")
            original = read(s.path)
            q(s,"Transaksi -:")
            q(s,"Tabel_Upt 'Rekening' Isi 'Saldo = Saldo - 500000' Dengan 'No = 1' -:")
            q(s,"Tabel_Upt 'Rekening' Isi 'Saldo = Saldo + 500000' Dengan 'No = 2' -:")
            @test A.exact(allrows(s,"Rekening")[1][2]) == 500000
            @test read(s.path) == original
            observer = Session(dir); q(observer,"Pilih 'Perusahaan' -:")
            @test A.exact(allrows(observer,"Rekening")[1][2]) == 1000000
            @test_throws AiresError q(s,"Transaksi -:")
            @test_throws AiresError q(s,"Pilih 'Perusahaan' -:")
            @test_throws AiresError q(s,"Buat 'Other' -:")
            q(s,"Gabungkan -:")
            q(observer,"Pilih 'Perusahaan' -:")
            @test A.exact(allrows(observer,"Rekening")[2][2]) == 2500000
            q(s,"Transaksi -:")
            q(s,"Baris_Rmv 'Rekening' -:")
            q(s,"Buat Tabel 'Temporary' Isi 'ID' Dengan 'ID = I' -:")
            q(s,"Kembalikan -:")
            @test length(allrows(s,"Rekening")) == 2
            @test_throws AiresError q(s,"Tampilkan 'Temporary' -:")
            q(s,"Transaksi -:")
            q(s,"Tabel_Upt 'Rekening' Isi 'Saldo = 100' Dengan 'No = 1' -:")
            @test_throws AiresError q(s,"Isi Tabel 'Rekening' '1 & 999' -:")
            @test A.exact(allrows(s,"Rekening")[1][2]) == 100
            q(s,"Gabungkan -:")
            @test_throws AiresError q(s,"Gabungkan -:")
            @test_throws AiresError q(s,"Kembalikan -:")
            @test !A.in_transaction(s)
        end
        fresh() do s,dir
            employees(s)
            q(s,"Transaksi -:")
            q(s,"Isi Tabel 'Karyawan' 'Rollback & 1 & rollback@e.com & X' -:")
            q(s,"Kembalikan -:")
            q(s,"Isi Tabel 'Karyawan' 'Commit & 1 & commit@e.com & X' -:")
            @test last(allrows(s,"Karyawan"))[1] == 4
        end
    end

    @testset "WAL recovery, transaction conflicts and failed publication" begin
        fresh() do s,dir
            employees(s)
            bytes = read(s.path)
            for (i,corrupt) in enumerate([UInt8[],bytes[1:10],bytes[1:end-1],vcat(bytes,UInt8[0]),copy(bytes),copy(bytes)])
                i == 5 && (corrupt[9] = 0xff)
                i == 6 && (corrupt[end] ⊻= 0x01)
                path = joinpath(dir,"Corrupt$i.aires")
                write(path,corrupt)
                candidate = Session(dir)
                if i == 3
                    # A physically incomplete final record is ignored. The
                    # preceding CREATE TABLE commit remains visible, while the
                    # interrupted INSERT does not become visible.
                    q(candidate,"Pilih 'Corrupt$i' -:")
                    @test A.wal_read(path).torn_tail
                    @test isempty(allrows(candidate,"Karyawan"))
                else
                    # Complete-frame damage, invalid trailing bytes and damaged
                    # headers are corruption rather than recoverable torn tails.
                    @test_throws AiresError q(candidate,"Pilih 'Corrupt$i' -:")
                end
                close(candidate)
            end
            observer = Session(dir); q(observer,"Pilih 'Perusahaan' -:")
            q(observer,"Transaksi -:")
            @test A.exact(allrows(observer,"Karyawan")[1][3]) == 7500000
            q(s,"Tabel_Upt 'Karyawan' Isi 'Gaji = 42' Dengan 'No = 1' -:")
            current = read(s.path)
            q(observer,"Baris_Rmv 'Karyawan' -:")
            @test read(s.path) == current
            @test isempty(allrows(observer,"Karyawan"))
            conflict = try q(observer,"Gabungkan -:"); nothing catch e; e end
            @test conflict isa AiresError
            conflict isa AiresError && @test conflict.category == "Transaction Conflict"
            @test A.in_transaction(observer)
            @test read(s.path) == current
            q(observer,"Kembalikan -:")
            @test length(allrows(observer,"Karyawan")) == 3
            @test A.exact(allrows(observer,"Karyawan")[1][3]) == 42
            @test isfile(s.path*".lock")
            @test filesize(s.path*".lock") == 0
            @test all(endswith(n,".aires") || endswith(n,".aires.lock") || endswith(n,".aires.pages") for n in readdir(dir))
            @test !any(startswith(n,".") for n in readdir(dir))
            small = Session(dir; storage=A.BinaryRowStore(128))
            @test_throws AiresError q(small,"Pilih 'Perusahaan' -:")
            corruptdb = deepcopy(s.database)
            push!(corruptdb.tables["Karyawan"].rows,copy(first(corruptdb.tables["Karyawan"].rows)))
            write(joinpath(dir,"BadConstraint.aires"),A.encode_database(A.BinaryRowStore(),corruptdb))
            @test_throws AiresError q(s,"Pilih 'BadConstraint' -:")
            corruptdb = deepcopy(s.database)
            corruptdb.tables["Karyawan"].next_ids["No"] = 1
            write(joinpath(dir,"BadSequence.aires"),A.encode_database(A.BinaryRowStore(),corruptdb))
            @test_throws AiresError q(s,"Pilih 'BadSequence' -:")
        end
    end

    @testset "Numeric equality keys and row update atomicity" begin
        fresh() do s,dir
            q(s,"Buat Tabel 'Numbers' Isi 'ID & V' Dengan 'ID = I(P) & V = F(N)' -:")
            q(s,"Isi Tabel 'Numbers' '1 & -0.0' -:")
            @test_throws AiresError q(s,"Isi Tabel 'Numbers' '2 & 0.0' -:")
            q(s,"Buat Tabel 'OtherNumbers' Isi 'V' Dengan 'V = F' -:")
            q(s,"Isi Tabel 'OtherNumbers' '0.0' '-0.0' -:")
            @test rows(s,"Pilih 'Count(*)' Dari 'Numbers &&& OtherNumbers' Gabung Dengan 'Numbers.V = OtherNumbers.V' -:") == [A.Cell[2]]
            @test length(rows(s,"Pilih 'V & Count(*)' Dari 'OtherNumbers' Grup Dari 'V' -:")) == 1
            q(s,"Buat Tabel 'Values' Isi 'I & V' Dengan 'I = I & V = U' -:")
            q(s,"Isi Tabel 'Values' '2 & 10' '0 & 20' -:")
            before = read(s.path)
            @test_throws AiresError q(s,"Tabel_Upt 'Values' Isi 'V = V / I' -:")
            @test read(s.path) == before
            @test A.exact(first(allrows(s,"Values"))[2]) == 10
            q(s,"Tabel_Upt 'Values' Isi 'I = I + 1 & V = I' -:")
            @test first(allrows(s,"Values"))[1] == 3
            @test A.exact(first(allrows(s,"Values"))[2]) == 2
        end
    end

    @testset "Formatter, script execution and user-friendly errors" begin
        fresh() do s,dir
            employees(s)
            output = format_table(q(s,"Pilih 'Nama' Dari 'Karyawan' -:"))
            @test occursin("| Aires",output)
            @test occursin("3 baris.",output)
            @test occursin("0 baris.",format_table(q(s,"Pilih '*' Dari 'Karyawan' Limit(0) -:")))
            escaped = format_table(QueryResult(["Value"],[A.Cell["line\n\e[31m"]]))
            @test !occursin('\e',escaped)
            @test occursin("\\n",escaped)
            @test occursin("…",format_table(QueryResult(["V"],[A.Cell[repeat("x",100)]]); max_width=10))
            results = execute_script!(s,"# Comment -:\nPilih 'Perusahaan' -:\nTampilkan 'Karyawan' -:\n# tail")
            @test length(results) == 2
            @test_throws AiresError execute_script!(s,"Pilih 'Perusahaan' -: Tampilkan 'Karyawan'")
        end
    end
end

# Permanent v0.1 audit suites. Each file owns a distinct module or global
# prefix so the combined Pkg.test process cannot silently shadow helpers.
include("relational_tests.jl")
include("mvcc_adversarial.jl")
include("wal_lowlevel.jl")
include("benchmark_tests.jl")
include("wal_mvcc_integration.jl")
include("source_audit_tests.jl")
include("backup_tests.jl")
include("airesql_logical_order_tests.jl")
include("arsp_storage_tests.jl")
include("arsp_pipeline_tests.jl")
include("pagestore_integration_tests.jl")
include("large_index_memory_tests.jl")
include("tinyserver_tests.jl")
include("optimizer_tests.jl")
