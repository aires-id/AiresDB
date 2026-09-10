module CompareBench

using AiresDB
using AiresDB.Internal
using SQLite
using DuckDB
using DBInterface
using Dates
using Random
using SHA
using Printf

include(joinpath(@__DIR__, "..", "AiresBench.jl"))
const AB = AiresBench
const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const ENGINE_NAMES = ("airesdb", "sqlite", "duckdb")

abstract type CompareBackend end

mutable struct AiresBackend <: CompareBackend
    directory::String
    database::String
    session::AiresDB.Session
end

mutable struct SQLiteBackend <: CompareBackend
    path::String
    db::SQLite.DB
end

mutable struct DuckDBBackend <: CompareBackend
    path::String
    db::DuckDB.DB
end

backend_name(::AiresBackend) = "airesdb"
backend_name(::SQLiteBackend) = "sqlite"
backend_name(::DuckDBBackend) = "duckdb"

const CORE_SCHEMA = [
    ("id", "I"),
    ("category", "I"),
    ("order_key", "I"),
    ("payload", "C(64)"),
    ("amount_cents", "I"),
    ("note", "C(64)"),
]
const CORE_KEYS = ["id"]
const CORE_TABLE = "records"

qident(name::AbstractString) = "\"" * replace(String(name), "\"" => "\"\"") * "\""

function _json_string(value::AbstractString)
    "\"" * replace(String(value), '\\' => "\\\\", '"' => "\\\"", '\b' => "\\b", '\f' => "\\f", '\n' => "\\n", '\r' => "\\r", '\t' => "\\t") * "\""
end

function write_json(io::IO, value)
    if value === nothing || value === missing
        print(io, "null")
    elseif value isa Bool
        print(io, value ? "true" : "false")
    elseif value isa Integer
        print(io, value)
    elseif value isa AbstractFloat
        isfinite(value) ? print(io, repr(value)) : print(io, "null")
    elseif value isa Rational
        write_json(io, string(numerator(value), "/", denominator(value)))
    elseif value isa AbstractString || value isa Symbol || value isa Char
        print(io, _json_string(string(value)))
    elseif value isa NamedTuple
        write_json(io, Dict(string(k) => getproperty(value, k) for k in keys(value)))
    elseif value isa AbstractDict
        print(io, '{')
        first_entry = true
        for (key, item) in sort!(collect(pairs(value)); by=pair -> string(pair.first))
            first_entry || print(io, ',')
            first_entry = false
            print(io, _json_string(string(key)), ':')
            write_json(io, item)
        end
        print(io, '}')
    elseif value isa Tuple || value isa AbstractVector || value isa Set
        print(io, '[')
        first_entry = true
        for item in value
            first_entry || print(io, ',')
            first_entry = false
            write_json(io, item)
        end
        print(io, ']')
    else
        write_json(io, string(value))
    end
end

function write_json(path::AbstractString, value)
    mkpath(dirname(abspath(path)))
    open(path, "w") do io
        write_json(io, value)
        println(io)
    end
    path
end

function _sha256_file(path::AbstractString)
    isfile(path) || return nothing
    open(path, "r") do io
        bytes2hex(SHA.sha256(read(io)))
    end
end

function source_hashes()
    files = (
        "Project.toml",
        joinpath("benchmark", "AiresBench.jl"),
        joinpath("benchmark", "tpcc.jl"),
        joinpath("benchmark", "tpch_data.jl"),
        joinpath("benchmark", "tpch_queries.jl"),
        joinpath("benchmark", "oracle.py"),
        joinpath("benchmark", "compare", "CompareBench.jl"),
        joinpath("benchmark", "compare", "run.jl"),
        joinpath("benchmark", "compare", "Project.toml"),
        joinpath("benchmark", "compare", "Manifest.toml"),
        # The comparison harness exercises the production page/MVCC path.  Keep
        # those implementation hashes in every report so an audit can reproduce
        # exactly which engine build was measured.
        joinpath("src", "api.jl"),
        joinpath("src", "transactions.jl"),
        joinpath("src", "storage", "pagestore.jl"),
        joinpath("src", "storage", "recordmanager.jl"),
        joinpath("src", "storage", "rollingpipeline.jl"),
        joinpath("test", "wal_mvcc_integration.jl"),
        joinpath("benchmark", "compare", "test", "runtests.jl"),
    )
    Dict(file => _sha256_file(joinpath(ROOT, file)) for file in files if isfile(joinpath(ROOT, file)))
end

function _package_version(package_module)
    version = Base.pkgversion(package_module)
    version === nothing ? "unknown" : string(version)
end

function environment_metadata()
    cpu_models = try
        unique(String(info.model) for info in Sys.cpu_info())
    catch
        String[]
    end
    Dict{String,Any}(
        "measured_at_local" => string(now()),
        "timezone" => get(ENV, "TZ", "host-local-time"),
        "julia_version" => string(VERSION),
        "julia_threads" => Threads.nthreads(),
        "cpu_threads_detected" => Sys.CPU_THREADS,
        "cpu_models" => cpu_models,
        "kernel" => string(Sys.KERNEL),
        "architecture" => string(Sys.ARCH),
        "word_size" => Sys.WORD_SIZE,
        "total_memory_bytes" => Int64(min(Sys.total_memory(), typemax(Int64))),
        "free_memory_bytes" => Int64(min(Sys.free_memory(), typemax(Int64))),
        "package_versions" => Dict(
            "AiresDB" => _package_version(AiresDB),
            "SQLite" => _package_version(SQLite),
            "DuckDB" => _package_version(DuckDB),
            "DBInterface" => _package_version(DBInterface),
        ),
    )
end

"""Reject an unqualified comparison profile before it can produce evidence.

DuckDB.jl on Windows can retain an in-process file handle after close when its
worker pool uses several Julia threads.  A one-thread, one-connection baseline
keeps the reopen check deterministic and is the profile documented by this
suite.  Concurrency needs its own separately validated profile.
"""
function require_baseline_profile!()
    Threads.nthreads() == 1 || error("The comparative baseline requires Julia --threads=1 and one connection per engine. Current Julia thread count: $(Threads.nthreads()).")
    nothing
end

function latency_summary(samples_ns::AbstractVector{<:Integer})
    samples = Float64.(samples_ns) ./ 1e6
    ordered = sort(copy(samples))
    n = length(ordered)
    percentile(p) = n == 0 ? nothing : ordered[clamp(ceil(Int, p * n), 1, n)]
    total = sum(samples)
    Dict{String,Any}(
        "count" => n,
        "samples_ms" => samples,
        "min_ms" => n == 0 ? nothing : first(ordered),
        "p50_ms" => percentile(0.50),
        "p95_ms" => n < 20 ? nothing : percentile(0.95),
        "p99_ms" => n < 100 ? nothing : percentile(0.99),
        "max_ms" => n == 0 ? nothing : last(ordered),
        "total_ms" => total,
        "operations_per_second" => total == 0 ? nothing : n * 1000 / total,
    )
end

function _canonical_value(value)
    if value === nothing || value === missing
        "N"
    elseif value isa Bool
        value ? "B1" : "B0"
    elseif value isa Integer
        "I:" * string(value)
    elseif value isa Rational
        "R:" * string(numerator(value), "/", denominator(value))
    elseif value isa AbstractFloat
        "F:" * @sprintf("%.9f", Float64(value))
    elseif value isa AbstractString
        "S:" * string(ncodeunits(value), ":", value)
    elseif value isa Symbol
        "Y:" * String(value)
    else
        "X:" * repr(value)
    end
end

_canonical_row(row) = join((_canonical_value(value) for value in row), "\u001f")

function row_digest(rows; unordered::Bool=false)
    text = [_canonical_row(row) for row in rows]
    unordered && sort!(text)
    bytes2hex(SHA.sha256(codeunits(join(text, "\u001e"))))
end

function _numeric(value)
    value isa Number && !(value isa Complex)
end

function _cell_equivalent(left, right)
    (left === nothing || left === missing) && return right === nothing || right === missing
    (right === nothing || right === missing) && return false
    if _numeric(left) && _numeric(right)
        return isapprox(Float64(left), Float64(right); rtol=1e-9, atol=1e-7)
    end
    left == right
end

function rows_equivalent(left, right; unordered::Bool=false)
    length(left) == length(right) || return false
    a = unordered ? sort(copy(left); by=_canonical_row) : left
    b = unordered ? sort(copy(right); by=_canonical_row) : right
    all(length(x) == length(y) && all(_cell_equivalent(l, r) for (l, r) in zip(x, y)) for (x, y) in zip(a, b))
end

function _rows_or_error(expected, actual, label::AbstractString; unordered::Bool=false)
    rows_equivalent(expected, actual; unordered=unordered) && return nothing
    error("$label mismatch: expected rows=$(length(expected)) digest=$(row_digest(expected; unordered=unordered)) actual rows=$(length(actual)) digest=$(row_digest(actual; unordered=unordered))")
end

function _directory_bytes(directory::AbstractString)
    isdir(directory) || return Int64(0)
    total = Int64(0)
    for (root, _, files) in walkdir(directory)
        for file in files
            path = joinpath(root, file)
            total += filesize(path)
        end
    end
    total
end

function _sql_rows(db, sql::AbstractString, params=())
    cursor = isempty(params) ? DBInterface.execute(db, String(sql)) : DBInterface.execute(db, String(sql), params)
    try
        return [Tuple(row) for row in cursor]
    finally
        try
            DBInterface.close!(cursor)
        catch
        end
    end
end

function _sql_exec(db, sql::AbstractString, params=())
    cursor = isempty(params) ? DBInterface.execute(db, String(sql)) : DBInterface.execute(db, String(sql), params)
    try
        # Materialize even DDL/DML cursors. DuckDB's binding otherwise can keep
        # a completed result alive until GC, which blocks a Windows file reopen.
        collect(cursor)
        nothing
    finally
        try
            DBInterface.close!(cursor)
        catch
        end
    end
    nothing
end

function _sqlite_configure!(db::SQLite.DB)
    _sql_rows(db, "PRAGMA journal_mode=WAL")
    _sql_exec(db, "PRAGMA synchronous=FULL")
    _sql_exec(db, "PRAGMA foreign_keys=ON")
    nothing
end

function new_aires_backend(directory::AbstractString; database::String="Compare")
    mkpath(directory)
    session = AiresDB.Session(directory)
    AiresDB.execute!(session, "Buat '$database' -:")
    AiresBackend(abspath(directory), database, session)
end

function new_sqlite_backend(path::AbstractString)
    mkpath(dirname(abspath(path)))
    db = SQLite.DB(path)
    _sqlite_configure!(db)
    SQLiteBackend(abspath(path), db)
end

function new_duckdb_backend(path::AbstractString)
    mkpath(dirname(abspath(path)))
    DuckDBBackend(abspath(path), DuckDB.DB(path))
end

function close_backend!(backend::AiresBackend)
    close(backend.session)
    AiresDB._close_page_stores_under!(backend.directory)
    nothing
end

function close_backend!(backend::SQLiteBackend)
    DBInterface.close!(backend.db)
    nothing
end

function close_backend!(backend::DuckDBBackend)
    DBInterface.close!(backend.db)
    # DuckDB.jl materializes query results in Julia objects.  Force their
    # finalizers before an in-process file reopen on Windows so a stale result
    # cannot retain the OS file handle.
    GC.gc(true)
    nothing
end

function reopen_backend!(backend::AiresBackend)
    close_backend!(backend)
    backend.session = AiresDB.Session(backend.directory)
    AiresDB.execute!(backend.session, "Pilih '$(backend.database)' -:")
    backend
end

function reopen_backend!(backend::SQLiteBackend)
    close_backend!(backend)
    backend.db = SQLite.DB(backend.path)
    _sqlite_configure!(backend.db)
    backend
end

function reopen_backend!(backend::DuckDBBackend)
    close_backend!(backend)
    # DuckDB worker shutdown is asynchronous on Windows when Julia has more
    # than one thread. Wait on the OS handle with a bounded retry rather than
    # treating an in-process close/reopen race as data loss.
    deadline = time_ns() + 5_000_000_000
    last_error = nothing
    while time_ns() <= deadline
        try
            backend.db = DuckDB.DB(backend.path)
            return backend
        catch error
            last_error = error
            GC.gc(true)
            sleep(0.05)
        end
    end
    throw(last_error)
end

function backend_settings(backend::AiresBackend)
    Dict{String,Any}(
        "binding" => "AiresDB public Julia API",
        "durability" => Sys.iswindows() ? "WAL commit FlushFileBuffers" : "WAL commit fsync",
        "mvcc" => "AiresDB optimistic serializable MVCC",
        "storage" => AiresDB.storage_stats(backend.session),
    )
end

function backend_settings(backend::SQLiteBackend)
    value(sql) = isempty(_sql_rows(backend.db, sql)) ? nothing : string(first(first(_sql_rows(backend.db, sql))))
    Dict{String,Any}(
        "binding" => "SQLite.jl / DBInterface",
        "journal_mode" => value("PRAGMA journal_mode"),
        "synchronous" => value("PRAGMA synchronous"),
        "foreign_keys" => value("PRAGMA foreign_keys"),
    )
end

function backend_settings(backend::DuckDBBackend)
    version = _sql_rows(backend.db, "SELECT version()")
    Dict{String,Any}(
        "binding" => "DuckDB.jl / DBInterface",
        "version" => isempty(version) ? nothing : string(first(first(version))),
        "durability" => "native DuckDB persistent database/WAL defaults; see engine version and configuration",
    )
end

function _sql_type(kind::AbstractString)
    startswith(kind, "I") && return "BIGINT"
    startswith(kind, "F") && return "DOUBLE"
    startswith(kind, "D") && return "DECIMAL(38, 10)"
    startswith(kind, "B") && return "BOOLEAN"
    "VARCHAR"
end

function create_table!(backend::AiresBackend, table::String, schema, keys)
    AB.create_schema!(backend.session, table, schema, keys)
    nothing
end

function create_table!(backend::Union{SQLiteBackend,DuckDBBackend}, table::String, schema, keys)
    definitions = [qident(name) * " " * _sql_type(kind) for (name, kind) in schema]
    append!(definitions, ["PRIMARY KEY (" * join(qident.(keys), ", ") * ")"])
    _sql_exec(backend.db, "CREATE TABLE " * qident(table) * " (" * join(definitions, ", ") * ")")
    nothing
end

function insert_rows!(backend::AiresBackend, table::String, rows; batch::Int=1000)
    for first_index in 1:batch:length(rows)
        last_index = min(length(rows), first_index + batch - 1)
        AiresDB.with_transaction(backend.session) do
            AiresDB.bulk_insert!(backend.session, table, rows[first_index:last_index])
        end
    end
    nothing
end

function _sql_begin!(backend::Union{SQLiteBackend,DuckDBBackend})
    _sql_exec(backend.db, "BEGIN TRANSACTION")
end

function _sql_commit!(backend::Union{SQLiteBackend,DuckDBBackend})
    _sql_exec(backend.db, "COMMIT")
end

function _sql_rollback!(backend::Union{SQLiteBackend,DuckDBBackend})
    try
        _sql_exec(backend.db, "ROLLBACK")
    catch
    end
    nothing
end

function insert_rows!(backend::Union{SQLiteBackend,DuckDBBackend}, table::String, rows; batch::Int=1000)
    isempty(rows) && return nothing
    placeholders = join(fill("?", length(first(rows))), ", ")
    sql = "INSERT INTO " * qident(table) * " VALUES (" * placeholders * ")"
    for first_index in 1:batch:length(rows)
        last_index = min(length(rows), first_index + batch - 1)
        _sql_begin!(backend)
        try
            for row in @view rows[first_index:last_index]
                _sql_exec(backend.db, sql, Tuple(row))
            end
            _sql_commit!(backend)
        catch
            _sql_rollback!(backend)
            rethrow()
        end
    end
    nothing
end

function prepare_dataset!(backend::CompareBackend, schema::Dict, keyspecs::Dict, data::Dict; batch::Int=1000)
    load_ns = Int[]
    for table in sort(collect(keys(schema)))
        create_table!(backend, String(table), schema[table], keyspecs[table])
        started = time_ns()
        insert_rows!(backend, String(table), data[table]; batch=batch)
        push!(load_ns, time_ns() - started)
    end
    sum(load_ns)
end

function core_fixture(rows::Int; seed::Int=20260904)
    rows >= 4 || error("Core fixture needs at least four rows.")
    rng = MersenneTwister(seed)
    values = Vector{Vector{Any}}(undef, rows)
    for id in 1:rows
        category = Int64(mod(id - 1, 17))
        order_key = Int64(rows - id + 1)
        amount = Int64(100 + mod(7919 * id + rand(rng, 0:999), 100_000))
        note = mod(id, 13) == 0 ? nothing : "note-$(mod(id, 97))"
        values[id] = Any[Int64(id), category, order_key, "payload-$(lpad(id, 8, '0'))", amount, note]
    end
    Dict(CORE_TABLE => values)
end

function core_schema()
    Dict(CORE_TABLE => CORE_SCHEMA), Dict(CORE_TABLE => CORE_KEYS)
end

function _sort_rows_by_column(rows, index::Int)
    sort(copy(rows); by=row -> begin
        value = row[index]
        value === nothing || value === missing ? (0, "") : (1, string(value))
    end)
end

function table_rows(backend::AiresBackend, table::String; order_columns=String[])
    rows = [Tuple(row) for row in AiresDB.scan_rows(backend.session, table)]
    if !isempty(order_columns)
        columns = table == CORE_TABLE ? first.(CORE_SCHEMA) : first.(get(AB.H_SCHEMA, table, get(AB.C_SCHEMA, table, Tuple{String,String}[])))
        positions = [findfirst(==(column), columns) for column in order_columns]
        all(!isnothing, positions) || error("Unknown ordering column for $table")
        # Ordering by native values keeps `2` before `10`; canonical strings
        # are for digests, not relational sort semantics.
        sort!(rows; by=row -> tuple((row[position] for position in positions)...))
    end
    rows
end

function table_rows(backend::Union{SQLiteBackend,DuckDBBackend}, table::String; order_columns=String[])
    order = isempty(order_columns) ? "" : " ORDER BY " * join(qident.(order_columns), ", ")
    _sql_rows(backend.db, "SELECT * FROM " * qident(table) * order)
end

function core_lookup(backend::AiresBackend, id::Int)
    row = AiresDB.lookup(backend.session, CORE_TABLE, Int64(id))
    row === nothing ? nothing : Tuple(row)
end

function core_lookup(backend::Union{SQLiteBackend,DuckDBBackend}, id::Int)
    rows = _sql_rows(backend.db, "SELECT * FROM " * qident(CORE_TABLE) * " WHERE \"id\" = ?", (Int64(id),))
    isempty(rows) ? nothing : only(rows)
end

function core_range(backend::AiresBackend, low::Int, high::Int)
    result = AiresDB.execute!(backend.session,
        "Pilih '*' Dari '$CORE_TABLE' Dengan 'id >= $low &: id <= $high' M: 'id Atas' -:")
    Tuple.(result.rows)
end

function core_range(backend::Union{SQLiteBackend,DuckDBBackend}, low::Int, high::Int)
    _sql_rows(backend.db, "SELECT * FROM " * qident(CORE_TABLE) * " WHERE \"id\" BETWEEN ? AND ? ORDER BY \"id\"", (Int64(low), Int64(high)))
end

function core_ordered(backend::AiresBackend)
    rows = [Tuple(row) for row in AiresDB.scan_rows(backend.session, CORE_TABLE)]
    sort(rows; by=row -> (row[3], row[1]))
end

function core_ordered(backend::Union{SQLiteBackend,DuckDBBackend})
    _sql_rows(backend.db, "SELECT * FROM " * qident(CORE_TABLE) * " ORDER BY \"order_key\", \"id\"")
end

function core_aggregate(backend::AiresBackend)
    result = AiresDB.execute!(backend.session,
        "Pilih 'Count(*) & Sum(amount_cents)' Dari '$CORE_TABLE' -:")
    Tuple(only(result.rows))
end

function core_aggregate(backend::Union{SQLiteBackend,DuckDBBackend})
    only(_sql_rows(backend.db, "SELECT COUNT(*), SUM(\"amount_cents\") FROM " * qident(CORE_TABLE)))
end

function _core_new_row(id::Int)
    Any[Int64(id), Int64(7), Int64(-id), "inserted-$id", Int64(90_000 + id), "inserted-note"]
end

function core_mutate!(backend::AiresBackend, row_count::Int)
    AiresDB.with_transaction(backend.session) do
        AiresDB.bulk_insert!(backend.session, CORE_TABLE, [_core_new_row(row_count + 1)])
        AiresDB.update_key!(backend.session, CORE_TABLE, Int64(1), Dict("payload" => "updated-1"))
        AiresDB.delete_key!(backend.session, CORE_TABLE, Int64(2))
    end
    nothing
end

function core_mutate!(backend::Union{SQLiteBackend,DuckDBBackend}, row_count::Int)
    row = _core_new_row(row_count + 1)
    _sql_begin!(backend)
    try
        _sql_exec(backend.db, "INSERT INTO " * qident(CORE_TABLE) * " VALUES (?, ?, ?, ?, ?, ?)", Tuple(row))
        _sql_exec(backend.db, "UPDATE " * qident(CORE_TABLE) * " SET \"payload\" = ? WHERE \"id\" = ?", ("updated-1", Int64(1)))
        _sql_exec(backend.db, "DELETE FROM " * qident(CORE_TABLE) * " WHERE \"id\" = ?", (Int64(2),))
        _sql_commit!(backend)
    catch
        _sql_rollback!(backend)
        rethrow()
    end
    nothing
end

function core_update!(backend::AiresBackend, id::Int, payload::String)
    AiresDB.update_key!(backend.session, CORE_TABLE, Int64(id), Dict("payload" => payload))
    nothing
end

function core_update!(backend::Union{SQLiteBackend,DuckDBBackend}, id::Int, payload::String)
    _sql_exec(backend.db, "UPDATE " * qident(CORE_TABLE) * " SET \"payload\" = ? WHERE \"id\" = ?", (payload, Int64(id)))
    nothing
end

function core_delete_insert_cycle!(backend::AiresBackend, row)
    AiresDB.with_transaction(backend.session) do
        AiresDB.delete_key!(backend.session, CORE_TABLE, row[1])
        AiresDB.bulk_insert!(backend.session, CORE_TABLE, [Any[row...]] )
    end
    nothing
end

function core_delete_insert_cycle!(backend::Union{SQLiteBackend,DuckDBBackend}, row)
    _sql_begin!(backend)
    try
        _sql_exec(backend.db, "DELETE FROM " * qident(CORE_TABLE) * " WHERE \"id\" = ?", (row[1],))
        _sql_exec(backend.db, "INSERT INTO " * qident(CORE_TABLE) * " VALUES (?, ?, ?, ?, ?, ?)", Tuple(row))
        _sql_commit!(backend)
    catch
        _sql_rollback!(backend)
        rethrow()
    end
    nothing
end

function _expect_error(f::Function)
    try
        f()
        false
    catch
        true
    end
end

function _make_backends(output::AbstractString)
    engine_root = joinpath(output, "engines")
    mkpath(engine_root)
    CompareBackend[
        new_aires_backend(joinpath(engine_root, "airesdb")),
        new_sqlite_backend(joinpath(engine_root, "sqlite", "compare.sqlite")),
        new_duckdb_backend(joinpath(engine_root, "duckdb", "compare.duckdb")),
    ]
end

function _backend_result(backend::CompareBackend, load_ns::Integer)
    Dict{String,Any}(
        "engine" => backend_name(backend),
        "load" => latency_summary([load_ns]),
        "database_bytes" => backend isa AiresBackend ? _directory_bytes(backend.directory) : filesize(backend.path),
        "settings" => backend_settings(backend),
    )
end

function setup_core!(output::AbstractString; rows::Int=10_000, batch::Int=1_000, seed::Int=20260904)
    schema, keys = core_schema()
    data = core_fixture(rows; seed=seed)
    backends = _make_backends(output)
    load_times = Dict{String,Int}()
    try
        for backend in backends
            load_times[backend_name(backend)] = prepare_dataset!(backend, schema, keys, data; batch=batch)
        end
        return backends, data, load_times
    catch
        for backend in backends
            try close_backend!(backend) catch; end
        end
        rethrow()
    end
end

function verify_core!(backends::Vector{<:CompareBackend}, row_count::Int)
    length(backends) == 3 || error("Expected AiresDB, SQLite, and DuckDB backends.")
    cases = Dict{String,Any}()
    baseline = only(filter(backend -> backend_name(backend) == "airesdb", backends))
    expected = table_rows(baseline, CORE_TABLE; order_columns=["id"])
    for backend in backends
        name = backend_name(backend)
        actual = table_rows(backend, CORE_TABLE; order_columns=["id"])
        _rows_or_error(expected, actual, "CMP-FIX-001 $name fixture")
        cases["CMP-FIX-001:$name"] = Dict("status" => "PASS", "rows" => length(actual), "digest" => row_digest(actual))
        for id in (1, div(row_count, 2), row_count)
            core_lookup(baseline, id) == core_lookup(backend, id) || error("CMP-FUN-001 $name lookup mismatch for id $id")
        end
        cases["CMP-FUN-001:$name"] = Dict("status" => "PASS", "keys" => [1, div(row_count, 2), row_count])
        _rows_or_error(core_range(baseline, 3, min(row_count, 67)), core_range(backend, 3, min(row_count, 67)), "CMP-FUN-002 $name range")
        _rows_or_error(core_ordered(baseline), core_ordered(backend), "CMP-FUN-002 $name ordering")
        core_aggregate(baseline) == core_aggregate(backend) || error("CMP-FUN-002 $name aggregate mismatch")
        cases["CMP-FUN-002:$name"] = Dict("status" => "PASS", "aggregate" => collect(core_aggregate(backend)))
        duplicate = _expect_error() do
            insert_rows!(backend, CORE_TABLE, [_core_new_row(1)]; batch=1)
        end
        duplicate || error("CMP-DQ-001 $name accepted duplicate primary key")
        cases["CMP-DQ-001:$name"] = Dict("status" => "PASS", "duplicate_primary_key_rejected" => true)
    end
    for backend in backends
        core_mutate!(backend, row_count)
    end
    expected_mutated = table_rows(baseline, CORE_TABLE; order_columns=["id"])
    for backend in backends
        name = backend_name(backend)
        actual = table_rows(backend, CORE_TABLE; order_columns=["id"])
        _rows_or_error(expected_mutated, actual, "CMP-FUN-003 $name mutation")
        reopen_backend!(backend)
        reopened = table_rows(backend, CORE_TABLE; order_columns=["id"])
        _rows_or_error(expected_mutated, reopened, "CMP-REL-001 $name reopen")
        cases["CMP-FUN-003:$name"] = Dict("status" => "PASS", "rows" => length(actual), "digest" => row_digest(actual))
        cases["CMP-REL-001:$name"] = Dict("status" => "PASS", "rows" => length(reopened), "digest" => row_digest(reopened))
    end
    cases, expected_mutated
end

function benchmark_core!(backends::Vector{<:CompareBackend}, expected_rows; samples::Int=100, warmup::Int=10, seed::Int=20260904)
    samples > 0 || error("samples must be positive")
    warmup >= 0 || error("warmup must be nonnegative")
    keys = Int[row[1] for row in expected_rows]
    length(keys) >= 3 || error("Core benchmark needs three rows after verification.")
    rng = MersenneTwister(seed + 1)
    expected_aggregate = (Int64(length(expected_rows)), sum(Int64(row[5]) for row in expected_rows))
    workloads = Dict{String,Any}()
    for backend in backends
        name = backend_name(backend)
        report = Dict{String,Any}()
        reopen_backend!(backend)
        started = time_ns()
        cold = table_rows(backend, CORE_TABLE; order_columns=["id"])
        elapsed = time_ns() - started
        _rows_or_error(expected_rows, cold, "CMP-PERF-001 $name cold scan")
        report["sequential_scan_process_cold"] = merge(latency_summary([elapsed]), Dict("rows" => length(cold), "rows_per_second" => length(cold) / (elapsed / 1e9)))
        for _ in 1:warmup
            _rows_or_error(expected_rows, table_rows(backend, CORE_TABLE; order_columns=["id"]), "warm scan $name")
        end
        scan_times = Int[]
        for _ in 1:samples
            started = time_ns()
            found = table_rows(backend, CORE_TABLE; order_columns=["id"])
            push!(scan_times, time_ns() - started)
            _rows_or_error(expected_rows, found, "CMP-PERF-001 $name warm scan")
        end
        report["sequential_scan_warm"] = merge(latency_summary(scan_times), Dict("rows" => length(expected_rows), "rows_per_second" => length(expected_rows) * samples / (sum(scan_times) / 1e9)))
        lookup_times = Int[]
        for _ in 1:samples
            id = rand(rng, keys)
            started = time_ns()
            row = core_lookup(backend, id)
            push!(lookup_times, time_ns() - started)
            row === nothing && error("CMP-PERF-001 $name lost key $id")
        end
        report["primary_key_lookup"] = latency_summary(lookup_times)
        range_times = Int[]
        for _ in 1:samples
            low = rand(rng, keys)
            high = min(maximum(keys), low + 63)
            expected = [row for row in expected_rows if low <= row[1] <= high]
            started = time_ns()
            actual = core_range(backend, low, high)
            push!(range_times, time_ns() - started)
            _rows_or_error(expected, actual, "CMP-PERF-001 $name range")
        end
        report["primary_key_range"] = latency_summary(range_times)
        aggregate_times = Int[]
        for _ in 1:samples
            started = time_ns()
            actual = core_aggregate(backend)
            push!(aggregate_times, time_ns() - started)
            actual == expected_aggregate || error("CMP-PERF-001 $name aggregate changed")
        end
        report["aggregate"] = latency_summary(aggregate_times)
        update_times = Int[]
        for sample in 1:min(samples, length(keys))
            id = keys[mod1(sample, length(keys))]
            started = time_ns()
            core_update!(backend, id, "benchmark-update-$sample")
            push!(update_times, time_ns() - started)
        end
        report["update_committed"] = latency_summary(update_times)
        cycle_row = first(filter(row -> row[1] != 1, expected_rows))
        delete_times = Int[]
        for _ in 1:min(samples, 50)
            started = time_ns()
            core_delete_insert_cycle!(backend, cycle_row)
            push!(delete_times, time_ns() - started)
        end
        report["delete_insert_cycle_committed"] = latency_summary(delete_times)
        final_rows = table_rows(backend, CORE_TABLE; order_columns=["id"])
        length(final_rows) == length(expected_rows) || error("CMP-PERF-001 $name changed row count")
        report["final_rows"] = length(final_rows)
        report["final_digest"] = row_digest(final_rows)
        report["database_bytes"] = backend isa AiresBackend ? _directory_bytes(backend.directory) : filesize(backend.path)
        report["settings_after_measurement"] = backend_settings(backend)
        workloads[name] = report
    end
    workloads
end

function run_core(output::AbstractString; rows::Int=10_000, batch::Int=1_000, samples::Int=100, warmup::Int=10, seed::Int=20260904, mode::String="core", command::Vector{String}=String[])
    require_baseline_profile!()
    ispath(output) && error("Refusing to overwrite existing output directory: $output")
    mkpath(output)
    started = time_ns()
    backends = CompareBackend[]
    try
        backends, _, load_times = setup_core!(output; rows=rows, batch=batch, seed=seed)
        cases, expected = verify_core!(backends, rows)
        workloads = mode == "verify" ? Dict{String,Any}() : benchmark_core!(backends, expected; samples=samples, warmup=warmup, seed=seed)
        report = Dict{String,Any}(
            "report_format" => "airesdb-compare-v1",
            "status" => "PASS",
            "mode" => mode,
            "notice" => "Local comparative engineering evidence. TPC-derived modes are not official or audited TPC-C/TPC-H results; this report is not ISO certification.",
            "command" => command,
            "configuration" => Dict("rows" => rows, "batch" => batch, "samples" => samples, "warmup" => warmup, "seed" => seed),
            "environment" => environment_metadata(),
            "source_hashes" => source_hashes(),
            "load" => Dict(name => _backend_result(backend, load_times[name]) for backend in backends for name in (backend_name(backend),)),
            "test_cases" => cases,
            "workloads" => workloads,
            "wall_seconds" => (time_ns() - started) / 1e9,
        )
        write_json(joinpath(output, "report.json"), report)
        return report
    catch error
        failure = Dict{String,Any}(
            "report_format" => "airesdb-compare-v1",
            "status" => "FAIL",
            "mode" => mode,
            "command" => command,
            "configuration" => Dict("rows" => rows, "batch" => batch, "samples" => samples, "warmup" => warmup, "seed" => seed),
            "environment" => environment_metadata(),
            "source_hashes" => source_hashes(),
            "error" => sprint(showerror, error, catch_backtrace()),
            "wall_seconds" => (time_ns() - started) / 1e9,
        )
        write_json(joinpath(output, "report.json"), failure)
        rethrow()
    finally
        for backend in backends
            try close_backend!(backend) catch; end
        end
    end
end

function semantic_row_digest(rows; unordered::Bool=false)
    function semantic_value(value)
        if _numeric(value)
            return "Q:" * @sprintf("%.9f", Float64(value))
        end
        _canonical_value(value)
    end
    text = [join((semantic_value(value) for value in row), "\u001f") for row in rows]
    unordered && sort!(text)
    bytes2hex(SHA.sha256(codeunits(join(text, "\u001e"))))
end

function tpch_sql_definitions()
    source = read(joinpath(ROOT, "benchmark", "oracle.py"), String)
    pattern = Regex("(?ms)^\\s*(\\d+):\\s*\\\"\\\"\\\"(.*?)\\\"\\\"\\\"")
    definitions = Dict{Int,String}()
    for match in eachmatch(pattern, source)
        definitions[parse(Int, match.captures[1])] = strip(match.captures[2])
    end
    length(definitions) == 22 || error("Could not extract all 22 TPC-H-derived SQL definitions from benchmark/oracle.py.")
    definitions
end

function tpch_rows(backend::AiresBackend, query_id::Int, sql::AbstractString; scale::Float64)
    answer = AB.tpch_query(backend.session, query_id; scale=scale)
    [Tuple(row) for row in answer.rows]
end

function tpch_rows(backend::Union{SQLiteBackend,DuckDBBackend}, query_id::Int, sql::AbstractString; scale::Float64)
    _sql_rows(backend.db, sql)
end

function _new_dataset_backends(output::AbstractString, schema::Dict, keyspecs::Dict, data::Dict; batch::Int)
    backends = _make_backends(output)
    load_times = Dict{String,Int}()
    try
        for backend in backends
            load_times[backend_name(backend)] = prepare_dataset!(backend, schema, keyspecs, data; batch=batch)
        end
        return backends, load_times
    catch
        for backend in backends
            try close_backend!(backend) catch; end
        end
        rethrow()
    end
end

"""Run all 22 synthetic TPC-H-shaped query families on identical datasets.

SQLite and DuckDB execute the portable SQL copied from the existing independent
oracle. AiresDB executes the corresponding public relational plans. This is a
differential engineering check, never an official TPC-H execution.
"""
function run_tpch(output::AbstractString; scale::Float64=0.0001, seed::Int=20260903,
                  batch::Int=1_000, repetitions::Int=3, warmup::Int=1,
                  command::Vector{String}=String[])
    require_baseline_profile!()
    0 < scale <= 10 || error("scale must be in (0, 10].")
    repetitions > 0 || error("repetitions must be positive.")
    warmup >= 0 || error("warmup must be nonnegative.")
    ispath(output) && error("Refusing to overwrite existing output directory: $output")
    mkpath(output)
    started = time_ns()
    backends = CompareBackend[]
    try
        data = AB.tpch_data(; scale=scale, seed=seed)
        backends, load_times = _new_dataset_backends(output, AB.H_SCHEMA, AB.H_KEYS, data; batch=batch)
        sql = tpch_sql_definitions()
        sqlite = only(filter(backend -> backend_name(backend) == "sqlite", backends))
        test_cases = Dict{String,Any}()
        workloads = Dict{String,Any}(backend_name(backend) => Dict{String,Any}() for backend in backends)
        for query_id in 1:22
            statement = replace(sql[query_id], "{fraction}" => string(0.0001 / scale))
            expected = tpch_rows(sqlite, query_id, statement; scale=scale)
            for backend in backends
                name = backend_name(backend)
                actual = tpch_rows(backend, query_id, statement; scale=scale)
                _rows_or_error(expected, actual, "CMP-TH-001 Q$(lpad(query_id, 2, '0')) $name"; unordered=true)
                test_cases["CMP-TH-001:Q$(lpad(query_id, 2, '0')):$name"] = Dict(
                    "status" => "PASS",
                    "rows" => length(actual),
                    "semantic_digest" => semantic_row_digest(actual; unordered=true),
                )
                for _ in 1:warmup
                    warm = tpch_rows(backend, query_id, statement; scale=scale)
                    _rows_or_error(expected, warm, "TPC-H warmup Q$query_id $name"; unordered=true)
                end
                samples = Int[]
                for _ in 1:repetitions
                    query_started = time_ns()
                    result = tpch_rows(backend, query_id, statement; scale=scale)
                    push!(samples, time_ns() - query_started)
                    _rows_or_error(expected, result, "TPC-H timed Q$query_id $name"; unordered=true)
                end
                workloads[name]["Q$(lpad(query_id, 2, '0'))"] = merge(latency_summary(samples), Dict(
                    "result_rows" => length(expected),
                    "semantic_digest" => semantic_row_digest(expected; unordered=true),
                ))
            end
        end
        report = Dict{String,Any}(
            "report_format" => "airesdb-compare-v1",
            "status" => "PASS",
            "mode" => "tpch-derived",
            "notice" => "Synthetic TPC-H-derived comparative workload. It is not an official/audited TPC-H result and does not compute QphH@Size.",
            "command" => command,
            "configuration" => Dict("scale" => scale, "seed" => seed, "batch" => batch, "repetitions" => repetitions, "warmup" => warmup),
            "environment" => environment_metadata(),
            "source_hashes" => source_hashes(),
            "cardinalities" => Dict(String(table) => length(rows) for (table, rows) in data),
            "load" => Dict(name => _backend_result(backend, load_times[name]) for backend in backends for name in (backend_name(backend),)),
            "test_cases" => test_cases,
            "queries" => workloads,
            "wall_seconds" => (time_ns() - started) / 1e9,
        )
        write_json(joinpath(output, "report.json"), report)
        return report
    catch error
        failure = Dict{String,Any}(
            "report_format" => "airesdb-compare-v1",
            "status" => "FAIL",
            "mode" => "tpch-derived",
            "command" => command,
            "environment" => environment_metadata(),
            "source_hashes" => source_hashes(),
            "error" => sprint(showerror, error, catch_backtrace()),
            "wall_seconds" => (time_ns() - started) / 1e9,
        )
        write_json(joinpath(output, "report.json"), failure)
        rethrow()
    finally
        for backend in backends
            try close_backend!(backend) catch; end
        end
    end
end

struct TPCCAction
    measured::Bool
    kind::Symbol
    warehouse::Int
    district::Int
    customer::Int
    items::Vector{Int}
    quantities::Vector{Int}
    supply::Vector{Int}
    customer_warehouse::Int
    customer_district::Int
    customer_selector::Union{Int,String}
    amount::Int
    history_id::Int
    carrier::Int
    threshold::Int
end

struct TPCCInvalidItem <: Exception
    item::Int
end

"""Materialize the TPC-C-derived driver choices once for every backend."""
function tpcc_actions(config::AB.CConfig; transactions::Int, warmup::Int, seed::Int=config.seed + 1)
    transactions > 0 || error("transactions must be positive.")
    warmup >= 0 || error("warmup must be nonnegative.")
    rng = MersenneTwister(seed)
    mix = vcat(fill(:NewOrder, 45), fill(:Payment, 43), fill(:OrderStatus, 4), fill(:Delivery, 4), fill(:StockLevel, 4))
    warm_types = (:NewOrder, :Payment, :OrderStatus, :Delivery, :StockLevel)
    history_id = config.warehouses * config.districts * config.customers
    actions = TPCCAction[]
    for iteration in 1:(warmup + transactions)
        measured = iteration > warmup
        slot = mod1(iteration - warmup, 100)
        measured && slot == 1 && shuffle!(rng, mix)
        kind = measured ? mix[slot] : warm_types[mod1(iteration, length(warm_types))]
        warehouse = rand(rng, 1:config.warehouses)
        district = rand(rng, 1:config.districts)
        customer = rand(rng, 1:config.customers)
        items = Int[]
        quantities = Int[]
        supply = Int[]
        customer_warehouse = warehouse
        customer_district = district
        selector::Union{Int,String} = customer
        amount = 0
        carrier = 0
        threshold = 0
        if kind === :NewOrder
            line_count = rand(rng, 5:15)
            items = rand(rng, 1:config.items, line_count)
            quantities = rand(rng, 1:10, line_count)
            supply = fill(warehouse, line_count)
            if config.warehouses > 1
                other_warehouses = filter(!=(warehouse), collect(1:config.warehouses))
                for index in eachindex(supply)
                    rand(rng) < 0.01 && (supply[index] = rand(rng, other_warehouses))
                end
            end
            rand(rng) < 0.01 && (items[end] = config.items + 1)
        elseif kind === :Payment
            history_id += 1
            if config.warehouses > 1 && rand(rng) < 0.15
                customer_warehouse = rand(rng, filter(!=(warehouse), collect(1:config.warehouses)))
                customer_district = rand(rng, 1:config.districts)
            end
            selector = rand(rng) < 0.6 ? AB.last_name((customer - 1) % 1000) : customer
            amount = rand(rng, 100:500_000)
        elseif kind === :OrderStatus
            selector = rand(rng) < 0.6 ? AB.last_name((customer - 1) % 1000) : customer
        elseif kind === :Delivery
            carrier = rand(rng, 1:10)
        else
            threshold = rand(rng, 10:20)
        end
        push!(actions, TPCCAction(measured, kind, warehouse, district, customer, items, quantities, supply,
            customer_warehouse, customer_district, selector, amount, history_id, carrier, threshold))
    end
    actions
end

function _tpcc_aires_payload!(backend::AiresBackend, action::TPCCAction, config::AB.CConfig)
    session = backend.session
    if action.kind === :NewOrder
        AB.new_order!(session, action.warehouse, action.district, action.customer, action.items, action.quantities, action.supply)
    elseif action.kind === :Payment
        AB.payment!(session, action.warehouse, action.district, action.customer_warehouse, action.customer_district,
            action.customer_selector, action.amount; history_id=action.history_id)
    elseif action.kind === :OrderStatus
        AB.order_status(session, action.warehouse, action.district, action.customer_selector)
    elseif action.kind === :Delivery
        AB.delivery!(session, action.warehouse, action.carrier; districts=config.districts)
    elseif action.kind === :StockLevel
        AB.stock_level(session, action.warehouse, action.district, action.threshold)
    else
        error("Unknown TPC-C action $(action.kind).")
    end
    nothing
end

function tpcc_execute!(backend::AiresBackend, action::TPCCAction, config::AB.CConfig)
    AiresDB.begin_transaction!(backend.session)
    try
        _tpcc_aires_payload!(backend, action, config)
        AiresDB.commit!(backend.session)
        return :commit
    catch error
        AiresDB.in_transaction(backend.session) && AiresDB.rollback!(backend.session)
        error isa AB.InvalidItem && return :expected_rollback
        rethrow()
    end
end

function _sql_one(backend::Union{SQLiteBackend,DuckDBBackend}, sql::AbstractString, params=())
    rows = _sql_rows(backend.db, sql, params)
    length(rows) == 1 || error("Expected one SQL row, received $(length(rows)) for: $sql")
    only(rows)
end

function _sql_customer(backend::Union{SQLiteBackend,DuckDBBackend}, warehouse::Int, district::Int, selector)
    columns = "\"c_id\", \"c_credit\", \"c_data\", \"c_balance\", \"c_ytd_payment\", \"c_payment_cnt\""
    if selector isa Integer
        return _sql_one(backend, "SELECT $columns FROM \"customer\" WHERE \"c_w_id\" = ? AND \"c_d_id\" = ? AND \"c_id\" = ?",
            (Int64(warehouse), Int64(district), Int64(selector)))
    end
    rows = _sql_rows(backend.db, "SELECT $columns FROM \"customer\" WHERE \"c_w_id\" = ? AND \"c_d_id\" = ? AND \"c_last\" = ? ORDER BY \"c_first\"",
        (Int64(warehouse), Int64(district), String(selector)))
    isempty(rows) && error("No matching customer for TPC-C last name.")
    rows[cld(length(rows), 2)]
end

function _tpcc_sql_new_order!(backend::Union{SQLiteBackend,DuckDBBackend}, action::TPCCAction)
    warehouse = _sql_one(backend, "SELECT \"w_tax\" FROM \"warehouse\" WHERE \"w_id\" = ?", (Int64(action.warehouse),))
    district = _sql_one(backend, "SELECT \"d_next_o_id\", \"d_tax\" FROM \"district\" WHERE \"d_w_id\" = ? AND \"d_id\" = ?", (Int64(action.warehouse), Int64(action.district)))
    customer = _sql_one(backend, "SELECT \"c_discount\" FROM \"customer\" WHERE \"c_w_id\" = ? AND \"c_d_id\" = ? AND \"c_id\" = ?",
        (Int64(action.warehouse), Int64(action.district), Int64(action.customer)))
    order_id = Int(district[1])
    _sql_exec(backend.db, "UPDATE \"district\" SET \"d_next_o_id\" = ? WHERE \"d_w_id\" = ? AND \"d_id\" = ?",
        (Int64(order_id + 1), Int64(action.warehouse), Int64(action.district)))
    _sql_exec(backend.db, "INSERT INTO \"orders\" VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (Int64(action.warehouse), Int64(action.district), Int64(order_id), Int64(action.customer), "2026-09-03T00:00:00", nothing,
         Int64(length(action.items)), Int64(all(==(action.warehouse), action.supply) ? 1 : 0)))
    _sql_exec(backend.db, "INSERT INTO \"new_order\" VALUES (?, ?, ?)", (Int64(action.warehouse), Int64(action.district), Int64(order_id)))
    subtotal = 0
    distribution_column = qident("s_dist_$(lpad(action.district, 2, '0'))")
    for index in eachindex(action.items)
        item_id = action.items[index]
        item_rows = _sql_rows(backend.db, "SELECT \"i_price\" FROM \"item\" WHERE \"i_id\" = ?", (Int64(item_id),))
        isempty(item_rows) && throw(TPCCInvalidItem(item_id))
        stock = _sql_one(backend, "SELECT \"s_quantity\", \"s_ytd\", \"s_order_cnt\", \"s_remote_cnt\", $distribution_column FROM \"stock\" WHERE \"s_w_id\" = ? AND \"s_i_id\" = ?",
            (Int64(action.supply[index]), Int64(item_id)))
        quantity = action.quantities[index]
        stock_quantity = Int(stock[1])
        new_quantity = stock_quantity >= quantity + 10 ? stock_quantity - quantity : stock_quantity - quantity + 91
        _sql_exec(backend.db, "UPDATE \"stock\" SET \"s_quantity\" = ?, \"s_ytd\" = ?, \"s_order_cnt\" = ?, \"s_remote_cnt\" = ? WHERE \"s_w_id\" = ? AND \"s_i_id\" = ?",
            (Int64(new_quantity), Int64(stock[2]) + quantity, Int64(stock[3]) + 1, Int64(stock[4]) + (action.supply[index] != action.warehouse),
             Int64(action.supply[index]), Int64(item_id)))
        amount = quantity * Int(item_rows[1][1])
        subtotal += amount
        _sql_exec(backend.db, "INSERT INTO \"order_line\" VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (Int64(action.warehouse), Int64(action.district), Int64(order_id), Int64(index), Int64(item_id), Int64(action.supply[index]), nothing,
             Int64(quantity), Int64(amount), stock[5]))
    end
    # Retain the same exact integer-cents expression as the AiresDB workload.
    BigInt(subtotal) * (10_000 - Int(customer[1])) * (10_000 + Int(warehouse[1]) + Int(district[2]))
    nothing
end

function _tpcc_sql_payment!(backend::Union{SQLiteBackend,DuckDBBackend}, action::TPCCAction)
    warehouse = _sql_one(backend, "SELECT \"w_ytd\", \"w_name\" FROM \"warehouse\" WHERE \"w_id\" = ?", (Int64(action.warehouse),))
    district = _sql_one(backend, "SELECT \"d_ytd\", \"d_name\" FROM \"district\" WHERE \"d_w_id\" = ? AND \"d_id\" = ?", (Int64(action.warehouse), Int64(action.district)))
    customer = _sql_customer(backend, action.customer_warehouse, action.customer_district, action.customer_selector)
    _sql_exec(backend.db, "UPDATE \"warehouse\" SET \"w_ytd\" = ? WHERE \"w_id\" = ?", (Int64(warehouse[1]) + action.amount, Int64(action.warehouse)))
    _sql_exec(backend.db, "UPDATE \"district\" SET \"d_ytd\" = ? WHERE \"d_w_id\" = ? AND \"d_id\" = ?", (Int64(district[1]) + action.amount, Int64(action.warehouse), Int64(action.district)))
    data = customer[2] == "BC" ? first("$(customer[1]) $(action.customer_district) $(action.customer_warehouse) $(action.district) $(action.warehouse) $(action.amount) | " * String(customer[3]), 500) : customer[3]
    _sql_exec(backend.db, "UPDATE \"customer\" SET \"c_balance\" = ?, \"c_ytd_payment\" = ?, \"c_payment_cnt\" = ?, \"c_data\" = ? WHERE \"c_w_id\" = ? AND \"c_d_id\" = ? AND \"c_id\" = ?",
        (Int64(customer[4]) - action.amount, Int64(customer[5]) + action.amount, Int64(customer[6]) + 1, data,
         Int64(action.customer_warehouse), Int64(action.customer_district), Int64(customer[1])))
    history_data = first(String(warehouse[2]) * "    " * String(district[2]), 24)
    _sql_exec(backend.db, "INSERT INTO \"history\" VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (Int64(action.history_id), Int64(action.customer_warehouse), Int64(action.customer_district), Int64(customer[1]), Int64(action.warehouse), Int64(action.district),
         "2026-09-03T00:00:00", Int64(action.amount), history_data))
    nothing
end

function _tpcc_sql_order_status!(backend::Union{SQLiteBackend,DuckDBBackend}, action::TPCCAction)
    customer = _sql_customer(backend, action.warehouse, action.district, action.customer_selector)
    orders = _sql_rows(backend.db, "SELECT \"o_id\", \"o_ol_cnt\" FROM \"orders\" WHERE \"o_w_id\" = ? AND \"o_d_id\" = ? AND \"o_c_id\" = ? ORDER BY \"o_id\" DESC LIMIT 1",
        (Int64(action.warehouse), Int64(action.district), Int64(customer[1])))
    isempty(orders) && return nothing
    order = only(orders)
    _sql_rows(backend.db, "SELECT * FROM \"order_line\" WHERE \"ol_w_id\" = ? AND \"ol_d_id\" = ? AND \"ol_o_id\" = ? ORDER BY \"ol_number\"",
        (Int64(action.warehouse), Int64(action.district), Int64(order[1])))
    nothing
end

function _tpcc_sql_delivery!(backend::Union{SQLiteBackend,DuckDBBackend}, action::TPCCAction, config::AB.CConfig)
    for district in 1:config.districts
        pending = _sql_rows(backend.db, "SELECT MIN(\"no_o_id\") FROM \"new_order\" WHERE \"no_w_id\" = ? AND \"no_d_id\" = ?",
            (Int64(action.warehouse), Int64(district)))
        order_id = only(pending)[1]
        (order_id === nothing || order_id === missing) && continue
        order_id = Int(order_id)
        _sql_exec(backend.db, "DELETE FROM \"new_order\" WHERE \"no_w_id\" = ? AND \"no_d_id\" = ? AND \"no_o_id\" = ?", (Int64(action.warehouse), Int64(district), Int64(order_id)))
        order = _sql_one(backend, "SELECT \"o_c_id\", \"o_ol_cnt\" FROM \"orders\" WHERE \"o_w_id\" = ? AND \"o_d_id\" = ? AND \"o_id\" = ?", (Int64(action.warehouse), Int64(district), Int64(order_id)))
        lines = _sql_rows(backend.db, "SELECT \"ol_amount\" FROM \"order_line\" WHERE \"ol_w_id\" = ? AND \"ol_d_id\" = ? AND \"ol_o_id\" = ?", (Int64(action.warehouse), Int64(district), Int64(order_id)))
        amount = sum(Int(line[1]) for line in lines)
        _sql_exec(backend.db, "UPDATE \"orders\" SET \"o_carrier_id\" = ? WHERE \"o_w_id\" = ? AND \"o_d_id\" = ? AND \"o_id\" = ?", (Int64(action.carrier), Int64(action.warehouse), Int64(district), Int64(order_id)))
        _sql_exec(backend.db, "UPDATE \"order_line\" SET \"ol_delivery_d\" = ? WHERE \"ol_w_id\" = ? AND \"ol_d_id\" = ? AND \"ol_o_id\" = ?", ("2026-09-03T00:00:00", Int64(action.warehouse), Int64(district), Int64(order_id)))
        customer = _sql_one(backend, "SELECT \"c_balance\", \"c_delivery_cnt\" FROM \"customer\" WHERE \"c_w_id\" = ? AND \"c_d_id\" = ? AND \"c_id\" = ?", (Int64(action.warehouse), Int64(district), Int64(order[1])))
        _sql_exec(backend.db, "UPDATE \"customer\" SET \"c_balance\" = ?, \"c_delivery_cnt\" = ? WHERE \"c_w_id\" = ? AND \"c_d_id\" = ? AND \"c_id\" = ?", (Int64(customer[1]) + amount, Int64(customer[2]) + 1, Int64(action.warehouse), Int64(district), Int64(order[1])))
    end
    nothing
end

function _tpcc_sql_stock_level!(backend::Union{SQLiteBackend,DuckDBBackend}, action::TPCCAction)
    next_order = _sql_one(backend, "SELECT \"d_next_o_id\" FROM \"district\" WHERE \"d_w_id\" = ? AND \"d_id\" = ?", (Int64(action.warehouse), Int64(action.district)))
    lower = max(1, Int(next_order[1]) - 20)
    upper = Int(next_order[1]) - 1
    _sql_one(backend, "SELECT COUNT(*) FROM \"stock\" WHERE \"s_w_id\" = ? AND \"s_quantity\" < ? AND \"s_i_id\" IN (SELECT DISTINCT \"ol_i_id\" FROM \"order_line\" WHERE \"ol_w_id\" = ? AND \"ol_d_id\" = ? AND \"ol_o_id\" BETWEEN ? AND ?)",
        (Int64(action.warehouse), Int64(action.threshold), Int64(action.warehouse), Int64(action.district), Int64(lower), Int64(upper)))
    nothing
end

function _tpcc_sql_payload!(backend::Union{SQLiteBackend,DuckDBBackend}, action::TPCCAction, config::AB.CConfig)
    if action.kind === :NewOrder
        _tpcc_sql_new_order!(backend, action)
    elseif action.kind === :Payment
        _tpcc_sql_payment!(backend, action)
    elseif action.kind === :OrderStatus
        _tpcc_sql_order_status!(backend, action)
    elseif action.kind === :Delivery
        _tpcc_sql_delivery!(backend, action, config)
    elseif action.kind === :StockLevel
        _tpcc_sql_stock_level!(backend, action)
    else
        error("Unknown TPC-C action $(action.kind).")
    end
    nothing
end

function tpcc_execute!(backend::Union{SQLiteBackend,DuckDBBackend}, action::TPCCAction, config::AB.CConfig)
    _sql_begin!(backend)
    try
        _tpcc_sql_payload!(backend, action, config)
        _sql_commit!(backend)
        return :commit
    catch error
        _sql_rollback!(backend)
        error isa TPCCInvalidItem && return :expected_rollback
        rethrow()
    end
end

function tpcc_consistency(backend::AiresBackend, config::AB.CConfig)
    Dict(String(name) => value for (name, value) in pairs(AB.tpcc_consistency(backend.session; config=config)))
end

function _sql_zero(backend::Union{SQLiteBackend,DuckDBBackend}, query::AbstractString)
    value = _sql_one(backend, query)[1]
    Int(value) == 0
end

function tpcc_consistency(backend::Union{SQLiteBackend,DuckDBBackend}, config::AB.CConfig)
    Dict(
        "warehouse_ytd_equals_district_sum" => _sql_zero(backend, "SELECT COUNT(*) FROM \"warehouse\" w WHERE \"w_ytd\" <> (SELECT COALESCE(SUM(\"d_ytd\"), 0) FROM \"district\" d WHERE d.\"d_w_id\" = w.\"w_id\")"),
        "district_next_order" => _sql_zero(backend, "SELECT COUNT(*) FROM \"district\" d WHERE \"d_next_o_id\" <> (SELECT MAX(\"o_id\") + 1 FROM \"orders\" o WHERE o.\"o_w_id\" = d.\"d_w_id\" AND o.\"o_d_id\" = d.\"d_id\")"),
        "order_line_counts" => _sql_zero(backend, "SELECT COUNT(*) FROM \"orders\" o WHERE \"o_ol_cnt\" <> (SELECT COUNT(*) FROM \"order_line\" l WHERE l.\"ol_w_id\" = o.\"o_w_id\" AND l.\"ol_d_id\" = o.\"o_d_id\" AND l.\"ol_o_id\" = o.\"o_id\")"),
        "new_orders_reference_undelivered_orders" => _sql_zero(backend, "SELECT COUNT(*) FROM \"new_order\" n LEFT JOIN \"orders\" o ON o.\"o_w_id\" = n.\"no_w_id\" AND o.\"o_d_id\" = n.\"no_d_id\" AND o.\"o_id\" = n.\"no_o_id\" WHERE o.\"o_id\" IS NULL OR o.\"o_carrier_id\" IS NOT NULL"),
        "customer_balance_matches_history_and_deliveries" => _sql_zero(backend, "WITH delivered AS (SELECT l.\"ol_w_id\" AS w, l.\"ol_d_id\" AS d, o.\"o_c_id\" AS c, SUM(l.\"ol_amount\") AS amount FROM \"order_line\" l JOIN \"orders\" o ON o.\"o_w_id\" = l.\"ol_w_id\" AND o.\"o_d_id\" = l.\"ol_d_id\" AND o.\"o_id\" = l.\"ol_o_id\" WHERE l.\"ol_delivery_d\" IS NOT NULL GROUP BY l.\"ol_w_id\", l.\"ol_d_id\", o.\"o_c_id\"), payments AS (SELECT \"h_c_w_id\" AS w, \"h_c_d_id\" AS d, \"h_c_id\" AS c, SUM(\"h_amount\") AS amount FROM \"history\" GROUP BY \"h_c_w_id\", \"h_c_d_id\", \"h_c_id\") SELECT COUNT(*) FROM \"customer\" c LEFT JOIN delivered d ON d.w = c.\"c_w_id\" AND d.d = c.\"c_d_id\" AND d.c = c.\"c_id\" LEFT JOIN payments p ON p.w = c.\"c_w_id\" AND p.d = c.\"c_d_id\" AND p.c = c.\"c_id\" WHERE c.\"c_balance\" <> COALESCE(d.amount, 0) - COALESCE(p.amount, 0)"),
        "customer_ytd_matches_history" => _sql_zero(backend, "SELECT COUNT(*) FROM \"customer\" c WHERE \"c_ytd_payment\" <> (SELECT COALESCE(SUM(\"h_amount\"), 0) FROM \"history\" h WHERE h.\"h_c_w_id\" = c.\"c_w_id\" AND h.\"h_c_d_id\" = c.\"c_d_id\" AND h.\"h_c_id\" = c.\"c_id\")"),
    )
end

function run_tpcc(output::AbstractString; warehouses::Int=1, districts::Int=2, customers::Int=30, items::Int=100,
                  transactions::Int=100, warmup::Int=10, batch::Int=1_000, seed::Int=20260903,
                  command::Vector{String}=String[])
    require_baseline_profile!()
    ispath(output) && error("Refusing to overwrite existing output directory: $output")
    mkpath(output)
    started = time_ns()
    config = AB.CConfig(warehouses=warehouses, districts=districts, customers=customers, items=items, seed=seed)
    actions = tpcc_actions(config; transactions=transactions, warmup=warmup)
    backends = CompareBackend[]
    try
        data = AB.tpcc_data(; config=config)
        backends, load_times = _new_dataset_backends(output, AB.C_SCHEMA, AB.C_KEYS, data; batch=batch)
        test_cases = Dict{String,Any}()
        performance = Dict{String,Any}()
        for backend in backends
            name = backend_name(backend)
            latencies = Dict(kind => Int[] for kind in (:NewOrder, :Payment, :OrderStatus, :Delivery, :StockLevel))
            counters = Dict("commits" => 0, "expected_rollbacks" => 0, "errors" => 0)
            measured_started = Int(0)
            for action in actions
                action.measured && measured_started == 0 && (measured_started = time_ns())
                action_started = time_ns()
                outcome = tpcc_execute!(backend, action, config)
                if action.measured
                    push!(latencies[action.kind], time_ns() - action_started)
                    outcome === :commit && (counters["commits"] += 1)
                    outcome === :expected_rollback && (counters["expected_rollbacks"] += 1)
                end
            end
            wall_ns = time_ns() - measured_started
            checks = tpcc_consistency(backend, config)
            all(values(checks)) || error("CMP-TC-001 $name TPC-C-derived invariants failed: $checks")
            performance[name] = Dict{String,Any}(
                "transactions" => transactions,
                "warmup_transactions" => warmup,
                "wall_seconds" => wall_ns / 1e9,
                "transactions_per_second" => transactions / (wall_ns / 1e9),
                "counters" => counters,
                "consistency" => checks,
                "latency" => Dict(String(kind) => latency_summary(latencies[kind]) for kind in keys(latencies)),
                "settings_after_measurement" => backend_settings(backend),
            )
        end
        baseline = only(filter(backend -> backend_name(backend) == "airesdb", backends))
        table_digests = Dict{String,Any}()
        for table in sort(collect(keys(AB.C_SCHEMA)))
            expected = table_rows(baseline, table)
            table_digests[table] = Dict{String,Any}("rows" => length(expected), "digest" => row_digest(expected; unordered=true))
            for backend in backends
                actual = table_rows(backend, table)
                _rows_or_error(expected, actual, "CMP-TC-001 $(backend_name(backend)) table $table"; unordered=true)
            end
        end
        for backend in backends
            name = backend_name(backend)
            test_cases["CMP-TC-001:$name"] = Dict("status" => "PASS", "consistency" => performance[name]["consistency"], "table_digests" => table_digests)
        end
        report = Dict{String,Any}(
            "report_format" => "airesdb-compare-v1",
            "status" => "PASS",
            "mode" => "tpcc-derived",
            "notice" => "TPC-C-derived comparative workload. It is not an official/audited TPC-C result and does not compute tpmC.",
            "command" => command,
            "configuration" => Dict("warehouses" => warehouses, "districts" => districts, "customers" => customers, "items" => items, "transactions" => transactions, "warmup" => warmup, "batch" => batch, "seed" => seed, "concurrent_terminals" => 1),
            "environment" => environment_metadata(),
            "source_hashes" => source_hashes(),
            "cardinalities" => Dict(String(table) => length(rows) for (table, rows) in data),
            "load" => Dict(name => _backend_result(backend, load_times[name]) for backend in backends for name in (backend_name(backend),)),
            "test_cases" => test_cases,
            "transactions" => performance,
            "wall_seconds" => (time_ns() - started) / 1e9,
        )
        write_json(joinpath(output, "report.json"), report)
        return report
    catch error
        failure = Dict{String,Any}(
            "report_format" => "airesdb-compare-v1",
            "status" => "FAIL",
            "mode" => "tpcc-derived",
            "command" => command,
            "environment" => environment_metadata(),
            "source_hashes" => source_hashes(),
            "error" => sprint(showerror, error, catch_backtrace()),
            "wall_seconds" => (time_ns() - started) / 1e9,
        )
        write_json(joinpath(output, "report.json"), failure)
        rethrow()
    finally
        for backend in backends
            try close_backend!(backend) catch; end
        end
    end
end

end # module
