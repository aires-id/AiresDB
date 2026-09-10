using HTTP
using JSON3

const BASE_URL = get(ENV, "AIRESDB_URL", "http://127.0.0.1:1972")
const PASSWORD = get(ENV, "AIRESDB_PASSWORD", "")

isempty(PASSWORD) && error("Set AIRESDB_PASSWORD to the TinyServer root password")

function request(method::String, path::String, body=nothing)
    headers = ["Accept" => "application/json"]
    payload = UInt8[]
    if body !== nothing
        push!(headers, "Content-Type" => "application/json")
        payload = Vector{UInt8}(codeunits(JSON3.write(body)))
    end
    response = HTTP.request(method, BASE_URL * path, headers, payload; status_exception=false)
    result = JSON3.read(String(response.body), Dict{String,Any})
    get(result, "ok", false) || error(JSON3.write(result))
    result
end

login() = request("POST", "/session", (; user="root", password=PASSWORD))["session"]
query(session, statement) = request("POST", "/query", (; session, query=statement))

first_session = login()
second_session = login()

try
    query(first_session, "Buat 'HTTPDemo' -:")
    query(first_session, "Buat Tabel 'Rekening' Isi 'ID & Saldo' Dengan 'ID = I(P) & Saldo = I' -:")
    query(first_session, "Isi Tabel 'Rekening' '1 & 100' '2 & 200' -:")
    query(second_session, "Pilih 'HTTPDemo' -:")

    query(first_session, "Transaksi -:")
    query(first_session, "Tabel_Upt 'Rekening' Isi 'Saldo = Saldo - 25' Dengan 'ID = 1' -:")
    query(first_session, "Tabel_Upt 'Rekening' Isi 'Saldo = Saldo + 25' Dengan 'ID = 2' -:")
    query(first_session, "Gabungkan -:")

    result = query(second_session, "Pilih 'ID & Saldo' Dari 'Rekening' M: 'ID Atas' -:")
    @assert result["rows"] == Any[Any[1, 75], Any[2, 225]]
    println(JSON3.pretty(result))
finally
    request("DELETE", "/session/$(first_session)")
    request("DELETE", "/session/$(second_session)")
end
