using PackageCompiler

repository = normpath(joinpath(@__DIR__,"..",".."))
destination = joinpath(@__DIR__,Sys.iswindows() ? "airesdb_server_final_v17.dll" : "airesdb_server_final_v17.so")
create_sysimage([:AiresDB];
    project=repository,
    sysimage_path=destination,
    precompile_execution_file=joinpath(@__DIR__,"precompile_workload.jl"),
    incremental=true,
    # Keep inference IR so Julia can compile a valid path that was not observed
    # by the fixture; method metadata is unnecessary in this deployment image.
    sysimage_build_args=`-O0 --strip-metadata`,
)
println(destination)
