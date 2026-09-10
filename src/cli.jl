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
  .cancel               Batalkan input multiline
  .exit                 Tutup session dan keluar
"""

function _http_json(method::String, url::String, body=nothing; timeout::Real=10)
    headers = ["Accept" => "application/json"]
    payload = UInt8[]
    if body !== nothing
        push!(headers, "Content-Type" => "application/json")
        payload = Vector{UInt8}(codeunits(JSON3.write(body)))
    end
    client = HTTP.Client(; connect_timeout=Float64(timeout))
    response = try
        HTTP.request(client, method, url, headers, payload; status_exception=false, retry=false)
    finally
        close(client)
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

function _close_remote_session(base_url::String, token::String)
    try
        _http_json("DELETE", "$base_url/session/$token"; timeout=3)
    catch
    end
    nothing
end

function run_client(; host::String=DEFAULT_SERVER_HOST, port::Int=DEFAULT_SERVER_PORT,
        user::String="root", password=nothing, ask_password::Bool=true,
        input::IO=stdin, output::IO=stdout, error_output::IO=stderr,
        interactive::Bool=(input isa Base.TTY && output isa Base.TTY),
        banner::Bool=interactive, stop_on_error::Bool=!interactive)
    base_url = "http://$host:$port"
    supplied_password = password === nothing && ask_password ? _read_password(input, output) : something(password, "")
    status, login = try
        _http_json("POST", "$base_url/session", (; user, password=String(supplied_password)))
    catch
        println(error_output, "ERROR A1000: Cannot connect to AiresDB server at $host:$port.\n\nStart the server with:\n\n    airesdb server")
        return 1
    end
    if status != 201 || get(login, "ok", false) !== true
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
                _http_json("POST", "$base_url/query", (; session=token, query=pending))
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
        _close_remote_session(base_url, token)
    end
    exit_code
end

function _parse_cli_options(args::Vector{String})
    options = Dict{String,Any}(
        "host" => DEFAULT_SERVER_HOST, "port" => DEFAULT_SERVER_PORT,
        "user" => "root", "ask_password" => false, "no_banner" => false,
        "file" => nothing, "data_root" => abspath("data"), "verbose" => false,
        "max_request_body" => DEFAULT_MAX_REQUEST_BODY,
        "max_sessions" => DEFAULT_MAX_SESSIONS, "idle_timeout" => DEFAULT_IDLE_TIMEOUT,
    )
    server = !isempty(args) && first(args) == "server"
    index = server ? 2 : 1
    while index <= length(args)
        arg = args[index]
        if arg in ("-h", "--host", "-P", "--port", "-u", "--user", "--file", "--data-root",
                   "--max-request-body", "--max-sessions", "--idle-timeout")
            index < length(args) || throw(ArgumentError("$arg requires a value."))
            index += 1; value = args[index]
            key = arg in ("-h", "--host") ? "host" : arg in ("-P", "--port") ? "port" :
                  arg in ("-u", "--user") ? "user" : replace(arg[3:end], '-' => '_')
            options[key] = key in ("port", "max_request_body", "max_sessions") ? parse(Int, value) :
                           key == "idle_timeout" ? parse(Float64, value) : value
        elseif arg == "-p"
            options["ask_password"] = true
        elseif arg == "--no-banner"
            options["no_banner"] = true
        elseif arg == "--verbose"
            options["verbose"] = true
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
    println(io, "airesdb server [--host HOST] [--port PORT] [--data-root DIR] [--verbose]")
    println(io, "airesdb -u USER -p [-h HOST] [-P PORT] [--file SCRIPT] [--no-banner]")
end

function cli_main(args::Vector{String}=ARGS)
    try
        server_mode, options = _parse_cli_options(args)
        if get(options, "help", false)
            _print_usage(); return 0
        end
        if server_mode
            config = TinyServerConfig(host=options["host"], port=options["port"],
                data_root=abspath(options["data_root"]), max_request_body=options["max_request_body"],
                max_sessions=options["max_sessions"], idle_timeout=options["idle_timeout"],
                verbose=options["verbose"])
            password = _server_password(config)
            server = start_tinyserver(config; password)
            println("AiresDB TinyServer $(AIRESDB_SERVER_VERSION)")
            println("Listening on $(server_url(server))")
            println("Data directory: $(config.data_root)")
            config.host in ("127.0.0.1", "localhost", "::1") || println(stderr,
                "WARNING: AiresDB TinyServer is exposed beyond loopback.\nUse a trusted LAN/firewall or TLS reverse proxy.")
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
