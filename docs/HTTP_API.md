# AiresDB TinyServer HTTP API

Base URL default adalah `http://127.0.0.1:1972`. Request dan response memakai
`application/json`.

## `GET /health`

```json
{"ok":true,"server":"AiresDB","version":"0.1.0"}
```

## `POST /session`

Request `{"user":"root","password":"secret"}`. Response sukses:

```json
{"ok":true,"session":"random-session-id","connection_id":1}
```

## `POST /query`

```json
{"session":"random-session-id","query":"Tampilkan 'Karyawan' -:"}
```

Response memuat `columns`, `types`, `rows`, `row_count`, `elapsed_ms`, database
aktif, dan status transaksi. Decimal, Money, dan exact number dikodekan sebagai
object bertanda seperti `{"type":"decimal","value":"12.34"}`. `NULL` menjadi
JSON `null`.

## `DELETE /session/{id}`

Menutup session dan me-rollback transaksi aktif. Response: `{"ok":true}`.

## Error

```json
{"ok":false,"error":{"code":"A3001","category":"Transaction Conflict","message":"..."}}
```

`Commit Outcome Unknown` dipertahankan sebagai kategori `A3002`.

## Contoh client

- JavaScript: `fetch(url + "/query", {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(payload)})`
- Python: `requests.post(url + "/query", json=payload)`
- PHP: cURL POST dengan body `json_encode($payload)`.
- C#: `HttpClient.PostAsJsonAsync("/query", payload)`.
- Go: `http.NewRequest("POST", url+"/query", jsonBody)`.
- Julia: `HTTP.request("POST", url*"/query", headers, JSON3.write(payload))`.
