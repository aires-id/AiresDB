#!/usr/bin/env julia

using JSON3
using Printf
using Dates

function usage()
    error("Usage: benchmark/compare/report.jl REPORT.json [REPORT.json ...] [--output=PATH]")
end

function parse_arguments(args)
    isempty(args) && usage()
    paths = String[]
    output = nothing
    for argument in args
        if startswith(argument, "--output=")
            output === nothing || error("--output may only be supplied once.")
            output = abspath(argument[10:end])
        else
            push!(paths, abspath(argument))
        end
    end
    isempty(paths) && usage()
    all(isfile, paths) || error("Every report path must exist.")
    paths, something(output, joinpath(dirname(first(paths)), "AUDIT_SUMMARY.md"))
end

function field(value, key, default=nothing)
    try
        haskey(value, key) && return value[key]
    catch
    end
    default
end

stringfield(value, key, default="N/A") = begin
    item = field(value, key, default)
    item === nothing || item === missing ? default : string(item)
end

function numberfield(value, key)
    item = field(value, key, nothing)
    item === nothing || item === missing ? nothing : Float64(item)
end

fmt_ms(value) = value === nothing ? "N/A" : @sprintf("%.4f", value)
fmt_rate(value) = value === nothing ? "N/A" : @sprintf("%.3f", value)
display_path(path) = replace(relpath(path, pwd()), '\\' => '/')

function write_header(io, reports, paths)
    println(io, "# Comparative test and benchmark evidence")
    println(io)
    println(io, "Generated: `", now(), "`")
    println(io)
    println(io, "This document summarizes immutable JSON artifacts produced by the local comparison runner. It is ISO/IEC/IEEE 29119-aligned engineering evidence and quality-model evidence for ISO/IEC 25010/25012; it is not an ISO certification.")
    println(io)
    println(io, "TPC-C-derived and TPC-H-derived entries are not audited TPC results. They do not compute `tpmC` or `QphH@Size`.")
    println(io)
    println(io, "| Report | Mode | Status | Wall seconds | Test cases |")
    println(io, "| --- | --- | --- | ---: | ---: |")
    for (report, path) in zip(reports, paths)
        cases = field(report, "test_cases", Dict())
        println(io, "| `", display_path(path), "` | ", stringfield(report, "mode"), " | ", stringfield(report, "status"), " | ", fmt_rate(numberfield(report, "wall_seconds")), " | ", length(keys(cases)), " |")
    end
    println(io)
end

function write_core(io, report)
    workloads = field(report, "workloads", nothing)
    workloads === nothing && return
    println(io, "## Core workload")
    println(io)
    println(io, "All rows were consumed and verified before timing. p95 is shown only when the report has at least 20 samples; p99 only at 100 samples.")
    println(io)
    println(io, "| Engine | Operation | p50 ms | p95 ms | ops/s | rows/s |")
    println(io, "| --- | --- | ---: | ---: | ---: | ---: |")
    for engine in sort(String.(collect(keys(workloads))))
        operations = workloads[engine]
        for operation in sort(String.(collect(keys(operations))))
            metric = operations[operation]
            field(metric, "p50_ms", nothing) === nothing && continue
            println(io, "| ", engine, " | ", operation, " | ", fmt_ms(numberfield(metric, "p50_ms")), " | ", fmt_ms(numberfield(metric, "p95_ms")), " | ", fmt_rate(numberfield(metric, "operations_per_second")), " | ", fmt_rate(numberfield(metric, "rows_per_second")), " |")
        end
    end
    println(io)
end

function write_tpcc(io, report)
    entries = field(report, "transactions", nothing)
    entries === nothing && return
    println(io, "## TPC-C-derived mixed workload")
    println(io)
    println(io, "One connection and the disclosed reduced synthetic configuration were used. This measures a local engineering workload only.")
    println(io)
    println(io, "| Engine | Transactions/s | Commits | Expected rollbacks | All invariants |")
    println(io, "| --- | ---: | ---: | ---: | --- |")
    for engine in sort(String.(collect(keys(entries))))
        entry = entries[engine]
        counters = field(entry, "counters", Dict())
        consistency = field(entry, "consistency", Dict())
        passed = all(Bool(value) for value in values(consistency))
        println(io, "| ", engine, " | ", fmt_rate(numberfield(entry, "transactions_per_second")), " | ", stringfield(counters, "commits", "0"), " | ", stringfield(counters, "expected_rollbacks", "0"), " | ", passed ? "PASS" : "FAIL", " |")
    end
    println(io)
    println(io, "| Engine | Family | Count | p50 ms | p95 ms |")
    println(io, "| --- | --- | ---: | ---: | ---: |")
    for engine in sort(String.(collect(keys(entries))))
        latency = field(entries[engine], "latency", Dict())
        for family in sort(String.(collect(keys(latency))))
            metric = latency[family]
            println(io, "| ", engine, " | ", family, " | ", stringfield(metric, "count", "0"), " | ", fmt_ms(numberfield(metric, "p50_ms")), " | ", fmt_ms(numberfield(metric, "p95_ms")), " |")
        end
    end
    println(io)
end

function write_tpch(io, report)
    entries = field(report, "queries", nothing)
    entries === nothing && return
    println(io, "## TPC-H-derived 22-query workload")
    println(io)
    println(io, "Each of the 22 query families was compared against the same SQLite SQL result set before its samples were accepted. Tied rows are compared as a multiset, because SQL permits tie permutation unless all tie breakers are specified.")
    println(io)
    println(io, "| Engine | Queries verified | Aggregate measured ms | Median query p50 ms |")
    println(io, "| --- | ---: | ---: | ---: |")
    for engine in sort(String.(collect(keys(entries))))
        queries = entries[engine]
        metrics = [queries[name] for name in keys(queries)]
        totals = sum(something(numberfield(metric, "total_ms"), 0.0) for metric in metrics)
        medians = sort([something(numberfield(metric, "p50_ms"), 0.0) for metric in metrics])
        median = isempty(medians) ? nothing : medians[cld(length(medians), 2)]
        println(io, "| ", engine, " | ", length(metrics), " | ", fmt_ms(totals), " | ", fmt_ms(median), " |")
    end
    println(io)
end

function write_traceability(io, reports)
    println(io, "## Audit disposition")
    println(io)
    println(io, "| Requirement family | Evidence in these reports |")
    println(io, "| --- | --- |")
    println(io, "| ISO/IEC/IEEE 29119-aligned process | executable test IDs, pass/fail report state, configuration, source hashes, and raw samples |")
    println(io, "| ISO/IEC 25010 | functional equivalence, performance efficiency, compatibility, and persistence evidence; boundaries remain documented |")
    println(io, "| ISO/IEC 25012 | deterministic provenance, counts, key checks, typed result comparison, and committed-state invariants |")
    println(io, "| TPC-C-derived | five transaction families and invariant checks; no official TPC claim |")
    println(io, "| TPC-H-derived | all 22 query families and differential result checks; no official TPC claim |")
    println(io)
    println(io, "Known limitation: this baseline uses one Julia thread and one connection per engine. It does not establish equivalent crash semantics, multicore scaling, or an audited TPC metric. AiresDB-specific WAL/MVCC/recovery evidence remains in the root project test suites.")
    println(io)
end

function main(args=ARGS)
    paths, output = parse_arguments(args)
    reports = [JSON3.read(read(path, String)) for path in paths]
    mkpath(dirname(output))
    open(output, "w") do io
        write_header(io, reports, paths)
        for report in reports
            mode = stringfield(report, "mode")
            mode == "core" && write_core(io, report)
            mode == "tpcc-derived" && write_tpcc(io, report)
            mode == "tpch-derived" && write_tpch(io, report)
        end
        write_traceability(io, reports)
    end
    println("Saved ", output)
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main()
