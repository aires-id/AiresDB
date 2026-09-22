# Automatic checkpoints, WAL archives, and PITR

AiresDB commits by appending one durable WAL record. TinyServer can compact that
append-only history automatically without putting backup work on the transaction
hot path.

## Default server policy

TinyServer evaluates only databases opened by its shared Engine. For a database
with uncheckpointed commits, it runs maintenance when either threshold is met:

| Setting | Default | Meaning |
|---|---:|---|
| `--auto-checkpoint-wal-bytes` | `67108864` (64 MiB) | Checkpoint when the current WAL segment reaches this size. |
| `--auto-checkpoint-interval` | `300` seconds | Checkpoint an active WAL segment after this much time. |
| `--wal-archive-directory` | `<data-root>/wal-archive` | Root directory for immutable archive artifacts. |
| `--wal-archive-max-bytes` | `0` | Archive capacity guard; `0` delegates retention/capacity to the operator. |

The timer only reads cached handle metadata while deciding whether work is due.
Normal commits still perform their usual WAL append and durability barrier; they
do not scan, copy, or checksum an archive.

When maintenance runs, AiresDB validates and publishes an immutable archive of
the current complete WAL prefix **before** publishing the replacement
checkpoint. If the archive cannot be created, including because a configured
capacity limit is exhausted, the checkpoint fails and the original WAL remains
authoritative. AiresDB never silently discards a recoverable WAL segment.

The archive and checkpoint are maintenance I/O, so they briefly serialize
writers for the current WAL segment. Keep the byte threshold below the normal
storage ceiling and select a value appropriate for the write rate and storage
throughput. The default 64 MiB threshold is deliberately well below the 256 MiB
default logical-WAL limit.

## Production configuration

Place the archive on a volume with enough capacity for the intended recovery
window, preferably in a different failure domain from the live database. A local
WAL archive detects corruption and supports operational recovery; it is not a
replacement for an off-host/off-site backup policy.

For example:

```text
airesdb server --data-root D:\AiresDB\data --wal-archive-directory E:\AiresDB-archive --wal-archive-max-bytes 21474836480 --auto-checkpoint-wal-bytes 67108864 --auto-checkpoint-interval 300
```

The same option names work on other platforms. A positive
`--wal-archive-max-bytes` is a fail-safe guard: once the
limit is reached, automatic checkpointing reports a failure rather than deleting
older recovery points. Plan retention and external archive rotation explicitly.

Manual `.checkpoint` commands issued through TinyServer use the same archive
policy. The server audit log records `auto_checkpoint` or
`auto_checkpoint_failed` events.

## Archive layout and verification

Each database receives its own directory:

```text
wal-archive/
  Perusahaan/
    20260922T101530123-<uuid>.aires.wal-archive
    20260922T101530123-<uuid>.toml
```

The artifact is a native, checksummed container for one complete validated WAL
prefix. Its TOML manifest records the database name, capture time, WAL file ID,
LSN, byte length, and SHA-256 digest. Names are UUID-derived and artifacts are
published only once; AiresDB never overwrites an existing archive point.

Checksums detect accidental corruption. They do not authenticate an archive
against an attacker who can modify both data and manifest, so protect archive
directories with operating-system access controls and an independent backup
destination.

## LSN point-in-time restore

Every archived WAL begins with a full checkpoint, so it is independently
restorable. An archive can also be restored at any committed LSN inside that
artifact. This is precise record-boundary PITR; no partial/torn record is ever
selected.

```julia
using AiresDB

points = AiresDB.list_wal_archives("E:/AiresDB-archive", "Perusahaan")
point = last(points)

# Restore the final committed record in this archive.
AiresDB.restore_database_at!("./restored", "Perusahaan",
    "E:/AiresDB-archive", point.id)

# Or restore an earlier committed record from the same independent segment.
AiresDB.restore_database_at!("./restored-before-change", "Perusahaan",
    "E:/AiresDB-archive", point.id; lsn=point.lsn - 1)
```

The timestamp overload selects the newest archive captured at or before a UTC
`DateTime`:

```julia
using AiresDB, Dates

AiresDB.restore_database_at!("./restored", "Perusahaan", "E:/AiresDB-archive";
    at=DateTime(2026, 9, 22, 10, 15))
```

Capture time is a safe lower-bound selector, not a transaction timestamp. Use
the archive ID plus LSN when an exact commit boundary matters.

As with native restore, stop all AiresDB sessions and processes that use the
target database before restoring. The `.aires.pages` sidecar is derived and is
rebuilt when the restored database is opened.

## Embedded maintenance API

Applications using the embedded maintenance API can create an archive before a
manual checkpoint:

```julia
using AiresDB
using AiresDB.Internal: Session, execute!, checkpoint!

session = Session("./data")
try
    execute!(session, "Pilih 'Perusahaan' -:")
    checkpoint!(session; archive_directory="./wal-archive",
        archive_max_bytes=20 * 1024^3)
finally
    close(session)
end
```

The public path-based helper is suitable for an external scheduler:

```julia
using AiresDB

AiresDB.archive_database!("./data", "Perusahaan", "./wal-archive")
```

Do not run an external checkpoint scheduler concurrently with TinyServer unless
it uses the same current AiresDB version and operational ownership is clear.
