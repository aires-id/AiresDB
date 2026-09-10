# Test plan — ISO/IEC/IEEE 29119-aligned

**Plan ID:** `AIRESCMP-TP-001`

**System under test:** AiresDB v0.1.0, SQLite, and DuckDB through their Julia bindings

**Owner:** AiresDB engineering

**Status:** executable engineering test plan; not an accredited conformance
claim.

This plan is aligned with the concepts, process, documentation, and test-design
intent of ISO/IEC/IEEE 29119. The current Part 1 is
[ISO/IEC/IEEE 29119-1:2022](https://www.iso.org/standard/81291.html); the ISO
committee describes Parts 2–4 as the process, documentation, and technique
parts of the series. This repository does not assert full conformance to any
part: tailoring, evidence gaps, and exclusions are explicit below.

## 1. Test basis and scope

The test basis is the AiresDB source, its public API/AiresQL semantics,
`benchmark/AiresBench.jl`, the deterministic TPC-C-shaped and TPC-H-shaped data
generators, and the SQL definitions in `benchmark/oracle.py`. The common runner
loads the same logical rows into all three engines. It uses only public
interfaces for every engine.

In scope:

| Area | Evidence |
| --- | --- |
| Functional equivalence | deterministic record fixture; row-count, aggregate, primary-key, range, order, mutation, and reopen checks |
| Transaction behavior | TPC-C-derived New-Order, Payment, Order-Status, Delivery, and Stock-Level families; committed-state invariants |
| Analytical behavior | all 22 TPC-H-derived SQL query families and result-digest comparison |
| Persistence/reopen | durable close, reopen, count/digest comparison |
| Performance | cold/warm core workloads and latency distribution with configuration disclosure |
| AiresDB regression | root `Pkg.test()` remains the engine correctness gate |

Out of scope: a TPC-audited result, published TPC metric, certified ISO
conformance, production security penetration test, physical power-loss test,
multi-host distributed behavior, and real-world source-data accuracy.

## 2. Risk-based objectives

| Risk | Control and objective | Acceptance evidence |
| --- | --- | --- |
| Different input causes misleading comparison | One seeded fixture and per-engine cardinality/digest checks before timing | fixture digest and counts match |
| Semantic divergence is hidden by timing | Differential results are checked before a performance result is accepted | no result mismatch |
| Setup/JIT/artifact download contaminates timing | Provisioning occurs before the measured phase; warmups are separately recorded | report has `warmup` and measured samples |
| Durability settings are silently unequal | Engine-specific PRAGMA/configuration is stored in the report | report contains durability section |
| One noisy sample is reported as a conclusion | report stores raw samples and nearest-rank p50/p95/p99 | sample list and summary agree |
| Failure destroys audit trail | runner is append-only by output directory and writes a manifest | fresh output directory, report state/error |

## 3. Test process and lifecycle

| Process stage | Implemented activity | Output |
| --- | --- | --- |
| Planning | version, seed, workload, workload limits, exit criteria | invocation and configuration block |
| Monitoring/control | runner records phase, result, exception, and duration | JSON report / console status |
| Analysis/design | equivalence partitions: empty, one, normal, invalid key, range boundary, duplicate key, reopen | IDs in `TRACEABILITY.md` |
| Implementation | deterministic fixtures and portable SQL or public API calls | source in this directory |
| Execution | provision → verify → benchmark → report → review | immutable output directory |
| Completion | reviewer checks all required test IDs and unresolved incidents | signed/dated review entry outside this repository |

## 4. Entry, suspension, and exit criteria

**Entry:** root AiresDB `Pkg.test()` is green for the revision under test;
compare `Manifest.toml` resolves; all engine versions load; output directory is
new; host has adequate free space; no competing benchmark process is running.

**Suspend:** fixture counts/digests differ, a query produces a different value,
an engine reports an error, a report cannot record its durability setting, or
the host experiences memory/disk pressure. Preserve the output directory and
record the incident; do not substitute a partial run for a pass.

**Exit:** all selected test IDs pass; all performance samples have a result
digest identical to the baseline where applicable; report metadata is complete;
known exceptions are listed. A performance run is **inconclusive**, rather
than passing, when functional verification is not complete.

## 5. Incident record

For each issue retain: incident ID, command, report path, engine/version,
fixture seed, test ID, expected/actual value, exception/stack trace, timestamp,
classification (defect/environment/test-data), owner, disposition, and retest
report. Never edit a failed report in place.

## 6. Tailoring disclosure

The suite supplies executable test cases, traceability, results, and incident
fields. It does not supply an independent test organization, formal test-policy
approval, all organization-level process artefacts, or an ISO conformity
assessment. These omissions make this an engineering implementation inspired
by 29119, not a statement of ISO/IEC/IEEE 29119 conformance.
