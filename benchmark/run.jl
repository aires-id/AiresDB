#!/usr/bin/env julia
# Run from the project root: julia --project=. benchmark/run.jl tpch --scale=0.001
include("AiresBench.jl")
using .AiresBench, AiresDB, Dates, TOML
using AiresDB.Internal

function arguments(args)
    isempty(args) && error("Usage: benchmark/run.jl tpcc|tpch [--key=value]")
    kind=args[1];kind in ("tpcc","tpch") || error("Workload must be tpcc or tpch")
    options=Dict{String,String}()
    for arg in args[2:end]
        startswith(arg,"--")&&occursin('=',arg) || error("Expected --key=value, got $arg")
        key,value=split(arg[3:end],'=';limit=2);options[key]=value
    end
    kind,options
end

function main(args)
    kind,opts=arguments(args)
    free_memory_before = Sys.free_memory()
    seed=parse(Int,get(opts,"seed","20260903"))
    directory=abspath(get(opts,"directory",joinpath("work","bench_"*kind*"_"*Dates.format(now(),"yyyymmdd_HHMMSS"))))
    mkpath(directory)
    isempty(filter(f->endswith(f,".aires"),readdir(directory))) || error("Benchmark directory already contains a database; use a new directory")
    output=abspath(get(opts,"output",joinpath(directory,"result.toml")))
    s=Session(directory);execute!(s,"Buat 'Benchmark' -:")
    started=time_ns()
    if kind=="tpcc"
        canonical=get(opts,"profile","reduced")=="canonical"
        config=AiresBench.CConfig(warehouses=parse(Int,get(opts,"warehouses","1")),
            districts=parse(Int,get(opts,"districts","10")),customers=parse(Int,get(opts,"customers",canonical ? "3000" : "100")),
            items=parse(Int,get(opts,"items",canonical ? "100000" : "1000")),seed=seed)
        println("Loading TPC-C-derived workload: ",config);flush(stdout)
        counts=AiresBench.load_tpcc!(s;config)
        load_seconds=(time_ns()-started)/1e9
        println("Loaded ",counts," in ",round(load_seconds;digits=3)," seconds. Starting measured workload.");flush(stdout)
        result=AiresBench.run_tpcc(s;config,transactions=parse(Int,get(opts,"transactions","500")),warmup=parse(Int,get(opts,"warmup","25")))
    else
        scale=parse(Float64,get(opts,"scale","0.001"))
        println("Loading all22 TPC-H-derived queries at synthetic scale ",scale);flush(stdout)
        imported=haskey(opts,"dbgen-directory")
        counts=imported ? AiresBench.load_tpch_dbgen!(s,opts["dbgen-directory"]) : AiresBench.load_tpch!(s;scale,seed)
        load_seconds=(time_ns()-started)/1e9
        println("Loaded ",counts," in ",round(load_seconds;digits=3)," seconds. Validating and measuring.");flush(stdout)
        if get(opts,"oracle","true")=="true"
            data=joinpath(directory,"oracle_data");answers=joinpath(directory,"oracle_answers")
            AiresBench.export_tpch(s,data);AiresBench.export_answers(s,answers;scale)
            python=get(opts,"python",get(ENV,"AIRESDB_PYTHON",joinpath(homedir(),".cache","codex-runtimes","codex-primary-runtime","dependencies","python","python.exe")))
            isfile(python) || (python=something(Sys.which("python3"),""))
            isempty(python) && error("Independent oracle requires Python3; pass --python=path")
            oracle=joinpath(@__DIR__,"oracle.py");report=joinpath(directory,"oracle-report.json")
            success(`$python $oracle $data $answers --scale $scale --report $report`) || error("TPC-H independent oracle failed")
        end
        result=AiresBench.run_tpch(s;scale,repetitions=parse(Int,get(opts,"repetitions","5")),warmup=parse(Int,get(opts,"warmup","1")))
        if imported
            result["generator"]="externally supplied DBGEN .tbl files; generator/version/seed not independently verified"
            result["dbgen_directory"]=abspath(opts["dbgen-directory"])
        end
        result["independent_sql_oracle_passed"]=get(opts,"oracle","true")=="true"
    end
    result["seed"]=seed;result["load_seconds"]=load_seconds;result["cardinalities_after_load"]=counts
    result["measured_on"]=string(now());result["julia_version"]=string(VERSION);result["julia_threads"]=Threads.nthreads();result["cpu_threads_detected"]=Sys.CPU_THREADS
    result["word_size"]=Sys.WORD_SIZE;result["kernel"]=string(Sys.KERNEL);result["architecture"]=string(Sys.ARCH)
    result["cpu_models"]=unique(String(info.model) for info in Sys.cpu_info())
    result["total_memory_bytes"]=Int64(min(Sys.total_memory(),typemax(Int64)))
    result["free_memory_before_bytes"]=Int64(min(free_memory_before,typemax(Int64)))
    result["free_memory_after_bytes"]=Int64(min(Sys.free_memory(),typemax(Int64)))
    result["database_directory"]=directory
    result["commit_flush_mode"]=Sys.iswindows() ? "FlushFileBuffers (Windows)" : "fsync"
    result["engine_after_run"]=Dict(String(k)=>(v isa UInt ? string(v) : v) for (k,v) in pairs(mvcc_stats(s)))
    AiresBench.write_report(output,result)
    println("Saved ",output)
    if kind=="tpcc"
        println("Transactions/s: ",result["transactions_per_second"]," counters=",result["counters"])
        for name in sort(collect(keys(result["latency"])))
            x=result["latency"][name];println(name," count=",x["count"]," p50_ms=",x["p50_ms"]," p95_ms=",x["p95_ms"])
        end
    else
        for name in sort(collect(keys(result["queries"])))
            x=result["queries"][name];println(name," rows=",x["result_rows"]," p50_ms=",x["p50_ms"]," p95_ms=",x["p95_ms"])
        end
    end
end

abspath(PROGRAM_FILE)==abspath(@__FILE__) && main(ARGS)
