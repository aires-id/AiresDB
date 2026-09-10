# AiresDB comparative verification suite

This directory contains the reproducible comparison harness for **AiresDB**,
**SQLite**, and **DuckDB**. It has three purposes:

1. differential functional verification against the same deterministic input;
2. local, repeatable engineering measurements; and
3. evidence packages structured around ISO/IEC/IEEE 29119, ISO/IEC 25010,
   and ISO/IEC 25012.

It is not a certification package. In particular, the TPC-derived workloads in
this repository are not audited TPC-C or TPC-H results, do not produce `tpmC`
or `QphH@Size`, and must not be compared with published TPC results.

## Provision the isolated runner

The comparison dependencies live here, not in AiresDB's root `Project.toml`.
From the repository root, run:

```powershell
julia --startup-file=no benchmark/compare/bootstrap.jl
```

That command pins AiresDB as the local package and obtains `SQLite.jl`,
`DuckDB.jl`, and `DBInterface.jl`. The resulting `Project.toml` and
`Manifest.toml` are evidence: retain them with every result set.

## Execute

The runner intentionally requires a new output directory. It never deletes or
overwrites a database or report.

```powershell
# Fast correctness gate; all engines, deterministic data and cross-engine checks.
julia --threads=1 --startup-file=no --project=benchmark/compare benchmark/compare/run.jl verify --output=verification/compare-smoke

# Common storage/CRUD workload. The default is deliberately moderate for a
developer workstation; use a new output path for every invocation.
julia --threads=1 --startup-file=no --project=benchmark/compare benchmark/compare/run.jl core --rows=10000 --samples=100 --warmup=10 --output=verification/compare-core

# TPC-C-derived five-transaction mix. It is not an official TPC-C run.
julia --threads=1 --startup-file=no --project=benchmark/compare benchmark/compare/run.jl tpcc --transactions=100 --warmup=10 --output=verification/compare-tpcc

# All 22 TPC-H-derived SQL query families. It is not an official TPC-H run.
julia --threads=1 --startup-file=no --project=benchmark/compare benchmark/compare/run.jl tpch --scale=0.0001 --repetitions=3 --warmup=1 --output=verification/compare-tpch

# Produce the immutable Markdown evidence index from JSON reports.
julia --threads=1 --startup-file=no --project=benchmark/compare benchmark/compare/report.jl verification/compare-core/report.json verification/compare-tpcc/report.json verification/compare-tpch/report.json --output=verification/COMPARE-AUDIT.md
```

The first use of DuckDB can include artifact download and compilation. Do not
include that provisioning cost in benchmark timing. The baseline deliberately
uses one Julia thread and one connection per engine. It rejects a different
thread count because DuckDB.jl's Windows file-handle cleanup makes an
in-process reopen nondeterministic on a multithreaded Julia runtime. Use a
separately designed concurrency profile for multicore claims, and never use
`--compile=min` for measurement.

Each device run is written to a separate output directory selected on the command
line. Archive the generated `report.json`, environment metadata, and source hashes
together when preserving a comparison run.

Run the harness regression checks before collecting a new evidence set:

```powershell
julia --threads=1 --startup-file=no --project=benchmark/compare benchmark/compare/test/runtests.jl
```

## Evidence and methodology

- [ISO/IEC/IEEE 29119-aligned test plan](docs/TEST_PLAN_29119.md)
- [ISO/IEC 25010:2023 quality evidence map](docs/QUALITY_25010.md)
- [ISO/IEC 25012 data-quality evidence map](docs/DATA_QUALITY_25012.md)
- [audit, reproducibility, and benchmark protocol](docs/AUDIT_PROTOCOL.md)
- [test-case traceability matrix](docs/TRACEABILITY.md)

All reports record exact engine package versions, Julia version, host details,
input seed, configuration, wall-clock measurements, result digests, and each
engine's durability configuration. A `PASS` means that the defined test case
passed under that recorded configuration only.
