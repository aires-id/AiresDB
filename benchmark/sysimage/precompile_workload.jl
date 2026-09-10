using AiresDB
using AiresDB.Internal
using Dates
using Random
using TOML

# Exercise the storage, MVCC, WAL, parser, executor, and ordered-index paths
# during sysimage construction. The fixture is deliberately small; method
# coverage matters here, while production cardinality belongs to benchmark.
mktempdir() do directory
    session = Session(directory)
    execute!(session,"Buat 'Precompile' -:")
    execute!(session,"Buat Tabel 'Records' Isi 'ID & OrderKey & Bucket & Amount & Payload' Dengan 'ID = I(P) & OrderKey = I(N & Not Null) & Bucket = I & Amount = D & Payload = C(64)' -:")
    bulk_insert!(session,"Records",((Int64(id),Int64(65-id),Int64(mod(id,8)),Int64(id),"payload-$id") for id in 1:64))
    lookup(session,"Records",Int64(32))
    scan_rows(session,"Records")
    execute!(session,"Pilih 'ID & Payload' Dari 'Records' Dengan 'ID >= 8 &: ID < 16' -:")
    execute!(session,"Pilih 'ID & OrderKey' Dari 'Records' M: 'OrderKey Atas' Limit(16) -:")
    begin_transaction!(session)
    update_key!(session,"Records",Int64(1),Dict("Payload"=>"updated"))
    commit!(session)
    delete_key!(session,"Records",Int64(2))
    checkpoint!(session)
    storage_stats(session)
    close(session)
end

# Compile the benchmark harness itself, including bounded scans, report
# conversion, page probes, checkpoint, and both reopen paths. This coverage is
# required before --strip-ir because stripped images cannot JIT a missed path.
include(joinpath(@__DIR__,"..","arsp4.jl"))
mktempdir() do directory
    output = joinpath(directory,"precompile-arsp4.toml")
    run_arsp4(Dict(
        "rows"=>"64", "batch"=>"64", "samples"=>"1", "warmup"=>"1",
        "updates"=>"1", "deletes"=>"1", "range-width"=>"8",
        "page-count"=>"1", "page-sizes"=>"8192",
        "directory"=>joinpath(directory,"run"), "output"=>output,
    ))
    TOML.parsefile(output)
end
