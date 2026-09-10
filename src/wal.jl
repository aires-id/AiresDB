# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

"""Embedded, append-only WAL. All `_locked` entry points require `with_wal_lock`.

The `.aires` file is authoritative; the persistent, empty `.lock` sidecar is only
an OS lock identity. Never unlink that sidecar while any process can use the DB.
"""
const WAL_MAGIC = UInt8[0x41,0x49,0x52,0x45,0x53,0x57,0x41,0x4c] # AIRESWAL
const WAL_RECORD_MAGIC = UInt8[0x41,0x49,0x52,0x54,0x58,0x4e,0x30,0x31]
const WAL_COMMIT_MAGIC = UInt8[0x41,0x49,0x52,0x43,0x4d,0x54,0x30,0x31]
const WAL_HEADER_SIZE = 80
const WAL_RECORD_HEADER_SIZE = 96
const WAL_COMMIT_SIZE = 48
const WAL_MAX_PAYLOAD = 256 * 1024 * 1024

struct WALRecord
    lsn::UInt64
    payload::Vector{UInt8}
    end_offset::Int64
end

"""A write may have reached storage. Reopen/recover before issuing another write."""
struct WALCommitUnknown <: Exception
    lsn::UInt64
    cause::Any
end
Base.showerror(io::IO, e::WALCommitUnknown) =
    print(io, "WAL commit outcome unknown at LSN ", e.lsn,
          "; reopen/recover the database. ", sprint(showerror,e.cause))

struct WALReceipt
    file_id::Vector{UInt8}
    lsn::UInt64
    end_offset::Int64
    physical_size::Int64
    device::UInt64
    inode::UInt64
end

mutable struct WALPathLock
    mutex::ReentrantLock
    owner::Union{Nothing,Task}
    depth::Int
    handle::Any
    receipt::Union{Nothing,WALReceipt}
    epoch::UInt64
    receipt_epoch::UInt64
    append_handle::Any
    append_file_id::Union{Nothing,Vector{UInt8}}
end
const _WAL_PATH_LOCKS = Dict{String,WALPathLock}()
const _WAL_PATH_LOCKS_GUARD = ReentrantLock()

function _wal_canonical(path::String)
    p = ispath(path) ? realpath(path) : joinpath(realpath(dirname(abspath(path))),basename(path))
    Sys.iswindows() ? lowercase(p) : p
end

function _wal_lock_state(path::String)
    key = _wal_canonical(path)
    lock(_WAL_PATH_LOCKS_GUARD) do
        get!(_WAL_PATH_LOCKS,key) do
            WALPathLock(ReentrantLock(),nothing,0,nothing,nothing,0,0,nothing,nothing)
        end
    end
end

"""Forget a private temporary WAL identity after its lock has been released."""
function _wal_forget_private!(path::String)
    key = _wal_canonical(path)
    lock(_WAL_PATH_LOCKS_GUARD) do
        state = get(_WAL_PATH_LOCKS,key,nothing)
        state === nothing && return nothing
        state.depth == 0 && state.owner === nothing ||
            storageerror("Kunci WAL sementara masih aktif.")
        _wal_close_cached!(state)
        delete!(_WAL_PATH_LOCKS,key)
    end
    nothing
end

function _wal_require_locked(path::String)
    state = _wal_lock_state(path)
    state.owner === current_task() && state.depth > 0 ||
        storageerror("Operasi WAL memerlukan with_wal_lock.")
    state
end

function _wal_close_cached!(state::WALPathLock)
    handle = state.append_handle
    state.append_handle = nothing
    state.append_file_id = nothing
    handle === nothing || _wal_windows_close(handle)
    nothing
end

function _wal_close_cached!(path::String)
    state = _wal_lock_state(path)
    lock(state.mutex) do
        state.depth == 0 || storageerror("Tidak dapat menutup cache WAL yang sedang digunakan.")
        _wal_close_cached!(state)
    end
end

_wal_winpath(path::String) = transcode(UInt16,abspath(path)*"\0")

function _wal_os_lock(path::String; timeout::Real=60)
    lockpath = _wal_canonical(path)*".lock"
    started = time_ns()
    if Sys.iswindows()
        wide = _wal_winpath(lockpath)
        while true
            # Sharing mode zero is an OS-enforced exclusive lock, released even
            # after TerminateProcess. NULL security attributes prevent inheritance.
            handle = ccall((:CreateFileW,"kernel32"),stdcall,Ptr{Cvoid},
                (Ptr{UInt16},UInt32,UInt32,Ptr{Cvoid},UInt32,UInt32,Ptr{Cvoid}),
                wide,0xc0000000,0,C_NULL,4,0x80,C_NULL)
            handle != Ptr{Cvoid}(typemax(UInt)) && return handle
            err = ccall((:GetLastError,"kernel32"),stdcall,UInt32,())
            err in (32,33) || storageerror("Tidak dapat membuka kunci WAL (Win32 $err).")
            (time_ns()-started)/1e9 < timeout || storageerror("Waktu tunggu kunci WAL habis.")
            sleep(0.005)
        end
    else
        # Julia maps portable flags through libuv. O_CLOEXEC avoids inherited locks.
        flags = Base.Filesystem.JL_O_RDWR | Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_CLOEXEC
        file = Base.Filesystem.open(lockpath,flags,0o600)
        try
            while true
                ccall(:flock,Cint,(Base.RawFD,Cint),Base.fd(file),6) == 0 && return file # EX|NB
                err = Base.Libc.errno()
                err in (Base.Libc.EAGAIN,Base.Libc.EWOULDBLOCK,Base.Libc.EINTR) ||
                    storageerror("Tidak dapat mengunci WAL (errno $err).")
                (time_ns()-started)/1e9 < timeout || storageerror("Waktu tunggu kunci WAL habis.")
                sleep(0.005)
            end
        catch
            close(file)
            rethrow()
        end
    end
end

function _wal_os_unlock(handle)
    if Sys.iswindows()
        ccall((:CloseHandle,"kernel32"),stdcall,Int32,(Ptr{Cvoid},),handle) != 0 ||
            storageerror("CloseHandle untuk kunci WAL gagal.")
    else
        close(handle) # Closing this open-file description releases flock.
    end
    nothing
end

"""Serialize cooperating tasks/processes using a persistent, OS-released lock.

Hold this lock across refresh, transaction certification, and durable append.
Nested calls in the same Julia task are supported. Never remove the lock file.
"""
function with_wal_lock(f::Function,path::String; timeout::Real=60)
    state = _wal_lock_state(path)
    lock(state.mutex)
    entered = false
    try
        if state.depth == 0
            state.handle = _wal_os_lock(path;timeout)
            state.owner = current_task()
            if state.epoch == typemax(UInt64)
                state.receipt = nothing
                state.epoch = 0
            end
            state.epoch += UInt64(1)
        end
        state.depth += 1
        entered = true
        f()
    finally
        if entered
            state.depth -= 1
            if state.depth == 0
                handle = state.handle
                state.handle = nothing
                state.owner = nothing
                try
                    _wal_os_unlock(handle)
                finally
                    unlock(state.mutex)
                end
            else
                unlock(state.mutex)
            end
        else
            unlock(state.mutex)
        end
    end
end

"""Flush Julia buffers, then demand an OS durability barrier; never ignore errors."""
function _wal_sync(io)
    flush(io)
    if Sys.iswindows()
        # Base.fd is a CRT descriptor, NOT a Win32 HANDLE, including Julia 1.12.
        handle = ccall(:_get_osfhandle,Ptr{Cvoid},(Base.RawFD,),Base.fd(io))
        handle != Ptr{Cvoid}(typemax(UInt)) || storageerror("Descriptor WAL tidak valid.")
        ok = ccall((:FlushFileBuffers,"kernel32"),stdcall,Int32,(Ptr{Cvoid},),handle)
        ok != 0 || storageerror("FlushFileBuffers WAL gagal (Win32 $(Base.Libc.GetLastError())).")
    else
        while ccall(:fsync,Cint,(Base.RawFD,),Base.fd(io)) != 0
            err = Base.Libc.errno()
            err == Base.Libc.EINTR && continue
            storageerror("fsync WAL gagal (errno $err).")
        end
    end
    nothing
end

# Julia's libuv update-open path can take around 10 ms for a recently modified
# file on Windows. WAL appends only need a small synchronous Win32 surface, so
# use it directly and still close the handle after every transaction. Keeping
# the handle open would prevent another process from atomically checkpointing
# over the database file.
function _wal_windows_open_update(path::String)
    handle = ccall((:CreateFileW,"kernel32"),stdcall,Ptr{Cvoid},
        (Ptr{UInt16},UInt32,UInt32,Ptr{Cvoid},UInt32,UInt32,Ptr{Cvoid}),
        _wal_winpath(path),UInt32(0xc0000000),UInt32(7),C_NULL,UInt32(3),UInt32(0x80),C_NULL)
    handle != Ptr{Cvoid}(typemax(UInt)) ||
        storageerror("Tidak dapat membuka WAL untuk append (Win32 $(Base.Libc.GetLastError())).")
    handle
end

function _wal_windows_seek(handle,offset::Int64)
    result = Ref{Int64}()
    ccall((:SetFilePointerEx,"kernel32"),stdcall,Int32,
        (Ptr{Cvoid},Int64,Ref{Int64},UInt32),handle,offset,result,UInt32(0)) != 0 ||
        storageerror("Seek WAL gagal (Win32 $(Base.Libc.GetLastError())).")
    result[] == offset || storageerror("Posisi append WAL tidak sesuai.")
    nothing
end

function _wal_windows_size(handle)::Int64
    result = Ref{Int64}()
    ccall((:GetFileSizeEx,"kernel32"),stdcall,Int32,
        (Ptr{Cvoid},Ref{Int64}),handle,result) != 0 ||
        storageerror("Ukuran WAL tidak dapat dibaca (Win32 $(Base.Libc.GetLastError())).")
    result[]
end

function _wal_windows_read(handle,offset::Int64,length_bytes::Int)::Vector{UInt8}
    length_bytes >= 0 || storageerror("Panjang baca WAL tidak valid.")
    length_bytes <= typemax(UInt32) || storageerror("Segmen WAL terlalu besar untuk Win32.")
    _wal_windows_seek(handle,offset)
    bytes = Vector{UInt8}(undef,length_bytes)
    isempty(bytes) && return bytes
    read_count = Ref{UInt32}()
    GC.@preserve bytes begin
        ccall((:ReadFile,"kernel32"),stdcall,Int32,
            (Ptr{Cvoid},Ptr{UInt8},UInt32,Ref{UInt32},Ptr{Cvoid}),
            handle,pointer(bytes),UInt32(length_bytes),read_count,C_NULL) != 0 ||
            storageerror("ReadFile WAL gagal (Win32 $(Base.Libc.GetLastError())).")
    end
    read_count[] == length_bytes || storageerror("WAL berubah atau terpotong saat dibaca.")
    bytes
end

function _wal_windows_close(handle)
    ccall((:CloseHandle,"kernel32"),stdcall,Int32,(Ptr{Cvoid},),handle) != 0 ||
        storageerror("CloseHandle WAL gagal.")
    nothing
end


function _wal_windows_write(handle,bytes::AbstractVector{UInt8})
    isempty(bytes) && return nothing
    length(bytes) <= typemax(UInt32) || storageerror("Segmen WAL terlalu besar untuk Win32.")
    written = Ref{UInt32}()
    GC.@preserve bytes begin
        pointer_bytes = pointer(bytes)
        ccall((:WriteFile,"kernel32"),stdcall,Int32,
            (Ptr{Cvoid},Ptr{UInt8},UInt32,Ref{UInt32},Ptr{Cvoid}),
            handle,pointer_bytes,UInt32(length(bytes)),written,C_NULL) != 0 ||
            storageerror("WriteFile WAL gagal (Win32 $(Base.Libc.GetLastError())).")
    end
    written[] == length(bytes) || storageerror("WriteFile WAL hanya menulis sebagian record.")
    nothing
end


function _wal_windows_sync(handle)
    ccall((:FlushFileBuffers,"kernel32"),stdcall,Int32,(Ptr{Cvoid},),handle) != 0 ||
        storageerror("FlushFileBuffers WAL gagal (Win32 $(Base.Libc.GetLastError())).")
    nothing
end


function _wal_windows_append_record(path::String,end_offset::Int64,torn_tail::Bool,
                                    file_id,lsn::UInt64,previous::UInt64,
                                    payload::Vector{UInt8};handle=nothing)::Int64
    owns_handle = handle === nothing
    handle === nothing && (handle = _wal_windows_open_update(path))
    try
        if torn_tail
            _wal_windows_seek(handle,end_offset)
            ccall((:SetEndOfFile,"kernel32"),stdcall,Int32,(Ptr{Cvoid},),handle) != 0 ||
                storageerror("Truncate tail WAL gagal (Win32 $(Base.Libc.GetLastError())).")
            _wal_windows_sync(handle)
        else
            _wal_windows_seek(handle,end_offset)
        end
        header = _wal_record_header(file_id,lsn,previous,length(payload))
        digest = _wal_hash(header,payload)
        _wal_windows_write(handle,header)
        _wal_failpoint("after_header")
        half = div(length(payload),2)
        _wal_windows_write(handle,@view payload[1:half])
        _wal_failpoint("mid_payload")
        _wal_windows_write(handle,@view payload[half+1:end])
        _wal_failpoint("after_payload")
        footer = IOBuffer()
        write(footer,WAL_COMMIT_MAGIC); _wal_put64(footer,lsn); write(footer,digest)
        _wal_windows_write(handle,take!(footer))
        _wal_failpoint("after_commit")
        _wal_failpoint("before_sync")
        _wal_windows_sync(handle)
        _wal_failpoint("after_sync")
        end_offset + WAL_RECORD_HEADER_SIZE + length(payload) + WAL_COMMIT_SIZE
    finally
        owns_handle && _wal_windows_close(handle)
    end
end

function _wal_sync_directory(path::String)
    Sys.iswindows() && return nothing # publication uses MoveFileExW WRITE_THROUGH
    flags = Base.Filesystem.JL_O_RDONLY | Base.Filesystem.JL_O_DIRECTORY | Base.Filesystem.JL_O_CLOEXEC
    io = Base.Filesystem.open(path,flags)
    try
        while ccall(:fsync,Cint,(Base.RawFD,),Base.fd(io)) != 0
            err = Base.Libc.errno()
            err == Base.Libc.EINTR && continue
            storageerror("fsync direktori WAL gagal (errno $err).")
        end
    finally
        close(io)
    end
    nothing
end

"""Sync and atomically replace a same-directory file, then sync publication.

The caller must hold the destination database's WAL lock. A failure after the
rename has an unknown publication outcome and requires reopen/recovery.
"""
function durable_replace(temporary::String,path::String; replace::Bool=true)
    _wal_require_locked(path)
    realpath(dirname(abspath(temporary))) == realpath(dirname(abspath(path))) ||
        storageerror("Publikasi WAL harus berada dalam direktori yang sama.")
    open(temporary,"r+") do io
        _wal_sync(io)
    end
    _wal_failpoint("before_publish")
    if Sys.iswindows()
        source = _wal_winpath(temporary); dest = _wal_winpath(path)
        ok = if replace
            # ReplaceFileW honors FILE_SHARE_DELETE on cached append handles,
            # allowing a different live process to publish a checkpoint.
            ccall((:ReplaceFileW,"kernel32"),stdcall,Int32,
                (Ptr{UInt16},Ptr{UInt16},Ptr{UInt16},UInt32,Ptr{Cvoid},Ptr{Cvoid}),
                dest,source,C_NULL,UInt32(1),C_NULL,C_NULL)
        else
            ccall((:MoveFileExW,"kernel32"),stdcall,Int32,
                (Ptr{UInt16},Ptr{UInt16},UInt32),source,dest,UInt32(8))
        end
        ok != 0 || storageerror("Publikasi WAL gagal (Win32 $(Base.Libc.GetLastError())).")
    else
        !replace && ispath(path) && storageerror("File tujuan WAL sudah ada.")
        Base.Filesystem.rename(temporary,path)
        _wal_sync_directory(dirname(abspath(path)))
    end
    _wal_failpoint("after_publish")
    state = _wal_lock_state(path)
    state.receipt = nothing
    _wal_close_cached!(state)
    nothing
end

function _wal_failpoint(stage::String,io=nothing)
    get(ENV,"AIRESDB_WAL_FAILPOINT","") == stage || return nothing
    io === nothing || flush(io)
    if get(ENV,"AIRESDB_WAL_FAILMODE","crash") == "error"
        storageerror("Injected WAL failure: $stage")
    end
    # Deliberately bypass Julia finalizers/atexit to model process termination.
    if Sys.iswindows()
        handle = ccall((:GetCurrentProcess,"kernel32"),stdcall,Ptr{Cvoid},())
        ccall((:TerminateProcess,"kernel32"),stdcall,Int32,(Ptr{Cvoid},UInt32),handle,86)
    else
        ccall(:_exit,Cvoid,(Cint,),86)
    end
    error("Process termination failpoint unexpectedly returned")
end

_wal_put16(io,x) = write(io,htol(UInt16(x)))
_wal_put32(io,x) = write(io,htol(UInt32(x)))
_wal_put64(io,x) = write(io,htol(UInt64(x)))
_wal_get16(io) = ltoh(read(io,UInt16))
_wal_get32(io) = ltoh(read(io,UInt32))
_wal_get64(io) = ltoh(read(io,UInt64))

function _wal_hash(parts::AbstractVector{UInt8}...)
    ctx = SHA.SHA2_256_CTX()
    for part in parts
        SHA.update!(ctx,part)
    end
    SHA.digest!(ctx)
end

function _wal_header(file_id::Vector{UInt8})
    io = IOBuffer()
    write(io,WAL_MAGIC); _wal_put16(io,1); _wal_put16(io,0)
    _wal_put32(io,WAL_HEADER_SIZE); write(io,file_id)
    _wal_put64(io,0); _wal_put64(io,0)
    prefix = take!(io)
    vcat(prefix,sha256(prefix))
end

function _wal_read_header(io)
    bytes = read(io,WAL_HEADER_SIZE)
    length(bytes) == WAL_HEADER_SIZE || storageerror("Header WAL terpotong.")
    sha256(@view bytes[1:48]) == bytes[49:80] || storageerror("Checksum header WAL gagal.")
    buf = IOBuffer(bytes)
    read(buf,8) == WAL_MAGIC || storageerror("Magic header bukan WAL AiresDB.")
    major = _wal_get16(buf); minor = _wal_get16(buf)
    major == 1 && minor == 0 || storageerror("Versi WAL $major.$minor belum didukung.")
    _wal_get32(buf) == WAL_HEADER_SIZE || storageerror("Ukuran header WAL tidak valid.")
    file_id = read(buf,16)
    _wal_get64(buf) == 0 && _wal_get64(buf) == 0 || storageerror("Flag header WAL tidak valid.")
    (file_id=file_id,major=major,minor=minor)
end

function detect_wal(path::String)
    isfile(path) || return false
    open(path,"r") do io
        read(io,8) == WAL_MAGIC
    end
end

function _wal_record_header(file_id,lsn,previous,payload_length)
    io = IOBuffer()
    write(io,WAL_RECORD_MAGIC); _wal_put64(io,lsn); _wal_put64(io,previous)
    _wal_put64(io,payload_length); write(io,file_id)
    _wal_put64(io,0); _wal_put64(io,0)
    prefix = take!(io)
    vcat(prefix,sha256(prefix))
end

function _wal_write_record(io,file_id,lsn,previous,payload)
    length(payload) <= WAL_MAX_PAYLOAD || storageerror("Payload WAL melebihi batas format.")
    header = _wal_record_header(file_id,lsn,previous,length(payload))
    digest = _wal_hash(header,payload)
    write(io,header)
    _wal_failpoint("after_header",io)
    half = div(length(payload),2)
    write(io,@view payload[1:half])
    _wal_failpoint("mid_payload",io)
    write(io,@view payload[half+1:end])
    _wal_failpoint("after_payload",io)
    write(io,WAL_COMMIT_MAGIC); _wal_put64(io,lsn); write(io,digest)
    _wal_failpoint("after_commit",io)
    _wal_failpoint("before_sync",io)
    _wal_sync(io)
    _wal_failpoint("after_sync",io)
    nothing
end

"""Create a WAL container with a committed initial payload at LSN 1."""
function wal_create(path::String,initial_payload::Vector{UInt8})
    length(initial_payload) <= WAL_MAX_PAYLOAD || storageerror("Payload WAL melebihi batas format.")
    with_wal_lock(path) do
        ispath(path) && storageerror("Database '$(basename(path))' sudah ada.")
        temporary,io = mktemp(dirname(abspath(path));cleanup=false)
        try
            idbuf = IOBuffer(); write(idbuf,htol(uuid4().value)); file_id = take!(idbuf)
            write(io,_wal_header(file_id))
            _wal_write_record(io,file_id,UInt64(1),UInt64(0),initial_payload)
            close(io)
            durable_replace(temporary,path;replace=false)
            state = _wal_lock_state(path)
            wal_stat = stat(path)
            final_size = Int64(wal_stat.size)
            state.receipt = WALReceipt(file_id,UInt64(1),final_size,final_size,
                UInt64(wal_stat.device),UInt64(wal_stat.inode))
            state.receipt_epoch = state.epoch
            UInt64(1)
        finally
            isopen(io) && close(io)
            isfile(temporary) && rm(temporary)
        end
    end
end

function _wal_read_at(io,offset,n)
    seek(io,offset)
    bytes = read(io,n)
    length(bytes) == n || storageerror("WAL berubah atau terpotong saat dibaca.")
    bytes
end

function _wal_file_id(path::String)::Vector{UInt8}
    if Sys.iswindows()
        handle = _wal_windows_open_update(path)
        try
            return _wal_read_header(IOBuffer(_wal_windows_read(handle,Int64(0),WAL_HEADER_SIZE))).file_id
        finally
            _wal_windows_close(handle)
        end
    end
    open(path,"r") do io
        _wal_read_header(io).file_id
    end
end

"""Read committed records, ignoring only a physically incomplete final frame.

`from_offset=0` fully validates the file. A nonzero value must be an end_offset
previously returned for this same file_id; prior payloads are not reread. Return
fields: file_id, major, minor, lsn, end_offset, records, torn_tail, physical_size.
The caller must reject a changed file_id before applying incremental records.
Recovery synchronizes newly observed complete records before exposing them,
including commits whose writer died before returning an acknowledgement.
"""
function _wal_scan_locked(state::WALPathLock,physical_size::Int64,device::UInt64,inode::UInt64,
                          from_offset::Integer,read_at::Function,sync_now::Function)
    metadata = _wal_read_header(IOBuffer(read_at(Int64(0),WAL_HEADER_SIZE)))
    0 <= from_offset <= physical_size || storageerror("Offset WAL di luar file; muat ulang database.")
    offset = from_offset == 0 ? Int64(WAL_HEADER_SIZE) : Int64(from_offset)
    offset >= WAL_HEADER_SIZE || storageerror("Offset WAL tidak valid.")
    last_lsn = UInt64(0)
    if offset > WAL_HEADER_SIZE
        offset >= WAL_HEADER_SIZE + WAL_RECORD_HEADER_SIZE + WAL_COMMIT_SIZE ||
            storageerror("Offset WAL bukan batas commit.")
        footer = IOBuffer(read_at(offset-WAL_COMMIT_SIZE,WAL_COMMIT_SIZE))
        read(footer,8) == WAL_COMMIT_MAGIC || storageerror("Offset WAL bukan batas commit.")
        last_lsn = _wal_get64(footer)
        last_lsn > 0 || storageerror("LSN WAL tidak valid.")
    end
    records = WALRecord[]
    while offset < physical_size
        remaining = physical_size-offset
        if remaining < WAL_RECORD_HEADER_SIZE
            prefix = read_at(offset,Int(min(remaining,8)))
            prefix == WAL_RECORD_MAGIC[1:length(prefix)] || storageerror("Magic ekor WAL rusak.")
            break
        end
        header = read_at(offset,WAL_RECORD_HEADER_SIZE)
        sha256(@view header[1:64]) == header[65:96] || storageerror("Checksum header record WAL gagal.")
        buf = IOBuffer(header)
        read(buf,8) == WAL_RECORD_MAGIC || storageerror("Magic record WAL tidak valid.")
        lsn = _wal_get64(buf); previous = _wal_get64(buf); payload_length = _wal_get64(buf)
        read(buf,16) == metadata.file_id || storageerror("Identitas record WAL tidak cocok.")
        _wal_get64(buf) == 0 && _wal_get64(buf) == 0 || storageerror("Flag record WAL tidak valid.")
        last_lsn < typemax(UInt64) && previous == last_lsn && lsn == last_lsn+1 ||
            storageerror("Urutan LSN WAL rusak.")
        payload_length <= WAL_MAX_PAYLOAD || storageerror("Panjang payload WAL melebihi batas format.")
        frame_size = WAL_RECORD_HEADER_SIZE + Int64(payload_length) + WAL_COMMIT_SIZE
        remaining < frame_size && break
        payload_offset = offset + WAL_RECORD_HEADER_SIZE
        payload = read_at(payload_offset,Int(payload_length))
        footer = IOBuffer(read_at(payload_offset+Int64(payload_length),WAL_COMMIT_SIZE))
        read(footer,8) == WAL_COMMIT_MAGIC || storageerror("Marker commit WAL rusak.")
        _wal_get64(footer) == lsn || storageerror("LSN marker commit WAL rusak.")
        read(footer,32) == _wal_hash(header,payload) || storageerror("Checksum commit WAL gagal.")
        offset += frame_size
        push!(records,WALRecord(lsn,payload,offset))
        last_lsn = lsn
    end
    last_lsn > 0 || storageerror("WAL tidak memiliki snapshot awal yang committed.")
    receipt = state.receipt
    if !isempty(records) && (receipt === nothing || receipt.file_id != metadata.file_id || receipt.end_offset < offset)
        sync_now()
    end
    state.receipt = WALReceipt(metadata.file_id,last_lsn,offset,physical_size,device,inode)
    state.receipt_epoch = state.epoch
    (file_id=metadata.file_id,major=metadata.major,minor=metadata.minor,
     lsn=last_lsn,end_offset=offset,records=records,torn_tail=offset<physical_size,
     physical_size=physical_size)
end

function wal_read_locked(path::String;from_offset::Integer=0)
    state = _wal_require_locked(path)
    isfile(path) || storageerror("File database tidak ditemukan.")
    if Sys.iswindows()
        handle = _wal_windows_open_update(path)
        try
            wal_stat = stat(path)
            return _wal_scan_locked(state,_wal_windows_size(handle),UInt64(wal_stat.device),
                UInt64(wal_stat.inode),from_offset,
                (offset,count)->_wal_windows_read(handle,offset,count),
                ()->_wal_windows_sync(handle))
        finally
            _wal_windows_close(handle)
        end
    end
    open(path,"r+") do io
        wal_stat = stat(io)
        _wal_scan_locked(state,Int64(wal_stat.size),UInt64(wal_stat.device),
            UInt64(wal_stat.inode),from_offset,
            (offset,count)->_wal_read_at(io,offset,count),()->_wal_sync(io))
    end
end

wal_read(path::String;kwargs...) = with_wal_lock(()->wal_read_locked(path;kwargs...),path)

"""Append one atomic transaction and return its LSN only after the sync barrier.

The expected LSN is checked under the same OS lock used by readers. A verified
receipt permits incremental refresh; complete old payloads are not rescanned.
An incomplete tail is truncated under the lock before writing a new frame.
After `WALCommitUnknown`, discard in-memory transaction state and reopen.
"""
function wal_append_locked(path::String,expected_lsn::UInt64,payload::Vector{UInt8};
                           cache_handle::Bool=false)
    state = _wal_require_locked(path)
    length(payload) <= WAL_MAX_PAYLOAD || storageerror("Payload WAL melebihi batas format.")
    receipt = state.receipt
    if receipt !== nothing && state.receipt_epoch == state.epoch
        # Refresh and certification already ran under this still-held OS lock.
        # No cooperating writer can invalidate that exact receipt in between.
        current = (file_id=receipt.file_id,lsn=receipt.lsn,end_offset=receipt.end_offset,
                   torn_tail=receipt.physical_size>receipt.end_offset)
    else
        current = nothing
        if receipt !== nothing
            wal_stat = stat(path)
            unchanged = Int64(wal_stat.size) == receipt.physical_size &&
                UInt64(wal_stat.device) == receipt.device && UInt64(wal_stat.inode) == receipt.inode
            if unchanged
                current = (file_id=receipt.file_id,lsn=receipt.lsn,end_offset=receipt.end_offset,
                           torn_tail=receipt.physical_size>receipt.end_offset)
                state.receipt_epoch = state.epoch
            else
                same_id = _wal_file_id(path) == receipt.file_id
                !same_id && (receipt=nothing; state.receipt=nothing)
            end
        end
        current === nothing &&
            (current = wal_read_locked(path;from_offset=receipt === nothing ? 0 : receipt.end_offset))
    end
    current.lsn == expected_lsn || storageerror("Database berubah di sesi lain (konflik LSN WAL).")
    expected_lsn < typemax(UInt64) || storageerror("Nomor transaksi WAL habis.")
    next_lsn = expected_lsn+UInt64(1)
    _wal_failpoint("before_append")
    try
        final_offset = if Sys.iswindows()
            append_handle = nothing
            if cache_handle
                if state.append_handle === nothing || state.append_file_id != current.file_id
                    _wal_close_cached!(state)
                    state.append_handle = _wal_windows_open_update(path)
                    state.append_file_id = copy(current.file_id)
                end
                append_handle = state.append_handle
            end
            _wal_windows_append_record(path,current.end_offset,current.torn_tail,
                current.file_id,next_lsn,expected_lsn,payload;handle=append_handle)
        else
            open(path,"r+") do io
                if current.torn_tail
                    truncate(io,current.end_offset)
                    _wal_sync(io)
                end
                seek(io,current.end_offset)
                _wal_write_record(io,current.file_id,next_lsn,expected_lsn,payload)
                Int64(position(io))
            end
        end
        wal_stat = stat(path)
        state.receipt = WALReceipt(current.file_id,next_lsn,final_offset,final_offset,
            UInt64(wal_stat.device),UInt64(wal_stat.inode))
        state.receipt_epoch = state.epoch
    catch e
        state.receipt = nothing
        cache_handle && _wal_close_cached!(state)
        throw(WALCommitUnknown(next_lsn,e))
    end
    next_lsn
end

wal_append(path::String,expected_lsn::UInt64,payload::Vector{UInt8}) =
    with_wal_lock(()->wal_append_locked(path,expected_lsn,payload),path)
