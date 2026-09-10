# Comparative audit and benchmark protocol

## Non-negotiable disclosure

The official current TPC specifications are
[TPC-C 5.11.0 and TPC-H 3.0.1](https://tpc.org/TPC_Documents_Current_Versions/current_specifications5.asp).
TPC-C uses the official `tpmC` metric and TPC-H uses `QphH@Size`; neither is
computed by this repository. The workloads here retain transaction/query
families for engineering coverage but deliberately omit required official
scale, driver, concurrency, pricing, availability, audit, and disclosure
procedures. Every report therefore labels them **TPC-C-derived** or
**TPC-H-derived**, never TPC-compliant, certified, `tpmC`, or `QphH@Size`.

## Reproducibility contract

1. Keep a clean revision of the root project and the complete
   `benchmark/compare/Project.toml` and `Manifest.toml`.
2. Run `bootstrap.jl` before timing. Package download, compilation, and JIT
   warmup are outside measured samples. Invoke each baseline command with
   `julia --threads=1`; the runner rejects another thread count because the
   Windows DuckDB.jl close/reopen lifecycle is not deterministic under a
   multithreaded Julia worker pool.
3. Use a new output directory. The runner rejects an existing result database.
4. Record command line, UTC/local timestamp, host/OS/CPU/RAM, Julia/package
   versions, engine settings, seed, table cardinalities, and source hashes.
5. Run functional `verify` first. A mismatch stops the performance phase.
6. Record all latency samples in milliseconds. Summaries use nearest-rank
   p50/p95/p99. Cold means process/connection reopen, not a guaranteed
   physical disk-cache eviction; warm means after explicit workload warmup.
7. Report load/setup, measurement, and cleanup separately. Do not include
   report-writing or integrity verification in a measured duration.

## Fairness rules

- All engines receive identical deterministic rows and the same logical primary
  keys. Each uses its native storage/file format and public Julia binding.
- Only primary-key indexes required by the shared schema are created by the
  core suite. No query-specific index, plan hint, result cache, or engine
  extension is added unless a named profile declares it.
- SQLite runs with `journal_mode=WAL`, `synchronous=FULL`, and
  `foreign_keys=ON`. DuckDB and AiresDB durability configuration is recorded
  verbatim. These are not a proof of identical crash semantics.
- All result rows are consumed during a measurement; counting a cursor without
  materializing it is prohibited.
- One process and one connection per engine are used in the baseline profile.
  Concurrency is a separate, explicitly named profile because locking and MVCC
  models differ.

## Audit review checklist

| Check | Reviewer action |
| --- | --- |
| Artifact integrity | verify report hash and source/package manifest paths |
| Input equivalence | compare seed, counts, schema digest, and fixture digest |
| Correctness | all verification IDs pass; inspect any incident records |
| Measurement hygiene | confirm warmups are outside measured samples and raw samples exist |
| Interpretation | compare only same workload/profile and state the durability/cold-warm limits |
| Claim boundary | reject any wording that calls this official TPC or ISO certification |

## Result disposition

`PASS` means all assertions for a named test case passed. `FAIL` means an
assertion or engine action failed. `BLOCKED` means the necessary runtime or
resource was absent. `INCONCLUSIVE` means execution completed but a required
metadata, equivalence, or sampling condition is missing. Preserve all four
states; do not delete a failed run to make a summary look clean.
