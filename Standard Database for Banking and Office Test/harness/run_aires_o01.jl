#!/usr/bin/env julia

include(joinpath(@__DIR__, "run_aires_resilience.jl"))

root = abspath(String(option("root"; required=true)))
output = abspath(String(option("output"; required=true)))
duration = parse(Int, String(option("duration"; default="900")))

session = open_sdbeo(root)
result = sustained_load!(session, duration)
checkpoint!(session)
close(session)
final_probe = probe_database(root)
result["restart_ok"] = final_probe["opened"]
result["correct"] = isempty(result["errors"]) && final_probe["opened"]

open(output, "w") do stream
    JSON3.pretty(stream, result)
    println(stream)
end
println(output)
