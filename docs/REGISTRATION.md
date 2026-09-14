# Registering AiresDB in Julia General

This is the maintainer checklist for the first `v0.1.0` release. Keep the
version in `Project.toml` at `0.1.0` throughout the initial registration.

## Repository preparation

1. Merge registration-readiness changes only after pull-request CI passes.
2. Rename the GitHub repository from `AiresDB` to `AiresDB.jl`. General's
   AutoMerge guidelines require a package URL shaped like
   `https://github.com/aires-id/AiresDB.jl.git`. GitHub redirects preserve the
   old clone URL.
3. Confirm that the default branch is public and the candidate commit can run
   `import AiresDB` on Julia 1.12.
4. Do not create a separate `v0.1.0` tag first. Registrator identifies the tree
   from the commit where the registration command is posted.

## Submit the registration

1. Install the [Julia Registrator](https://github.com/apps/julia-registrator)
   GitHub App for `aires-id/AiresDB.jl`.
2. Open the merged commit on GitHub and post:

   ```text
   @JuliaRegistrator register

   Release notes:

   Initial technical-preview release of AiresDB, including the AiresQL engine,
   MVCC transactions, durable WAL recovery, page-based storage, TinyServer,
   and the `airesdb` Julia app.
   ```

3. Registrator opens a pull request in
   [JuliaRegistries/General](https://github.com/JuliaRegistries/General). Review
   the AutoMerge result. Fix failures in this repository, then rerun the
   Registrator command when necessary.
4. New-package registrations have a three-day community review period. After
   the General pull request is merged and registry updates reach users,
   `Pkg.add("AiresDB")` becomes available.
5. TagBot creates the tag and GitHub release after registry acceptance. If a
   workflow-file change prevents TagBot from creating the release commit, tag
   the exact registered tree as `v0.1.0` and create the GitHub release manually.

## Verify after registration

Use a temporary depot or environment so the verification cannot reuse this
development checkout:

```sh
julia -e 'using Pkg; Pkg.activate(; temp=true); Pkg.add("AiresDB"); import AiresDB'
julia -e 'using Pkg; Pkg.Apps.add("AiresDB")'
airesdb --help
```

Official references:

- [General registry](https://github.com/JuliaRegistries/General)
- [Registrator](https://github.com/JuliaRegistries/Registrator.jl)
- [Pkg apps](https://pkgdocs.julialang.org/v1/apps/)
- [RegistryCI AutoMerge guidelines](https://juliaregistries.github.io/RegistryCI.jl/stable/guidelines/)
