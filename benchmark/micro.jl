#!/usr/bin/env julia
# Comparable point-read/point-update microbenchmark for AiresDB releases.
# Example: julia --project=. benchmark/micro.jl --output=verification/micro.toml
using AiresDB, TOML, Dates
using AiresDB.Internal

function options(args)
    result = Dict{String,String}()
    for arg in args
        startswith(arg,"--") && occursin('=',arg) || error("Expected --key=value, got $arg")
        key,value = split(arg[3:end],'=';limit=2)
        result[key] = value
    end
    result
end

function distribution(samples_ns)
    values = sort(Float64.(samples_ns)./1e6)
    n = length(values)
    Dict(
        "count"=>n,
        "total_ms"=>sum(values),
        "p50_ms"=>values[clamp(ceil(Int,0.50n),1,n)],
        "p95_ms"=>values[clamp(ceil(Int,0.95n),1,n)],
        "min_ms"=>first(values),
        "max_ms"=>last(values),
        "operations_per_second"=>n*1000/sum(values),
        "samples_ms"=>values,
    )
end

function main(args)
    opt = options(args)
    rows = parse(Int,get(opt,"rows","1000"))
    reads = parse(Int,get(opt,"reads","200"))
    writes = parse(Int,get(opt,"writes","50"))
    warmup = parse(Int,get(opt,"warmup","10"))
    rows > 0 && reads > 0 && writes > 0 && warmup >= 0 || error("Counts must be positive; warmup may be zero")
    directory = abspath(get(opt,"directory",joinpath("work","micro_"*Dates.format(now(),"yyyymmdd_HHMMSS_sss"))))
    output = abspath(get(opt,"output",joinpath(directory,"result.toml")))
    mkpath(directory)
    isempty(filter(f->endswith(f,".aires"),readdir(directory))) || error("Use a fresh benchmark directory")

    session = Session(directory)
    database = "Micro_"*string(time_ns())
    load_start = time_ns()
    execute!(session,"Buat '$database' -:")
    execute!(session,"Buat Tabel 'Accounts' Isi 'ID & Balance & Name' Dengan 'ID = I(P) & Balance = U & Name = C' -:")
    execute!(session,"Isi Tabel 'Accounts' "*join(["'$i & 1000.00 & Account$i'" for i in 1:rows]," ")*" -:")
    load_seconds = (time_ns()-load_start)/1e9

    target = max(1,cld(rows,2))
    read_query = "Pilih 'Balance' Dari 'Accounts' Dengan 'ID = $target' -:"
    write_query = "Tabel_Upt 'Accounts' Isi 'Balance = Balance + 0.01' Dengan 'ID = $target' -:"
    for _ in 1:warmup
        execute!(session,read_query)
        execute!(session,write_query)
    end
    GC.gc()
    read_samples = Int[]
    for _ in 1:reads
        started = time_ns(); execute!(session,read_query); push!(read_samples,time_ns()-started)
    end
    GC.gc()
    write_samples = Int[]
    for _ in 1:writes
        started = time_ns(); execute!(session,write_query); push!(write_samples,time_ns()-started)
    end

    report = Dict{String,Any}(
        "notice"=>"Local microbenchmark; not a TPC result.",
        "engine_version"=>string(something(Base.pkgversion(AiresDB),v"0.0.0")),
        "label"=>get(opt,"label","AiresDB"),
        "rows"=>rows,"warmup_pairs"=>warmup,
        "read"=>distribution(read_samples),"write"=>distribution(write_samples),
        "load_seconds"=>load_seconds,"database_bytes"=>filesize(session.path),
        "measured_on"=>string(now()),"julia_version"=>string(VERSION),
        "julia_threads"=>Threads.nthreads(),"cpu_threads_detected"=>Sys.CPU_THREADS,
        "kernel"=>string(Sys.KERNEL),"architecture"=>string(Sys.ARCH),
        "durability_label"=>get(opt,"durability","unspecified"),
    )
    if isdefined(AiresDB,:mvcc_stats)
        report["engine_after_run"] = Dict(String(k)=>(v isa UInt ? string(v) : v) for (k,v) in pairs(AiresDB.mvcc_stats(session)))
    end
    mkpath(dirname(output))
    open(output,"w") do io; TOML.print(io,report;sorted=true); end
    println("Saved ",output)
    println("read=",report["read"])
    println("write=",report["write"])
end

abspath(PROGRAM_FILE)==abspath(@__FILE__) && main(ARGS)
