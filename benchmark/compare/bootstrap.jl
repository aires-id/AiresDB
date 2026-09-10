#!/usr/bin/env julia
# Reproducibly provision the isolated comparison environment.
# It deliberately leaves AiresDB's root Project.toml unchanged.

using Pkg

const COMPARE_ROOT = @__DIR__
const AIRESDB_ROOT = normpath(joinpath(COMPARE_ROOT, "..", ".."))
const REQUIRED_PACKAGES = ("SQLite", "DuckDB", "DBInterface", "JSON3")

Pkg.activate(COMPARE_ROOT)
Pkg.develop(path=AIRESDB_ROOT)

project = Pkg.project()
for package in REQUIRED_PACKAGES
    haskey(project.dependencies, package) || Pkg.add(package)
end

Pkg.instantiate()
println("Comparison environment is ready at ", COMPARE_ROOT)
