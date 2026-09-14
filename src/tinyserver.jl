# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

const AIRESDB_SERVER_VERSION = string(pkgversion(@__MODULE__))
const DEFAULT_SERVER_HOST = "127.0.0.1"
const DEFAULT_SERVER_PORT = 1972
const DEFAULT_MAX_HEADER_BYTES = 32 * 1024
const DEFAULT_MAX_REQUEST_BODY = 8 * 1024 * 1024
const DEFAULT_MAX_CONCURRENT_REQUESTS = 128
const DEFAULT_MAX_SESSIONS = 64
const DEFAULT_IDLE_TIMEOUT = 600.0
const DEFAULT_MAX_SESSION_LIFETIME = 3600.0
const DEFAULT_MAX_RESULT_ROWS = 100_000
const DEFAULT_MAX_QUERY_SECONDS = 30.0
const DEFAULT_MAX_RESPONSE_BODY = 64 * 1024 * 1024
const DEFAULT_MAX_QUERY_MEMORY_BYTES = 64 * 1024 * 1024
const DEFAULT_MAX_QUERY_SPILL_BYTES = 1024 * 1024 * 1024
const ROOT_CREDENTIAL_FILE = ".airesdb-auth.toml"
const DEFAULT_AUDIT_LOG_FILE = ".airesdb-audit.jsonl"
const DEFAULT_AUDIT_MAX_BYTES = 64 * 1024 * 1024
const PASSWORD_ITERATIONS = 210_000
const PASSWORD_SALT_BYTES = 16
const PASSWORD_HASH_BYTES = 32
const DEFAULT_MAX_FAILED_LOGINS = 5
const DEFAULT_LOGIN_LOCKOUT_SECONDS = 60.0
const DEFAULT_MAX_TRACKED_LOGIN_USERS = 1024
const DEFAULT_TLS_HANDSHAKE_TIMEOUT = 10.0
const DEFAULT_HTTP_READ_HEADER_TIMEOUT = 10.0
const DEFAULT_HTTP_IO_TIMEOUT = 30.0
const DEFAULT_TLS_MIN_VERSION = HTTP.TLS.TLS1_3_VERSION
const CREDENTIALS_MUTEX = ReentrantLock()
const DUMMY_PASSWORD_SALT = fill(UInt8(0xa5), PASSWORD_SALT_BYTES)
const DUMMY_PASSWORD = "AiresDB invalid credential"

Base.@kwdef struct TinyServerConfig
    host::String = DEFAULT_SERVER_HOST
    port::Int = DEFAULT_SERVER_PORT
    data_root::String = abspath("data")
    max_header_bytes::Int = DEFAULT_MAX_HEADER_BYTES
    max_request_body::Int = DEFAULT_MAX_REQUEST_BODY
    max_concurrent_requests::Int = DEFAULT_MAX_CONCURRENT_REQUESTS
    max_sessions::Int = DEFAULT_MAX_SESSIONS
    idle_timeout::Float64 = DEFAULT_IDLE_TIMEOUT
    max_session_lifetime::Float64 = DEFAULT_MAX_SESSION_LIFETIME
    max_result_rows::Int = DEFAULT_MAX_RESULT_ROWS
    max_query_seconds::Float64 = DEFAULT_MAX_QUERY_SECONDS
    max_response_body::Int = DEFAULT_MAX_RESPONSE_BODY
    max_query_memory_bytes::Int = DEFAULT_MAX_QUERY_MEMORY_BYTES
    max_query_spill_bytes::Int = DEFAULT_MAX_QUERY_SPILL_BYTES
    # Retained for source compatibility; it never bypasses non-loopback TLS.
    allow_insecure_network::Bool = false
    tls_cert_file::Union{Nothing,String} = nothing
    tls_key_file::Union{Nothing,String} = nothing
    tls_handshake_timeout::Float64 = DEFAULT_TLS_HANDSHAKE_TIMEOUT
    tls_min_version::UInt16 = DEFAULT_TLS_MIN_VERSION
    audit_log_file::String = DEFAULT_AUDIT_LOG_FILE
    audit_max_bytes::Int = DEFAULT_AUDIT_MAX_BYTES
    max_failed_logins::Int = DEFAULT_MAX_FAILED_LOGINS
    login_lockout_seconds::Float64 = DEFAULT_LOGIN_LOCKOUT_SECONDS
    max_tracked_login_users::Int = DEFAULT_MAX_TRACKED_LOGIN_USERS
    verbose::Bool = false
end

mutable struct ServerSession
    user::String
    role::Symbol
    token::String
    connection_id::UInt64
    session::Session
    created_at::Float64
    last_activity::Float64
    active_requests::Int
    mutex::ReentrantLock
end

mutable struct TinyServer
    config::TinyServerConfig
    engine::Engine
    sessions::Dict{String,ServerSession}
    mutex::ReentrantLock
    auth_mutex::ReentrantLock
    audit_mutex::ReentrantLock
    auth_users::Set{String}
    failed_logins::Dict{String,Tuple{Int,Float64}}
    next_connection_id::UInt64
    active_requests::Int
    http_server::Any
    reaper::Union{Nothing,Timer}
    stopped::Bool
end

_tls_enabled(config::TinyServerConfig) = config.tls_cert_file !== nothing && config.tls_key_file !== nothing
server_url(server::TinyServer) = (_tls_enabled(server.config) ? "https://" : "http://") *
    HTTP.HostResolvers.join_host_port(server.config.host, server.config.port)
_credential_path(config::TinyServerConfig) = joinpath(config.data_root, ROOT_CREDENTIAL_FILE)

function _audit_path(config::TinyServerConfig)
    candidate = String(config.audit_log_file)
    isempty(candidate) && throw(ArgumentError("audit_log_file must not be empty"))
    isabspath(candidate) ? candidate : joinpath(config.data_root, candidate)
end

function _bounded_text(value, limit::Int=128)
    text = replace(String(value), '\n' => ' ', '\r' => ' ', '\t' => ' ')
    ncodeunits(text) <= limit && return text
    String(first(collect(text), limit))
end

function _prepare_audit_file!(config::TinyServerConfig)
    audit_path = _audit_path(config)
    mkpath(dirname(audit_path))
    islink(audit_path) && throw(AiresError("Audit Error", "Audit log must not be a symbolic link."))
    if isfile(audit_path) && filesize(audit_path) >= config.audit_max_bytes
        rotated = audit_path * ".1"
        islink(rotated) && throw(AiresError("Audit Error", "Rotated audit log must not be a symbolic link."))
        mv(audit_path, rotated; force=true)
    end
    audit_path
end

function _audit!(server::TinyServer; event::AbstractString, user::AbstractString="anonymous",
        role::Union{Symbol,AbstractString}=:anonymous, action::AbstractString="",
        outcome::AbstractString="", status=nothing, path::AbstractString="",
        query_hash=nothing, connection_id=nothing)
    path_value = String(path)
    startswith(path_value, "/session/") && (path_value = "/session/:token")
    record = (; timestamp=string(now(UTC)), event=_bounded_text(event),
        user=_bounded_text(user), role=_bounded_text(role), action=_bounded_text(action),
        outcome=_bounded_text(outcome), status, path=_bounded_text(path_value, 256),
        query_hash, connection_id)
    try
        lock(server.audit_mutex) do
            audit_path = _prepare_audit_file!(server.config)
            open(audit_path, "a") do io
                write(io, JSON3.write(record)); write(io, '\n'); flush(io)
            end
            Sys.iswindows() || chmod(audit_path, 0o600)
        end
    catch exception
        server.config.verbose && (Base.showerror(stderr, exception, catch_backtrace()); println(stderr))
        exception isa AiresError && exception.category == "Audit Error" && rethrow()
        throw(AiresError("Audit Error", "Audit log is unavailable; request denied."))
    end
    nothing
end

function _query_hash(query::AbstractString)
    bytes2hex(sha256(Vector{UInt8}(codeunits(String(query)))))
end

function _query_action(query::AbstractString)
    stripped = strip(String(query))
    isempty(stripped) && return "empty"
    first_word = first(split(stripped; limit=2))
    _bounded_text(lowercase(first_word))
end

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

# Precomputed once so unknown users cost the same PBKDF2 work as valid users
# without doing a second derivation that would itself create a timing signal.
const DUMMY_PASSWORD_HASH = _pbkdf2_sha256(DUMMY_PASSWORD, DUMMY_PASSWORD_SALT)

function _validate_auth_user(user::AbstractString)
    text = String(user)
    occursin(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$", text) ||
        throw(ArgumentError("User name must be 1-64 ASCII letters, digits, '.', '_' or '-'."))
    text
end

function _validate_auth_role(role)
    text = lowercase(String(role))
    text in ("admin", "reader") || throw(ArgumentError("Role must be :admin or :reader."))
    Symbol(text)
end

function _password_record(password::AbstractString, role::Symbol)
    ncodeunits(password) >= 8 || throw(ArgumentError("Password must contain at least 8 bytes."))
    ncodeunits(password) <= 1024 || throw(ArgumentError("Password is too long."))
    salt = rand(RandomDevice(), UInt8, PASSWORD_SALT_BYTES)
    digest = _pbkdf2_sha256(password, salt)
    Dict{String,Any}(
        "role" => String(role),
        "algorithm" => "pbkdf2-hmac-sha256",
        "iterations" => PASSWORD_ITERATIONS,
        "salt" => base64encode(salt),
        "hash" => base64encode(digest),
    )
end

function _write_credentials!(config::TinyServerConfig, users::AbstractDict)
    mkpath(config.data_root)
    path = _credential_path(config)
    temporary = path * ".tmp-" * string(uuid4())
    try
        open(temporary, "w") do io
            TOML.print(io, Dict("format" => 2, "users" => Dict(String(k) => v for (k, v) in users)))
            flush(io)
        end
        Sys.iswindows() || chmod(temporary, 0o600)
        mv(temporary, path; force=true)
    catch
        isfile(temporary) && rm(temporary; force=true)
        rethrow()
    end
    path
end

function _auth_users(record::AbstractDict)
    format = Int(get(record, "format", 0))
    if format == 2
        users = get(record, "users", nothing)
        return users isa AbstractDict ? users : Dict{String,Any}()
    elseif format == 1 && get(record, "user", "") == "root"
        # Read the v1 single-root format written by older AiresDB releases.
        return Dict{String,Any}("root" => Dict{String,Any}(
            "role" => "admin",
            "algorithm" => get(record, "algorithm", ""),
            "iterations" => get(record, "iterations", 0),
            "salt" => get(record, "salt", ""),
            "hash" => get(record, "hash", ""),
        ))
    end
    Dict{String,Any}()
end

function _validated_auth_user_names(config::TinyServerConfig)
    path = _credential_path(config)
    record = try
        TOML.parsefile(path)
    catch
        throw(AiresError("Authentication Setup", "Credential file is invalid."))
    end
    users = try
        _auth_users(record)
    catch
        throw(AiresError("Authentication Setup", "Credential file is invalid."))
    end
    isempty(users) && throw(AiresError("Authentication Setup", "Credential file contains no users."))
    names = Set{String}()
    root_role = nothing
    for (raw_name, credentials) in users
        raw_name isa AbstractString && credentials isa AbstractDict ||
            throw(AiresError("Authentication Setup", "Credential file contains an invalid user record."))
        name = try
            _validate_auth_user(String(raw_name))
        catch
            throw(AiresError("Authentication Setup", "Credential file contains an invalid user name."))
        end
        role = try lowercase(String(get(credentials, "role", ""))) catch; "" end
        role in ("admin", "reader") ||
            throw(AiresError("Authentication Setup", "Credential file contains an invalid role."))
        get(credentials, "algorithm", "") == "pbkdf2-hmac-sha256" ||
            throw(AiresError("Authentication Setup", "Credential file contains an unsupported password hash."))
        iterations = try Int(get(credentials, "iterations", 0)) catch; 0 end
        10_000 <= iterations <= 1_000_000 ||
            throw(AiresError("Authentication Setup", "Credential file contains invalid PBKDF2 parameters."))
        salt = try base64decode(String(credentials["salt"])) catch; UInt8[] end
        digest = try base64decode(String(credentials["hash"])) catch; UInt8[] end
        length(salt) == PASSWORD_SALT_BYTES && length(digest) == PASSWORD_HASH_BYTES ||
            throw(AiresError("Authentication Setup", "Credential file contains an invalid password hash."))
        push!(names, name)
        name == "root" && (root_role = role)
    end
    root_role == "admin" ||
        throw(AiresError("Authentication Setup", "Credential file must contain an admin root user."))
    names
end

function _dummy_password_check(password::AbstractString)
    actual = _pbkdf2_sha256(password, DUMMY_PASSWORD_SALT)
    _constant_time_equal(actual, DUMMY_PASSWORD_HASH)
    fill!(actual, 0x00)
    nothing
end

function initialize_root_credentials!(config::TinyServerConfig, password::AbstractString)
    lock(CREDENTIALS_MUTEX) do
        isfile(_credential_path(config)) && throw(ArgumentError("Root credentials already exist."))
        _write_credentials!(config, Dict("root" => _password_record(password, :admin)))
    end
end

"""Create an additional TinyServer user in the local credential file.

The default role is `:reader`, which can run read-only queries and metadata
commands. Only `:admin` users may mutate databases or run maintenance commands.
"""
function initialize_user_credentials!(config::TinyServerConfig, user::AbstractString,
        password::AbstractString; role=:reader)
    name = _validate_auth_user(user)
    name == "root" && throw(ArgumentError("The root user is reserved and always has the admin role."))
    selected_role = _validate_auth_role(role)
    path = _credential_path(config)
    lock(CREDENTIALS_MUTEX) do
        isfile(path) || throw(ArgumentError("Root credentials must be initialized first."))
        record = try TOML.parsefile(path) catch; throw(ArgumentError("Credential file is invalid.")) end
        users = _auth_users(record)
        haskey(users, name) && throw(ArgumentError("User '$name' already exists."))
        normalized = Dict{String,Any}(String(k) => v for (k, v) in users)
        normalized[name] = _password_record(password, selected_role)
        _write_credentials!(config, normalized)
    end
end

function _verify_user_password(config::TinyServerConfig, user::AbstractString, password::AbstractString)
    name = String(user)
    if ncodeunits(password) > 1024
        _dummy_password_check(DUMMY_PASSWORD)
        return nothing
    end
    record = try
        TOML.parsefile(_credential_path(config))
    catch
        _dummy_password_check(password)
        return nothing
    end
    credentials = try get(_auth_users(record), name, nothing) catch; _dummy_password_check(password); return nothing end
    if !(credentials isa AbstractDict)
        _dummy_password_check(password)
        return nothing
    end
    role_text = lowercase(String(get(credentials, "role", "")))
    role_text in ("admin", "reader") || return nothing
    get(credentials, "algorithm", "") == "pbkdf2-hmac-sha256" || return nothing
    iterations = try Int(get(credentials, "iterations", 0)) catch; return nothing end
    10_000 <= iterations <= 1_000_000 || return nothing
    salt = try base64decode(String(credentials["salt"])) catch; return nothing end
    expected = try base64decode(String(credentials["hash"])) catch; return nothing end
    length(salt) == PASSWORD_SALT_BYTES && length(expected) == PASSWORD_HASH_BYTES || return nothing
    actual = _pbkdf2_sha256(password, salt, iterations)
    valid = _constant_time_equal(actual, expected)
    fill!(actual, 0x00)
    valid ? (; user=name, role=Symbol(role_text)) : nothing
end

_verify_root_password(config::TinyServerConfig, user::AbstractString, password::AbstractString) =
    user == "root" && _verify_user_password(config, user, password) !== nothing

function _string_field(body::AbstractDict, key::String)
    value = get(body, key, nothing)
    value isa AbstractString || throw(AiresError("Request Error", "JSON field '$key' must be a string."))
    String(value)
end

function _request_session_token(request::HTTP.Request)
    authorization = strip(HTTP.header(request.headers, "Authorization", ""))
    if startswith(lowercase(authorization), "bearer ")
        token = strip(authorization[8:end])
        occursin(r"^[0-9a-fA-F]{64}$", token) && return lowercase(token)
    end
    nothing
end

function _required_permission(query::AbstractString)
    stripped = strip(String(query))
    isempty(stripped) && return :read
    if startswith(stripped, ".")
        command = lowercase(first(split(stripped; limit=2)))
        return command in (".help", ".databases", ".tables", ".schema", ".current", ".mvcc") ? :read : :write
    end
    statement = parse_airesql(stripped)
    statement isa Union{UseDatabase,SelectQuery,ExplainQuery} ? :read : :write
end

_role_allows(role::Symbol, permission::Symbol) = role == :admin ||
    (role == :reader && permission == :read)

function _login_allowed!(server::TinyServer, user::AbstractString, now_value::Float64=time())
    allowed = true
    lock(server.mutex) do
        state = get(server.failed_logins, String(user), nothing)
        if state !== nothing
            _, blocked_until = state
            if blocked_until > 0 && now_value < blocked_until
                allowed = false
            elseif blocked_until > 0
                if String(user) in server.auth_users
                    server.failed_logins[String(user)] = (0, 0.0)
                else
                    delete!(server.failed_logins, String(user))
                end
            end
        end
    end
    allowed
end

function _record_login_failure!(server::TinyServer, user::AbstractString, now_value::Float64=time())
    lock(server.mutex) do
        key = String(user)
        if !haskey(server.failed_logins, key) &&
                length(server.failed_logins) >= server.config.max_tracked_login_users
            return nothing
        end
        count, blocked_until = get(server.failed_logins, key, (0, 0.0))
        if now_value < blocked_until
            return nothing
        end
        count += 1
        if count >= server.config.max_failed_logins
            server.failed_logins[key] = (count, now_value + server.config.login_lockout_seconds)
        else
            server.failed_logins[key] = (count, 0.0)
        end
    end
    nothing
end

function _record_login_success!(server::TinyServer, user::AbstractString)
    lock(server.mutex) do
        key = String(user)
        push!(server.auth_users, key)
        server.failed_logins[key] = (0, 0.0)
    end
    nothing
end

function _tls_server_config(config::TinyServerConfig)
    cert = config.tls_cert_file
    key = config.tls_key_file
    (cert === nothing) == (key === nothing) ||
        throw(ArgumentError("tls_cert_file and tls_key_file must be provided together."))
    cert === nothing && return nothing
    cert_path = abspath(String(cert))
    key_path = abspath(String(key))
    isfile(cert_path) || throw(ArgumentError("TLS certificate file not found: $cert_path"))
    isfile(key_path) || throw(ArgumentError("TLS private key file not found: $key_path"))
    config.tls_min_version >= DEFAULT_TLS_MIN_VERSION ||
        throw(ArgumentError("TinyServer requires TLS 1.3 or newer."))
    isfinite(config.tls_handshake_timeout) && config.tls_handshake_timeout > 0 ||
        throw(ArgumentError("tls_handshake_timeout must be finite and positive"))
    HTTP.TLS.Config(
        cert_file=cert_path,
        key_file=key_path,
        verify_peer=false,
        verify_hostname=false,
        client_auth=HTTP.TLS.ClientAuthMode.NoClientCert,
        min_version=config.tls_min_version,
        handshake_timeout_ns=Int64(round(config.tls_handshake_timeout * 1_000_000_000)),
    )
end

@inline _saturating_size_add(left::Int, right::Int) =
    left > typemax(Int) - right ? typemax(Int) : left + right

function _json_string_size(value::AbstractString)
    total = 2
    for byte in codeunits(value)
        extra = byte == UInt8('"') || byte == UInt8('\\') ? 2 : byte < 0x20 ? 6 : 1
        total = _saturating_size_add(total,extra)
    end
    total
end

function _json_serialized_upper_bound(value)::Int
    value === nothing && return 4
    value === missing && return 4
    value isa Bool && return value ? 4 : 5
    value isa AbstractString && return _json_string_size(value)
    value isa Symbol && return _json_string_size(String(value))
    value isa Integer && return ncodeunits(string(value))
    value isa AbstractFloat && return max(32,ncodeunits(string(value)))
    if value isa NamedTuple || value isa AbstractDict
        total = 2
        separator = 0
        for (key,item) in pairs(value)
            total = _saturating_size_add(total,separator)
            total = _saturating_size_add(total,_json_string_size(String(key)))
            total = _saturating_size_add(total,1)
            total = _saturating_size_add(total,_json_serialized_upper_bound(item))
            separator = 1
        end
        return total
    end
    if value isa AbstractArray || value isa Tuple
        total = 2
        separator = 0
        for item in value
            total = _saturating_size_add(total,separator)
            total = _saturating_size_add(total,_json_serialized_upper_bound(item))
            separator = 1
        end
        return total
    end
    # TinyServer payloads use only the shapes above. Keep the fallback exact for
    # future small metadata types instead of silently underestimating them.
    ncodeunits(JSON3.write(value))
end

function _json_response(status::Int, body; max_bytes::Union{Nothing,Integer}=nothing)
    max_bytes === nothing || _json_serialized_upper_bound(body) <= max_bytes ||
        throw(AiresError("Resource Limit", "Response exceeds the $(max_bytes)-byte limit."))
    payload = JSON3.write(body)
    max_bytes === nothing || ncodeunits(payload) <= max_bytes ||
        throw(AiresError("Resource Limit", "Response exceeds the $(max_bytes)-byte limit."))
    HTTP.Response(status,
        ["Content-Type" => "application/json; charset=utf-8",
         "Cache-Control" => "no-store",
         "X-Content-Type-Options" => "nosniff",
         "X-Frame-Options" => "DENY",
         "Referrer-Policy" => "no-referrer"],
        payload)
end

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
    expired = Tuple{ServerSession,String}[]
    lock(server.mutex) do
        for (token, entry) in collect(server.sessions)
            idle_expired = now - entry.last_activity >= server.config.idle_timeout
            lifetime_expired = now - entry.created_at >= server.config.max_session_lifetime
            if entry.active_requests == 0 && (idle_expired || lifetime_expired)
                delete!(server.sessions, token)
                push!(expired, (entry, lifetime_expired ? "max_lifetime" : "idle_timeout"))
            end
        end
    end
    audit_error = nothing
    for (entry, reason) in expired
        try
            _audit!(server; event="session_expired", user=entry.user, role=entry.role,
                action="session", outcome=reason, status=401, path="/session",
                connection_id=entry.connection_id)
        catch error
            audit_error === nothing && (audit_error = error)
        finally
            _close_server_session!(entry)
        end
    end
    audit_error === nothing || throw(audit_error)
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

function _try_acquire_request!(server::TinyServer)
    lock(server.mutex) do
        if server.active_requests >= server.config.max_concurrent_requests
            return false
        end
        server.active_requests += 1
        true
    end
end

function _release_request!(server::TinyServer)
    lock(server.mutex) do
        server.active_requests = max(0, server.active_requests - 1)
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
    _query_budget_memory!(types)
    rows = Vector{Any}()
    sizehint!(rows,length(result.rows))
    for row in result.rows
        wire_row = Any[_wire_cell(value) for value in row]
        _query_budget_memory!(wire_row)
        push!(rows,wire_row)
    end
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
    command in (".help", ".databases", ".tables", ".current", ".mvcc", ".checkpoint", ".vacuum", ".compact") &&
        length(parts) != 1 && fail("$command tidak menerima argumen.")
    if command == ".help"
        return "Gunakan .databases, .tables, .schema Nama, .current, .mvcc, .checkpoint, .vacuum, .compact, .cancel, atau .exit."
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
    elseif command == ".compact"
        return String(compact_page_store!(session).rows[1][1])
    elseif command in (".exit", ".cancel")
        fail("Perintah '$command' ditangani oleh client monitor.")
    end
    fail("Perintah internal '$command' tidak dikenal. Gunakan .help.")
end

function _execute_server_query(entry::ServerSession, query::String, config::TinyServerConfig,
                               execution_completed::Base.RefValue{Bool})
    lock(entry.mutex) do
        stripped = strip(query)
        isempty(stripped) && throw(AiresError("Request Error", "Query must not be empty."))
        deadline = UInt64(time_ns()) + UInt64(round(config.max_query_seconds * 1_000_000_000))
        intermediate_limit = config.max_result_rows > typemax(Int) ÷ 4 ? typemax(Int) :
            max(config.max_result_rows * 4,config.max_result_rows + 1024)
        spill_directory = mktempdir()
        budget = QueryBudget(deadline,config.max_result_rows,intermediate_limit,
            config.max_query_memory_bytes,config.max_query_spill_bytes,spill_directory,
            0,0,0,0,0,0,0)
        try
            payload = _with_query_budget(() -> begin
                started = time_ns()
                result = startswith(stripped, ".") ? _server_command(entry.session, stripped) : execute!(entry.session, query)
                execution_completed[] = true
                elapsed = (time_ns() - started) / 1_000_000
                result isa QueryResult ? _result_payload(result, elapsed, entry.session) : _command_payload(String(result), elapsed, entry.session)
            end,budget)
            (payload=payload,budget=budget)
        finally
            isdir(spill_directory) && rm(spill_directory; recursive=true, force=true)
        end
    end
end

function _error_response(error)
    error isa AiresError || return _server_error(500, "A5000", "Internal server error.")
    category = error.category
    code, status = if category == "Transaction Conflict"
        "A3001", 409
    elseif category == "Commit Outcome Unknown"
        "A3002", 503
    elseif category == "Authentication Error" || category == "Session Error"
        "A1002", 401
    elseif category == "Authorization Error"
        "A1006", 403
    elseif category == "Audit Error"
        "A5001", 503
    elseif category == "Request Too Large"
        "A1004", 413
    elseif category == "Resource Limit"
        "A1005", 429
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

_is_audit_error(error) = error isa AiresError && error.category == "Audit Error"

function _login_response(server::TinyServer, user::String, password::String)
    login_user = _bounded_text(user, 64)
    if !trylock(server.auth_mutex)
        _audit!(server; event="login_failed", user=login_user, action="login",
            outcome="server_busy", status=429, path="/session")
        return _server_error(429, "A1005", "Too many concurrent login attempts.";
            category="Resource Limit")
    end
    try
        if !_login_allowed!(server, login_user)
            _dummy_password_check(ncodeunits(password) <= 1024 ? password : DUMMY_PASSWORD)
            _audit!(server; event="login_failed", user=login_user, action="login",
                outcome="locked", status=401, path="/session")
            return _server_error(401, "A1001", "Access denied."; category="Authentication Error")
        end
        principal = _verify_user_password(server.config, user, password)
        if principal === nothing
            _record_login_failure!(server, login_user)
            _audit!(server; event="login_failed", user=login_user, action="login",
                outcome="denied", status=401, path="/session")
            return _server_error(401, "A1001", "Access denied."; category="Authentication Error")
        end
        _record_login_success!(server, login_user)
        token = bytes2hex(rand(RandomDevice(), UInt8, 32))
        _reap_expired!(server)
        entry = lock(server.mutex) do
            length(server.sessions) < server.config.max_sessions || return nothing
            connection_id = server.next_connection_id
            server.next_connection_id += 1
            now_value = time()
            created = ServerSession(principal.user, principal.role, token, connection_id,
                Session(server.engine), now_value, now_value, 0, ReentrantLock())
            server.sessions[token] = created
            created
        end
        if entry === nothing
            _audit!(server; event="login_failed", user=principal.user, role=principal.role,
                action="login", outcome="session_limit", status=503, path="/session")
            return _server_error(503, "A1005", "Session limit reached."; category="Resource Limit")
        end
        try
            _audit!(server; event="login_success", user=entry.user, role=entry.role,
                action="login", outcome="success", status=201, path="/session",
                connection_id=entry.connection_id)
        catch
            lock(server.mutex) do
                pop!(server.sessions, token, nothing)
            end
            _close_server_session!(entry)
            rethrow()
        end
        _json_response(201, (; ok=true, session=token, connection_id=entry.connection_id))
    finally
        unlock(server.auth_mutex)
    end
end

function tinyserver_handler(server::TinyServer, request::HTTP.Request)
    if !_try_acquire_request!(server)
        response = _server_error(503, "A1005", "Server request capacity reached.";
            category="Resource Limit")
        HTTP.setheader(response, "Retry-After" => "1")
        response.close = true
        return response
    end
    try
        _handle_tinyserver_request(server, request)
    finally
        _release_request!(server)
    end
end

function _handle_tinyserver_request(server::TinyServer, request::HTTP.Request)
    method = ""
    path = ""
    try
        method = uppercase(String(request.method))
        path = split(String(request.target), '?'; limit=2)[1]
        if method == "GET" && path == "/health"
            return _json_response(200, (; ok=true, server="AiresDB", version=AIRESDB_SERVER_VERSION))
        elseif method == "POST" && path == "/session"
            body = _request_json(request, server.config)
            user = _string_field(body, "user"); password = _string_field(body, "password")
            return _login_response(server, user, password)
        elseif method == "POST" && path == "/query"
            length(request.body) <= server.config.max_request_body ||
                throw(AiresError("Request Too Large", "Request body exceeds the configured limit."))
            token = _request_session_token(request)
            if token === nothing
                _audit!(server; event="query_auth_failed", action="query",
                    outcome="missing_or_malformed_token", status=401, path="/query")
                return _server_error(401, "A1002", "Invalid or expired session."; category="Session Error")
            end
            entry = _take_session(server, token)
            if entry === nothing
                _audit!(server; event="query_auth_failed", action="query",
                    outcome="invalid_session", status=401, path="/query")
                return _server_error(401, "A1002", "Invalid or expired session."; category="Session Error")
            end
            query = ""
            permission = nothing
            executed = false
            execution_completed = Ref(false)
            try
                body = _request_json(request, server.config)
                query = _string_field(body, "query")
                permission = _required_permission(query)
                if !_role_allows(entry.role, permission)
                    _audit!(server; event="authorization_denied", user=entry.user, role=entry.role,
                        action=_query_action(query), outcome=String(permission), status=403,
                        path="/query", query_hash=_query_hash(query),
                        connection_id=entry.connection_id)
                    return _server_error(403, "A1006", "User role is not allowed to execute this operation.";
                        category="Authorization Error")
                end
                _audit!(server; event="query_started", user=entry.user, role=entry.role,
                    action=_query_action(query), outcome=String(permission), status=202,
                    path="/query", query_hash=_query_hash(query),
                    connection_id=entry.connection_id)
                execution = _execute_server_query(entry, query, server.config, execution_completed)
                executed = execution_completed[]
                remaining_memory = max(0,server.config.max_query_memory_bytes - execution.budget.allocated_bytes)
                response_limit = min(server.config.max_response_body,remaining_memory)
                response = _json_response(200, execution.payload; max_bytes=response_limit)
                try
                    _audit!(server; event="query", user=entry.user, role=entry.role,
                        action=_query_action(query), outcome="success", status=response.status,
                        path="/query", query_hash=_query_hash(query),
                        connection_id=entry.connection_id)
                catch audit_error
                    if permission == :write
                        return _error_response(AiresError("Commit Outcome Unknown",
                            "Query may have committed, but completion could not be acknowledged. Inspect database state before retrying."))
                    end
                    return _error_response(audit_error)
                end
                return response
            catch error
                if (executed || execution_completed[]) && permission == :write
                    if !_is_audit_error(error)
                        try
                            _audit!(server; event="query_outcome_unknown", user=entry.user,
                                role=entry.role, action=_query_action(query), outcome="error",
                                status=503, path="/query", query_hash=_query_hash(query),
                                connection_id=entry.connection_id)
                        catch
                        end
                    end
                    return _error_response(AiresError("Commit Outcome Unknown",
                        "Query may have committed, but completion could not be acknowledged. Inspect database state before retrying."))
                end
                _is_audit_error(error) && return _error_response(error)
                response = _error_response(error)
                try
                    _audit!(server; event="query_failed", user=entry.user, role=entry.role,
                        action=_query_action(query), outcome="error", status=response.status,
                        path="/query", query_hash=_query_hash(query),
                        connection_id=entry.connection_id)
                catch audit_error
                    return _error_response(audit_error)
                end
                return response
            finally
                _release_session!(server, entry)
            end
        elseif method == "DELETE" && path == "/session"
            token = _request_session_token(request)
            if token === nothing
                _audit!(server; event="session_close_failed", action="logout",
                    outcome="missing_or_malformed_token", status=401, path="/session")
                return _server_error(401, "A1002", "Invalid or expired session."; category="Session Error")
            end
            entry = lock(server.mutex) do
                get(server.sessions, token, nothing)
            end
            if entry === nothing
                _audit!(server; event="session_close_failed", action="logout",
                    outcome="invalid_session", status=401, path="/session")
                return _server_error(401, "A1002", "Invalid or expired session."; category="Session Error")
            end
            _audit!(server; event="session_close_started", user=entry.user, role=entry.role,
                action="logout", outcome="accepted", status=202, path="/session",
                connection_id=entry.connection_id)
            entry = lock(server.mutex) do
                pop!(server.sessions, token, nothing)
            end
            if entry === nothing
                _audit!(server; event="session_close_failed", action="logout",
                    outcome="invalid_session", status=401, path="/session")
                return _server_error(401, "A1002", "Invalid or expired session."; category="Session Error")
            end
            _close_server_session!(entry)
            _audit!(server; event="session_closed", user=entry.user, role=entry.role,
                action="logout", outcome="success", status=200, path="/session",
                connection_id=entry.connection_id)
            return _json_response(200, (; ok=true))
        end
        _audit!(server; event="route_not_found", action=method, outcome="not_found", status=404, path)
        _server_error(404, "A1003", "Route not found."; category="Request Error")
    catch error
        server.config.verbose && Base.showerror(stderr, error, catch_backtrace())
        response = _error_response(error)
        if !_is_audit_error(error)
            try
                _audit!(server; event="request_failed", action=method, outcome="error",
                    status=response.status, path)
            catch audit_error
                return _error_response(audit_error)
            end
        end
        response
    end
end

function start_tinyserver(config::TinyServerConfig=TinyServerConfig(); password=nothing)
    1 <= config.port <= 65535 || throw(ArgumentError("port must be between 1 and 65535"))
    config.max_header_bytes > 0 || throw(ArgumentError("max_header_bytes must be positive"))
    config.max_request_body > 0 || throw(ArgumentError("max_request_body must be positive"))
    config.max_concurrent_requests > 0 ||
        throw(ArgumentError("max_concurrent_requests must be positive"))
    config.max_sessions > 0 || throw(ArgumentError("max_sessions must be positive"))
    isfinite(config.idle_timeout) && config.idle_timeout > 0 ||
        throw(ArgumentError("idle_timeout must be finite and positive"))
    isfinite(config.max_session_lifetime) && config.max_session_lifetime > 0 ||
        throw(ArgumentError("max_session_lifetime must be finite and positive"))
    config.max_result_rows > 0 || throw(ArgumentError("max_result_rows must be positive"))
    isfinite(config.max_query_seconds) && config.max_query_seconds > 0 ||
        throw(ArgumentError("max_query_seconds must be finite and positive"))
    config.max_response_body > 0 || throw(ArgumentError("max_response_body must be positive"))
    config.max_query_memory_bytes > 0 || throw(ArgumentError("max_query_memory_bytes must be positive"))
    config.max_query_spill_bytes >= config.max_query_memory_bytes ||
        throw(ArgumentError("max_query_spill_bytes must be at least max_query_memory_bytes"))
    config.audit_max_bytes > 0 || throw(ArgumentError("audit_max_bytes must be positive"))
    config.max_failed_logins > 0 || throw(ArgumentError("max_failed_logins must be positive"))
    isfinite(config.login_lockout_seconds) && config.login_lockout_seconds > 0 ||
        throw(ArgumentError("login_lockout_seconds must be finite and positive"))
    config.max_tracked_login_users > 0 ||
        throw(ArgumentError("max_tracked_login_users must be positive"))
    _audit_path(config)
    tls_config = _tls_server_config(config)
    loopback = lowercase(strip(config.host)) in ("127.0.0.1", "localhost", "::1")
    loopback || tls_config !== nothing ||
        throw(AiresError("Network Security", "Binding ke alamat non-loopback wajib memakai TLS certificate dan private key; insecure bypass tidak diizinkan."))
    mkpath(config.data_root)
    credential = _credential_path(config)
    if !isfile(credential)
        password === nothing && throw(AiresError("Authentication Setup", "Root credentials do not exist. Run interactive server setup."))
        initialize_root_credentials!(config, String(password))
    end
    auth_users = _validated_auth_user_names(config)
    length(auth_users) <= config.max_tracked_login_users ||
        throw(AiresError("Authentication Setup", "Configured users exceed max_tracked_login_users."))
    failed_logins = Dict{String,Tuple{Int,Float64}}(user => (0, 0.0) for user in auth_users)
    server = TinyServer(config, Engine(config.data_root), Dict{String,ServerSession}(),
        ReentrantLock(), ReentrantLock(), ReentrantLock(), auth_users, failed_logins,
        UInt64(1), 0, nothing, nothing, false)
    _audit!(server; event="server_starting", action="start", outcome="accepted", status=202, path="/")
    interval = min(30.0, max(0.1, config.idle_timeout / 2))
    server.reaper = Timer(interval; interval) do _
        try
            _reap_expired!(server)
        catch error
            config.verbose && (Base.showerror(stderr, error, catch_backtrace()); println(stderr))
        end
    end
    handler = request -> tinyserver_handler(server, request)
    listener = nothing
    try
        if tls_config === nothing
            server.http_server = HTTP.serve!(handler, config.host, config.port;
                verbose=config.verbose, max_body_bytes=config.max_request_body,
                max_header_bytes=config.max_header_bytes,
                max_concurrent_streams=config.max_concurrent_requests,
                read_header_timeout=DEFAULT_HTTP_READ_HEADER_TIMEOUT,
                read_timeout=DEFAULT_HTTP_IO_TIMEOUT, write_timeout=DEFAULT_HTTP_IO_TIMEOUT)
        else
            listener = HTTP.TLS.listen("tcp",
                HTTP.HostResolvers.join_host_port(config.host, config.port), tls_config)
            server.http_server = HTTP.serve!(handler, listener;
                verbose=config.verbose, max_body_bytes=config.max_request_body,
                max_header_bytes=config.max_header_bytes,
                max_concurrent_streams=config.max_concurrent_requests,
                read_header_timeout=DEFAULT_HTTP_READ_HEADER_TIMEOUT,
                read_timeout=DEFAULT_HTTP_IO_TIMEOUT, write_timeout=DEFAULT_HTTP_IO_TIMEOUT)
        end
        _audit!(server; event="server_started", action="start", outcome="success", status=200, path="/")
    catch error
        try
            _audit!(server; event="server_start_failed", action="start", outcome="error", status=503, path="/")
        catch
        end
        close(server.reaper)
        server.http_server === nothing || close(server.http_server)
        listener === nothing || close(listener)
        rethrow()
    end
    server
end

function stop_tinyserver!(server::TinyServer)
    server.stopped && return nothing
    audit_error = try
        _audit!(server; event="server_stopped", action="stop", outcome="success", status=200, path="/")
        nothing
    catch error
        error
    end
    server.stopped = true
    server.reaper === nothing || close(server.reaper)
    server.http_server === nothing || close(server.http_server)
    entries = lock(server.mutex) do
        current = collect(values(server.sessions))
        empty!(server.sessions)
        current
    end
    foreach(_close_server_session!, entries)
    audit_error === nothing || throw(audit_error)
    nothing
end
