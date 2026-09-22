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
                               payload_length::Int64; overwrite::Bool=true)
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
            exists = ispath(destination)
            !overwrite && exists && storageerror("Backup destination already exists: '$destination'.")
            durable_replace(temporary,destination;replace=overwrite && exists)
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

# ---------------------------------------------------------------------------
# WAL archive and point-in-time restore
# ---------------------------------------------------------------------------

"""Immutable, self-contained archive of one verified authoritative WAL prefix.

The current WAL format deliberately starts every checkpoint with a full logical
snapshot.  An archived prefix can therefore be restored independently, and can
also be truncated at any complete record boundary for an exact LSN-based point
in time restore.  This avoids a fragile cross-checkpoint replay chain.
"""
const WAL_ARCHIVE_FORMAT = "AiresDB WAL Archive"
const WAL_ARCHIVE_VERSION = 1
const WAL_ARCHIVE_ARTIFACT_SUFFIX = ".aires.wal-archive"
const WAL_ARCHIVE_MANIFEST_SUFFIX = ".toml"
const WAL_ARCHIVE_TIME_FORMAT = dateformat"yyyy-mm-ddTHH:MM:SS.sss"

function _wal_archive_root(directory::AbstractString)
    value = strip(String(directory))
    isempty(value) && throw(ArgumentError("WAL archive directory must not be empty."))
    path = abspath(value)
    isfile(path) && storageerror("WAL archive directory '$path' is a file.")
    path
end

function _wal_archive_database_directory(directory::AbstractString,database::AbstractString)
    joinpath(_wal_archive_root(directory),database_name(database))
end

function _wal_archive_identifier()
    stamp = Dates.format(now(UTC),dateformat"yyyymmddTHHMMSSsss")
    "$(stamp)-$(uuid4())"
end

_wal_archive_timestamp() = Dates.format(now(UTC),WAL_ARCHIVE_TIME_FORMAT) * "Z"

function _parse_wal_archive_timestamp(value::AbstractString)
    text = String(value)
    endswith(text,"Z") || storageerror("WAL archive timestamp must be UTC.")
    try
        DateTime(chop(text),WAL_ARCHIVE_TIME_FORMAT)
    catch
        storageerror("WAL archive timestamp is invalid.")
    end
end

function _wal_archive_limit(max_bytes)
    max_bytes === nothing && return nothing
    max_bytes isa Integer || throw(ArgumentError("WAL archive max_bytes must be an integer or nothing."))
    0 < max_bytes <= typemax(Int64) || throw(ArgumentError("WAL archive max_bytes must be between 1 and $(typemax(Int64))."))
    Int64(max_bytes)
end

function _wal_archive_used_bytes(directory::String)
    isdir(directory) || return Int64(0)
    total = Int64(0)
    for name in readdir(directory)
        endswith(name,WAL_ARCHIVE_ARTIFACT_SUFFIX) || continue
        path = joinpath(directory,name)
        isfile(path) || continue
        size = Int64(filesize(path))
        total <= typemax(Int64)-size || storageerror("WAL archive size overflows this host.")
        total += size
    end
    total
end

function _durable_write_new_file!(path::String,bytes::Vector{UInt8})
    isdir(path) && storageerror("Archive manifest destination must be a file, not a directory.")
    mkpath(dirname(path))
    temporary,output = mktemp(dirname(path);cleanup=false)
    output_open = true
    try
        write(output,bytes)
        _wal_sync(output)
        close(output); output_open = false
        with_wal_lock(path) do
            ispath(path) && storageerror("Archive manifest already exists: '$path'.")
            durable_replace(temporary,path;replace=false)
        end
    finally
        output_open && close(output)
        isfile(temporary) && rm(temporary;force=true)
    end
    path
end

function _write_wal_archive_manifest!(directory::String,id::String,database::String,
                                      captured_at::String,file_id::Vector{UInt8},
                                      lsn::UInt64,bytes::Int64,commit_csn::UInt64,
                                      artifact::String,sha256sum::String)
    values = Dict{String,Any}(
        "format" => WAL_ARCHIVE_FORMAT,
        "version" => WAL_ARCHIVE_VERSION,
        "id" => id,
        "database" => database,
        "captured_at" => captured_at,
        "wal_file_id" => lowercase(bytes2hex(file_id)),
        "wal_lsn" => string(lsn),
        "wal_bytes" => string(bytes),
        "commit_csn" => string(commit_csn),
        "artifact" => artifact,
        "sha256" => lowercase(sha256sum),
    )
    output = IOBuffer()
    TOML.print(output,values)
    _durable_write_new_file!(joinpath(directory,id*WAL_ARCHIVE_MANIFEST_SUFFIX),take!(output))
end

function _archive_manifest_text(values,key::String)
    value = get(values,key,nothing)
    value isa AbstractString || storageerror("WAL archive manifest field '$key' must be text.")
    String(value)
end

function _archive_manifest_uint(values,key::String)
    value = tryparse(UInt64,_archive_manifest_text(values,key))
    value === nothing && storageerror("WAL archive manifest field '$key' must be an unsigned integer.")
    value
end

function _archive_manifest_hex(values,key::String,length_bytes::Int)
    value = lowercase(_archive_manifest_text(values,key))
    ncodeunits(value) == 2*length_bytes && occursin(r"^[0-9a-f]+$",value) ||
        storageerror("WAL archive manifest field '$key' is not valid hexadecimal.")
    value
end

function _read_wal_archive_manifest(path::String,expected_database::String)
    values = try
        TOML.parsefile(path)
    catch
        storageerror("WAL archive manifest '$(basename(path))' cannot be parsed.")
    end
    _archive_manifest_text(values,"format") == WAL_ARCHIVE_FORMAT ||
        storageerror("WAL archive manifest has an unsupported format.")
    version = get(values,"version",nothing)
    version isa Integer && version == WAL_ARCHIVE_VERSION ||
        storageerror("WAL archive manifest has an unsupported version.")
    id = _archive_manifest_text(values,"id")
    ncodeunits(id) <= 96 && occursin(r"^[0-9A-Za-z-]+$",id) ||
        storageerror("WAL archive manifest has an invalid id.")
    basename(path) == id*WAL_ARCHIVE_MANIFEST_SUFFIX ||
        storageerror("WAL archive manifest filename does not match its id.")
    database = database_name(_archive_manifest_text(values,"database"))
    database == expected_database || storageerror("WAL archive belongs to '$database', not '$expected_database'.")
    artifact = _archive_manifest_text(values,"artifact")
    artifact == id*WAL_ARCHIVE_ARTIFACT_SUFFIX ||
        storageerror("WAL archive artifact name does not match its id.")
    captured_at_text = _archive_manifest_text(values,"captured_at")
    captured_at = _parse_wal_archive_timestamp(captured_at_text)
    file_id = _archive_manifest_hex(values,"wal_file_id",16)
    lsn = _archive_manifest_uint(values,"wal_lsn")
    lsn > 0 || storageerror("WAL archive LSN must be positive.")
    bytes = _archive_manifest_uint(values,"wal_bytes")
    bytes <= UInt64(typemax(Int64)) || storageerror("WAL archive byte count exceeds this host.")
    bytes >= UInt64(WAL_HEADER_SIZE) || storageerror("WAL archive is smaller than a WAL header.")
    commit_csn = _archive_manifest_uint(values,"commit_csn")
    sha256sum = _archive_manifest_hex(values,"sha256",32)
    artifact_path = joinpath(dirname(path),artifact)
    isfile(artifact_path) || storageerror("WAL archive artifact '$artifact' is missing.")
    (id=id,database=database,captured_at=captured_at,captured_at_text=captured_at_text,
     file_id=file_id,lsn=lsn,bytes=Int64(bytes),commit_csn=commit_csn,
     artifact=artifact,path=artifact_path,sha256=sha256sum,manifest=path)
end

"""List durable WAL archive points for one database.

Each result identifies an independently restorable WAL segment. `lsn` is the
latest committed record captured in that artifact; pass the returned `id` and
an optional earlier LSN to `restore_database_at!` for exact record-boundary
recovery.
"""
function list_wal_archives(directory::AbstractString,database::AbstractString)
    database_name_value = database_name(database)
    archive_directory = _wal_archive_database_directory(directory,database_name_value)
    isdir(archive_directory) || return NamedTuple[]
    entries = NamedTuple[]
    for manifest_name in readdir(archive_directory)
        endswith(manifest_name,WAL_ARCHIVE_MANIFEST_SUFFIX) || continue
        push!(entries,_read_wal_archive_manifest(joinpath(archive_directory,manifest_name),database_name_value))
    end
    sort!(entries;by=entry -> (entry.captured_at,entry.id))
    entries
end

function _wal_archive_entry(directory::AbstractString,database::AbstractString,id::AbstractString)
    requested = String(id)
    entries = list_wal_archives(directory,database)
    entry = findfirst(candidate -> candidate.id == requested,entries)
    entry === nothing && storageerror("WAL archive '$requested' was not found for database '$(database_name(database))'.")
    entries[entry]
end

function _archive_database_locked!(session::Session,handle::DatabaseHandle,directory::AbstractString;
                                   max_bytes=nothing)
    _wal_require_locked(handle.path)
    name = handle.current.name
    archive_directory = _wal_archive_database_directory(directory,name)
    mkpath(archive_directory)
    limit = _wal_archive_limit(max_bytes)
    receipt = wal_read_locked(handle.path)
    receipt.file_id == handle.file_id || storageerror("WAL identity changed while preparing an archive.")
    receipt.lsn == handle.lsn || storageerror("WAL LSN changed while preparing an archive.")
    receipt.end_offset == handle.offset || storageerror("WAL offset changed while preparing an archive.")
    artifact_bytes = Int64(NATIVE_BACKUP_HEADER_SIZE) + receipt.end_offset
    if limit !== nothing
        used = _wal_archive_used_bytes(archive_directory)
        used <= limit-artifact_bytes ||
            storageerror("WAL archive capacity is exhausted; archive a larger volume before checkpointing.")
    end
    id = _wal_archive_identifier()
    artifact = id*WAL_ARCHIVE_ARTIFACT_SUFFIX
    destination = joinpath(archive_directory,artifact)
    captured_at = _wal_archive_timestamp()
    result = _native_backup_write!(destination,handle.path,receipt.file_id,receipt.lsn,
        receipt.end_offset;overwrite=false)
    manifest = _write_wal_archive_manifest!(archive_directory,id,name,captured_at,
        receipt.file_id,receipt.lsn,receipt.end_offset,handle.csn,artifact,result.sha256)
    (id=id,database=name,captured_at=_parse_wal_archive_timestamp(captured_at),
     captured_at_text=captured_at,file_id=lowercase(bytes2hex(receipt.file_id)),
     lsn=receipt.lsn,bytes=receipt.end_offset,commit_csn=handle.csn,
     artifact=destination,manifest=manifest,sha256=result.sha256)
end

"""Archive the current verified WAL prefix without checkpointing.

The artifact is published once under a UUID-derived name and never overwritten.
The database write lock is held only while the prefix is validated and streamed,
so a failed archive leaves the authoritative WAL untouched.
"""
function archive_database!(session::Session,directory::AbstractString; max_bytes=nothing)
    lock(session.mutex) do
        active_database(session)
        in_transaction(session) && fail("WAL archive cannot run inside a transaction.")
        handle = session.handle::DatabaseHandle
        lock(handle.mutex) do
            with_wal_lock(handle.path) do
                refresh_locked!(handle,session.storage)
                _archive_database_locked!(session,handle,directory;max_bytes)
            end
        end
    end
end

"""Archive one database using a short-lived maintenance session."""
function archive_database!(root::AbstractString,database::AbstractString,directory::AbstractString; kwargs...)
    session = Session(root)
    try
        open_database!(session,String(database))
        archive_database!(session,directory;kwargs...)
    finally
        close(session)
    end
end

function _truncate_wal_prefix_locked!(path::String,end_offset::Int64)
    _wal_require_locked(path)
    receipt = wal_read_locked(path)
    WAL_HEADER_SIZE <= end_offset <= receipt.end_offset ||
        storageerror("Requested PITR offset is outside the archived WAL prefix.")
    end_offset == receipt.end_offset && return receipt
    if Sys.iswindows()
        handle = _wal_windows_open_update(path)
        try
            _wal_windows_seek(handle,end_offset)
            ccall((:SetEndOfFile,"kernel32"),stdcall,Int32,(Ptr{Cvoid},),handle) != 0 ||
                storageerror("Could not truncate the PITR WAL (Win32 $(Base.Libc.GetLastError())).")
            _wal_windows_sync(handle)
        finally
            _wal_windows_close(handle)
        end
    else
        open(path,"r+") do io
            truncate(io,end_offset)
            _wal_sync(io)
        end
    end
    state = _wal_lock_state(path)
    state.receipt = nothing
    state.receipt_epoch = 0
    verified = wal_read_locked(path)
    verified.end_offset == end_offset && !verified.torn_tail ||
        storageerror("Truncated PITR WAL did not validate to the selected record boundary.")
    verified
end

function _archive_target_lsn(value,receipt)
    value === nothing && return receipt.lsn
    value isa Integer || throw(ArgumentError("PITR lsn must be an integer or nothing."))
    1 <= value <= typemax(UInt64) || throw(ArgumentError("PITR lsn is outside the UInt64 range."))
    target = UInt64(value)
    target <= receipt.lsn || storageerror("Requested PITR LSN $target is newer than this archive.")
    target
end

function _archive_manifest_matches_backup!(entry,metadata)
    lowercase(bytes2hex(metadata.file_id)) == entry.file_id ||
        storageerror("WAL archive file identity does not match its manifest.")
    metadata.lsn == entry.lsn || storageerror("WAL archive LSN does not match its manifest.")
    metadata.payload_length == entry.bytes || storageerror("WAL archive byte count does not match its manifest.")
    lowercase(bytes2hex(metadata.digest)) == entry.sha256 ||
        storageerror("WAL archive checksum does not match its manifest.")
    nothing
end

function _restore_wal_archive!(root::AbstractString,database::AbstractString,entry;
                               lsn=nothing,overwrite::Bool=false)
    root_path = abspath(String(root))
    mkpath(root_path)
    name = database_name(database)
    entry.database == name || storageerror("WAL archive database does not match the restore target.")
    target = abspath(joinpath(root_path,name*".aires"))
    target == abspath(entry.path) && storageerror("WAL archive file cannot be its own restore target.")
    isfile(target) && !overwrite && storageerror("Database '$name' already exists; use overwrite=true.")
    !overwrite && isfile(page_store_path(target)) &&
        storageerror("Sidecar '$name.aires.pages' already exists; use overwrite=true or clean the old installation.")
    temporary = nothing
    try
        materialized = _native_backup_materialize(entry.path,dirname(target))
        temporary = materialized.temporary
        metadata = materialized.metadata
        _archive_manifest_matches_backup!(entry,metadata)
        materialized.database == name ||
            storageerror("WAL archive database '$(materialized.database)' does not match target '$name'.")
        receipt = with_wal_lock(temporary) do
            full = wal_read_locked(temporary)
            target_lsn = _archive_target_lsn(lsn,full)
            record_index = findfirst(record -> record.lsn == target_lsn,full.records)
            record_index === nothing && storageerror("Requested PITR LSN $target_lsn is not a committed archive boundary.")
            _truncate_wal_prefix_locked!(temporary,full.records[record_index].end_offset)
        end
        target_lsn = receipt.lsn
        lock(_DATABASE_MAINTENANCE_LOCK) do
            _native_backup_restore_guard(target)
            with_wal_lock(target) do
                isfile(target) && !overwrite && storageerror("Database '$name' was created while PITR restore was running.")
                !overwrite && isfile(page_store_path(target)) &&
                    storageerror("Sidecar '$name.aires.pages' was created while PITR restore was running.")
                durable_replace(temporary,target;replace=overwrite && isfile(target))
            end
        end
        isfile(temporary*".lock") && rm(temporary*".lock";force=true)
        _wal_forget_private!(temporary)
        temporary = nothing
        (path=target,database=name,archive_id=entry.id,archive_captured_at=entry.captured_at,
         lsn=target_lsn,bytes=receipt.end_offset,page_store_rebuilt_on_open=true)
    finally
        if temporary !== nothing
            isfile(temporary) && rm(temporary;force=true)
            isfile(temporary*".lock") && rm(temporary*".lock";force=true)
            _wal_forget_private!(temporary)
        end
    end
end

"""Restore an archived database to a selected committed WAL LSN.

`archive_id` comes from `list_wal_archives`.  With no `lsn` keyword, the
latest committed record in that archive is restored.  A supplied LSN is exact:
the restored WAL is truncated only at a verified commit boundary.
"""
function restore_database_at!(root::AbstractString,database::AbstractString,
                              archive_directory::AbstractString,archive_id::AbstractString;
                              lsn=nothing,overwrite::Bool=false)
    entry = _wal_archive_entry(archive_directory,database,archive_id)
    _restore_wal_archive!(root,database,entry;lsn,overwrite)
end

"""Restore the latest archive captured at or before a UTC `DateTime`.

Archive capture time selects a safe lower bound; it is not a substitute for a
record timestamp.  Use the archive-id overload and LSN from
`list_wal_archives` when an exact transaction boundary is required.
"""
function restore_database_at!(root::AbstractString,database::AbstractString,
                              archive_directory::AbstractString;
                              at::DateTime,overwrite::Bool=false)
    entries = list_wal_archives(archive_directory,database)
    index = findlast(entry -> entry.captured_at <= at,entries)
    index === nothing && storageerror("No WAL archive exists at or before the requested time.")
    _restore_wal_archive!(root,database,entries[index];overwrite)
end
