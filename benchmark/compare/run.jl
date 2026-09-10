#!/usr/bin/env julia

include("CompareBench.jl")
using .CompareBench
using Dates

function parse_arguments(args)
    isempty(args) && error("Usage: benchmark/compare/run.jl verify|core|tpcc|tpch [--key=value]")
    mode = lowercase(first(args))
    mode in ("verify", "core", "tpcc", "tpch") || error("Unknown comparison mode '$mode'.")
    options = Dict{String,String}()
    for argument in args[2:end]
        startswith(argument, "--") && occursin('=', argument) || error("Expected --key=value, got '$argument'.")
        key, value = split(argument[3:end], '='; limit=2)
        haskey(options, key) && error("Duplicate option --$key.")
        options[key] = value
    end
    mode, options
end

function int_option(options, name, default; minimum=nothing)
    value = parse(Int, get(options, name, string(default)))
    minimum === nothing || value >= minimum || error("--$name must be >= $minimum.")
    value
end

function core_main(mode, options, args)
    rows = int_option(options, "rows", 10_000; minimum=4)
    batch = int_option(options, "batch", min(1_000, rows); minimum=1)
    batch <= rows || error("--batch cannot exceed --rows.")
    samples = int_option(options, "samples", mode == "verify" ? 1 : 100; minimum=1)
    warmup = int_option(options, "warmup", mode == "verify" ? 0 : 10; minimum=0)
    seed = int_option(options, "seed", 20260904; minimum=0)
    default_output = joinpath(CompareBench.ROOT, "verification", "compare-$(mode)-" * Dates.format(now(), "yyyymmdd_HHMMSS"))
    output = abspath(get(options, "output", default_output))
    report = CompareBench.run_core(output; rows=rows, batch=batch, samples=samples, warmup=warmup, seed=seed, mode=mode, command=String.(args))
    println("Saved ", joinpath(output, "report.json"))
    println("status=", report["status"], " wall_seconds=", report["wall_seconds"])
end

function tpch_main(options, args)
    scale = parse(Float64, get(options, "scale", "0.0001"))
    batch = int_option(options, "batch", 1_000; minimum=1)
    repetitions = int_option(options, "repetitions", 3; minimum=1)
    warmup = int_option(options, "warmup", 1; minimum=0)
    seed = int_option(options, "seed", 20260903; minimum=0)
    default_output = joinpath(CompareBench.ROOT, "verification", "compare-tpch-" * Dates.format(now(), "yyyymmdd_HHMMSS"))
    output = abspath(get(options, "output", default_output))
    report = CompareBench.run_tpch(output; scale=scale, batch=batch, repetitions=repetitions, warmup=warmup, seed=seed, command=String.(args))
    println("Saved ", joinpath(output, "report.json"))
    println("status=", report["status"], " wall_seconds=", report["wall_seconds"])
end

function tpcc_main(options, args)
    warehouses = int_option(options, "warehouses", 1; minimum=1)
    districts = int_option(options, "districts", 2; minimum=1)
    districts <= 10 || error("--districts must be <= 10.")
    customers = int_option(options, "customers", 30; minimum=10)
    items = int_option(options, "items", 100; minimum=15)
    transactions = int_option(options, "transactions", 100; minimum=1)
    warmup = int_option(options, "warmup", 10; minimum=0)
    batch = int_option(options, "batch", 1_000; minimum=1)
    seed = int_option(options, "seed", 20260903; minimum=0)
    default_output = joinpath(CompareBench.ROOT, "verification", "compare-tpcc-" * Dates.format(now(), "yyyymmdd_HHMMSS"))
    output = abspath(get(options, "output", default_output))
    report = CompareBench.run_tpcc(output; warehouses=warehouses, districts=districts, customers=customers, items=items,
        transactions=transactions, warmup=warmup, batch=batch, seed=seed, command=String.(args))
    println("Saved ", joinpath(output, "report.json"))
    println("status=", report["status"], " wall_seconds=", report["wall_seconds"])
end

function main(args=ARGS)
    mode, options = parse_arguments(args)
    if mode == "verify" || mode == "core"
        core_main(mode, options, args)
    elseif mode == "tpch"
        tpch_main(options, args)
    elseif mode == "tpcc"
        tpcc_main(options, args)
    else
        error("$mode runner is being finalized; use verify/core/tpcc/tpch while the common fixture gate is active.")
    end
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main()
