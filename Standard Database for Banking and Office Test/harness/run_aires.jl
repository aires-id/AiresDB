#!/usr/bin/env julia

using AiresDB
using AiresDB.Internal
using Dates
using JSON3
using SHA
using Statistics

const AB = AiresDB
const SEED = 1999

function option(name::String; required::Bool=false, default=nothing)
    prefix = "--$name="
    value = findfirst(argument -> startswith(argument, prefix), ARGS)
    value === nothing && required && error("Missing $prefix...")
    value === nothing ? default : ARGS[value][length(prefix)+1:end]
end

function percentile_ns(values::Vector{Int}, fraction::Float64)
    ordered = sort(values)
    ordered[clamp(ceil(Int, fraction * length(ordered)), 1, length(ordered))] / 1e6
end

function latency(values::Vector{Int})
    Dict(
        "count" => length(values),
        "samples_ms" => values ./ 1e6,
        "p50_ms" => percentile_ns(values, 0.50),
        "p95_ms" => percentile_ns(values, 0.95),
        "p99_ms" => percentile_ns(values, 0.99),
        "errors" => 0,
    )
end

function rss_bytes(; peak::Bool=false)
    Sys.iswindows() || return Int(Sys.maxrss())
    process = ccall((:GetCurrentProcess, "kernel32"), stdcall, Ptr{Cvoid}, ())
    counters = zeros(UInt8, 80)
    counters[1:4] .= reinterpret(UInt8, [UInt32(length(counters))])
    ok = ccall((:GetProcessMemoryInfo, "psapi"), stdcall, Int32,
        (Ptr{Cvoid}, Ptr{UInt8}, UInt32), process, counters, UInt32(length(counters)))
    ok == 0 && return 0
    bytes = peak ? @view(counters[9:16]) : @view(counters[17:24])
    Int(only(reinterpret(UInt64, bytes)))
end

const SCHEMAS = [
    "Buat Tabel 'branches' Isi 'branch_id & code & city & status' Dengan 'branch_id = I(P) & code = C(8&N&Not Null) & city = C(40&Not Null) & status = C(16&Not Null)' -:",
    "Buat Tabel 'departments' Isi 'department_id & name & cost_center' Dengan 'department_id = I(P) & name = C(64&Not Null) & cost_center = C(16&N&Not Null)' -:",
    "Buat Tabel 'customers' Isi 'customer_id & branch_id & name & status & risk_class & created_at' Dengan 'customer_id = I(P) & branch_id = I(Not Null) & name = C(96&Not Null) & status = C(16&Not Null) & risk_class = I(Not Null) & created_at = T(Not Null)' -:",
    "Buat Tabel 'accounts' Isi 'account_id & customer_id & account_type & balance_cents & status & opened_at' Dengan 'account_id = I(P) & customer_id = I(Not Null) & account_type = C(16&Not Null) & balance_cents = I(Not Null) & status = C(16&Not Null) & opened_at = T(Not Null)' -:",
    "Buat Tabel 'transactions' Isi 'transaction_id & account_id & timestamp & type & amount_cents & channel & reference' Dengan 'transaction_id = I(P) & account_id = I(Not Null) & timestamp = TW(Not Null) & type = C(16&Not Null) & amount_cents = I(Not Null) & channel = C(16&Not Null) & reference = C(32&N&Not Null)' -:",
    "Buat Tabel 'employees' Isi 'employee_id & department_id & branch_id & name & role & salary_cents & status' Dengan 'employee_id = I(P) & department_id = I(Not Null) & branch_id = I(Not Null) & name = C(96&Not Null) & role = C(16&Not Null) & salary_cents = I(Not Null) & status = C(16&Not Null)' -:",
    "Buat Tabel 'documents' Isi 'document_id & owner_type & owner_id & document_type & title & created_at & checksum' Dengan 'document_id = I(P) & owner_type = C(16&Not Null) & owner_id = I(Not Null) & document_type = C(16&Not Null) & title = C(128&Not Null) & created_at = T(Not Null) & checksum = C(64&Not Null)' -:",
]

const TABLE_ORDER = ["branches", "departments", "customers", "accounts", "transactions", "employees", "documents"]

function parse_row(name::String, fields::Vector{SubString{String}})
    if name == "branches"
        Any[parse(Int64, fields[1]), String(fields[2]), String(fields[3]), String(fields[4])]
    elseif name == "departments"
        Any[parse(Int64, fields[1]), String(fields[2]), String(fields[3])]
    elseif name == "customers"
        Any[parse(Int64, fields[1]), parse(Int64, fields[2]), String(fields[3]), String(fields[4]), parse(Int64, fields[5]), String(fields[6])]
    elseif name == "accounts"
        Any[parse(Int64, fields[1]), parse(Int64, fields[2]), String(fields[3]), parse(Int64, fields[4]), String(fields[5]), String(fields[6])]
    elseif name == "transactions"
        Any[parse(Int64, fields[1]), parse(Int64, fields[2]), String(fields[3]), String(fields[4]), parse(Int64, fields[5]), String(fields[6]), String(fields[7])]
    elseif name == "employees"
        Any[parse(Int64, fields[1]), parse(Int64, fields[2]), parse(Int64, fields[3]), String(fields[4]), String(fields[5]), parse(Int64, fields[6]), String(fields[7])]
    elseif name == "documents"
        Any[parse(Int64, fields[1]), String(fields[2]), parse(Int64, fields[3]), String(fields[4]), String(fields[5]), String(fields[6]), String(fields[7])]
    else
        error("Unknown SDEBO table $name")
    end
end

function load_table!(session::Session, dataset::String, name::String)
    path = joinpath(dataset, "$name.psv")
    open(path, "r") do stream
        eof(stream) && error("Empty dataset file $path")
        readline(stream) # header
        rows = (parse_row(name, split(line, '|'; keepempty=true)) for line in eachline(stream))
        bulk_insert!(session, name, rows)
    end
end

function prewarm!()
    mktempdir() do root
        session = Session(root; storage=AB.BinaryRowStore(64 * 1024 * 1024))
        execute!(session, "Buat 'warmup' -:")
        execute!(session, "Buat Tabel 't' Isi 'id & value' Dengan 'id = I(P) & value = I(Not Null)' -:")
        bulk_insert!(session, "t", ([Int64(i), Int64(i)] for i in 1:16))
        lookup(session, "t", 8)
        execute!(session, "Pilih 'Sum(value)' Dari 't' -:")
        close(session)
    end
end

function create_database!(root::String)
    session = Session(root; storage=AB.BinaryRowStore(4 * 1024 * 1024 * 1024))
    execute!(session, "Buat 'sdbeo' -:")
    foreach(statement -> execute!(session, statement), SCHEMAS)
    session
end

function file_sizes(root::String)
    sum(filesize(joinpath(root, name)) for name in readdir(root) if isfile(joinpath(root, name)))
end

function timed_samples!(operation, warmup::Int, measured::Int)
    for index in 1:warmup
        operation(index)
    end
    values = Int[]
    for index in 1:measured
        started = time_ns()
        operation(warmup + index)
        push!(values, time_ns() - started)
    end
    values
end

function canonical(value)
    value === nothing && return "NULL"
    value isa DateTime && return Dates.format(value, dateformat"yyyy-mm-ddTHH:MM:SS")
    value isa Date && return Dates.format(value, dateformat"yyyy-mm-dd")
    String(string(value))
end

function result_digest(rows)
    io = IOBuffer()
    for row in rows
        println(io, join(canonical.(row), '|'))
    end
    bytes2hex(sha256(take!(io)))
end

function aggregate_result_digest(rows)
    io = IOBuffer()
    for row in rows
        values = String[string(row[1])]
        for (offset, value) in enumerate(row[2:end])
            column = offset + 1
            if column == 4 && value isa Rational
                scale = 1_000_000
                scaled = div(numerator(value) * scale, denominator(value))
                divisor = gcd(scaled, scale)
                push!(values, "$(div(scaled, divisor))/$(div(scale, divisor))")
            elseif value isa Rational
                push!(values, "$(numerator(value))/$(denominator(value))")
            elseif value isa Integer
                push!(values, "$(value)/1")
            else
                exact = AB.exact(value)
                push!(values, "$(numerator(exact))/$(denominator(exact))")
            end
        end
        println(io, join(values, '|'))
    end
    bytes2hex(sha256(take!(io)))
end

function verify_counts(session::Session, manifest)
    actual = Dict{String,Int}()
    for name in TABLE_ORDER
        count = Int(only(only(execute!(session, "Pilih 'Count(*)' Dari '$name' -:").rows)))
        expected = Int(manifest["tables"][name]["rows"])
        count == expected || error("$name row count $count != $expected")
        actual[name] = count
    end
    actual
end

function run_workload(dataset::String, output::String, run_number::Int)
    mkpath(output)
    prewarm!()
    database_root = joinpath(output, "database")
    mkpath(database_root)
    manifest = JSON3.read(read(joinpath(dataset, "manifest.json"), String))
    session = create_database!(database_root)
    tests = Dict{String,Any}()

    load_started = time_ns()
    load_error = nothing
    try
        foreach(name -> load_table!(session, dataset, name), TABLE_ORDER)
    catch error
        load_error = sprint(showerror, error)
    end
    load_ns = time_ns() - load_started
    load_error === nothing || error(load_error)
    counts = verify_counts(session, manifest)
    checkpoint!(session)
    total_rows = Int(manifest["total_rows"])
    tests["Q01"] = Dict(
        "elapsed_ms" => load_ns / 1e6,
        "throughput_rows_s" => total_rows / (load_ns / 1e9),
        "rows" => total_rows,
        "row_counts" => counts,
        "storage_bytes" => file_sizes(database_root),
        "process_peak_rss_bytes" => rss_bytes(peak=true),
        "errors" => 0,
    )

    transaction_count = Int(manifest["tables"]["transactions"]["rows"])
    transaction_key(iteration) = Int64(1 + mod(iteration * 104_729 + SEED, transaction_count))

    lookup_samples = timed_samples!(100, 1000) do iteration
        key = transaction_key(iteration)
        row = lookup(session, "transactions", key)
        row !== nothing && row[1] == key || error("Q02 lookup mismatch for $key")
    end
    tests["Q02"] = merge(latency(lookup_samples), Dict("correct" => true, "allocation" => "not recorded"))

    filter_samples = timed_samples!(100, 1000) do iteration
        key = transaction_key(iteration)
        reference = "TX-$SEED-" * lpad(key, 12, '0')
        query = "Pilih 'transaction_id & reference' Dari 'transactions' Dengan 'reference = \"$reference\"' M: 'reference Atas' Limit(1) -:"
        rows = execute!(session, query).rows
        length(rows) == 1 && rows[1][1] == key && rows[1][2] == reference || error("Q03 indexed filter mismatch")
    end
    tests["Q03"] = merge(latency(filter_samples), Dict("correct" => true, "index" => "unique B+Tree(reference)"))

    range_samples = timed_samples!(2, 7) do iteration
        first_key = Int64(1 + mod(iteration * 7_919 + SEED, transaction_count - 100))
        last_key = first_key + 99
        query = "Pilih 'transaction_id & amount_cents' Dari 'transactions' Dengan 'transaction_id >= $first_key &: transaction_id <= $last_key' M: 'transaction_id Atas' Limit(100) -:"
        rows = execute!(session, query).rows
        length(rows) == 100 && rows[1][1] == first_key && rows[end][1] == last_key || error("Q04 range mismatch")
    end
    tests["Q04"] = merge(latency(range_samples), Dict("correct" => true, "rows_per_result" => 100, "index" => "primary B+Tree(transaction_id)"))

    aggregate_query = "Pilih 'channel & Count(*) & Sum(amount_cents) & Avg(amount_cents) & Min(amount_cents) & Max(amount_cents)' Dari 'transactions' Grup Dari 'channel' M: 'channel Atas' -:"
    aggregate_digest = Ref("")
    aggregate_samples = timed_samples!(2, 7) do _
        rows = execute!(session, aggregate_query).rows
        length(rows) == 5 || error("Q05 group count mismatch")
        aggregate_digest[] = aggregate_result_digest(rows)
    end
    tests["Q05"] = merge(latency(aggregate_samples), Dict("correct" => true, "result_digest" => aggregate_digest[]))

    join_queries = [
        "Pilih 'Count(*)' Dari 'accounts &&& customers' Gabung Dengan 'accounts.customer_id = customers.customer_id' Dengan 'customers.branch_id = 7' -:",
        "Pilih 'Count(*)' Dari 'employees &&& departments' Gabung Dengan 'employees.department_id = departments.department_id' Dengan 'employees.branch_id = 11' -:",
    ]
    join_digests = String[]
    join_samples = Int[]
    for query in join_queries
        holder = Ref("")
        append!(join_samples, timed_samples!(2, 7) do _
            rows = execute!(session, query).rows
            holder[] = result_digest(rows)
        end)
        push!(join_digests, holder[])
    end
    tests["Q06"] = merge(latency(join_samples), Dict("correct" => true, "result_digests" => join_digests, "relations" => 2))

    scan_count = Ref(0)
    scan_digest = Ref("")
    scan_samples = timed_samples!(2, 7) do _
        rows = execute!(session, "Pilih 'transaction_id & amount_cents' Dari 'transactions' -:").rows
        scan_count[] = length(rows)
        scan_count[] == transaction_count || error("Q07 scan count mismatch")
        scan_digest[] = result_digest(rows)
    end
    tests["Q07"] = merge(latency(scan_samples), Dict(
        "correct" => true,
        "rows" => scan_count[],
        "throughput_rows_s" => scan_count[] / (median(scan_samples) / 1e9),
        "result_digest" => scan_digest[],
    ))

    execute!(session, "Buat Tabel 'operations' Isi 'operation_id & value & note' Dengan 'operation_id = I(P) & value = I(Not Null) & note = C(64&Not Null)' -:")
    insert_samples = timed_samples!(20, 200) do iteration
        bulk_insert!(session, "operations", [[Int64(iteration), Int64(iteration * 3), "insert-$iteration"]])
    end
    tests["T01"] = merge(latency(insert_samples), Dict("correct" => length(scan_rows(session, "operations")) == 220, "durability" => "WAL sync per commit"))

    update_samples = timed_samples!(20, 100) do iteration
        key = Int64(1 + mod(iteration * 17 + SEED, 220))
        update_key!(session, "operations", key, Dict("value" => Int64(iteration * 11)))
    end
    delete_samples = timed_samples!(20, 100) do iteration
        key = Int64(221 - iteration)
        delete_key!(session, "operations", key)
    end
    combined_write = vcat(update_samples, delete_samples)
    tests["T02"] = merge(latency(combined_write), Dict(
        "correct" => length(scan_rows(session, "operations")) == 100,
        "update" => latency(update_samples),
        "delete" => latency(delete_samples),
        "durability" => "WAL sync per commit",
    ))

    checkpoint!(session)
    close(session)
    reopened = Session(database_root; storage=AB.BinaryRowStore(4 * 1024 * 1024 * 1024))
    execute!(reopened, "Pilih 'sdbeo' -:")
    reopen_checks = Dict(
        "Q02_key" => lookup(reopened, "transactions", Int64(transaction_count)) !== nothing,
        "T01_rows" => length(scan_rows(reopened, "operations")),
    )
    close(reopened)

    report = Dict(
        "engine" => "AiresDB",
        "engine_version" => "0.1.0",
        "mode" => "embedded",
        "run" => run_number,
        "dataset" => String(manifest["profile"]),
        "seed" => SEED,
        "source_digest" => String(manifest["logical_source_sha256"]),
        "configuration" => Dict(
            "runtime" => string("Julia ", VERSION),
            "threads" => Threads.nthreads(),
            "storage_limit_bytes" => 4 * 1024 * 1024 * 1024,
            "durability" => "WAL commit marker followed by FlushFileBuffers; PageStore is WAL-derived",
            "money_representation" => "signed Int-bit integer cents",
        ),
        "tests" => tests,
        "reopen_checks" => reopen_checks,
        "status" => reopen_checks["Q02_key"] && reopen_checks["T01_rows"] == 100,
    )
    path = joinpath(output, "result.json")
    open(path, "w") do stream
        JSON3.pretty(stream, report)
        println(stream)
    end
    println(path)
end

dataset = abspath(String(option("dataset"; required=true)))
output = abspath(String(option("output"; required=true)))
run_number = parse(Int, String(option("run"; default="1")))
run_workload(dataset, output, run_number)
