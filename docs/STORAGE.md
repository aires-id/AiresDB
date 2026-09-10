# ARSP-4 storage format

AiresDB keeps the existing `Database.aires` WAL as the transaction and
recovery authority. ARSP-4 adds a derived, page-based sidecar named
`Database.aires.pages`. The two files have deliberately different roles:

```text
Database.aires        committed checkpoint + WAL deltas (authority)
Database.aires.pages  ARSP-4 heap/index image (page data path)
```

This preserves compatibility with existing AiresDB databases. A database with
no sidecar creates one from recovered WAL state; a `.aires` file is never treated
as a page file or migrated in place. A sidecar whose WAL identity or applied LSN
does not match recovered WAL state is not accepted as current and is rebuilt from
that state when it is safe to replace. An invalid page magic, format, length, or
checksum is reported as a storage error; corruption is never treated as an empty
database.

## File layout

The sidecar begins with one 8 KiB superblock followed by fixed-size pages. The
production page size is `PAGE_SIZE = 8192`; tests may create isolated 4 KiB or
16 KiB files through the page-manager constructor.

```text
offset 0                 ARSP superblock: AIRESAR4, version, page size,
                         next page ID, free-list head, SHA-256 checksum
offset PAGE_SIZE          Page ID 1: page-store catalog
offset 2 * PAGE_SIZE      Page ID 2 and later: heap, B+Tree, metadata, free pages
```

Page IDs are `UInt64`. A page manager opens the file once for its lifecycle and
uses offsets derived from `page_id * page_size`; it does not open and close a
file per page operation.

## Common page header

Every data page starts with an 80-byte header:

```text
0..7    magic             AIRESPG4
8..9    page-format version
10      page type
11      flags
12..19  page ID (UInt64)
20..27  page LSN (UInt64)
28..29  slot count (UInt16)
30..31  free-space start (UInt16)
32..33  free-space end, exclusive (UInt16)
36..67  SHA-256 checksum over the page with this field zeroed
```

`read_page` verifies magic, version, bounds, page ID, and checksum. The
checksum detects accidental corruption; it is not an authentication mechanism.

Page types are free, heap, heap metadata, catalog, B+Tree metadata, B+Tree leaf,
and B+Tree internal. The catalog page stores the WAL file ID, the applied WAL
LSN/CSN, and table-to-heap/index metadata.

## Catalog and reclaim scope

The current PageStore catalog is one slotted 8 KiB page. A database whose table
and index metadata does not fit receives an explicit storage error; there is no
silent overflow to a `Dict` or an unversioned auxiliary file. The page manager
has a free-list primitive, but PageStore does not yet physically reclaim old heap
versions, B+Tree delete space, or superseded build pages. `vacuum!` only removes
logical MVCC history that no active snapshot needs; it does not compact or shrink
`.aires.pages`.

## Slotted pages and RID

Heap, catalog, and B+Tree node pages use a slotted layout. Slots grow upward;
payloads grow downward from the end of the page.

```text
┌───────────────────────────────────────┐
│ common header                          │
│ heap/catalog/B+Tree local metadata     │
│ slot 1 │ slot 2 │ ...                  │  ← grows upward
│                 free space             │
│                    record N            │
│                    record 2            │  ← grows downward
│                    record 1            │
└───────────────────────────────────────┘
```

A slot is eight bytes: `offset`, `length`, `flags`, and `generation`, each
`UInt16`. Page offsets are one-based and `free_end` is exclusive. A persistent
RID is `RID(page_id::UInt64, slot_id::UInt16)`.

Slots are never reused in the current format. Compaction moves only payloads,
so the RID remains stable. A deleted slot is a tombstone. If a raw record must
relocate, the previous terminal slot is rewritten as an `ARFW` forwarding payload
to a newly inserted target record. Reads resolve that chain; heap scans skip
forwarding slots. Later raw updates follow the terminal target before rewriting
it, preventing obsolete targets from becoming visible during scans.

That forwarding guarantee belongs to raw `heap_update_raw!`. PageStore MVCC
updates instead close the old heap version and append a new version, then update
the current row-to-RID mapping and index entries. A stable AiresDB application
identity is the logical row ID; its current physical RID may change after an
MVCC update, while the old RID continues to identify the old physical version.

## Heap records and MVCC

Heap records have a deterministic binary codec, with no Julia
`Serialization.serialize` payloads:

```text
record format version, flags, column count
row ID (UInt128)
begin CSN, end CSN
previous RID
schema epoch
typed AiresDB cells
```

The codec reuses AiresDB's exact Decimal and Money encodings, so neither is
reduced to `Float64`. A record is visible when
`begin_csn <= snapshot_csn < end_csn` and it is not a tombstone.

The logical MVCC history and certification structures remain in place. Page
latches protect short physical mutations; they do not replace snapshot
visibility, read/write sets, table epochs, or first-committer-wins.

## WAL and recovery boundary

The page manager rejects a dirty page flush when `page_lsn` exceeds its durable
WAL watermark. Commit execution does the following after AiresDB has certified
the transaction:

```text
WAL append + OS durability barrier
        ↓
ARSP P1/P2/P3 mutate heap and B+Tree pages
        ↓
flush data/index pages
        ↓
ARSP P4 writes catalog applied WAL identity + LSN and flushes it
        ↓
publish MVCC versions
```

If a failure occurs after the WAL durability point, AiresDB reports **Commit
Outcome Unknown** as before. The sidecar catalog remains at the old applied LSN
until all page data has flushed. On recovery, WAL replay reconstructs the
logical committed database and a stale sidecar is rebuilt. This is why a torn
or partial page application cannot silently publish a transaction.

Before replacing a stale image, a process tries to reopen and validate a sidecar
that another process may already have published. If a separate live process still
owns an older stale `.aires.pages` file, Windows sharing can prevent replacement;
AiresDB reports that storage error rather than writing around the open handle.
Generation-based copy-on-write sidecars are future work.

## Current read routing

The new pages are on the active data path for:

- public primary-key `lookup`;
- `scan_rows`;
- single-table projection/filter/`Limit` queries, streamed in bounded heap
  batches;
- single-table non-aggregate `M:` ordering when bare order columns exactly match
  a primary/unique B+Tree, all directions agree, the columns are declared
  `NOT NULL`, and the current snapshot is available.

The source traversal above uses bounded batches (256 rows by default), but the
legacy public `scan_rows` API still returns a materialized `Vector` and SELECT
still materializes its final `QueryResult.rows` for the caller. It does not first
materialize a second source-table vector on the physical simple-query route.

Joins, grouping, aggregates, mixed-direction ordering, nullable index ordering,
any snapshot whose CSN differs from `store.applied_csn`, and any table with a
local transaction overlay correctly fall back to the existing relational/MVCC
executor. This preserves AiresQL behavior while those operators are migrated to
fully streaming physical operators.

## Current execution and concurrency bounds

`RollingScheduler` has four generic lanes and a bounded ingress queue, but the
current PageStore facade holds its store mutex while it submits and completes one
public lookup, scan batch, index batch, or commit work unit. P2 cache misses are
delegated to `Threads.@spawn`, park only their lane, and resume by signaling the
scheduler `Base.Event`, so ready lanes can advance in the same tick. The scheduler's
rolling state machine is real and directly tested with four independent work
units, but ordinary PageStore API calls do not yet overlap four public physical
requests. Deeper B+Tree/heap traversal in P3 can still use a synchronous fetch.
See [ARSP4.md](ARSP4.md) for the distinction.
