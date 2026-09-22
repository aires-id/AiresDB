module TinyServerTests

using Test
using AiresDB
using AiresDB.Internal
using HTTP
using JSON3
using Random

const TS = AiresDB
const PASSWORD = "correct horse battery staple"

function request_json(method, url, body=nothing; headers=Pair{String,String}[])
    request_headers = ["Content-Type" => "application/json"]
    append!(request_headers, headers)
    payload = body === nothing ? UInt8[] : Vector{UInt8}(codeunits(JSON3.write(body)))
    client = HTTP.Client()
    response = try
        HTTP.request(client, method, url, request_headers, payload; status_exception=false, retry=false)
    finally
        close(client)
    end
    parsed = isempty(response.body) ? Dict{String,Any}() : JSON3.read(String(response.body), Dict{String,Any})
    response.status, parsed
end

function start_fixture(directory; kwargs...)
    last_error = nothing
    for _ in 1:20
        port = rand(25_000:49_000)
        config = TinyServerConfig(; port, data_root=directory, kwargs...)
        try
            return start_tinyserver(config; password=PASSWORD)
        catch error
            last_error = error
            isfile(joinpath(directory, TS.ROOT_CREDENTIAL_FILE)) || continue
        end
    end
    throw(last_error)
end

login(server; user="root", password=PASSWORD) = request_json("POST", server_url(server) * "/session", (; user, password))
query(server, token, text) = request_json("POST", server_url(server) * "/query", (; query=text);
    headers=["Authorization" => "Bearer $token"])

@testset "AiresDB TinyServer and mandatory client" begin
    @test TinyServerConfig().host == "127.0.0.1"
    @test TinyServerConfig().port == 1972
    @test TinyServerConfig().max_header_bytes == 32 * 1024
    @test TinyServerConfig().max_request_body == 8 * 1024 * 1024
    @test TinyServerConfig().max_concurrent_requests == 128
    @test TinyServerConfig().max_sessions == 64
    @test TinyServerConfig().idle_timeout == 600.0
    @test TinyServerConfig().max_session_lifetime == 3600.0
    @test TinyServerConfig().max_result_rows == 100_000
    @test TinyServerConfig().max_query_seconds == 30.0
    @test TinyServerConfig().max_response_body == 64 * 1024 * 1024
    @test TinyServerConfig().auto_checkpoint_wal_bytes == 64 * 1024 * 1024
    @test TinyServerConfig().auto_checkpoint_interval == 300.0
    @test TinyServerConfig().wal_archive_directory === nothing
    @test TinyServerConfig().wal_archive_max_bytes == 0
    @test TS._json_serialized_upper_bound((; text="quote: \" and control: \n")) >=
        ncodeunits(JSON3.write((; text="quote: \" and control: \n")))
    @test_throws AiresError TS._json_response(200,(; value=repeat("x",128));max_bytes=64)
    @test !TinyServerConfig().allow_insecure_network
    @test TinyServerConfig().tls_cert_file === nothing
    @test TinyServerConfig().tls_key_file === nothing
    @test TinyServerConfig().tls_min_version == HTTP.TLS.TLS1_3_VERSION
    @test TinyServerConfig().cors_allowed_origins == String[]
    @test TinyServerConfig().audit_log_file == ".airesdb-audit.jsonl"
    @test TinyServerConfig().audit_max_bytes == 64 * 1024 * 1024
    @test TinyServerConfig().max_failed_logins == 5
    @test TinyServerConfig().max_tracked_login_users == 1024
    @test TS.CLIENT_HTTP_IDLE_TIMEOUT_NS <
        round(Int64, TS.DEFAULT_HTTP_READ_HEADER_TIMEOUT * 1_000_000_000)

    @testset "automatic checkpoints archive before replacing WAL" begin
        mktempdir() do directory
            archive_directory = joinpath(directory,"archive")
            server = start_fixture(directory; auto_checkpoint_wal_bytes=1,
                auto_checkpoint_interval=0, wal_archive_directory=archive_directory)
            try
                _, logged_in = login(server)
                token = String(logged_in["session"])
                @test query(server,token,"Buat 'AutoCheckpoint' -:")[1] == 200
                @test query(server,token,"Buat Tabel 'T' Isi 'ID & Value' Dengan 'ID = I(P) & Value = I' -:")[1] == 200
                @test query(server,token,"Isi Tabel 'T' '1 & 10' -:")[1] == 200
                TS._run_auto_checkpoint!(server)
                archives = list_wal_archives(archive_directory,"AutoCheckpoint")
                @test !isempty(archives)
                @test only(TS.wal_read(joinpath(directory,"AutoCheckpoint.aires")).records).lsn == 1
                @test occursin("auto_checkpoint",read(joinpath(directory,TS.DEFAULT_AUDIT_LOG_FILE),String))
            finally
                stop_tinyserver!(server)
                TS._close_page_stores_under!(directory)
            end
        end
    end

    @testset "failed automatic checkpoints back off without rewriting WAL" begin
        mktempdir() do directory
            archive_directory = joinpath(directory,"archive")
            server = start_fixture(directory; auto_checkpoint_wal_bytes=1,
                auto_checkpoint_interval=0, wal_archive_directory=archive_directory,
                wal_archive_max_bytes=1)
            try
                _, logged_in = login(server)
                token = String(logged_in["session"])
                @test query(server,token,"Buat 'ArchiveBackoff' -:")[1] == 200
                @test query(server,token,"Buat Tabel 'T' Isi 'ID & Value' Dengan 'ID = I(P) & Value = I' -:")[1] == 200
                @test query(server,token,"Isi Tabel 'T' '1 & 10' -:")[1] == 200
                path = joinpath(directory,"ArchiveBackoff.aires")
                before = read(path)
                TS._run_auto_checkpoint!(server)
                retry = only(values(server.checkpoint_failures))
                @test retry[1] == 1
                @test retry[2] > time()
                @test read(path) == before
                TS._run_auto_checkpoint!(server)
                @test only(values(server.checkpoint_failures)) == retry
                audit_lines = split(read(joinpath(directory,TS.DEFAULT_AUDIT_LOG_FILE),String),'\n')
                @test count(line -> occursin("auto_checkpoint_failed",line),audit_lines) == 1
            finally
                stop_tinyserver!(server)
                TS._close_page_stores_under!(directory)
            end
        end
    end

    @testset "CLI replaces server-expired pooled connections" begin
        mktempdir() do directory
            server = start_fixture(directory)
            client = TS._new_http_client()
            token = nothing
            try
                status, logged_in = TS._http_json("POST", server_url(server) * "/session",
                    (; user="root", password=PASSWORD); client)
                @test status == 201
                token = String(logged_in["session"])

                sleep(TS.DEFAULT_HTTP_READ_HEADER_TIMEOUT + 2)

                status, response = TS._http_json("POST", server_url(server) * "/query",
                    (; query="Buat 'AfterIdle' -:"); client,
                    headers=["Authorization" => "Bearer $token"])
                @test status == 200
                @test response["ok"] === true
                @test response["database"] == "AfterIdle"
            finally
                token === nothing || TS._close_remote_session(server_url(server), token; client)
                close(client)
                stop_tinyserver!(server)
            end
        end
    end

    @testset "network binding and query result limits" begin
        mktempdir() do directory
            @test_throws AiresError start_tinyserver(TinyServerConfig(host="0.0.0.0",
                port=rand(25_000:49_000), data_root=directory); password=PASSWORD)
            @test_throws AiresError start_tinyserver(TinyServerConfig(host="0.0.0.0",
                port=rand(25_000:49_000), data_root=directory,
                allow_insecure_network=true); password=PASSWORD)

            server = start_fixture(directory; max_result_rows=1)
            try
                _, logged_in = login(server)
                token = String(logged_in["session"])
                query(server, token, "Buat 'Limited' -:")
                query(server, token, "Buat Tabel 'T' Isi 'Id' Dengan 'Id = I(P)' -:")
                query(server, token, "Isi Tabel 'T' '1' '2' -:")
                status, limited = query(server, token, "Tampilkan 'T' -:")
                @test status == 429
                @test limited["error"]["code"] == "A1005"
                @test limited["error"]["category"] == "Resource Limit"
            finally
                stop_tinyserver!(server)
            end

            server = start_fixture(directory; max_result_rows=1_000, max_query_seconds=1e-9)
            try
                _, logged_in = login(server)
                token = String(logged_in["session"])
                query(server, token, "Pilih 'Limited' -:")
                for index in 3:70
                    insert_status, _ = query(server, token, "Isi Tabel 'T' '$index' -:")
                    @test insert_status == 200
                end
                status, timed_out = query(server, token, "Tampilkan 'T' -:")
                @test status == 429
                @test timed_out["error"]["code"] == "A1005"
                @test timed_out["error"]["category"] == "Resource Limit"
            finally
                stop_tinyserver!(server)
            end
        end
    end

    @testset "browser CORS allowlist" begin
        mktempdir() do directory
            allowed = "https://app.example"
            server = start_fixture(directory; cors_allowed_origins=[allowed, "http://localhost:3000"])
            try
                preflight = HTTP.Request("OPTIONS", "/query", [
                    "Origin" => allowed,
                    "Access-Control-Request-Method" => "POST",
                    "Access-Control-Request-Headers" => "Authorization, Content-Type",
                ])
                response = tinyserver_handler(server, preflight)
                @test response.status == 204
                @test HTTP.header(response.headers, "Access-Control-Allow-Origin", "") == allowed
                @test HTTP.header(response.headers, "Access-Control-Allow-Methods", "") == "GET, POST, DELETE, OPTIONS"
                @test HTTP.header(response.headers, "Access-Control-Allow-Headers", "") == "Authorization, Content-Type"
                @test HTTP.header(response.headers, "Vary", "") == "Origin"

                health = tinyserver_handler(server, HTTP.Request("GET", "/health", ["Origin" => allowed]))
                @test health.status == 200
                @test HTTP.header(health.headers, "Access-Control-Allow-Origin", "") == allowed

                untrusted_health = tinyserver_handler(server,
                    HTTP.Request("GET", "/health", ["Origin" => "https://untrusted.example"]))
                @test untrusted_health.status == 200
                @test isempty(HTTP.header(untrusted_health.headers, "Access-Control-Allow-Origin", ""))

                blocked = tinyserver_handler(server, HTTP.Request("OPTIONS", "/query", [
                    "Origin" => "https://untrusted.example",
                    "Access-Control-Request-Method" => "POST",
                ]))
                @test blocked.status == 403
                @test isempty(HTTP.header(blocked.headers, "Access-Control-Allow-Origin", ""))

                bad_header = tinyserver_handler(server, HTTP.Request("OPTIONS", "/query", [
                    "Origin" => allowed,
                    "Access-Control-Request-Method" => "POST",
                    "Access-Control-Request-Headers" => "X-Unexpected",
                ]))
                @test bad_header.status == 403
                @test HTTP.header(bad_header.headers, "Access-Control-Allow-Origin", "") == allowed
                @test isempty(HTTP.header(bad_header.headers, "Access-Control-Allow-Headers", ""))
            finally
                stop_tinyserver!(server)
            end

            for origin in ("*", "https://app.example/", "ftp://app.example", "https://user@app.example")
                @test_throws ArgumentError start_tinyserver(TinyServerConfig(port=rand(25_000:49_000),
                    data_root=directory, cors_allowed_origins=[origin]); password=PASSWORD)
            end
        end
    end

    @testset "credentials, health, sessions, values, persistence" begin
        mktempdir() do directory
            server = start_fixture(directory)
            base = server_url(server)
            try
                credential = read(joinpath(directory, TS.ROOT_CREDENTIAL_FILE), String)
                @test !occursin(PASSWORD, credential)
                @test occursin("pbkdf2-hmac-sha256", credential)

                status, health = request_json("GET", base * "/health")
                @test status == 200
                @test health["ok"] === true
                @test health["server"] == "AiresDB"
                @test health["version"] == "0.1.0"
                @test !haskey(health, "data_root")

                status, denied = login(server; password="incorrect password")
                @test status == 401
                @test denied["error"]["code"] == "A1001"

                status, logged_in = login(server)
                @test status == 201
                token = String(logged_in["session"])
                @test length(token) == 64
                @test logged_in["connection_id"] == 1

                malformed = HTTP.Request("POST", "/query",
                    ["Content-Type" => "application/json", "Authorization" => "Bearer $token"], UInt8['{'])
                malformed_response = tinyserver_handler(server, malformed)
                @test malformed_response.status == 400
                @test server.sessions[token].active_requests == 0

                status, created = query(server, token, "Buat 'Perusahaan' -:")
                @test status == 200
                @test created["database"] == "Perusahaan"
                @test isfile(joinpath(directory, "Perusahaan.aires"))

                status, _ = query(server, token,
                    "Buat Tabel 'Nilai' Isi 'Id & Nama & Desimal & Uang & Catatan' Dengan 'Id = I(P) & Nama = C & Desimal = D & Uang = U & Catatan = C(50&Null)' -:")
                @test status == 200
                status, _ = query(server, token, "Isi Tabel 'Nilai' '1 & Ångström 東京 & 12.340 & 99.95 & NULL' '2 & Aires & 0.01 & 1.00 & aman' -:")
                @test status == 200
                status, result = query(server, token, "Tampilkan 'Nilai' -:")
                @test status == 200
                @test result["row_count"] == 2
                @test result["rows"][1][2] == "Ångström 東京"
                @test result["rows"][1][3]["type"] == "decimal"
                @test result["rows"][1][3]["value"] == "12.34"
                @test result["rows"][1][4]["type"] == "money"
                @test result["rows"][1][4]["value"] == "99.95"
                @test result["rows"][1][5] === nothing

                status, syntax = query(server, token, "Tampilkan -:")
                @test status == 400
                @test syntax["error"]["code"] == "A2000"
                @test !occursin("Stacktrace", JSON3.write(syntax))

                status, traversal = query(server, token, "Pilih '../../Escape' -:")
                @test status == 400
                @test traversal["ok"] === false
                @test !isfile(joinpath(dirname(directory), "Escape.aires"))

                status, _ = query(server, token, "Transaksi -:")
                @test status == 200
                query(server, token, "Isi Tabel 'Nilai' '3 & Rollback & 3.00 & 3.00 & NULL' -:")
                status, rolled_back = query(server, token, "Kembalikan -:")
                @test status == 200
                @test occursin("dikembalikan", rolled_back["message"])
                _, after_rollback = query(server, token, "Tampilkan 'Nilai' -:")
                @test after_rollback["row_count"] == 2

                query(server, token, "Transaksi -:")
                query(server, token, "Isi Tabel 'Nilai' '3 & Commit & 3.00 & 3.00 & NULL' -:")
                status, committed = query(server, token, "Gabungkan -:")
                @test status == 200
                @test occursin("digabungkan", committed["message"])

                status, databases = query(server, token, ".databases")
                @test status == 200
                @test occursin("Perusahaan.aires", databases["message"])

                status, _ = request_json("DELETE", base * "/session";
                    headers=["Authorization" => "Bearer $token"])
                @test status == 200
                status, invalid = query(server, token, "Tampilkan 'Nilai' -:")
                @test status == 401
                @test invalid["error"]["code"] == "A1002"
            finally
                stop_tinyserver!(server)
            end

            restarted = start_tinyserver(TinyServerConfig(port=rand(25_000:49_000), data_root=directory))
            try
                _, logged_in = login(restarted)
                token = String(logged_in["session"])
                query(restarted, token, "Pilih 'Perusahaan' -:")
                status, persisted = query(restarted, token, "Tampilkan 'Nilai' -:")
                @test status == 200
                @test persisted["row_count"] == 3
            finally
                stop_tinyserver!(restarted)
            end
        end
    end

    @testset "TLS, RBAC, login lockout and audit" begin
        mktempdir() do directory
            config = TinyServerConfig(port=rand(25_000:49_000), data_root=directory,
                max_failed_logins=2, login_lockout_seconds=60.0,
                max_tracked_login_users=3)
            initialize_root_credentials!(config, PASSWORD)
            initialize_user_credentials!(config, "analyst", "reader password"; role=:reader)
            server = start_tinyserver(config)
            try
                status, _ = login(server; user="analyst", password="wrong password")
                @test status == 401
                lock(server.auth_mutex)
                try
                    status, busy = login(server; user="analyst", password="reader password")
                    @test status == 429
                    @test busy["error"]["code"] == "A1005"
                finally
                    unlock(server.auth_mutex)
                end
                status, logged_in = login(server; user="analyst", password="reader password")
                @test status == 201
                reader_token = String(logged_in["session"])

                status, _ = query(server, reader_token, ".databases")
                @test status == 200
                status, denied = query(server, reader_token, "Buat 'ReaderMustNotWrite' -:")
                @test status == 403
                @test denied["error"]["code"] == "A1006"
                status, missing_auth = request_json("POST", server_url(server) * "/query",
                    (; session=reader_token, query=".current"))
                @test status == 401
                @test missing_auth["error"]["code"] == "A1002"
                status, legacy_logout = request_json("DELETE",
                    server_url(server) * "/session/$reader_token";
                    headers=["Authorization" => "Bearer $reader_token"])
                @test status == 404
                @test legacy_logout["error"]["code"] == "A1003"
                status, _ = request_json("DELETE", server_url(server) * "/session")
                @test status == 401
                status, _ = request_json("DELETE", server_url(server) * "/session";
                    headers=["Authorization" => "Bearer $reader_token"])
                @test status == 200

                login(server; password="wrong password")
                login(server; password="wrong password")
                status, locked = login(server)
                @test status == 401
                @test locked["error"]["code"] == "A1001"
                lock(server.mutex) do
                    server.failed_logins["root"] = (2, time() - 1.0)
                end
                status, _ = login(server)
                @test status == 201

                login(server; user="unknown-one", password="wrong password")
                login(server; user="unknown-two", password="wrong password")
                @test length(server.failed_logins) <= config.max_tracked_login_users

                @test TS._required_permission("Pilih 'Database' -:") == :read
                @test TS._required_permission("Explain Pilih '*' Dari 'T' -:") == :read
                @test TS._required_permission("Buat 'Database' -:") == :write

                audit_path = joinpath(directory, ".airesdb-audit.jsonl")
                @test isfile(audit_path)
                audit = read(audit_path, String)
                @test occursin("login_success", audit)
                @test occursin("authorization_denied", audit)
                @test occursin("query_hash", audit)
                @test !occursin("reader password", audit)
                @test !occursin("ReaderMustNotWrite", audit)
                @test !occursin(reader_token, audit)
                @test all(line -> begin
                    record = JSON3.read(line, Dict{String,Any})
                    haskey(record, "timestamp") && haskey(record, "event") && haskey(record, "status")
                end, filter(!isempty, split(audit, '\n')))
            finally
                stop_tinyserver!(server)
            end
        end

        cert = normpath(joinpath(dirname(pathof(HTTP)), "..", "test", "resources", "unittests.crt"))
        key = normpath(joinpath(dirname(pathof(HTTP)), "..", "test", "resources", "unittests.key"))
        @test isfile(cert)
        @test isfile(key)
        mktempdir() do directory
            @test_throws ArgumentError start_tinyserver(TinyServerConfig(
                port=rand(25_000:49_000), data_root=directory, tls_cert_file=cert);
                password=PASSWORD)
            config = TinyServerConfig(host="127.0.0.1", port=rand(25_000:49_000),
                data_root=directory, tls_cert_file=cert, tls_key_file=key)
            server = start_tinyserver(config; password=PASSWORD)
            client = nothing
            try
                @test startswith(server_url(server), "https://")
                # The bundled HTTP fixture certificate is intentionally old on
                # future-dated CI machines; the server-side TLS handshake is
                # what this regression covers.
                tls_config = HTTP.TLS.Config(verify_peer=false, verify_hostname=false,
                    min_version=HTTP.TLS.TLS1_3_VERSION)
                client = HTTP.Client(transport=HTTP.Transport(tls_config=tls_config))
                response = HTTP.request(client, "GET", server_url(server) * "/health";
                    status_exception=false, retry=false)
                @test response.status == 200
            finally
                client === nothing || close(client)
                stop_tinyserver!(server)
            end
        end

        mktempdir() do directory
            config = TinyServerConfig(port=rand(25_000:49_000), data_root=directory,
                idle_timeout=60.0, max_session_lifetime=1.0)
            server = start_tinyserver(config; password=PASSWORD)
            try
                _, logged_in = login(server)
                token = String(logged_in["session"])
                server.sessions[token].created_at = time() - 2.0
                status, expired = query(server, token, ".current")
                @test status == 401
                @test expired["error"]["code"] == "A1002"
            finally
                stop_tinyserver!(server)
            end
        end

        mktempdir() do directory
            audit_path = joinpath(directory, "audit.jsonl")
            config = TinyServerConfig(port=rand(25_000:49_000), data_root=directory,
                audit_log_file=audit_path, audit_max_bytes=1)
            server = start_tinyserver(config; password=PASSWORD)
            try
                login(server)
                @test isfile(audit_path * ".1")
            finally
                stop_tinyserver!(server)
            end
        end

        mktempdir() do directory
            audit_path = joinpath(directory, "unwritable-audit")
            config = TinyServerConfig(port=rand(25_000:49_000), data_root=directory,
                audit_log_file=audit_path)
            server = start_tinyserver(config; password=PASSWORD)
            _, logged_in = login(server)
            token = String(logged_in["session"])
            rm(audit_path; force=true)
            mkpath(audit_path)
            status, body = query(server, token, "Buat 'AuditMustBlock' -:")
            @test status == 503
            @test body["error"]["code"] == "A5001"
            @test !isfile(joinpath(directory, "AuditMustBlock.aires"))
            @test_throws AiresError stop_tinyserver!(server)
            @test server.stopped
        end
    end

    @testset "rollback on disconnect, conflict and error identity" begin
        mktempdir() do directory
            server = start_fixture(directory)
            try
                _, first_login = login(server); first = String(first_login["session"])
                query(server, first, "Buat 'Bank' -:")
                query(server, first, "Buat Tabel 'Rekening' Isi 'Id & Saldo' Dengan 'Id = I(P) & Saldo = U' -:")
                query(server, first, "Isi Tabel 'Rekening' '1 & 100.00' -:")

                _, second_login = login(server); second = String(second_login["session"])
                query(server, second, "Pilih 'Bank' -:")
                query(server, first, "Transaksi -:"); query(server, second, "Transaksi -:")
                query(server, first, "Tabel_Upt 'Rekening' Isi 'Saldo = 110.00' Dengan 'Id = 1' -:")
                query(server, second, "Tabel_Upt 'Rekening' Isi 'Saldo = 120.00' Dengan 'Id = 1' -:")
                commit_status, _ = query(server, first, "Gabungkan -:")
                @test commit_status == 200
                status, conflict = query(server, second, "Gabungkan -:")
                @test status == 409
                @test conflict["error"]["code"] == "A3001"
                @test conflict["error"]["category"] == "Transaction Conflict"

                _, third_login = login(server); third = String(third_login["session"])
                query(server, third, "Pilih 'Bank' -:")
                query(server, third, "Transaksi -:")
                query(server, third, "Isi Tabel 'Rekening' '2 & 50.00' -:")
                request_json("DELETE", server_url(server) * "/session";
                    headers=["Authorization" => "Bearer $third"])
                _, check_login = login(server); check = String(check_login["session"])
                query(server, check, "Pilih 'Bank' -:")
                _, rows = query(server, check, "Tampilkan 'Rekening' -:")
                @test rows["row_count"] == 1

                response = TS._error_response(AiresError("Commit Outcome Unknown", "Durability acknowledgement lost."))
                body = JSON3.read(String(response.body), Dict{String,Any})
                @test response.status == 503
                @test body["error"]["code"] == "A3002"
                @test body["error"]["category"] == "Commit Outcome Unknown"
            finally
                stop_tinyserver!(server)
            end

            expiring = start_tinyserver(TinyServerConfig(port=rand(25_000:49_000),
                data_root=directory, idle_timeout=0.1))
            try
                _, opened = login(expiring); token = String(opened["session"])
                query(expiring, token, "Buat 'Expiry' -:")
                query(expiring, token, "Buat Tabel 'T' Isi 'Id' Dengan 'Id = I(P)' -:")
                query(expiring, token, "Transaksi -:")
                query(expiring, token, "Isi Tabel 'T' '1' -:")
                sleep(0.35)
                @test isempty(expiring.sessions)
                _, reopened = login(expiring); replacement = String(reopened["session"])
                query(expiring, replacement, "Pilih 'Expiry' -:")
                _, rows = query(expiring, replacement, "Tampilkan 'T' -:")
                @test rows["row_count"] == 0
            finally
                stop_tinyserver!(expiring)
            end
        end
    end

    @testset "resource limits and expiry" begin
        mktempdir() do directory
            server = start_fixture(directory; max_sessions=1, idle_timeout=10.0, max_request_body=128)
            try
                _, first_login = login(server); token = String(first_login["session"])
                status, limited = login(server)
                @test status == 503
                @test limited["error"]["code"] == "A1005"
                server.sessions[token].last_activity = time() - 11.0
                status, expired = query(server, token, ".current")
                @test status == 401
                @test expired["error"]["code"] == "A1002"
                status, replacement = login(server)
                @test status == 201

                request = HTTP.Request("POST", "/query", ["Content-Type" => "application/json"], fill(UInt8('x'), 129))
                response = tinyserver_handler(server, request)
                @test response.status == 413

                malformed = HTTP.Request("POST", "/query", ["Content-Type" => "application/json"], UInt8['{'])
                response = tinyserver_handler(server, malformed)
                @test response.status == 401
                invalid = HTTP.Request("POST", "/query",
                    ["Content-Type" => "application/json", "Authorization" => "Bearer invalid"], UInt8['{'])
                response = tinyserver_handler(server, invalid)
                @test response.status == 401

                lock(server.mutex) do
                    server.active_requests = server.config.max_concurrent_requests
                end
                response = tinyserver_handler(server, HTTP.Request("GET", "/health"))
                @test response.status == 503
                @test HTTP.header(response.headers, "Retry-After", "") == "1"
                @test response.close
                @test server.active_requests == server.config.max_concurrent_requests
                lock(server.mutex) do
                    server.active_requests = 0
                end
            finally
                stop_tinyserver!(server)
            end
        end


        mktempdir() do directory
            server = start_fixture(directory; max_query_memory_bytes=512,
                max_query_spill_bytes=512, max_result_rows=1_000)
            try
                _, logged_in = login(server)
                token = String(logged_in["session"])
                query(server, token, "Buat 'MemoryLimited' -:")
                query(server, token, "Buat Tabel 'T' Isi 'Id & Payload' Dengan 'Id = I(P) & Payload = C(1000)' -:")
                query(server, token, "Isi Tabel 'T' '1 & $(repeat("x",400))' -:")
                status, limited = query(server, token, "Tampilkan 'T' -:")
                @test status == 429
                @test limited["error"]["category"] == "Resource Limit"
            finally
                stop_tinyserver!(server)
            end
        end
    end

    @testset "CLI is server-only, multiline and banner rules" begin
        server_mode, parsed = TS._parse_cli_options(["server", "--max-header-bytes", "16384",
            "--max-concurrent-requests", "32", "--max-session-lifetime", "7200",
            "--max-query-seconds", "12.5", "--audit-max-bytes", "4096",
            "--max-failed-logins", "3", "--login-lockout-seconds", "90",
            "--auto-checkpoint-wal-bytes", "1048576", "--auto-checkpoint-interval", "45",
            "--wal-archive-directory", "D:/archive", "--wal-archive-max-bytes", "4096"])
        @test server_mode
        @test parsed["max_header_bytes"] === 16384
        @test parsed["max_concurrent_requests"] === 32
        @test parsed["max_session_lifetime"] === 7200.0
        @test parsed["max_query_seconds"] === 12.5
        @test parsed["audit_max_bytes"] === 4096
        @test parsed["max_failed_logins"] === 3
        @test parsed["login_lockout_seconds"] === 90.0
        @test parsed["auto_checkpoint_wal_bytes"] === 1_048_576
        @test parsed["auto_checkpoint_interval"] === 45.0
        @test parsed["wal_archive_directory"] == "D:/archive"
        @test parsed["wal_archive_max_bytes"] === 4096
        _, parsed = TS._parse_cli_options(["server", "--cors-allow-origin", "https://app.example",
            "--cors-allow-origin", "http://localhost:3000"])
        @test parsed["cors_allowed_origins"] == ["https://app.example", "http://localhost:3000"]
        @test_throws ArgumentError TS._parse_cli_options(["server", "--allow-insecure-network"])

        mktempdir() do directory
            unavailable_port = rand(50_000:59_000)
            output = IOBuffer(); errors = IOBuffer()
            code = run_client(port=unavailable_port, password=PASSWORD, ask_password=false,
                input=IOBuffer(".exit\n"), output=output, error_output=errors,
                interactive=false, banner=false)
            @test code == 1
            @test occursin("ERROR A1000", String(take!(errors)))
            @test isempty(readdir(directory))

            project = dirname(@__DIR__)
            launcher = joinpath(project, "bin", "airesdb.jl")
            process_out = IOBuffer(); process_err = IOBuffer()
            command = Cmd(`$(Base.julia_cmd()) --startup-file=no --project=$project $launcher -P $unavailable_port -u root -p`; dir=directory)
            process = run(pipeline(ignorestatus(command), stdin=IOBuffer("no server password\n"),
                stdout=process_out, stderr=process_err))
            @test process.exitcode != 0
            @test occursin("ERROR A1000", String(take!(process_err)))
            @test isempty(readdir(directory))

            server = start_fixture(directory)
            try
                output = IOBuffer(); errors = IOBuffer()
                source = "Buat 'CLI' -:\nBuat Tabel 'T' Isi 'Id & Nama' Dengan 'Id = I(P) & Nama = C' -:\nIsi Tabel 'T' '1 & Server' -:\nPilih 'Nama'\nDari 'T'\n-:\n.exit\n"
                code = run_client(port=server.config.port, password=PASSWORD, ask_password=false,
                    input=IOBuffer(source), output=output, error_output=errors,
                    interactive=true, banner=false)
                text = String(take!(output))
                @test code == 0
                @test isempty(String(take!(errors)))
                @test occursin("AiresDB [(none)]>", text)
                @test occursin("AiresDB [CLI]>", text)
                @test occursin("->", text)
                @test occursin("Server", text)
                @test !occursin(".***************", text)

                output = IOBuffer()
                code = run_client(port=server.config.port, password=PASSWORD, ask_password=false,
                    input=IOBuffer(".exit\n"), output=output, error_output=IOBuffer(),
                    interactive=false)
                @test code == 0
                @test isempty(String(take!(output)))
            finally
                stop_tinyserver!(server)
            end
        end
    end

    @testset "no embedded fallback in official CLI source" begin
        source = read(joinpath(dirname(@__DIR__), "src", "cli.jl"), String)
        @test !occursin("Session(", source)
        @test !occursin("Engine(", source)
        @test !occursin("open_database!", source)
        @test !occursin(".aires\"", source)
        @test !occursin("--root", source)
        @test occursin("/session", source)
        @test occursin("/query", source)
        project = dirname(@__DIR__)
        help = read(`$(Base.julia_cmd()) --startup-file=no --project=$project -m AiresDB --help`, String)
        @test occursin("airesdb server", help)
        @test !occursin("--root", help)
        public_surface = read(`$(Base.julia_cmd()) --startup-file=no --project=$project -e "using AiresDB; print(isdefined(Main, :Engine), ',', isdefined(Main, :Session))"`, String)
        @test public_surface == "false,false"
    end
end

end
