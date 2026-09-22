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
        @test !ispath(dirname(artifact))
        @test begin
            A._page_store_registry_key(artifact)
            true
        end
        result = backup_database!(source,artifact)
        @test isfile(artifact)
        @test result.bytes > 0
        @test result.bytes == filesize(joinpath(root,"Bank.aires"))
        @test length(result.sha256) == 64
        scripted_artifact = joinpath(root,"backup","Bank-scripted.aires.bak")
        scripted = backup_database!(root,"Bank",scripted_artifact)
        @test scripted.bytes == result.bytes

        @test_throws AiresError restore_database!(root,"Bank",artifact;overwrite=true)
        @test_throws AiresError restore_database!(joinpath(root,"wrong-name"),"Other",artifact)

        execute!(source,"Tabel_Upt 'T' Isi 'Value = 20' Dengan 'ID = 1' -:")
        close(source)

        gate_ready = Channel{Nothing}(1)
        gate_release = Channel{Nothing}(1)
        gate_holder = @async lock(A._DATABASE_MAINTENANCE_LOCK) do
            put!(gate_ready,nothing)
            take!(gate_release)
        end
        take!(gate_ready)
        opener = @async begin
            blocked = Session(root)
            try
                execute!(blocked,"Pilih 'Bank' -:")
            finally
                close(blocked)
            end
        end
        yield()
        @test !istaskdone(opener)
        put!(gate_release,nothing)
        wait(gate_holder)
        wait(opener)

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

@testset "Immutable WAL archive and LSN point-in-time restore" begin
    mktempdir() do root
        archive_root = joinpath(root,"wal-archive")
        source = Session(root)
        try
            execute!(source,"Buat 'Bank' -:")
            execute!(source,"Buat Tabel 'Ledger' Isi 'ID & Value' Dengan 'ID = I(P) & Value = I' -:")
            execute!(source,"Isi Tabel 'Ledger' '1 & 10' -:")
            first_archive = archive_database!(source,archive_root)
            @test isfile(first_archive.artifact)
            @test isfile(first_archive.manifest)
            @test first_archive.lsn > 1
            archives = list_wal_archives(archive_root,"Bank")
            @test length(archives) == 1
            @test only(archives).id == first_archive.id
            @test only(archives).lsn == first_archive.lsn
            @test only(archives).bytes == first_archive.bytes

            before_failed_checkpoint = read(source.path)
            @test_throws AiresError checkpoint!(source;archive_directory=archive_root,
                archive_max_bytes=1)
            @test read(source.path) == before_failed_checkpoint

            execute!(source,"Tabel_Upt 'Ledger' Isi 'Value = 20' Dengan 'ID = 1' -:")
            checkpoint!(source;archive_directory=archive_root)
            @test length(A.wal_read(source.path).records) == 1
            archives = list_wal_archives(archive_root,"Bank")
            @test length(archives) == 2
            checkpoint_archive = only(filter(entry -> entry.id != first_archive.id,archives))
            @test checkpoint_archive.lsn > first_archive.lsn

            restored_latest_root = joinpath(root,"restored-latest")
            restored_latest = restore_database_at!(restored_latest_root,"Bank",archive_root,
                first_archive.id)
            @test restored_latest.lsn == first_archive.lsn
            latest_session = Session(restored_latest_root)
            try
                execute!(latest_session,"Pilih 'Bank' -:")
                @test lookup(latest_session,"Ledger",1) == [1,10]
            finally
                close(latest_session)
                A._close_page_stores_under!(restored_latest_root)
            end

            restored_prefix_root = joinpath(root,"restored-prefix")
            restored_prefix = restore_database_at!(restored_prefix_root,"Bank",archive_root,
                first_archive.id;lsn=first_archive.lsn-UInt64(1))
            @test restored_prefix.lsn == first_archive.lsn-UInt64(1)
            prefix_session = Session(restored_prefix_root)
            try
                execute!(prefix_session,"Pilih 'Bank' -:")
                @test lookup(prefix_session,"Ledger",1) === nothing
            finally
                close(prefix_session)
                A._close_page_stores_under!(restored_prefix_root)
            end

            restored_time_root = joinpath(root,"restored-time")
            restored_time = restore_database_at!(restored_time_root,"Bank",archive_root;
                at=first_archive.captured_at)
            @test restored_time.archive_id == first_archive.id
            A._close_page_stores_under!(restored_time_root)

            bytes = read(first_archive.artifact)
            bytes[end] = xor(bytes[end],UInt8(0x01))
            write(first_archive.artifact,bytes)
            @test_throws AiresError restore_database_at!(joinpath(root,"corrupt-restore"),"Bank",
                archive_root,first_archive.id)
        finally
            close(source)
            A._close_page_stores_under!(root)
        end
    end
end

end
