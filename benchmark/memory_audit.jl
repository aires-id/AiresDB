#!/usr/bin/env julia
"""Inspect live AiresDB memory without materializing query results.

Usage: julia --project=. benchmark/memory_audit.jl DATABASE_DIRECTORY DATABASE
"""

using AiresDB
using AiresDB.Internal

function current_rss_bytes()
    Sys.iswindows() || return Int64(Sys.maxrss())
    counters = zeros(UInt8,80)
    counters[1:4] .= reinterpret(UInt8,[UInt32(length(counters))])
    process = ccall((:GetCurrentProcess,"kernel32"),stdcall,Ptr{Cvoid},())
    ok = ccall((:GetProcessMemoryInfo,"psapi"),stdcall,Int32,
        (Ptr{Cvoid},Ptr{UInt8},UInt32),process,counters,UInt32(length(counters)))
    ok != 0 || return Int64(0)
    Int64(only(reinterpret(UInt64,@view counters[17:24])))
end

length(ARGS) == 2 || error("Usage: memory_audit.jl DATABASE_DIRECTORY DATABASE")
session = Session(ARGS[1])
execute!(session,"Pilih '$(ARGS[2])' -:")
GC.gc(true)
handle = session.handle::AiresDB.DatabaseHandle
store = handle.page_store::AiresDB.PageStore
println("current_rss_bytes=",current_rss_bytes())
println("peak_rss_bytes=",Sys.maxrss())
println("gc_live_bytes=",Base.gc_live_bytes())
println("database_summary_bytes=",Base.summarysize(handle.current))
println("histories_summary_bytes=",Base.summarysize(handle.histories))
println("pagestore_summary_bytes=",Base.summarysize(store))
for name in sort!(collect(keys(handle.current.tables)))
    table = handle.current.tables[name]
    println("table[",name,"]_rows=",length(table.rows),
        " summary_bytes=",Base.summarysize(table),
        " changes=",length(table.changes),
        " histories=",length(get(handle.histories,name,Dict())))
end
close(session)
