# AiresDB benchmark sysimage

This isolated environment builds a stripped incremental Julia sysimage for controlled
large-table memory measurements. It does not change the AiresDB storage format
or transaction semantics.

From the repository root:

```powershell
julia --startup-file=no --project=benchmark/sysimage benchmark/sysimage/build.jl
```

The build script writes `airesdb_server_final_v17.dll` on Windows (or the
corresponding `.so` on Unix). Generated native images are intentionally ignored
by Git because they are platform and Julia-version specific.

The reproducible 250k memory profile is:

```powershell
julia --startup-file=no `
  --sysimage=benchmark/sysimage/airesdb_server_final_v17.dll `
  --threads=1 --optimize=0 --heap-size-hint=96M --project=. `
  benchmark/arsp4.jl --rows=250000 --batch=250000 --samples=1 `
  --warmup=0 --updates=0 --deletes=0 --range-width=64 `
  --page-count=8 --page-sizes=8192 `
  --directory=work/arsp4_250k_final_v17_stream `
  --output=verification/arsp4-250k-final-v17-stream.toml
```

Run the benchmark on an otherwise idle machine. `process_peak_rss_bytes` is the
process high-water mark reported by Julia/Windows and covers bulk load, page
publication, reopen, cold and warm scans, B+Tree lookups, ordering, checkpoint,
and final recovery. The one-sample profile is a capacity/RSS test; it is not
tail-latency evidence.
