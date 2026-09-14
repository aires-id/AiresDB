# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

"""Native, consistent backup and restore for the authoritative WAL.

The `.aires` WAL is the source of truth.  A native backup therefore stores a
verified WAL prefix and deliberately does not copy `.aires.pages`; the derived
sidecar is rebuilt on the first open after restore.  This keeps backup atomic
even when a page publication is in flight and avoids treating a physical cache
as independent user data.
"""

const NATIVE_BACKUP_MAGIC = UInt8[0x41,0x49,0x52,0x45,0x53,0x42,0x4b,0x31] # AIRESBK1
const NATIVE_BACKUP_VERSION = UInt16(1)
const NATIVE_BACKUP_HEADER_SIZE = 80
const NATIVE_BACKUP_COPY_CHUNK = 1024 * 1024

function _native_backup_header(file_id::Vector{UInt8},lsn::UInt64,payload_length::Int64,
                               digest::Vector{UInt8})
    length(file_id) == 16 || storageerror("Identitas WAL untuk backup tidak valid.")
    length(digest) == 32 || storageerror("Checksum backup tidak valid.")
    payload_length >= 0 || storageerror("Ukuran payload backup tidak valid.")
    io = IOBuffer()
    write(io,NATIVE_BACKUP_MAGIC)
    _wal_put16(io,NATIVE_BACKUP_VERSION)
    _wal_put16(io,0)
    _wal_put32(io,NATIVE_BACKUP_HEADER_SIZE)
    write(io,file_id)
    _wal_put64(io,lsn)
    _wal_put64(io,UInt64(payload_length))
    write(io,digest)
    header = take!(io)
    length(header) == NATIVE_BACKUP_HEADER_SIZE || error("Ukuran header backup internal tidak konsisten.")
    header
end

function _native_backup_decode_header(bytes::Vector{UInt8})
    length(bytes) == NATIVE_BACKUP_HEADER_SIZE || storageerror("Header backup terpotong.")
    io = IOBuffer(bytes)
    read(io,8) == NATIVE_BACKUP_MAGIC || storageerror("Magic backup AiresDB tidak valid.")
    _wal_get16(io) == NATIVE_BACKUP_VERSION || storageerror("Versi backup AiresDB belum didukung.")
    _wal_get16(io) == 0 || storageerror("Flag header backup tidak valid.")
    _wal_get32(io) == NATIVE_BACKUP_HEADER_SIZE || storageerror("Ukuran header backup tidak valid.")
    file_id = read(io,16)
    lsn = _wal_get64(io)
    payload_length = _wal_get64(io)
    payload_length <= UInt64(typemax(Int64) - NATIVE_BACKUP_HEADER_SIZE) ||
        storageerror("Ukuran backup melampaui kapasitas host.")
    digest = read(io,32)
    (file_id=file_id,lsn=lsn,payload_length=Int64(payload_length),digest=digest)
end

function _native_backup_write!(destination::String,source::String,file_id::Vector{UInt8},lsn::UInt64,
                               payload_length::Int64)
    _page_store_registry_key(destination) == _page_store_registry_key(source) &&
        storageerror("Tujuan backup tidak boleh sama dengan database aktif.")
    isdir(destination) && storageerror("Tujuan backup harus berupa file, bukan direktori.")
    mkpath(dirname(destination))
    temporary,output = mktemp(dirname(destination);cleanup=false)
    output_open = true
    try
        # Write a placeholder digest, stream the WAL without a second full-size
        # allocation, then patch the fixed header before the durability barrier.
        write(output,_native_backup_header(file_id,lsn,payload_length,zeros(UInt8,32)))
        digest_context = SHA.SHA2_256_CTX()
        open(source,"r") do input
            remaining = payload_length
            while remaining > 0
                count = Int(min(remaining,Int64(NATIVE_BACKUP_COPY_CHUNK)))
                chunk = read(input,count)
                length(chunk) == count || storageerror("WAL berubah atau terpotong saat backup.")
                write(output,chunk)
                SHA.update!(digest_context,chunk)
                remaining -= count
            end
        end
        digest = SHA.digest!(digest_context)
        seekstart(output)
        write(output,_native_backup_header(file_id,lsn,payload_length,digest))
        _wal_sync(output)
        close(output); output_open = false
        # Reuse the proven same-directory atomic publication path.  The backup
        # artifact gets a stable `.lock` identity just like a database file.
        with_wal_lock(destination) do
            durable_replace(temporary,destination;replace=isfile(destination))
        end
        (path=destination,lsn=lsn,bytes=payload_length,
         sha256=lowercase(bytes2hex(digest)))
    finally
        output_open && close(output)
        isfile(temporary) && rm(temporary;force=true)
    end
end

function _native_backup_materialize(backup::String,directory::String)
    isfile(backup) || storageerror("File backup '$backup' tidak ditemukan.")
    filesize(backup) >= NATIVE_BACKUP_HEADER_SIZE || storageerror("File backup terpotong.")
    temporary,output = mktemp(directory;cleanup=false)
    output_open = true
    metadata = nothing
    try
        open(backup,"r") do input
            metadata = _native_backup_decode_header(read(input,NATIVE_BACKUP_HEADER_SIZE))
            expected_size = Int64(NATIVE_BACKUP_HEADER_SIZE) + metadata.payload_length
            filesize(backup) == expected_size || storageerror("Ukuran backup tidak cocok dengan header.")
            digest_context = SHA.SHA2_256_CTX()
            remaining = metadata.payload_length
            while remaining > 0
                count = Int(min(remaining,Int64(NATIVE_BACKUP_COPY_CHUNK)))
                chunk = read(input,count)
                length(chunk) == count || storageerror("Payload backup terpotong.")
                write(output,chunk)
                SHA.update!(digest_context,chunk)
                remaining -= count
            end
            SHA.digest!(digest_context) == metadata.digest || storageerror("Checksum payload backup gagal.")
            eof(input) || storageerror("Backup memiliki data tambahan setelah payload.")
        end
        _wal_sync(output)
        close(output); output_open = false
        # Validate the embedded WAL before it can replace a live database.
        receipt = with_wal_lock(temporary) do
            wal_read_locked(temporary)
        end
        receipt.torn_tail && storageerror("Backup WAL memiliki ekor parsial.")
        receipt.file_id == metadata.file_id || storageerror("Identitas WAL backup tidak cocok.")
        receipt.lsn == metadata.lsn || storageerror("LSN WAL backup tidak cocok.")
        receipt.end_offset == metadata.payload_length || storageerror("Panjang WAL backup tidak cocok.")
        isempty(receipt.records) && storageerror("Backup WAL tidak memiliki checkpoint.")
        checkpoint = IOBuffer(first(receipt.records).payload)
        get_u8(checkpoint) == 1 || storageerror("Record pertama backup bukan checkpoint.")
        get_u64(checkpoint); get_u64(checkpoint)
        embedded_name = decode_database(BinaryRowStore(),get_blob(checkpoint)).name
        (temporary=temporary,metadata=metadata,database=embedded_name)
    catch
        output_open && close(output)
        isfile(temporary) && rm(temporary;force=true)
        isfile(temporary*".lock") && rm(temporary*".lock";force=true)
        _wal_forget_private!(temporary)
        rethrow()
    end
end

function _native_backup_restore_guard(path::String)
    _engine_uses_path(path) &&
        storageerror("Tutup semua session sebelum restore database '$path'.")
    key = _page_store_registry_key(page_store_path(path))
    store = lock(_PAGE_STORE_REGISTRY_LOCK) do
        get(_PAGE_STORE_REGISTRY,key,nothing)
    end
    store === nothing && return nothing
    store.leases == 0 || storageerror("Tutup semua session sebelum restore database '$path'.")
    close_page_store!(store)
    nothing
end

"""Create an atomic, checksummed native backup from a consistent WAL snapshot.

The backup contains the authoritative `.aires` WAL only.  The `.aires.pages`
sidecar is intentionally omitted and is rebuilt during the next open.
"""
function backup_database!(session::Session,destination::AbstractString)
    lock(session.mutex) do
        active_database(session)
        in_transaction(session) && fail("Backup tidak boleh dibuat selama transaksi aktif.")
        handle = session.handle::DatabaseHandle
        destination_path = abspath(String(destination))
        source_path = abspath(handle.path)
        _page_store_registry_key(destination_path) == _page_store_registry_key(source_path) &&
            storageerror("Tujuan backup tidak boleh sama dengan database aktif.")
        lock(handle.mutex) do
            with_wal_lock(handle.path) do
                refresh_locked!(handle,session.storage)
                receipt = wal_read_locked(handle.path)
                # A torn tail is excluded from the artifact; the complete WAL
                # prefix is still a valid recoverable point-in-time backup.
                _native_backup_write!(destination_path,source_path,receipt.file_id,receipt.lsn,receipt.end_offset)
            end
        end
    end
end

"""Create a native backup without exposing a long-lived internal Session.

This overload is suitable for maintenance jobs and scripts.  It opens one
short-lived reader under the same WAL protocol, writes the backup, and closes
the reader before returning.
"""
function backup_database!(root::AbstractString,database::AbstractString,destination::AbstractString)
    session = Session(root)
    try
        open_database!(session,database)
        backup_database!(session,destination)
    finally
        close(session)
    end
end

"""Restore a native backup into `root/database` using atomic WAL publication.

All sessions/processes using the target database must be stopped first.  The
derived page sidecar is retained as stale cache and rebuilt on the next open.
"""
function restore_database!(root::AbstractString,database::AbstractString,backup::AbstractString;
                           overwrite::Bool=false)
    root_path = abspath(String(root))
    mkpath(root_path)
    name = database_name(database)
    target = abspath(joinpath(root_path,name*".aires"))
    backup_path = abspath(String(backup))
    target == backup_path && storageerror("File backup tidak boleh menjadi target restore.")
    isfile(target) && !overwrite && storageerror("Database '$name' sudah ada; gunakan overwrite=true.")
    !overwrite && isfile(page_store_path(target)) &&
        storageerror("Sidecar '$name.aires.pages' sudah ada; gunakan overwrite=true atau bersihkan instalasi lama.")
    temporary = nothing
    try
        materialized = _native_backup_materialize(backup_path,dirname(target))
        temporary = materialized.temporary
        metadata = materialized.metadata
        materialized.database == name ||
            storageerror("Nama database backup '$(materialized.database)' tidak cocok dengan target '$name'.")
        lock(_DATABASE_MAINTENANCE_LOCK) do
            _native_backup_restore_guard(target)
            with_wal_lock(target) do
                isfile(target) && !overwrite && storageerror("Database '$name' dibuat proses lain saat restore.")
                !overwrite && isfile(page_store_path(target)) &&
                    storageerror("Sidecar '$name.aires.pages' dibuat proses lain saat restore.")
                durable_replace(temporary,target;replace=overwrite && isfile(target))
            end
        end
        isfile(temporary*".lock") && rm(temporary*".lock";force=true)
        _wal_forget_private!(temporary)
        temporary = nothing
        (path=target,database=name,lsn=metadata.lsn,bytes=metadata.payload_length,
         sha256=lowercase(bytes2hex(metadata.digest)),page_store_rebuilt_on_open=true)
    finally
        if temporary !== nothing
            isfile(temporary) && rm(temporary;force=true)
            isfile(temporary*".lock") && rm(temporary*".lock";force=true)
            _wal_forget_private!(temporary)
        end
    end
end
