# Product-quality evidence — ISO/IEC 25010:2023

[ISO/IEC 25010:2023](https://www.iso.org/standard/78176.html) is the current
product quality model and defines nine characteristics. This document maps
measurable evidence to that model. It is an evaluation framework, not a claim
that any engine is certified or meets every characteristic.

| Characteristic | Measured evidence in this suite | Status boundary |
| --- | --- | --- |
| Functional suitability | differential core checks; TPC-C-derived invariants; 22 TPC-H-derived result digests | coverage is limited to disclosed workloads |
| Performance efficiency | elapsed time, operations/rows per second, raw samples, p50/p95/p99, cold/warm labels | local hardware only; no cross-host conclusion |
| Compatibility | same portable logical schema/data and SQL workload run on three engines | does not establish full SQL dialect interoperability |
| Interaction capability | AiresDB API/CLI regression is covered by root tests | no end-user usability study is performed here |
| Reliability | durable close/reopen check; AiresDB WAL/recovery tests in root suite | no physical power-loss or long-duration soak evidence in this suite |
| Security | source-level safety audit remains in root suite | no threat model, penetration test, or access-control evaluation |
| Maintainability | versioned source, deterministic test runner, traceability, and regression gate | no independent maintainability assessment |
| Flexibility | runner provisions isolated dependencies and captures versions/configuration | no portability certification across operating systems or architectures |
| Safety | explicit corruption/error behavior in AiresDB root tests | no safety-critical hazard analysis is performed |

The report is designed to support a quality evaluation by exposing evidence and
limits. It does not turn a throughput number into a general quality score.

## Quality gates

1. A functional mismatch blocks interpretation of a performance result.
2. Missing environment, version, seed, or durability metadata makes a run
   non-reproducible.
3. A single sample has no tail-latency claim; p95/p99 are only reported when
   enough samples were requested and raw samples are retained.
4. Engine-specific features are disclosed rather than normalized away. AiresDB
   exposes MVCC/WAL and page-buffer statistics; SQLite/DuckDB do not expose an
   equivalent metric through this runner, so those fields are `null`.
