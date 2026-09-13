# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

const AIRESDB_BANNER = raw"""
                         .          .
                     .:***************-.:
                 .-***********************-+
              --*******------#@@*------*******+
            .-******:-@@@@@@@@@@@@@@@@@@-.******-+
          :-*****+*%@@@@@@@@@@@@@@@@@@@@@@%-+*****-
         .****-+*@@@@@@@@@@@@@@@@@@@@@@@@@@@@*-*****+
       .-****-#@@@@@@@@@--**--@@@@@@@@@@@@@@@@@--****+
      .-****:@@@@@@@@@@@-****-@@@@@@@@@@@@@@@@@@--****+
     +:****:@@@@@@@@@@@@-****-@@@@@@@@@@@@@@@@@@@*-****.
     .****-*@@@@@@@@@@@@-****-@@@@@@@@@@@@@@@@@@@@*-***-.
     -****-@@@@@@@@@@@@@-****--+-****@@@@@@@@@@@@@%-****:
     -***.@@@@@@@@@@@@@@-****-***:-**-@@@@@@@@@@@@@-****-
    --***.@@@@@@@@@@@@@@-********--**+**-%@@@@@@@@@*:***-
    +-***.@@@@@@@@@@@@*-+-+---**---**+**-#@@@@@@@@@*.***-
    +-***.@@@@@@@@@*-**********----**+**-#@@@@@@@@@-****-
     -****-@@@@@@@@-*****:....***--**+**:#@@@@@@@@@-****+:
     :****-*@@@@@@@@*-*******-+**::---**-#@@@@@@@@*-****.
      :****-@@@@@@@@@@@--******--*****--*@@@@@@@@*+****.
      :+****:#@@@@@@@@@@-************-*@@@@@@@@@-+****-
       .-****-#@@@@@@@@@#:*********-@@@@@@@@@@@:-****:.
         .*****:*@@@@@@@#:********-*@@@@@@@@@--****--
          :-*****-*#@@@@-***********@@@@@@#+-*****-
            .-******+-*#-**********+@@**:+******-
              -+*****************************-.
                . :-**********************-:
                     :.+---********---:.
"""

# Retire pooled connections before TinyServer's read-header timeout closes them.
# Mutating requests deliberately keep retry=false, so stale sockets must never be
# handed back to a query instead of relying on an unsafe automatic replay.
const CLIENT_HTTP_IDLE_TIMEOUT_NS = Int64(5_000_000_000)

const CLIENT_HELP_TEXT = """
AiresDB monitor adalah client untuk AiresDB TinyServer.
Semua statement AiresQL wajib diakhiri -: dan dapat ditulis multiline.

  .help                 Bantuan
  .databases            Daftar database pada server
  .tables               Daftar tabel dan view database aktif
  .schema Nama          Schema tabel
  .current              Database aktif dan status transaksi
  .mvcc                 Statistik MVCC dan WAL
  .checkpoint           Jalankan checkpoint durable
  .vacuum               Bersihkan versi lama
  .compact              Rebuild dan reclaim PageStore (offline)
  .cancel               Batalkan input multiline
  .exit                 Tutup session dan keluar
"""

function _new_http_client(; timeout::Real=10, tls_config=nothing)
    transport = HTTP.Transport(; tls_config, idle_timeout_ns=CLIENT_HTTP_IDLE_TIMEOUT_NS)
    HTTP.Client(; connect_timeout=Float64(timeout), transport)
end

function _http_json(method::String, url::String, body=nothing; timeout::Real=10,
        headers::AbstractVector{<:Pair}=Pair{String,String}[], client=nothing)
    request_headers = ["Accept" => "application/json"]
    append!(request_headers, headers)
    payload = UInt8[]
    if body !== nothing
        push!(request_headers, "Content-Type" => "application/json")
        payload = Vector{UInt8}(codeunits(JSON3.write(body)))
    end
    request_client = client === nothing ? _new_http_client(; timeout) : client
    response = try
        HTTP.request(request_client, method, url, request_headers, payload; status_exception=false, retry=false)
    finally
        client === nothing && close(request_client)
    end
    parsed = isempty(response.body) ? Dict{String,Any}() : JSON3.read(String(response.body), Dict{String,Any})
    response.status, parsed
end

function _client_error(body, fallback::String)
    error = get(body, "error", nothing)
    error isa AbstractDict || return fallback
    code = String(get(error, "code", "A5000"))
    message = String(get(error, "message", fallback))
    "ERROR $code: $message"
end

function _wire_text(value)
    value === nothing && return "NULL"
    if value isa AbstractDict && haskey(value, "value")
        return String(value["value"])
    end
    string(value)
end

function _format_wire_table(columns, rows; max_width::Int=80)
    headers = [terminal_text(String(value), max_width) for value in columns]
    data = [[terminal_text(_wire_text(value), max_width) for value in row] for row in rows]
    isempty(headers) && return ""
    widths = [maximum([textwidth(headers[i]); [textwidth(row[i]) for row in data]]) for i in eachindex(headers)]
    border = "+" * join([repeat("-", width + 2) for width in widths], "+") * "+"
    render(row) = "| " * join([row[i] * repeat(" ", widths[i] - textwidth(row[i])) for i in eachindex(row)], " | ") * " |"
    lines = String[border, render(headers), border]
    append!(lines, [render(row) for row in data]); push!(lines, border)
    join(lines, "\n")
end

function _render_client_result(body)
    message = get(body, "message", nothing)
    message === nothing || return String(message)
    columns = get(body, "columns", Any[]); rows = get(body, "rows", Any[])
    rendered = _format_wire_table(columns, rows)
    count = Int(get(body, "row_count", length(rows)))
    elapsed = round(Float64(get(body, "elapsed_ms", 0.0)); digits=2)
    isempty(rendered) ? "$count rows in set ($(elapsed) ms)" : "$rendered\n$count rows in set ($(elapsed) ms)"
end

function _client_prompt(database)
    name = database === nothing ? "(none)" : String(database)
    "AiresDB [$name]> "
end

function _read_password(input::IO, output::IO)
    if input isa Base.TTY && input === stdin
        secret = Base.getpass(input, output, "Enter password"; with_suffix=true)
        password = read(secret, String)
        Base.shred!(secret)
        println(output)
        return password
    end
    print(output, "Enter password: "); flush(output)
    eof(input) && return ""
    readline(input)
end

function _close_remote_session(base_url::String, token::String; client=nothing)
    try
        _http_json("DELETE", "$base_url/session";
            timeout=3, client=client, headers=["Authorization" => "Bearer $token"])
    catch
    end
    nothing
end

function run_client(; host::String=DEFAULT_SERVER_HOST, port::Int=DEFAULT_SERVER_PORT,
        user::String="root", password=nothing, ask_password::Bool=true,
        tls::Bool=false, tls_ca_file=nothing,
        input::IO=stdin, output::IO=stdout, error_output::IO=stderr,
        interactive::Bool=(input isa Base.TTY && output isa Base.TTY),
        banner::Bool=interactive, stop_on_error::Bool=!interactive)
    scheme = tls ? "https" : "http"
    base_url = "$scheme://" * HTTP.HostResolvers.join_host_port(host, port)
    http_client = try
        if tls
            ca_file = tls_ca_file === nothing ? nothing : abspath(String(tls_ca_file))
            ca_file === nothing || isfile(ca_file) || throw(ArgumentError("TLS CA file not found: $ca_file"))
            tls_config = ca_file === nothing ?
                HTTP.TLS.Config(min_version=HTTP.TLS.TLS1_3_VERSION) :
                HTTP.TLS.Config(ca_file=ca_file, min_version=HTTP.TLS.TLS1_3_VERSION)
            _new_http_client(; timeout=10.0, tls_config)
        else
            _new_http_client(; timeout=10.0)
        end
    catch error
        println(error_output, "ERROR A1000: Cannot configure the AiresDB client: ", sprint(showerror, error))
        return 1
    end
    supplied_password = password === nothing && ask_password ? _read_password(input, output) : something(password, "")
    status, login = try
        _http_json("POST", "$base_url/session", (; user, password=String(supplied_password)); client=http_client)
    catch
        close(http_client)
        println(error_output, "ERROR A1000: Cannot connect to AiresDB server at $host:$port.\n\nStart the server with:\n\n    airesdb server")
        return 1
    end
    if status != 201 || get(login, "ok", false) !== true
        close(http_client)
        println(error_output, _client_error(login, "Login failed."))
        return 1
    end
    token = String(login["session"]); connection_id = login["connection_id"]
    database = nothing
    if banner
        println(output, AIRESDB_BANNER)
        println(output, "Welcome to the AiresDB monitor.\n")
        println(output, "AiresDB connection id: $connection_id")
        println(output, "Server version:         $(AIRESDB_SERVER_VERSION) AiresDB")
        println(output, "Server:                 $host:$port")
        println(output, "User:                   $user")
        println(output, "Database:               (none)\n")
        println(output, "Statements end with -:")
        println(output, "Type '.help' for help.\n")
    end
    pending = ""; exit_code = 0
    try
        while true
            if interactive
                print(output, isempty(strip(pending)) ? _client_prompt(database) : "                    -> ")
                flush(output)
            end
            eof(input) && break
            line = readline(input)
            stripped = strip(line)
            if startswith(stripped, ".")
                command = lowercase(stripped)
                if command == ".exit"
                    break
                elseif command == ".cancel"
                    pending = ""; println(output, "Input cancelled"); continue
                elseif command == ".help"
                    println(output, CLIENT_HELP_TEXT); continue
                end
                if !isempty(strip(pending))
                    println(error_output, "ERROR A2000: Complete the statement with -: or use .cancel.")
                    exit_code = 1; stop_on_error && break; continue
                end
                pending = stripped
            else
                pending *= line * "\n"
                occursin("-:", pending) || continue
            end
            status, response = try
                _http_json("POST", "$base_url/query", (; query=pending);
                    client=http_client, headers=["Authorization" => "Bearer $token"])
            catch
                println(error_output, "ERROR A1000: Connection to AiresDB server was lost.")
                return 1
            end
            pending = ""
            if status != 200 || get(response, "ok", false) !== true
                println(error_output, _client_error(response, "Query failed."))
                exit_code = 1; stop_on_error && break; continue
            end
            database = get(response, "database", nothing)
            println(output, _render_client_result(response))
        end
        if !isempty(strip(pending))
            println(error_output, "ERROR A2000: Statement must end with -:.")
            exit_code = 1
        end
    finally
        _close_remote_session(base_url, token; client=http_client)
        close(http_client)
    end
    exit_code
end

function _parse_cli_options(args::Vector{String})
    options = Dict{String,Any}(
        "host" => DEFAULT_SERVER_HOST, "port" => DEFAULT_SERVER_PORT,
        "user" => "root", "ask_password" => false, "no_banner" => false,
        "file" => nothing, "data_root" => abspath("data"), "verbose" => false,
        "max_header_bytes" => DEFAULT_MAX_HEADER_BYTES,
        "max_request_body" => DEFAULT_MAX_REQUEST_BODY,
        "max_concurrent_requests" => DEFAULT_MAX_CONCURRENT_REQUESTS,
        "max_sessions" => DEFAULT_MAX_SESSIONS, "idle_timeout" => DEFAULT_IDLE_TIMEOUT,
        "max_session_lifetime" => DEFAULT_MAX_SESSION_LIFETIME,
        "max_result_rows" => DEFAULT_MAX_RESULT_ROWS,
        "max_query_seconds" => DEFAULT_MAX_QUERY_SECONDS,
        "max_response_body" => DEFAULT_MAX_RESPONSE_BODY,
        "max_query_memory_bytes" => DEFAULT_MAX_QUERY_MEMORY_BYTES,
        "max_query_spill_bytes" => DEFAULT_MAX_QUERY_SPILL_BYTES,
        "tls" => false, "tls_ca_file" => nothing,
        "tls_cert_file" => nothing, "tls_key_file" => nothing,
        "audit_log_file" => DEFAULT_AUDIT_LOG_FILE,
        "audit_max_bytes" => DEFAULT_AUDIT_MAX_BYTES,
        "max_failed_logins" => DEFAULT_MAX_FAILED_LOGINS,
        "login_lockout_seconds" => DEFAULT_LOGIN_LOCKOUT_SECONDS,
        "max_tracked_login_users" => DEFAULT_MAX_TRACKED_LOGIN_USERS,
    )
    server = !isempty(args) && first(args) == "server"
    index = server ? 2 : 1
    while index <= length(args)
        arg = args[index]
        if arg in ("-h", "--host", "-P", "--port", "-u", "--user", "--file", "--data-root",
                   "--max-header-bytes", "--max-request-body", "--max-concurrent-requests",
                   "--max-sessions", "--idle-timeout", "--max-session-lifetime", "--max-result-rows",
                   "--max-query-seconds", "--max-response-body", "--max-query-memory-bytes",
                   "--max-query-spill-bytes", "--tls-ca-file", "--tls-cert-file",
                   "--tls-key-file", "--audit-log-file", "--audit-max-bytes",
                   "--max-failed-logins", "--login-lockout-seconds", "--max-tracked-login-users")
            index < length(args) || throw(ArgumentError("$arg requires a value."))
            index += 1; value = args[index]
            key = arg in ("-h", "--host") ? "host" : arg in ("-P", "--port") ? "port" :
                  arg in ("-u", "--user") ? "user" : replace(arg[3:end], '-' => '_')
            options[key] = key in ("port", "max_header_bytes", "max_request_body",
                                   "max_concurrent_requests", "max_sessions", "max_result_rows", "max_response_body",
                                   "max_query_memory_bytes", "max_query_spill_bytes", "audit_max_bytes",
                                   "max_failed_logins", "max_tracked_login_users") ? parse(Int, value) :
                           key in ("idle_timeout", "max_session_lifetime", "max_query_seconds",
                                   "login_lockout_seconds") ? parse(Float64, value) : value
        elseif arg == "-p"
            options["ask_password"] = true
        elseif arg == "--no-banner"
            options["no_banner"] = true
        elseif arg == "--verbose"
            options["verbose"] = true
        elseif arg == "--tls"
            options["tls"] = true
        elseif arg == "--help"
            options["help"] = true
        else
            throw(ArgumentError("Unknown argument '$arg'."))
        end
        index += 1
    end
    server, options
end

function _server_password(config::TinyServerConfig)
    isfile(_credential_path(config)) && return nothing
    println("First-time setup")
    first = _read_password(stdin, stdout)
    second = begin
        if stdin isa Base.TTY
            secret = Base.getpass(stdin, stdout, "Confirm password"; with_suffix=true)
            value = read(secret, String); Base.shred!(secret); println(); value
        else
            print("Confirm password: "); flush(stdout); eof(stdin) ? "" : readline(stdin)
        end
    end
    first == second || throw(ArgumentError("Passwords do not match."))
    first
end

function _print_usage(io::IO=stdout)
    println(io, "airesdb server [--host HOST] [--port PORT] [--data-root DIR] [--tls-cert-file FILE --tls-key-file FILE] [--audit-log-file FILE] [--audit-max-bytes BYTES] [--max-header-bytes BYTES] [--max-request-body BYTES] [--max-concurrent-requests N] [--max-sessions N] [--idle-timeout N] [--max-session-lifetime N] [--max-failed-logins N] [--login-lockout-seconds N] [--max-result-rows N] [--max-query-seconds N] [--max-response-body BYTES] [--max-query-memory-bytes BYTES] [--max-query-spill-bytes BYTES] [--verbose]")
    println(io, "airesdb -u USER -p [-h HOST] [-P PORT] [--tls [--tls-ca-file FILE]] [--file SCRIPT] [--no-banner]")
end

function cli_main(args::Vector{String}=ARGS)
    try
        server_mode, options = _parse_cli_options(args)
        if get(options, "help", false)
            _print_usage(); return 0
        end
        if server_mode
            config = TinyServerConfig(host=options["host"], port=options["port"],
                data_root=abspath(options["data_root"]), max_header_bytes=options["max_header_bytes"],
                max_request_body=options["max_request_body"],
                max_concurrent_requests=options["max_concurrent_requests"],
                max_sessions=options["max_sessions"], idle_timeout=options["idle_timeout"],
                max_session_lifetime=options["max_session_lifetime"],
                max_result_rows=options["max_result_rows"], max_query_seconds=options["max_query_seconds"],
                max_response_body=options["max_response_body"],
                max_query_memory_bytes=options["max_query_memory_bytes"], max_query_spill_bytes=options["max_query_spill_bytes"],
                tls_cert_file=options["tls_cert_file"], tls_key_file=options["tls_key_file"],
                audit_log_file=options["audit_log_file"], audit_max_bytes=options["audit_max_bytes"],
                max_failed_logins=options["max_failed_logins"],
                login_lockout_seconds=options["login_lockout_seconds"],
                max_tracked_login_users=options["max_tracked_login_users"],
                verbose=options["verbose"])
            password = _server_password(config)
            server = start_tinyserver(config; password)
            println("AiresDB TinyServer $(AIRESDB_SERVER_VERSION)")
            println("Listening on $(server_url(server))")
            println("Data directory: $(config.data_root)")
            if !(config.host in ("127.0.0.1", "localhost", "::1"))
                println(stderr, "TLS enabled; protect the private key and restrict network access.")
            end
            try
                wait(server.http_server)
            finally
                stop_tinyserver!(server)
                println("AiresDB TinyServer stopped")
            end
            return 0
        end
        input = options["file"] === nothing ? stdin : open(String(options["file"]), "r")
        try
            return run_client(host=options["host"], port=options["port"], user=options["user"],
                tls=options["tls"], tls_ca_file=options["tls_ca_file"],
                ask_password=options["ask_password"], input=input,
                interactive=options["file"] === nothing && stdin isa Base.TTY,
                banner=!options["no_banner"] && options["file"] === nothing && stdout isa Base.TTY)
        finally
            input === stdin || close(input)
        end
    catch error
        println(stderr, "ERROR A5000: ", sprint(showerror, error))
        return 1
    end
end

main(args::Vector{String}=ARGS) = cli_main(args)
(@main)(args) = cli_main(args)
