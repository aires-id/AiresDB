# Audit lanjutan ARSP-4

Dokumen ini adalah audit implementasi storage **ARSP-4 -- Aires Rolling Storage
Pipeline** pada AiresDB v0.1.0. Ia melengkapi
[AUDIT-v0.1.0.md](AUDIT-v0.1.0.md): hasil perangkat 3 September yang dicatat di
audit lama adalah baseline sebelum PageStore ARSP-4, bukan bukti performa jalur
page baru.

## Batas audit

ARSP-4 menambah file turunan `<database>.aires.pages`; file `.aires` tetap WAL
dan satu-satunya authority untuk recovery. Implementasi tidak mengganti lexer,
parser, AiresQL, MVCC logical, transaction certification, atau format WAL lama.
Dengan demikian perubahan dapat dipulihkan dari WAL yang sudah tervalidasi dan
database `.aires` yang sudah ada tidak ditafsirkan diam-diam sebagai format page
baru.

Jalur fisik yang telah terintegrasi adalah lookup primary key, `scan_rows`,
SELECT satu tabel tanpa global ordering/group/aggregate, dan `M:` bila bare order
columns tepat cocok dengan primary/unique B+Tree, semua arah sama, seluruh kolom
order dideklarasikan `NOT NULL`, dan snapshot terbaru dipakai.
Join, grouping, aggregate, mixed-direction ordering, nullable index ordering,
read-your-writes, dan snapshot yang lebih lama tetap memakai jalur MVCC/
relational lama untuk menjaga semantik AiresQL.

## Arsitektur yang diaudit

```text
                    AiresQL / API
                          |
                       Executor
                          |
             current physical read/write plan
                          |
              ARSP-4 RollingScheduler
              P1 -> P2 -> P3 -> P4
              lanes 0, 1, 2, 3
                          |
        +-----------------+-----------------+
        |                 |                 |
      heap             B+Tree            catalog
        +-----------------+-----------------+
                          |
                    BufferPool
                          |
             PageManager (8 KiB production)
                          |
                 <database>.aires.pages

MVCC certification -> durable .aires WAL -> P3 dirty pages -> P4 catalog marker

P2 cache hit: cached frame -> continue
P2 cache miss: park lane -> bounded worker -> scheduler Base.Event -> resume lane
```

The four lanes are generic storage slots, not fixed operation types and not a
`Threads.@threads` wrapper. Every scheduler tick advances each ready lane at
most one phase, retires completed/error work, then admits queued work to empty
lanes. Its ingress queue and completion history are bounded.

## Format and durability findings

| Area | Implemented behavior | Audit consequence |
| --- | --- | --- |
| Page manager | Versioned `AIRESAR4` superblock; fixed-size pages; default 8 KiB; `UInt64` IDs; SHA-256 page checksum | Corrupt magic/version/length/checksum is a storage error, never an empty database. |
| Slotted heap | Stable slot IDs, payload compaction, tombstone slots, forwarding RID when a raw record relocates | Compaction does not change a live `RID(page_id, slot_id)`; PageStore MVCC update appends a new version, so a logical row's current RID may change. |
| Record codec | Deterministic binary encoding for typed AiresDB cells and MVCC metadata | Decimal and Money retain exact encodings; Julia `Serialization.serialize` is not used. |
| Buffer pool | Fixed 64-frame default, pin count, per-frame latch, Clock replacement | A pinned page is not evicted; dirty flush calls the page manager. |
| B+Tree | Persistent metadata/leaf/internal pages, leaf sibling links, point/range/cursor traversal | It is not a `Dict` dumped at checkpoint; current tree latch serializes each reader/writer operation and cursor batch. |
| WAL boundary | Page manager rejects flush if `page_lsn` is newer than durable WAL LSN | Dirty committed pages cannot be written ahead of their commit record. |
| Publication | Catalog records WAL file identity and applied LSN/CSN after dirty data/index pages flush | An interrupted publication leaves a sidecar that can be rejected and rebuilt from recovered WAL state. |

The PageStore does not silently accept a mismatched WAL identity or LSN. It first
tries to reopen a complete sidecar published by another process; otherwise an
unowned stale image is rebuilt from the recovered logical database. If a separate
live process still owns a stale `.aires.pages` file, Windows sharing can prevent
replacement and AiresDB surfaces a storage error rather than writing around the
handle.

## Scheduler findings

The core scheduler has exactly four lanes and explicit states `EMPTY`, `PHASE1`,
`PHASE2`, `PHASE3`, `PHASE4`, `BLOCKED_IO`, `BLOCKED_LATCH`, `DONE`, and `ERROR`.
P2 uses the bounded buffer pool; a fully pinned pool blocks only that lane. The
owner must call `resume_lane!` after an explicit blocked resource becomes ready;
for a registered P2 acquisition, `run_until_complete!` waits on the scheduler
`Base.Event` rather than spinning. P2 cache misses create a per-work state and
delegate `fetch_page_wait!` to `Threads.@spawn`; the worker resumes only its
original lane after it has unpinned the acquired page.

The scheduler is deterministic and tick-driven, while P2 has a bounded
asynchronous acquisition worker per blocked lane. PageStore currently holds its
store mutex while a public lookup, scan batch, index batch, or commit submits and
runs one work unit. The public PageStore facade therefore does **not** yet expose
four simultaneous physical requests. P2 removes the first-page cache-miss stall,
but a deeper B+Tree/heap traversal in P3 can still take the synchronous fetch
path. This is a deliberate correctness limit, not an unlimited-concurrency or
four-thread-throughput claim.

## Test gate

The earlier ARSP integration checkpoint completed with 2,414 passing assertions;
that count is historical only. The final optimization gate on 7 September 2026 ran the
package test with startup-file isolation, exited with status 0, and recorded
**2,438/2,438 assertions passing**:

```sh
julia --startup-file=no --project=. -e 'using Pkg; Pkg.test()'
```

The final ARSP groups were **55/55** page-storage primitives, **28/28** rolling
scheduler, and **24/24** WAL/PageStore integration. The rest of the package
contributed 2,327 assertions. Targeted four-thread checks additionally ran
`test/arsp_pipeline_tests.jl` at 28/28 and
`test/pagestore_integration_tests.jl` at 24/24.

The ARSP groups cover page allocation/reopen/checksum, slotted-page edge cases,
RID persistence, bounded buffer behavior, B+Tree leaf/internal/root split,
bulk-load sorting/duplicate atomicity/reopen, rolling-tick order, blocked-lane
progress, backpressure, WAL-before-page publication, failure injection,
checkpoint/reopen, and atomic unique-key swap. The scheduler's asynchronous-wait
test registers four parked lanes, places a fifth request in the queue, and
verifies that `run_until_complete!` waits for the `Base.Event` rather than
burning its tick limit. The cold-reopen regression covers the fast P2 completion
race: the blocked/async decision and `Base.Event` reset occur under the scheduler
mutex, so a completed acquisition is retried rather than losing its notification.

The benchmark and TPC-derived evidence below was generated from the engine source
exercised by that final gate. Their report file, hardware, Julia version, sample
count, warmup, directory, and durability mode are part of the evidence; no device
number is inferred by this document.

## Reproducible measurements

```powershell
julia --project=. benchmark/arsp4.jl --rows=100000 --batch=5000 --samples=500 `
  --directory=work/arsp4_run --output=verification/arsp4.toml

julia --project=. benchmark/run.jl tpcc --transactions=500 --warmup=25 `
  --directory=work/tpcc_run --output=verification/tpcc.toml

julia --project=. benchmark/run.jl tpch --scale=0.001 --repetitions=5 --warmup=1 `
  --directory=work/tpch_run --output=verification/tpch.toml
```

`arsp4.jl` reports bulk insert, reopen/warm scan, PK lookup, predicate range,
direct persistent B+Tree range, indexed `M:`, update, delete, checkpoint,
reopen, RSS, file/WAL bytes, buffer statistics, and pipeline statistics. Its
4/8/16 KiB probes exercise an isolated page manager; PageStore production format
remains 8 KiB. The TPC-C/TPC-H drivers remain exploratory TPC-derived workloads,
not compliant or certified TPC results and not sources of `tpmC` or `QphH`.

## Device evidence from the final run

The local ARSP-4 runs used Windows NT, an Intel Core i5-2400S, 8.56 GB RAM,
Julia 1.12.7, and four Julia threads. Production sidecars used 8 KiB pages.

| Rows / batch | Bulk rows/s | Cold scan rows/s | Warm scan rows/s | Peak RSS |
|---:|---:|---:|---:|---:|
| 10,000 / 10,000 | 2,019.98 | 20,137.97 | 202,957.08 | 1,087,524,864 B |
| 100,000 / 100,000 | 2,258.96 | 100,146.45 | 153,251.26 | 2,327,973,888 B |
| 250,000 / 250,000 | 2,102.64 | 140,308.33 | 190,531.98 | 4,828,901,376 B |

The 10K run has 30 samples (except one-shot operations); the 100K and 250K
runs intentionally have one sample, so their percentile fields are not presented
as tail-latency evidence. `process cold` reopens the session/page manager after
releasing the prior session; it does not flush the operating-system cache. The
table preserves the historical baseline used to assess the final 250k report.

## Final bounded-memory and transaction gates

The 7 September optimization run used the same 250,000-row, one-transaction
workload as the 4,828,901,376-byte baseline. Its deployment profile used one
Julia thread, `--optimize=0`, `--heap-size-hint=96M`, and the stripped O0
sysimage documented in `benchmark/sysimage/README.md`. The complete run exited
successfully, reopened exactly 250,000 rows, and recorded a peak RSS of
**659,251,200 bytes (628.71 MiB)**. This is an **86.35% reduction** or **7.32x
smaller** than the baseline and is 25,748,800 bytes below the 685 MB gate.

| Final 250k metric | Result |
|---|---:|
| Rows after reopen | 250,000 |
| Peak RSS | 659,251,200 B |
| Bulk insert | 23.760 rows/s |
| Process-cold sequential scan | 20,436.598 rows/s |
| Warm sequential scan | 23,100.416 rows/s |
| Page sidecar | 51,060,736 B |
| WAL | 21,889,355 B |

The low-memory bulk loader performs full collection at bounded heap/leaf
publication points. That trades initial-load speed for a stable high-water mark;
the report does not present 23.760 rows/s as the general transaction rate.
Scans consume 256-row page batches and still visit all rows without retaining a
second 250,000-row result graph.

The separate O1 transactional profile completed 500 measured TPC-C-derived
transactions at **97.185 tx/s**, with 500 commits, zero errors, zero retries,
and all six consistency checks true. This is **9.95x** the 9.772 tx/s ARSP
baseline and exceeds the 70 tx/s gate. It remains an engineering TPC-derived
result, not certified `tpmC`. Raw evidence is
`verification/arsp4-250k-final-v17-stream.toml`,
`verification/tpcc-memory-final-500.toml`, and the current package-test log
`verification/pkg-test-v010-final.log`.

The final TPC-H-derived rerun used synthetic scale 0.001, one warmup and one
measured repetition for every Q01--Q22 plan. It exited successfully and the
independent SQLite SQL oracle accepted every complete result set. The raw report
is `verification/tpch-memory-final.toml`; the oracle detail is
`verification/tpch-memory-final-oracle.json`. One measured sample per query is a
correctness/reproducibility gate, not tail-latency evidence.

## Known limits and next checks

1. PageStore stores only the current physical image. Older snapshots and local
   write overlays fall back to logical MVCC history.
2. The PageStore catalog currently fits in one 8 KiB page. Excess table/index
   metadata fails explicitly; it does not spill to an unversioned structure.
3. B+Tree delete does not rebalance/merge leaves, shrink roots, or recycle pages.
   Initial bulk load is now bottom-up and packed; ordinary incremental mutation
   still decodes and rewrites a node, so slot-level search remains a hot-path
   optimization target.
4. PageStore public work units are serialized per store. P2 cache misses use a
   bounded asynchronous worker, but P3 can still fetch deeper B+Tree/heap pages
   synchronously. Releasing the facade mutex and extending nonblocking
   acquisition through P3 are required before claiming request-level four-lane
   concurrency.
5. A stale sidecar held open by another process is reported rather than replaced
   on Windows. Copy-on-write sidecar generations would remove that maintenance
   conflict.

The next implementation priority is to preserve the existing WAL/MVCC boundary
while adding multi-page catalog/reclaim, nonblocking P3 acquisition, and
page/batch implementations for join, aggregate, and range predicate planning.
