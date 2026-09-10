using Pkg

repository = normpath(joinpath(@__DIR__,"..",".."))
Pkg.develop(path=repository)
Pkg.instantiate()
