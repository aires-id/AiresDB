# Embedded WAL and durability

AiresDB stores its initial snapshot and every subsequent committed transaction
inside the **same official `.aires` file**. The empty `.aires.lock` sidecar is
only an operating-system lock identity. It contains no catalog, rows, recovery
log, or transaction state. Do not delete, replace, or rename this lock file while
any process might open the database. Its existence does not mean it is locked.

## Commit contract

The engine holds `with_wal_lock` across refresh, conflict certification, and
`wal_append_locked`. Append checks the expected LSN, writes one framed record,
flushes Julia's user-space buffer, and calls the operating-system durability API
before returning the new LSN. The engine must publish its changed in-memory state
only after this call succeeds. There is no asynchronous or unsynchronized commit
mode in this implementation.

On Windows, `_get_osfhandle(Base.fd(io))` converts Julia's CRT file descriptor to
the actual Win32 handle passed to `FlushFileBuffers`. Passing the small CRT file
descriptor as a handle would be incorrect. On POSIX, the implementation calls
`fsync` on the file descriptor and retries interrupted calls. All synchronization
failures propagate; none are silently treated as successful commits.

A failure after a write has started raises `WALCommitUnknown`. The caller must
discard its active transaction state and reopen/recover before writing again.
An application that loses its connection or receives this exception must inspect
the recovered state before retrying a non-idempotent operation: the original
transaction may already be committed. A lost acknowledgement cannot be converted
into a guaranteed rollback.

The supported durability contract assumes a local filesystem and a storage stack
that honor the operating system's synchronization requests. The device tests
exercise process termination and injected errors. They **do not demonstrate
survival of a physical power cut, failed SSD firmware, or an OS crash**. POSIX code
is present but Windows device results do not constitute POSIX platform testing.

## Locking and publication

Windows opens the stable sidecar using `CreateFileW` with sharing mode zero and a
non-inheritable handle. POSIX uses `flock(LOCK_EX | LOCK_NB)` on a non-inheritable
file descriptor. Contention retries until a 60-second timeout. The OS releases
the lock when a process terminates, including termination without Julia cleanup.
A per-path reentrant Julia lock serializes tasks and threads within one process.
The lock remains held through the durable append and publication of the engine's
commit state.

These are cooperative locks: every participating process must use the current
engine and the same canonical database path. Hard-link aliases and programs that
directly modify database bytes are unsupported. Do not run a legacy v0.1 writer
against a database concurrently with the WAL engine; the older lock protocol is
different. Network filesystems and their locking/durability semantics are outside
the tested contract.

Creation first writes and synchronizes a temporary file in the destination
directory, then publishes it under the destination lock. `durable_replace` also
supports legacy migration or an engine-controlled checkpoint. Windows publication
uses same-directory `MoveFileExW` with `MOVEFILE_WRITE_THROUGH` (and replacement
when requested). POSIX uses rename followed by `fsync` of the parent directory.
The Windows path does not claim an independent directory-handle flush or a
volume-wide flush requiring administrator rights. Failed publication requires
checking which file is present. A process killed during creation may leave an
unpublished temporary file; it is not an official database and is never replayed.

## Binary layout

All integer fields are unsigned and little-endian. File and record flags and
reserved fields must be zero. The supported embedded-WAL format is version 1.0;
this is independent of the legacy snapshot container's version number.

| Structure | Bytes | Contents |
|---|---:|---|
| File header prefix | 48 | `AIRESWAL` magic (8), major/minor (2 each), header size (4), random file ID (16), flags (8), reserved (8) |
| File header checksum | 32 | SHA-256 of the preceding 48 bytes |
| Record header prefix | 64 | `AIRTXN01` magic (8), LSN (8), previous LSN (8), payload length (8), file ID (16), flags (8), reserved (8) |
| Record header checksum | 32 | SHA-256 of the preceding 64 bytes |
| Transaction payload | variable | Opaque engine transaction bytes; at most 256 MiB per frame |
| Commit footer | 48 | `AIRCMT01` magic (8), LSN (8), SHA-256 of the full record header and payload (32) |

The first committed payload has LSN 1. Each later LSN must be exactly its
predecessor plus one, and the record's file ID must match its containing file.
The payload codec belongs to the transaction/MVCC layer; WAL never interprets or
partially applies a payload. SHA-256 detects accidental corruption. It does not
authenticate a file against someone able to rewrite both data and checksums.

Record length is bounded and its header is checked **before** allocation or using
that length to identify a torn tail. At the low-level WAL API, the 256 MiB bound
applies to each individual record, not the container total. The public transaction
engine adds a stricter `BinaryRowStore.max_bytes` limit to the **entire `.aires`
file**; its default is also 256 MiB. Applications using the normal `Session` API
must checkpoint or configure a larger storage limit before the whole file reaches
that bound.

## Recovery and incremental reads

A complete frame is replayable only when its record header, sequence, file ID,
commit marker, and full-record checksum all pass validation. A complete corrupt
frame is an error even when it is the last frame. Recovery does not silently
discard it, nor does it skip bytes to look for a later commit.

A physically incomplete final frame is ignored. An incomplete header must still
have a valid available magic prefix. The next append truncates that incomplete
tail while holding the OS lock, synchronizes the truncation, then writes the next
record. Recovery never truncates during a read. Newly observed complete records
are synchronized before they become visible, covering a previous writer that
died after writing a valid footer but before its synchronization or acknowledgement.

`wal_read_locked(path; from_offset=0)` fully validates and returns committed
records. `from_offset` may be the `end_offset` of a previously validated commit
for the same `file_id`; the fixed preceding footer recovers the base LSN, and only
new frames are scanned. The caller must detect a changed `file_id` and reload
before applying incremental records. Incremental operation intentionally does
not rehash old committed payloads on every statement; use a full read for a
whole-file corruption audit. The reader opens the file with write permission
because crash recovery can require a durability barrier.

The return value contains `file_id`, `major`, `minor`, `lsn`, `end_offset`,
`records`, `torn_tail`, and `physical_size`. Each `WALRecord` contains `lsn`,
`payload`, and `end_offset`. `wal_append_locked` returns the new `UInt64` LSN;
`filesize(path)` under the same lock gives the resulting commit end offset.
The public `wal_read`, `wal_append`, and `wal_create` acquire the lock themselves.

Append uses a verified per-process receipt to refresh incrementally rather than
rescan the complete historical file before each transaction. The WAL remains
append-only on the commit path. TinyServer schedules automatic maintenance by
WAL size or elapsed time; before replacing a segment with a checkpoint it
publishes a verified immutable archive of that complete prefix. A failed archive
aborts the checkpoint, so a capacity or I/O error cannot silently discard the
recovery window.

The embedded `Session` API remains explicit by default: callers can pass an
archive directory to `checkpoint!`, or use `archive_database!` in their own
maintenance job. Archive artifacts are self-contained WAL prefixes and support
LSN record-boundary PITR through `restore_database_at!`. See
[automatic checkpoints, WAL archives, and PITR](DURABILITY.md) for the policy,
capacity, and restore contract. Concurrent online replacement still requires
the engine's generation checks and cannot be implemented by simply renaming
files.

## Failure injection and verification

Set `AIRESDB_WAL_FAILPOINT` only in an isolated test process. Supported append
stages are `before_append`, `after_header`, `mid_payload`, `after_payload`,
`after_commit`, `before_sync`, and `after_sync`. Publication stages are
`before_publish` and `after_publish`. The default action forcibly terminates the
process with exit code 86. `AIRESDB_WAL_FAILMODE=error` injects an exception
instead. Write-stage injection flushes Julia's buffer so a process-crash test
actually leaves the intended physical prefix in the OS cache.

Run the focused suite with:

```sh
julia --startup-file=no --project=. test/wal_lowlevel.jl
```

The suite checks every truncation boundary of a final frame, corruption at every
byte of a complete final frame and file header, oversized lengths, stale LSNs,
invalid offsets, nested/task locks, concurrent processes, migration/replacement,
exception failpoints, crash failpoints, and lock release after forced process
termination. A successful process-crash test is deliberately not described as a
power-failure test.

References: [Julia file descriptors](https://docs.julialang.org/en/v1/base/io-network/#Base.fd),
[Julia SHA contexts](https://docs.julialang.org/en/v1.12-dev/stdlib/SHA/),
[Microsoft FlushFileBuffers](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-flushfilebuffers),
[Microsoft CreateFileW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew),
[Microsoft MoveFileExW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw).
