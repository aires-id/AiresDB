# ARSP-4 — Aires Rolling Storage Pipeline

ARSP-4 is AiresDB's storage scheduler. It is a deterministic rolling pipeline,
not a synonym for four worker threads. It has four generic lanes and moves a
ready work unit by at most one phase per tick.

```text
Tick 1      A:P1
Tick 2      A:P2  B:P1
Tick 3      A:P3  B:P2  C:P1
Tick 4      A:P4  B:P3  C:P2  D:P1
Tick 5      E:P1  B:P4  C:P3  D:P2     (A has completed and its lane is reused)
```

The implementation lives in `src/storage/rollingpipeline.jl` and is used by
the page-store read, index, and publication paths.

## Work unit and lanes

`StorageWorkUnit` carries the request ID, operation kind, database/table,
optional RID, encoded key, target-page hint, snapshot CSN, transaction ID, and
phase context. Operation kinds are:

```text
POINT_LOOKUP
SEQUENTIAL_SCAN
WRITE
INDEX
```

There are exactly four `StorageLane` values, numbered 0 to 3. A lane accepts any
operation; it is never permanently assigned to one work type.

```text
EMPTY → PHASE1 → PHASE2 → PHASE3 → PHASE4 → DONE → EMPTY
                    │         │
                    └─────────┴→ BLOCKED_IO / BLOCKED_LATCH → resume → phase
                                                   │
                                                   └────────→ ERROR → EMPTY
```

Completion and failure are retained in a bounded completion history so callers
can retrieve `request_result`. An ingress ring queue is bounded separately.
`submit!` always enters that ring first and raises an explicit ARSP-4
backpressure storage error when the ring is full, even if a later `tick!` could
have admitted work into an empty lane. A tick then admits at most four active
work units into the four lanes; no unbounded queue is allocated.

## Four phases

| Phase | Scheduler responsibility | Page-store use |
| --- | --- | --- |
| P1 — intake/planning | Classify and bind request metadata. No disk write occurs. | Creates a scan, point lookup, index scan, or WAL-durable write plan. |
| P2 — page acquisition | Buffer lookup, pin/prefetch, async cache-miss acquisition, or park the lane. | Scan/index work attempts to pin the next heap/B+Tree page. A cache miss is delegated to a bounded per-lane worker; a full pool remains `BLOCKED_IO` and increments buffer-wait statistics. |
| P3 — record/index processing | Decode slotted records, inspect B+Tree entries, apply visibility, or stage mutation. | Scan decodes one bounded visible batch. Point lookup traverses B+Tree then heap. Write mutates version records and index pages only after WAL durability. |
| P4 — publication | Emit batch/result or make a durable page image visible. | Scan/index returns a row batch. Write flushes the applied-LSN catalog marker after data/index pages are durable. |

Phase functions return an explicit `StoragePhaseResult`: advance, blocked I/O,
blocked latch, or complete. A blocked lane remains parked; `resume_lane!` is
called by the owner once its resource is ready. A P2 handler that registers an
async page acquisition later resumes its own lane and signals the scheduler's
`Base.Event`; `run_until_complete!` resets and waits for that registered work without
busy-spinning. A manually blocked lane without an async owner still reports a
storage error until an owner calls `resume_lane!`. A handler that promptly
returns `BLOCKED_IO` or `BLOCKED_LATCH` cannot prevent other ready lanes from
advancing on the same tick.

## API

```julia
scheduler = RollingScheduler(queue_capacity=64)
request_id = submit!(scheduler, work)
tick!(scheduler)
result = run_until_complete!(scheduler, request_id)
resume_lane!(scheduler, 0)
pipeline_stats(scheduler)
```

`pipeline_stats` reports active lanes, queued/completed/failed work, I/O,
latch, buffer, and asynchronous waits, tick count, utilisation, and a current
lane snapshot. The page-store statistics returned by `storage_stats(session)`
include these pipeline counters together with buffer-pool and page-manager
counters.

## Buffer misses and read-ahead

P2 first uses the cache-only `try_fetch_cached_page!`. On a miss it attaches a
per-work acquisition state, parks that lane, and starts `Threads.@spawn` to call
the bounded `fetch_page_wait!` worker. The worker unpins the acquired page and
resumes the original lane while signaling the scheduler `Base.Event`; unrelated ready
lanes can therefore advance in the same rolling window. The worker count is
bounded by the four active lanes, not by ingress queue length. Heap batch
iteration prefetches the next linked page after the current page is exhausted,
warming it without retaining a pin. Pinned frames cannot be evicted.

## Current PageStore integration limit

The generic scheduler can hold four independent direct submissions in its four
lanes, and its rolling order/backpressure/blocked-lane behavior is tested.
Current PageStore wrappers, however, hold the store mutex across `submit!` and
`run_until_complete!` for each lookup, scan batch, index batch, or commit work
unit. Normal public PageStore calls are therefore serialized per store. P2
removes the first-page cache-miss stall, but a deeper B+Tree or heap traversal in
P3 can still call the synchronous buffer fetch path. This release does not claim
unlimited physical concurrency or a fully asynchronous P3 traversal.

## MVCC and WAL interaction

ARSP-4 is a physical scheduler. A latch protects a page/frame only while its
bytes or structural pointers are read or changed. MVCC still decides which row
version a transaction can observe; certification still checks row/table/catalog
epochs and first-committer-wins conflicts.

For writes, P2 records the durable WAL watermark and P3 cannot flush a page
whose page LSN is greater than it. P4 writes the sidecar applied-LSN catalog only
after dirty data/index pages are durable. This keeps WAL-before-data and the
existing Commit Outcome Unknown behavior intact.
