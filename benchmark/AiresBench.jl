module AiresBench

using AiresDB, Dates, Random, TOML, Printf, SHA
using AiresDB.Internal

const AB = AiresDB
const BENCHMARK_NOTICE = "Exploratory TPC-derived workloads; not audited or compliant TPC-C/TPC-H results."

function create_schema!(s, name, columns, primary)
    names = first.(columns)
    definitions = ["$(n) = $(t)" * (n in primary ? "(P)" : "") for (n,t) in columns]
    execute!(s,"Buat Tabel '$name' Isi '$(join(names, " & "))' Dengan '$(join(definitions, " & "))' -:")
end

function load_rows!(s, name, rows; batch=5000)
    for start in 1:batch:length(rows)
        with_transaction(s) do
            bulk_insert!(s,name,rows[start:min(end,start+batch-1)])
        end
    end
end

snapshot(f,s)=with_snapshot(()->f(s),s)

function transaction(f,s)
    begin_transaction!(s)
    try
        answer=f(s)
        commit!(s)
        answer
    catch
        AB.in_transaction(s) && rollback!(s)
        rethrow()
    end
end

# Nearest rank percentiles; zero observations are reported as zero, with count=0.
function latency_summary(ns)
    v=sort(Float64.(ns)./1e6)
    n=length(v)
    Dict("count"=>n,"p50_ms"=>n==0 ? 0.0 : v[clamp(ceil(Int,0.50n),1,n)],
         "p95_ms"=>n==0 ? 0.0 : v[clamp(ceil(Int,0.95n),1,n)],
         "min_ms"=>n==0 ? 0.0 : first(v),"max_ms"=>n==0 ? 0.0 : last(v),
         "total_ms"=>sum(v),"operations_per_second"=>sum(v)==0 ? 0.0 : n*1000/sum(v),
         "samples_ms"=>v)
end

function write_report(path, report)
    mkpath(dirname(abspath(path)))
    open(path,"w") do io
        TOML.print(io,report;sorted=true)
    end
end

include("tpcc.jl")
include("tpch_data.jl")
include("tpch_queries.jl")

end
