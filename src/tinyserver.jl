# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

const AIRESDB_SERVER_VERSION = string(pkgversion(@__MODULE__))
const DEFAULT_SERVER_HOST = "127.0.0.1"
const DEFAULT_SERVER_PORT = 1972
const DEFAULT_MAX_REQUEST_BODY = 8 * 1024 * 1024
const DEFAULT_MAX_SESSIONS = 64
const DEFAULT_IDLE_TIMEOUT = 600.0
const ROOT_CREDENTIAL_FILE = ".airesdb-auth.toml"
const PASSWORD_ITERATIONS = 210_000
const PASSWORD_SALT_BYTES = 16
const PASSWORD_HASH_BYTES = 32

Base.@kwdef struct TinyServerConfig
    host::String = DEFAULT_SERVER_HOST
    port::Int = DEFAULT_SERVER_PORT
    data_root::String = abspath("data")
    max_request_body::Int = DEFAULT_MAX_REQUEST_BODY
    max_sessions::Int = DEFAULT_MAX_SESSIONS
    idle_timeout::Float64 = DEFAULT_IDLE_TIMEOUT
    verbose::Bool = false
end

mutable struct ServerSession
    token::String
    connection_id::UInt64
    session::Session
    last_activity::Float64
    active_requests::Int
    mutex::ReentrantLock
end

mutable struct TinyServer
    config::TinyServerConfig
    engine::Engine
    sessions::Dict{String,ServerSession}
    mutex::ReentrantLock
    next_connection_id::UInt64
    http_server::Any
    reaper::Union{Nothing,Timer}
    stopped::Bool
end

server_url(server::TinyServer) = "http://$(server.config.host):$(server.config.port)"
_credential_path(config::TinyServerConfig) = joinpath(config.data_root, ROOT_CREDENTIAL_FILE)

function _pbkdf2_sha256(password::AbstractString, salt::Vector{UInt8}, iterations::Int=PASSWORD_ITERATIONS)
    iterations > 0 || throw(ArgumentError("iterations must be positive"))
    output = Vector{UInt8}(undef, PASSWORD_HASH_BYTES)
    digest = ccall((:EVP_sha256, OpenSSL_jll.libcrypto), Ptr{Cvoid}, ())
    digest == C_NULL && error("OpenSSL SHA-256 digest unavailable")
    bytes = Vector{UInt8}(codeunits(String(password)))
    result = GC.@preserve bytes salt output ccall(
        (:PKCS5_PBKDF2_HMAC, OpenSSL_jll.libcrypto), Cint,
        (Ptr{UInt8}, Cint, Ptr{UInt8}, Cint, Cint, Ptr{Cvoid}, Cint, Ptr{UInt8}),
        pointer(bytes), length(bytes), pointer(salt), length(salt), iterations,
        digest, length(output), pointer(output))
    fill!(bytes, 0x00)
    result == 1 || error("OpenSSL PBKDF2 failed")
    output
end

function _constant_time_equal(left::Vector{UInt8}, right::Vector{UInt8})
    length(left) == length(right) || return false
    difference = UInt8(0)
    @inbounds for index in eachindex(left, right)
        difference |= left[index] ⊻ right[index]
    end
    iszero(difference)
end

function initialize_root_credentials!(config::TinyServerConfig, password::AbstractString)
    ncodeunits(password) >= 8 || throw(ArgumentError("Root password must contain at least 8 bytes."))
    ncodeunits(password) <= 1024 || throw(ArgumentError("Root password is too long."))
    mkpath(config.data_root)
    path = _credential_path(config)
    isfile(path) && throw(ArgumentError("Root credentials already exist."))
    salt = rand(RandomDevice(), UInt8, PASSWORD_SALT_BYTES)
    digest = _pbkdf2_sha256(password, salt)
    temporary = path * ".tmp-" * string(uuid4())
    open(temporary, "w") do io
        TOML.print(io, Dict(
            "format" => 1,
            "user" => "root",
            "algorithm" => "pbkdf2-hmac-sha256",
            "iterations" => PASSWORD_ITERATIONS,
            "salt" => base64encode(salt),
            "hash" => base64encode(digest),
        ))
        flush(io)
    end
    Sys.iswindows() || chmod(temporary, 0o600)
    mv(temporary, path; force=true)
    path
end

function _verify_root_password(config::TinyServerConfig, user::AbstractString, password::AbstractString)
    user == "root" || return false
    ncodeunits(password) <= 1024 || return false
    path = _credential_path(config)
    isfile(path) || return false
    record = TOML.parsefile(path)
    get(record, "format", 0) == 1 || return false
    get(record, "algorithm", "") == "pbkdf2-hmac-sha256" || return false
    iterations = Int(get(record, "iterations", 0))
    10_000 <= iterations <= 1_000_000 || return false
    salt = try base64decode(String(record["salt"])) catch; return false end
    expected = try base64decode(String(record["hash"])) catch; return false end
    length(salt) == PASSWORD_SALT_BYTES && length(expected) == PASSWORD_HASH_BYTES || return false
    actual = _pbkdf2_sha256(password, salt, iterations)
    valid = _constant_time_equal(actual, expected)
    fill!(actual, 0x00)
    valid
end

function _string_field(body::AbstractDict, key::String)
    value = get(body, key, nothing)
    value isa AbstractString || throw(AiresError("Request Error", "JSON field '$key' must be a string."))
    String(value)
end

_json_response(status::Int, body) = HTTP.Response(status,
    ["Content-Type" => "application/json; charset=utf-8", "Cache-Control" => "no-store"],
    JSON3.write(body))

function _server_error(status::Int, code::String, message::String; category::String="Server Error")
    _json_response(status, (; ok=false, error=(; code, category, message)))
end

function _request_json(request::HTTP.Request, config::TinyServerConfig)
    length(request.body) <= config.max_request_body || throw(AiresError("Request Too Large", "Request body exceeds the configured limit."))
    isempty(request.body) && throw(AiresError("Request Error", "JSON request body is required."))
    try
        JSON3.read(String(request.body), Dict{String,Any})
    catch
        throw(AiresError("Request Error", "Request body is not valid JSON."))
    end
end

function _close_server_session!(entry::ServerSession)
    lock(entry.mutex) do
        try
            close(entry.session)
        catch
        end
    end
    nothing
end

function _reap_expired!(server::TinyServer, now::Float64=time())
    expired = ServerSession[]
    lock(server.mutex) do
        for (token, entry) in collect(server.sessions)
            if entry.active_requests == 0 && now - entry.last_activity >= server.config.idle_timeout
                delete!(server.sessions, token)
                push!(expired, entry)
            end
        end
    end
    foreach(_close_server_session!, expired)
    nothing
end

function _take_session(server::TinyServer, token::AbstractString)
    _reap_expired!(server)
    lock(server.mutex) do
        entry = get(server.sessions, String(token), nothing)
        entry === nothing && return nothing
        entry.last_activity = time()
        entry.active_requests += 1
        entry
    end
end

function _release_session!(server::TinyServer, entry::ServerSession)
    lock(server.mutex) do
        entry.active_requests = max(0, entry.active_requests - 1)
        entry.last_activity = time()
    end
    nothing
end

function _cell_type(value)
    value === nothing && return nothing
    value isa Bool && return "B"
    value isa Int64 && return "I"
    value isa Float64 && return "F"
    value isa Decimal && return "D"
    value isa Money && return "U"
    value isa Date && return "T"
    value isa Time && return "W"
    value isa DateTime && return "Tw"
    value isa Exact && return "D"
    "C"
end

function _wire_cell(value)
    value === nothing && return nothing
    value isa Decimal && return (; type="decimal", value=string(value))
    value isa Money && return (; type="money", value=string(value))
    if value isa Exact
        rendered = try string(decimal_from_exact(value)) catch; string(numerator(value), "/", denominator(value)) end
        return (; type="exact", value=rendered)
    end
    value isa Union{Date,Time,DateTime} && return string(value)
    value
end

function _result_payload(result::QueryResult, elapsed_ms::Float64, session::Session)
    if result.columns == ["Status", "Baris"] && length(result.rows) == 1
        payload = _command_payload(String(result.rows[1][1]), elapsed_ms, session)
        return merge(payload, (; affected_rows=Int(result.rows[1][2])))
    end
    types = String[]
    for index in eachindex(result.columns)
        kind = nothing
        for row in result.rows
            kind = _cell_type(row[index])
            kind === nothing || break
        end
        push!(types, something(kind, "NULL"))
    end
    rows = [[_wire_cell(value) for value in row] for row in result.rows]
    database = session.database === nothing ? nothing : session.database.name
    (; ok=true, columns=result.columns, types, rows, row_count=length(rows), elapsed_ms, database,
       transaction=in_transaction(session))
end

function _command_payload(result::AbstractString, elapsed_ms::Float64, session::Session)
    database = session.database === nothing ? nothing : session.database.name
    (; ok=true, message=String(result), columns=String[], types=String[], rows=Any[], row_count=0,
       elapsed_ms, database, transaction=in_transaction(session))
end

function _server_command(session::Session, line::AbstractString)
    parts = split(strip(line); limit=2)
    command = lowercase(parts[1])
    command in (".help", ".databases", ".tables", ".current", ".mvcc", ".checkpoint", ".vacuum") &&
        length(parts) != 1 && fail("$command tidak menerima argumen.")
    if command == ".help"
        return "Gunakan .databases, .tables, .schema Nama, .current, .mvcc, .checkpoint, .vacuum, .cancel, atau .exit."
    elseif command == ".databases"
        names = sort(filter(name -> endswith(name, ".aires") && !startswith(name, ".") &&
            isfile(joinpath(session.root, name)), readdir(session.root)))
        return format_table(QueryResult(["Database"], [Cell[name] for name in names]))
    elseif command == ".tables"
        if !in_transaction(session)
            return with_snapshot(() -> _server_command(session, line), session)
        end
        session.transaction.catalog_read = true
        database = active_database(session)
        rows = [Cell[name, "Tabel"] for name in sort!(collect(keys(database.tables)))]
        append!(rows, [Cell[name, "View"] for name in sort!(collect(keys(database.views)))])
        return format_table(QueryResult(["Nama", "Jenis"], rows))
    elseif command == ".schema"
        length(parts) == 2 || fail("Gunakan .schema NamaTabel")
        if !in_transaction(session)
            return with_snapshot(() -> _server_command(session, line), session)
        end
        name = String(parts[2]); record_read!(session, name)
        table = get_table(active_database(session), name)
        rows = Row[]
        for column in table.columns
            flags = String[]
            column.primary && push!(flags, "Primary Key")
            column.unique && push!(flags, "Unique")
            push!(flags, column.nullable ? "Null" : "Not Null")
            column.auto && push!(flags, "Auto_")
            push!(rows, Cell[column.name, column.kind == :C ? "C($(column.max_length))" : string(column.kind), join(flags, ", ")])
        end
        return format_table(QueryResult(["Kolom", "Tipe", "Constraint"], rows))
    elseif command == ".current"
        database = session.database === nothing ? "Belum dipilih" : session.database.name
        return format_table(QueryResult(["Database", "Transaksi"], [Cell[database, in_transaction(session) ? "Aktif" : "Tidak aktif"]]))
    elseif command == ".mvcc"
        stats = mvcc_stats(session)
        return format_table(QueryResult(["CSN", "LSN WAL", "Snapshot", "Versi Row", "Byte WAL"],
            [Cell[string(stats.commit_csn), string(stats.wal_lsn), Int64(stats.active_snapshots),
                  Int64(stats.row_versions), Int64(stats.wal_bytes)]]))
    elseif command == ".checkpoint"
        return format_table(checkpoint!(session))
    elseif command == ".vacuum"
        return "Vacuum selesai; $(vacuum!(session)) versi lama dibersihkan."
    elseif command in (".exit", ".cancel")
        fail("Perintah '$command' ditangani oleh client monitor.")
    end
    fail("Perintah internal '$command' tidak dikenal. Gunakan .help.")
end

function _execute_server_query(entry::ServerSession, query::String)
    lock(entry.mutex) do
        stripped = strip(query)
        isempty(stripped) && throw(AiresError("Request Error", "Query must not be empty."))
        started = time_ns()
        result = startswith(stripped, ".") ? _server_command(entry.session, stripped) : execute!(entry.session, query)
        elapsed = (time_ns() - started) / 1_000_000
        result isa QueryResult ? _result_payload(result, elapsed, entry.session) : _command_payload(String(result), elapsed, entry.session)
    end
end

function _error_response(error)
    error isa AiresError || return _server_error(500, "A5000", "Internal server error.")
    category = error.category
    code, status = if category == "Transaction Conflict"
        "A3001", 409
    elseif category == "Commit Outcome Unknown"
        "A3002", 503
    elseif category == "Request Too Large"
        "A1004", 413
    elseif category == "Request Error"
        "A1003", 400
    elseif category == "Storage Error" && occursin("tidak ditemukan", error.message)
        "A2001", 404
    else
        "A2000", 400
    end
    message = if code == "A2001"
        matched = match(r"File '(.+)\.aires' tidak ditemukan", error.message)
        matched === nothing ? "Database does not exist." : "Database '$(matched.captures[1])' does not exist."
    else
        error.message
    end
    _server_error(status, code, message; category)
end

function tinyserver_handler(server::TinyServer, request::HTTP.Request)
    try
        method = uppercase(String(request.method))
        path = split(String(request.target), '?'; limit=2)[1]
        if method == "GET" && path == "/health"
            return _json_response(200, (; ok=true, server="AiresDB", version=AIRESDB_SERVER_VERSION))
        elseif method == "POST" && path == "/session"
            body = _request_json(request, server.config)
            user = _string_field(body, "user"); password = _string_field(body, "password")
            _verify_root_password(server.config, user, password) || return _server_error(401, "A1001", "Access denied for user '$user'."; category="Authentication Error")
            token = bytes2hex(rand(RandomDevice(), UInt8, 32))
            entry = lock(server.mutex) do
                _reap_expired!(server)
                length(server.sessions) < server.config.max_sessions || return nothing
                connection_id = server.next_connection_id
                server.next_connection_id += 1
                created = ServerSession(token, connection_id, Session(server.engine), time(), 0, ReentrantLock())
                server.sessions[token] = created
                created
            end
            entry === nothing && return _server_error(503, "A1005", "Session limit reached."; category="Resource Limit")
            return _json_response(201, (; ok=true, session=token, connection_id=entry.connection_id))
        elseif method == "POST" && path == "/query"
            body = _request_json(request, server.config)
            token = _string_field(body, "session"); query = _string_field(body, "query")
            entry = _take_session(server, token)
            entry === nothing && return _server_error(401, "A1002", "Invalid or expired session."; category="Session Error")
            try
                return _json_response(200, _execute_server_query(entry, query))
            finally
                _release_session!(server, entry)
            end
        elseif method == "DELETE" && startswith(path, "/session/")
            token = path[length("/session/")+1:end]
            isempty(token) && return _server_error(404, "A1002", "Invalid session."; category="Session Error")
            entry = lock(server.mutex) do
                pop!(server.sessions, token, nothing)
            end
            entry === nothing && return _server_error(404, "A1002", "Invalid or expired session."; category="Session Error")
            _close_server_session!(entry)
            return _json_response(200, (; ok=true))
        end
        _server_error(404, "A1003", "Route not found."; category="Request Error")
    catch error
        server.config.verbose && Base.showerror(stderr, error, catch_backtrace())
        _error_response(error)
    end
end

function start_tinyserver(config::TinyServerConfig=TinyServerConfig(); password=nothing)
    1 <= config.port <= 65535 || throw(ArgumentError("port must be between 1 and 65535"))
    config.max_request_body > 0 || throw(ArgumentError("max_request_body must be positive"))
    config.max_sessions > 0 || throw(ArgumentError("max_sessions must be positive"))
    config.idle_timeout > 0 || throw(ArgumentError("idle_timeout must be positive"))
    mkpath(config.data_root)
    credential = _credential_path(config)
    if !isfile(credential)
        password === nothing && throw(AiresError("Authentication Setup", "Root credentials do not exist. Run interactive server setup."))
        initialize_root_credentials!(config, String(password))
    end
    server = TinyServer(config, Engine(config.data_root), Dict{String,ServerSession}(), ReentrantLock(), UInt64(1), nothing, nothing, false)
    interval = min(30.0, max(0.1, config.idle_timeout / 2))
    server.reaper = Timer(interval; interval) do _
        try
            _reap_expired!(server)
        catch error
            config.verbose && (Base.showerror(stderr, error, catch_backtrace()); println(stderr))
        end
    end
    handler = request -> tinyserver_handler(server, request)
    try
        server.http_server = HTTP.serve!(handler, config.host, config.port;
            verbose=config.verbose, max_body_bytes=config.max_request_body)
    catch
        close(server.reaper)
        rethrow()
    end
    server
end

function stop_tinyserver!(server::TinyServer)
    server.stopped && return nothing
    server.stopped = true
    server.reaper === nothing || close(server.reaper)
    server.http_server === nothing || close(server.http_server)
    entries = lock(server.mutex) do
        current = collect(values(server.sessions))
        empty!(server.sessions)
        current
    end
    foreach(_close_server_session!, entries)
    nothing
end
