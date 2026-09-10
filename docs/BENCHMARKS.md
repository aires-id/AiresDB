# AiresDB v0.1.0 benchmark workloads and reproducibility

> Benchmark di direktori ini adalah harness internal engine. Ia bukan API
> penggunaan aplikasi; client produksi tetap wajib melalui TinyServer.

This repository implements all **five TPC-C transaction families** and **22 TPC-H query families** as exploratory, TPC-derived workloads. Results are **not audited or compliant TPC-C/TPC-H benchmark results**. Do not compare their throughput with published `tpmC` or `QphH` results; neither official metric is computed here.

The reference specifications are [TPC-C revision5.11.0](https://www.tpc.org/TPC_Documents_Current_Versions/pdf/tpc-c_v5.11.0.pdf) and [TPC-H revision3.0.1](https://www.tpc.org/tpc_documents_current_versions/pdf/tpc-h_v3.0.1.pdf). The implementations below are derived application workloads with explicitly documented differences.

## Run on this computer

From the AiresDB project directory, with Julia1.12:

```powershell
julia --project=. benchmark/run.jl tpcc --transactions=500 --warmup=25 --directory=work/c_run --output=verification/tpcc.toml
julia --project=. benchmark/run.jl tpch --scale=0.001 --repetitions=5 --warmup=1 --directory=work/h_run --output=verification/tpch.toml
```

Each invocation requires a new database directory; it never deletes a prior run. Data loading and query correctness checks are excluded from measured query latencies. TPC-C warmup transactions modify the database and remain committed, as in an ordinary warmup. Use `--seed=20260903` to reproduce input generation. Run workloads sequentially and avoid other heavy applications when measuring. The report includes seed, exact cardinalities, load duration, Julia/OS details, sample count, nearest-rank p50/p95, minimum/maximum, errors/retries, and throughput. Small sample p95 values are exploratory, not a stable tail-latency estimate. Per-type `mix_operations_per_second` divides that type's count by the entire mixed workload duration; `operations_per_second` describes its measured service rate. Read-only transaction commits do not append a WAL record; all write commits use the engine's durable flush.

TPC-C options: `--warehouses=1 --districts=10 --customers=100 --items=1000 --transactions=500 --warmup=25`. `--profile=canonical` changes item and customer counts to100000 items and3000 customers per district, while retaining all other disclosed generator/driver differences. The full cardinality profile may require considerably more memory and load time than the reduced profile; it is not automatically selected. Read-only Order-Status and Stock-Level are included among committed transactions; expected invalid-item rollbacks are counted separately.

TPC-H options: `--scale=0.001 --repetitions=5 --warmup=1`. Defaults correspond to nominal200 parts,150 customers,1500 orders, with supplier count floored at25 and explicit extra correctness coverage rows. Actual cardinalities, including variable line counts and coverage rows, are written to the report. These are synthetic scale parameters, **not an official TPC-H scale factor claim**. An independent Python3 SQLite oracle runs by default; pass `--python=C:\path\python.exe` or set `AIRESDB_PYTHON` if Python is not found. `--oracle=false` is available for controlled repeat measurements but records that validation did not run.

For externally generated official DBGEN data, add `--dbgen-directory=C:\path\to\tbl-files --scale=1` with the actual generation scale. The importer expects all eight unmodified `table.tbl` files, converts monetary/rate fields exactly, rejects precision loss, and loads through the same public engine API. It does not download or bundle DBGEN and does not independently verify the external generator's version or seed. Importing official data alone does not satisfy the omitted benchmark execution/audit requirements. The recorded device measurements identify whether synthetic generation or imported data was used.

## Transaction coverage

| Transaction | Behavior exercised |
|---|---|
| New-Order | Warehouse/district/customer reads, order and new-order inserts,5–15 order lines, local/remote stock update, exact tax/discount result, missing final item rolls back all earlier writes |
| Payment | Warehouse/district totals, local/remote customer, lookup by id or lower median first-name order for matching last names, balance/history update, bad-credit data prepend |
| Order-Status | Customer selection, newest order, all order lines |
| Delivery | Oldest pending order in each district, queue deletion, carrier/delivery time updates, customer balance and delivery count |
| Stock-Level | Distinct items from the previous20 orders, stock below threshold |

All nine logical tables are stored in AiresDB. Natural compound keys use the engine's compound primary-key support; history has an additional surrogate identifier. Every table load and transaction uses the public transaction, scan, lookup and CRUD APIs. Monetary values are signed integer cents; tax/discount are basis points. New-Order's final tax/discount expression is an exact rational number of cents, so the driver does not silently round a financial result.

The measured mix is shuffled in100-operation blocks with45% New-Order,43% Payment and4% each of the remaining types. Incomplete final blocks may differ; per-type actual counts are reported. One percent of New-Order requests select a missing final item. Remote stock1% per order line and remote Payment15% are enabled when more than one warehouse exists. Sixty percent of Payment and Order-Status use last-name customer selection. Runtime uniform item/customer identifiers replace the specification's NURand distribution, and initial last names cycle deterministically. Initial reduced warehouse/district monetary totals scale with customer count to preserve accounting consistency. All addresses/comments are shortened synthetic values. The driver is a single closed-loop session, has no terminal think/keying times or prescribed measurement-duration gate, and Delivery runs synchronously. These differences prevent compliance claims.

Consistency verification checks warehouse/district YTD sums, district next-order identifiers, order-line counts, pending-order references, customer balances against delivery amounts and payment history, and customer YTD against history. Independent expected-state tests cover all five transactions, remote behavior, lower-median selection, and whole-transaction rollback after partial staging.

## Analytical coverage

All22 plans use the engine's generic relational operators and a pinned public snapshot. There is no precomputed answer cache or auxiliary analytical database in the measured path. Money is represented by exact integer cents and discount/tax by integer percentages; final ratios use exact rational arithmetic. Dates use ISO `YYYY-MM-DD` strings with equivalent lexicographic date predicates for these workloads.

| Query | Business family | Fixed parameters |
|---|---|---|
| Q01 | Pricing summary |90 days before1998-12-01 |
| Q02 | Minimum-cost supplier | size15, BRASS, EUROPE |
| Q03 | Shipping priority | BUILDING,1995-03-15 |
| Q04 | Order priority |1993-07-01 through next quarter |
| Q05 | Local supplier revenue | ASIA,1994 |
| Q06 | Forecast revenue change |1994, discount5–7%, quantity<24 |
| Q07 | Bilateral shipping | FRANCE/GERMANY,1995–1996 |
| Q08 | National market share | AMERICA/BRAZIL, ECONOMY ANODIZED STEEL,1995–1996 |
| Q09 | Product profit | green part names |
| Q10 | Returned item reporting |1993-10-01 through next quarter, returned lines |
| Q11 | Important stock | GERMANY, fraction0.0001/scale |
| Q12 | Shipping modes | MAIL/SHIP,1994 receipts |
| Q13 | Customer distribution | exclude `%special%requests%` |
| Q14 | Promotion effect | September1995 |
| Q15 | Top supplier | January–March1996 |
| Q16 | Parts/supplier relationships | exclude Brand#45, MEDIUM POLISHED, eight specified sizes |
| Q17 | Small-quantity order revenue | Brand#23, MED BOX |
| Q18 | Large-volume customer | order quantity>300 |
| Q19 | Discounted revenue | Brand#12/#23/#34; quantity bands1–11/10–20/20–30; AIR/AIR REG |
| Q20 | Potential part promotion | forest prefix, CANADA,1994 |
| Q21 | Suppliers with delayed orders | SAUDI ARABIA; exactly one late supplier and another supplier present |
| Q22 | Global sales opportunity | telephone codes13/31/23/29/30/18/17, high balance, no orders |

The generator is **not official DBGEN/QGEN**. It uses deterministic Julia MersenneTwister random numbers, simplified dimensions, synthetic addresses/comments, uniform selection, dense order keys, variable1–7 lines, and added hand-designed positive/edge cases. Coverage rows add five parts,30 partsupp records, seven customers,12 orders and22 lineitems. Coverage orders deliberately target unusual combinations (the seven-line order has total quantity350) to exercise Q18 at tiny size. Supplier minimum25, customer minimum25 and other size floors also differ from DBGEN. Exact actual counts are authoritative. At synthetic scale0.0001, Q11's fraction is1 and its empty result is mathematically correct; larger scales exercise nonempty Q11 results. Tests independently verify the empty case and all other query families.

The implementation supports all22 query semantics, including correlated aggregate replacements, semi/anti joins, left outer joins, distinct supplier counts and exact arithmetic. It uses fixed validation-style parameters rather than QGEN random substitutions. Queries run through the native Julia relational API alongside the existing AiresQL syntax. The measurement omits TPC-H refresh functions, mandated power/throughput stream procedures, minimum official dataset sizes, pricing, availability and independent TPC audit. These results cannot establish official TPC-H compliance.

## Correctness oracle and measurement boundaries

`benchmark/oracle.py` imports public AiresDB scan exports into **SQLite memory only**, executes independent SQL for all22 queries, verifies each query's declared ORDER BY keys, and compares complete result multisets. Output rows tied on all SQL ordering keys may be permuted; comparisons tolerate only final SQLite binary-floating arithmetic (`rel_tol=1e-11`, `abs_tol=1e-7`). AiresDB calculations retain exact integers/rationals. SQLite is neither linked to AiresDB nor used during any measured query. No `.db`/`.sqlite` artifact is produced.

`test/benchmark_tests.jl` runs transaction expected-state checks plus the22-query oracle against a small fixture. The command-line benchmark validates the actual larger measured H dataset again before timing. Warmup is separate; each query repetition rescans the public database snapshot and recomputes its full relational plan. Reports preserve sample counts and actual row counts. The driver does not extrapolate small-scale numbers to larger data or other computers.

## Release evidence

Raw reports produced on the release computer belong in `verification/` and must be
kept together with the tested source. The concise device result and the audit
interpretation are recorded in [AUDIT-v0.1.0.md](AUDIT-v0.1.0.md). A result is
reproducible only with its hardware/OS, Julia version and thread count, seed,
generator/import mode, exact cardinalities, warmup, repetitions, durability mode,
and oracle status. Throughput from a reduced synthetic run remains an AiresDB
engineering measurement; recording more metadata does not turn it into an
official TPC result.

## ARSP-4 storage-path benchmark

`benchmark/arsp4.jl` measures the page-based ARSP-4 path separately from the
TPC-derived drivers. It creates a fresh database directory and exercises batched
bulk insert, sequential scan after a process reopen and with a warm buffer pool,
primary-key lookup, range predicates, direct persistent B+Tree range traversal,
`M:` ordered index traversal, update, delete, checkpoint, and reopen.

```powershell
julia --project=. benchmark/arsp4.jl --rows=100000 --batch=5000 --samples=500 --warmup=10 `
  --directory=work/arsp4_run --output=verification/arsp4.toml
```

The report contains raw latency samples plus nearest-rank p50/p95/p99,
rows/operations per second, peak process RSS, file sizes, WAL bytes, page-manager
counts, buffer hit/miss/eviction/flush statistics, and ARSP-4 pipeline statistics.
Use a new `--directory` for every run; the script refuses to overwrite a database
or a page-size probe.

The default page-size probe uses 4 KiB, 8 KiB, and 16 KiB. Those probes benchmark
the isolated `PageManager` only; the production PageStore format remains 8 KiB.
"Process cold" means that the Julia page manager and session were reopened. It
does not flush the operating-system file cache, so it is not a claim of physical
disk cold-cache latency. Before each timed reopen, the closed prior session is
released and collected outside the timing interval so the result does not
measure two complete in-process catalog images competing for memory.
`range_predicate_query` records the current AiresQL
predicate path; `persistent_btree_range` records the physical B+Tree primitive
separately so the two paths are not conflated.

### Bounded-memory release profile

The reproducible 250,000-row memory command and sysimage build are in
`benchmark/sysimage/README.md`. The final 7 September 2026 run completed with
659,251,200 bytes peak RSS and 250,000 rows after reopen. The earlier identical
cardinality/batch baseline was 4,828,901,376 bytes. Bounded 256-row scan
consumption prevents benchmark result retention from being counted as storage
memory; every scan still consumes the complete table.

The memory profile deliberately uses O0 and aggressive collection at initial
heap/B+Tree publication boundaries, yielding 23.760 bulk rows/s. Transaction
throughput is measured separately with O1: the final 500-transaction reduced
TPC-C-derived run reached 97.185 tx/s with 500 commits, no errors or retries,
and six consistency checks passing. These are local engineering gates, not
official TPC metrics. Raw reports are
`verification/arsp4-250k-final-v17-stream.toml` and
`verification/tpcc-memory-final-500.toml`.

The matching final TPC-H-derived run executed Q01--Q22 at synthetic scale 0.001
with one warmup and one measured repetition. The independent SQLite oracle
passed all result sets. Its raw evidence is
`verification/tpch-memory-final.toml` and
`verification/tpch-memory-final-oracle.json`; the single latency observation per
query is not a p95/p99 claim.
