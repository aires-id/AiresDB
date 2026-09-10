#!/usr/bin/env julia
"""ARSP-4 storage-path benchmark for AiresDB.

Run from the repository root:

    julia --project=. benchmark/arsp4.jl --rows=100000 --batch=5000 \
        --samples=500 --directory=work/arsp4_run --output=verification/arsp4.toml

This is an engineering benchmark, not a TPC-C or TPC-H result.  It measures
the AiresDB API and the ARSP-4 physical primitives separately, reports the
configuration needed to reproduce a run, and deliberately does not compare
the results with another database.
"""

using AiresDB
using AiresDB.Internal
using Dates
using Random
using TOML

const AB = AiresDB

function _options(args)
    options = Dict{String,String}()
    for argument in args
        startswith(argument,"--") && occursin('=',argument) ||
            error("Expected --key=value, got $argument")
        key,value = split(argument[3:end],'=';limit=2)
        isempty(key) && error("Empty option name.")
        haskey(options,key) && error("Option --$key was supplied more than once.")
        options[key] = value
    end
    options
end

function _int_option(options,name,default;minimum=0)
    value = tryparse(Int,get(options,name,string(default)))
    value === nothing && error("--$name must be an integer.")
    value >= minimum || error("--$name must be at least $minimum.")
    value
end

function _page_sizes(options)
    raw = split(get(options,"page-sizes","4096,8192,16384"),',')
    sizes = Int[]
    for text in raw
        size = tryparse(Int,strip(text))
        size === nothing && error("--page-sizes contains a non-integer value.")
        size >= AB.PAGE_HEADER_SIZE || error("A page size must be at least $(AB.PAGE_HEADER_SIZE) bytes.")
        size < typemax(UInt16) || error("A page size must fit the ARSP-4 page format.")
        size in sizes || push!(sizes,size)
    end
    isempty(sizes) && error("--page-sizes must contain at least one page size.")
    sizes
end

# Nearest-rank timing summary. Samples remain in the report for rechecking.
function latency_summary(samples_ns::AbstractVector{<:Integer})
    milliseconds = sort!(Float64.(samples_ns) ./ 1e6)
    count = length(milliseconds)
    percentile(p) = count == 0 ? 0.0 : milliseconds[clamp(ceil(Int,p * count),1,count)]
    total = sum(milliseconds)
    Dict{String,Any}(
        "count" => count,
        "total_ms" => total,
        "p50_ms" => percentile(0.50),
        "p95_ms" => percentile(0.95),
        "p99_ms" => percentile(0.99),
        "min_ms" => count == 0 ? 0.0 : first(milliseconds),
        "max_ms" => count == 0 ? 0.0 : last(milliseconds),
        "operations_per_second" => total == 0 ? 0.0 : count * 1000 / total,
        "samples_ms" => milliseconds,
    )
end

function _timed_samples!(count::Integer,f::Function)
    samples = Int[]
    for _ in 1:count
        started = time_ns()
        f()
        push!(samples,time_ns() - started)
    end
    latency_summary(samples)
end
# Julia's `do` syntax supplies the function as the first positional argument.
_timed_samples!(f::Function,count::Integer) = _timed_samples!(count,f)

function _throughput(summary::Dict{String,Any},rows::Integer)
    result = copy(summary)
    result["rows"] = Int(rows)
    result["rows_per_second"] = summary["total_ms"] == 0 ? 0.0 : rows * 1000 / summary["total_ms"]
    result
end

function _bytes_throughput(summary::Dict{String,Any},bytes::Integer)
    result = copy(summary)
    result["bytes"] = Int(bytes)
    result["bytes_per_second"] = summary["total_ms"] == 0 ? 0.0 : bytes * 1000 / summary["total_ms"]
    result
end

function _rss_bytes()
    isdefined(Sys,:maxrss) || return 0
    value = Sys.maxrss()
    value <= typemax(Int64) || return typemax(Int64)
    Int64(value)
end

# Turn named tuples, unsigned counters, and symbols into TOML-safe values.
function _toml_value(value)
    value isa NamedTuple && return Dict(String(key)=>_toml_value(item) for (key,item) in pairs(value))
    value isa AbstractDict && return Dict(string(key)=>_toml_value(item) for (key,item) in pairs(value))
    value isa Tuple && return [_toml_value(item) for item in value]
    value isa AbstractVector && return [_toml_value(item) for item in value]
    value isa Symbol && return String(value)
    value isa Enum && return string(value)
    value isa Bool && return value
    value isa Unsigned && return value <= typemax(Int64) ? Int64(value) : string(value)
    value isa Integer && return value <= typemax(Int64) && value >= typemin(Int64) ? Int64(value) : string(value)
    value === nothing && return "unavailable"
    value
end

function _write_report(path::String,report::Dict{String,Any})
    mkpath(dirname(abspath(path)))
    open(path,"w") do io
        TOML.print(io,_toml_value(report);sorted=true)
    end
    path
end

function _file_bytes(path::String)
    isfile(path) ? filesize(path) : 0
end

function _database_bytes(directory::String,database::String)
    wal = joinpath(directory,database * ".aires")
    pages = wal * ".pages"
    Dict{String,Any}(
        "wal_bytes" => _file_bytes(wal),
        "page_store_bytes" => _file_bytes(pages),
        "total_bytes" => _file_bytes(wal) + _file_bytes(pages),
    )
end

function _new_session(directory::String,database::String;create::Bool=false)
    session = Session(directory)
    execute!(session,create ? "Buat '$database' -:" : "Pilih '$database' -:")
    session
end

# Release a closed session before timing a reopen. Dropping its logical image
# prevents the measurement from retaining two complete catalogs at once.
function _release_before_reopen!(session::Session)
    close(session)
    GC.gc(true)
    nothing
end

function _create_benchmark_table!(session)
    execute!(session,"""
        Buat Tabel 'Records' Isi 'ID & OrderKey & Bucket & Amount & Payload'
        Dengan 'ID = I(P) & OrderKey = I(N & Not Null) & Bucket = I & Amount = D & Payload = C(64)' -:
    """)
end

function _insert_batch!(session,start_id::Int,stop_id::Int,rows::Int)
    # Feed bulk_insert! lazily.  The transaction still contains exactly the
    # same rows and one atomic commit, while the benchmark no longer retains a
    # second 250k-row object graph solely as input staging.
    input = ((Int64(id),Int64(rows - id + 1),Int64(mod(id,64)),Int64(id),"payload-$id")
             for id in start_id:stop_id)
    started = time_ns()
    bulk_insert!(session,"Records",input)
    time_ns() - started
end

function _bulk_insert!(session,rows::Int,batch_size::Int)
    samples = Int[]
    for start_id in 1:batch_size:rows
        stop_id = min(rows,start_id + batch_size - 1)
        push!(samples,_insert_batch!(session,start_id,stop_id,rows))
    end
    _throughput(latency_summary(samples),rows)
end

# Consume a complete snapshot through bounded ARSP-4 batches. This keeps the
# full-row workload while avoiding retained materialized scan results.
function _stream_scan_count(session,name::String;batch_size::Int=256)
    AB.with_snapshot(session) do
        table = AB.get_table(AB.active_database(session),name)
        AB.record_read!(session,name)
        AB.with_page_store_snapshot(session,name) do physical
            physical === nothing && return length(table.rows)
            cursor = AB.page_store_scan_cursor(physical[1],name,physical[2];batch_size,row_ids=table.row_ids)
            cursor === nothing && return length(table.rows)
            count = 0
            while true
                batch = AB.next_page_store_batch!(cursor)
                batch === nothing && break
                count += length(batch)
            end
            count
        end
    end
end

function _warm_scan!(session,warmup::Int)
    for _ in 1:warmup
        _stream_scan_count(session,"Records")
    end
    nothing
end

function _page_store_primary_tree(session)
    handle = session.handle::AB.DatabaseHandle
    store = handle.page_store::AB.PageStore
    entry = store.tables["Records"]
    tree = entry.indexes[(1,)]
    store.pool,tree
end

# Compare isolated page sizes without changing the production sidecar format.
function _page_size_probe!(directory::String,page_size::Int,page_count::Int)
    path = joinpath(directory,"page-manager-$(page_size).arsp")
    ispath(path) && error("Refusing to overwrite page-size probe: $path")
    manager = AB.open_page_manager(path;create=true,page_size=page_size,durable_lsn=0)
    ids = UInt64[]
    writes = Int[]
    write_stats = nothing
    try
        for number in 1:page_count
            page = AB.allocate_page!(manager,AB.PageTypeHeap)
            fill!(@view(page.bytes[AB.PAGE_HEADER_SIZE+1:end]),UInt8(mod(number,256)))
            AB.finalize_page!(page)
            started = time_ns()
            AB.write_page!(manager,page)
            push!(writes,time_ns() - started)
            push!(ids,page.id)
        end
        AB.flush_all_pages!(manager)
        write_stats = AB.page_manager_stats(manager)
    finally
        close(manager)
    end

    # Reopening removes all process-local page-manager state. The OS file cache
    # can still be warm; reports label this "process cold" rather than disk cold.
    reopened = AB.open_page_manager(path;page_size=page_size,durable_lsn=0)
    cold = Int[]
    warm = Int[]
    try
        for id in ids
            started = time_ns()
            AB.read_page(reopened,id)
            push!(cold,time_ns() - started)
        end
        for id in ids
            started = time_ns()
            AB.read_page(reopened,id)
            push!(warm,time_ns() - started)
        end
        stats = AB.page_manager_stats(reopened)
        return Dict{String,Any}(
            "page_size" => page_size,
            "pages" => page_count,
            "file_bytes" => filesize(path),
            "write" => _bytes_throughput(latency_summary(writes),page_size * page_count),
            "process_cold_read" => _bytes_throughput(latency_summary(cold),page_size * page_count),
            "warm_read" => _bytes_throughput(latency_summary(warm),page_size * page_count),
            "write_page_manager" => _toml_value(write_stats),
            "read_page_manager" => _toml_value(stats),
        )
    finally
        close(reopened)
    end
end

function _parse_configuration(options)
    rows = _int_option(options,"rows",10_000;minimum=1)
    batch = _int_option(options,"batch",1_000;minimum=1)
    samples = _int_option(options,"samples",200;minimum=1)
    warmup = _int_option(options,"warmup",10;minimum=0)
    updates = _int_option(options,"updates",min(200,rows);minimum=0)
    deletes = _int_option(options,"deletes",min(200,max(0,rows - updates));minimum=0)
    range_width = _int_option(options,"range-width",min(128,rows);minimum=1)
    page_count = _int_option(options,"page-count",128;minimum=1)
    seed = _int_option(options,"seed",20260904;minimum=0)
    batch <= rows || error("--batch cannot exceed --rows.")
    updates + deletes <= rows || error("--updates + --deletes cannot exceed --rows.")
    range_width <= rows || error("--range-width cannot exceed --rows.")
    (rows=rows,batch=batch,samples=samples,warmup=warmup,updates=updates,deletes=deletes,
     range_width=range_width,page_count=page_count,seed=seed,page_sizes=_page_sizes(options))
end

function _environment()
    Dict{String,Any}(
        "measured_on" => string(now()),
        "julia_version" => string(VERSION),
        "julia_threads" => Threads.nthreads(),
        "cpu_threads_detected" => Sys.CPU_THREADS,
        "kernel" => string(Sys.KERNEL),
        "architecture" => string(Sys.ARCH),
        "word_size" => Sys.WORD_SIZE,
        "cpu_models" => unique(String(info.model) for info in Sys.cpu_info()),
        "total_memory_bytes" => Int64(min(Sys.total_memory(),typemax(Int64))),
        "process_peak_rss_bytes" => _rss_bytes(),
        "commit_flush_mode" => Sys.iswindows() ? "FlushFileBuffers (Windows)" : "fsync",
    )
end

function run_arsp4(options=Dict{String,String}())
    config = _parse_configuration(options)
    directory = abspath(get(options,"directory",joinpath("work","arsp4_" * Dates.format(now(),"yyyymmdd_HHMMSS"))))
    database_directory = joinpath(directory,"database")
    output = abspath(get(options,"output",joinpath(directory,"arsp4.toml")))
    mkpath(database_directory)
    any(name->endswith(name,".aires") || endswith(name,".aires.pages"),readdir(database_directory)) &&
        error("Database benchmark directory already contains an AiresDB file: $database_directory")
    mkpath(directory)

    page_probe_directory = joinpath(directory,"page_sizes")
    mkpath(page_probe_directory)
    page_probes = Dict{String,Any}()
    for page_size in config.page_sizes
        page_probes[string(page_size)] = _page_size_probe!(page_probe_directory,page_size,config.page_count)
    end

    database = "ARSP4Bench"
    session = _new_session(database_directory,database;create=true)
    rng = MersenneTwister(config.seed)
    workloads = Dict{String,Any}()
    error_text = nothing
    try
        _create_benchmark_table!(session)
        workloads["bulk_insert"] = _bulk_insert!(session,config.rows,config.batch)

        # Reopen after initial load to record a process-cold scan, then retain
        # the new session for warm cache, index, mutation, and checkpoint paths.
        session = _release_before_reopen!(session)
        started = time_ns()
        session = _new_session(database_directory,database)
        workloads["startup_reopen"] = latency_summary([time_ns() - started])

        started = time_ns()
        cold_count = _stream_scan_count(session,"Records")
        cold_count == config.rows || error("Cold scan returned an unexpected row count.")
        workloads["sequential_scan_process_cold"] = _throughput(latency_summary([time_ns() - started]),cold_count)
        _warm_scan!(session,config.warmup)
        workloads["sequential_scan_warm"] = _throughput(_timed_samples!(config.samples) do
            _stream_scan_count(session,"Records") == config.rows || error("Warm scan lost a row.")
        end,config.rows * config.samples)

        keys = rand(rng,1:config.rows,config.samples)
        workloads["primary_key_lookup"] = _timed_samples!(config.samples) do
            id = keys[rand(rng,eachindex(keys))]
            lookup(session,"Records",id) === nothing && error("Primary-key lookup lost ID $id.")
        end

        range_starts = [rand(rng,1:config.rows - config.range_width + 1) for _ in 1:config.samples]
        workloads["range_predicate_query"] = _throughput(_timed_samples!(config.samples) do
            lower = range_starts[rand(rng,eachindex(range_starts))]
            result = execute!(session,"Pilih 'ID & Payload' Dari 'Records' Dengan 'ID >= $lower &: ID < $(lower + config.range_width)' -:")
            length(result.rows) == config.range_width || error("Range predicate returned an unexpected row count.")
        end,config.range_width * config.samples)

        # This is the physical B+Tree range primitive. The paired predicate
        # measurement above shows the current AiresQL plan path separately.
        pool,tree = _page_store_primary_tree(session)
        workloads["persistent_btree_range"] = _throughput(_timed_samples!(config.samples) do
            lower = range_starts[rand(rng,eachindex(range_starts))]
            matches = AB.btree_range(pool,tree;lower=(Int64(lower),),upper=(Int64(lower + config.range_width - 1),))
            length(matches) == config.range_width || error("B+Tree range returned an unexpected entry count.")
        end,config.range_width * config.samples)

        order_limit = min(256,config.rows)
        workloads["order_m_index"] = _throughput(_timed_samples!(config.samples) do
            result = execute!(session,"Pilih 'ID & OrderKey' Dari 'Records' M: 'OrderKey Atas' Limit($order_limit) -:")
            length(result.rows) == order_limit || error("M: query returned an unexpected row count.")
        end,order_limit * config.samples)

        update_keys = collect(1:config.updates)
        update_position = Ref(1)
        workloads["update"] = _timed_samples!(length(update_keys)) do
            id = update_keys[update_position[]]
            update_position[] += 1
            update_key!(session,"Records",id,Dict("Payload" => "updated-$id"))
        end
        delete_keys = collect(config.updates+1:config.updates+config.deletes)
        delete_position = Ref(1)
        workloads["delete"] = _timed_samples!(length(delete_keys)) do
            id = delete_keys[delete_position[]]
            delete_position[] += 1
            delete_key!(session,"Records",id)
        end

        before_checkpoint = storage_stats(session)
        workloads["checkpoint"] = _timed_samples!(1) do
            checkpoint!(session)
        end
        after_checkpoint = storage_stats(session)

        session = _release_before_reopen!(session)
        started = time_ns()
        session = _new_session(database_directory,database)
        workloads["startup_reopen_after_checkpoint"] = latency_summary([time_ns() - started])
        expected_rows = config.rows - config.deletes
        reopened_count = _stream_scan_count(session,"Records")
        reopened_count == expected_rows || error("Reopened database returned an unexpected row count.")

        report = Dict{String,Any}(
            "report_format" => "airesdb-arsp4-benchmark-v1",
            "notice" => "Local ARSP-4 engineering benchmark; not audited TPC-C/TPC-H and not comparable with official TPC metrics.",
            "page_size_note" => "Production PageStore remains 8192 bytes. 4/8/16 KiB results are isolated PageManager probes, not a migration of the production sidecar format.",
            "database_directory" => database_directory,
            "database" => database,
            "configuration" => Dict{String,Any}(
                "rows"=>config.rows,"bulk_batch_rows"=>config.batch,"samples"=>config.samples,
                "warmup_scans"=>config.warmup,"updates"=>config.updates,"deletes"=>config.deletes,
                "range_width"=>config.range_width,"page_probe_count"=>config.page_count,
                "page_sizes"=>config.page_sizes,"seed"=>config.seed,
            ),
            "environment" => _environment(),
            "workloads" => workloads,
            "page_size_probes" => page_probes,
            "storage_before_checkpoint" => _toml_value(before_checkpoint),
            "storage_after_checkpoint" => _toml_value(after_checkpoint),
            "storage_after_reopen" => _toml_value(storage_stats(session)),
            "files_after_reopen" => _database_bytes(database_directory,database),
            "rows_after_reopen" => reopened_count,
        )
        _write_report(output,report)
        return output,report
    catch error
        error_text = sprint(showerror,error)
        rethrow()
    finally
        try
            session === nothing || close(session)
        catch close_error
            if error_text !== nothing
                @warn "Could not close benchmark session after failure" exception=(close_error,catch_backtrace())
            end
        end
    end
end

function main(args=ARGS)
    options = _options(args)
    output,report = run_arsp4(options)
    println("Saved ",output)
    println("bulk rows/s=",report["workloads"]["bulk_insert"]["rows_per_second"])
    println("PK ops/s=",report["workloads"]["primary_key_lookup"]["operations_per_second"])
    println("final page hit ratio=",report["storage_after_reopen"]["buffer_pool"]["hit_ratio"])
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main()
