module NativeBackupTests

using Test
using AiresDB
using AiresDB.Internal

const A = AiresDB

@testset "Native WAL backup and restore" begin
    mktempdir() do root
        source = Session(root)
        execute!(source,"Buat 'Bank' -:")
        execute!(source,"Buat Tabel 'T' Isi 'ID & Value' Dengan 'ID = I(P) & Value = I' -:")
        execute!(source,"Isi Tabel 'T' '1 & 10' -:")
        artifact = joinpath(root,"backup","Bank.aires.bak")
        result = backup_database!(source,artifact)
        @test isfile(artifact)
        @test result.bytes > 0
        @test result.bytes == filesize(joinpath(root,"Bank.aires"))
        @test length(result.sha256) == 64
        scripted_artifact = joinpath(root,"backup","Bank-scripted.aires.bak")
        scripted = backup_database!(root,"Bank",scripted_artifact)
        @test scripted.bytes == result.bytes

        execute!(source,"Tabel_Upt 'T' Isi 'Value = 20' Dengan 'ID = 1' -:")
        close(source)

        restored_root = joinpath(root,"restored")
        restored = restore_database!(restored_root,"Bank",artifact)
        @test restored.database == "Bank"
        @test restored.page_store_rebuilt_on_open
        reopened = Session(restored_root)
        execute!(reopened,"Pilih 'Bank' -:")
        @test lookup(reopened,"T",1) == [1,10]
        close(reopened)
        A._close_page_stores_under!(restored_root)

        overwritten = restore_database!(root,"Bank",artifact;overwrite=true)
        @test overwritten.path == joinpath(root,"Bank.aires")
        reopened = Session(root)
        execute!(reopened,"Pilih 'Bank' -:")
        @test lookup(reopened,"T",1) == [1,10]
        close(reopened)
        A._close_page_stores_under!(root)

        corrupted = joinpath(root,"corrupt.bak")
        bytes = read(artifact)
        bytes[end] ⊻= UInt8(0x01)
        write(corrupted,bytes)
        @test_throws AiresError restore_database!(joinpath(root,"bad-restore"),"Bank",corrupted)
    end
end

end
