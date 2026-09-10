# Traceability matrix

| ID | Requirement / risk | Runner phase | Expected evidence |
| --- | --- | --- | --- |
| CMP-ENV-001 | exact dependencies are recoverable | `bootstrap.jl` | `Project.toml`, `Manifest.toml` |
| CMP-FIX-001 | all engines receive the same core data | `verify`, `core` | schema/count/fixture digest match |
| CMP-FUN-001 | primary-key behavior is equivalent | `verify` | lookup values/digest |
| CMP-FUN-002 | range and ordered result behavior is equivalent | `verify`, `core` | ordered row digest |
| CMP-FUN-003 | insert/update/delete commit behavior is visible after reopen | `verify`, `core` | pre/post-reopen checks |
| CMP-PERF-001 | core performance is reproducible | `core` | raw samples, p50/p95/p99, configuration |
| CMP-TC-001 | five TPC-C-derived transaction families execute correctly | `tpcc` | mix, counters, invariants, per-family latency |
| CMP-TH-001 | 22 TPC-H-derived query families agree | `tpch` | per-query result count/digest and latency |
| CMP-DQ-001 | structural data quality is checked | all phases | counts, null/key/schema checks |
| CMP-DQ-002 | monetary/data precision is not silently lost | all phases | typed canonical digest |
| CMP-REL-001 | clean persistence/reopen path is checked | `verify`, `core` | reopen digest |
| CMP-AUD-001 | measurements can be reviewed | all completed phases | report metadata + source hashes |

Root AiresDB test suites provide the deeper engine-specific evidence for WAL,
MVCC, corruption, and ARSP-4 behavior. Their test output must be stored beside
a comparison run when an audit needs an end-to-end release decision.
