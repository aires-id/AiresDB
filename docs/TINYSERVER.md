# AiresDB TinyServer

TinyServer adalah satu-satunya process pengguna yang memiliki AiresDB Engine dan
file database.

| Konfigurasi | Default |
|---|---:|
| Host | `127.0.0.1` |
| Port | `1972` |
| Data root | `./data` |
| Request body | 8 MiB |
| Active sessions | 64 |
| Idle timeout | 600 detik |
| Query result rows | 100.000 |
| Query execution time | 30 detik |
| JSON response body | 64 MiB |
| HTTP header timeout | 10 detik |
| TLS minimum | TLS 1.3 bila TLS diaktifkan |
| Login lockout | 5 kegagalan / 60 detik |
| Audit log | `.airesdb-audit.jsonl` |

Mulai dengan `airesdb server`. Start pertama meminta password `root` dua kali.
Salt dan hash PBKDF2-HMAC-SHA256 dibuat melalui OpenSSL; password asli tidak
disimpan.

Satu login menghasilkan satu AiresDB Session dan connection ID monotonik.
Session menyimpan database terpilih dan transaction state. Logout, expiry, atau
shutdown menutup session; transaction manager me-rollback transaksi aktif.

Server hanya menyediakan empat route. Tidak ada protocol TCP custom, WebSocket,
gRPC, GraphQL, JWT, cookie, atau connection pool kompleks. Authentication
session memakai bearer token; token boleh dikirim lewat header
`Authorization: Bearer ...` dan tidak boleh ditaruh di URL.

Loopback adalah default. Binding non-loopback ditolak kecuali server dijalankan
dengan TLS certificate dan private key:

```text
airesdb server --host 0.0.0.0 --tls-cert-file server.crt --tls-key-file server.key
airesdb -u root -p --host db.example --tls --tls-ca-file ca.crt
```

TLS native menolak konfigurasi certificate/key yang tidak lengkap dan hanya
mengizinkan TLS 1.3 atau lebih baru. `--allow-insecure-network` hanya untuk
deployment di belakang reverse proxy tepercaya yang memang mengakhiri TLS;
jangan gunakan untuk mengekspos TinyServer langsung ke LAN atau internet.

Credential file format 2 menyimpan user root sebagai `admin` dan user tambahan
bisa dibuat dari Julia:

```julia
initialize_user_credentials!(TinyServerConfig(data_root="data"),
    "analyst", "password-minimal-8"; role=:reader)
```

Role `reader` hanya boleh menjalankan query baca dan metadata; role `admin`
diperlukan untuk perubahan data, transaksi, checkpoint, vacuum, dan compact.
Login gagal dilimit dengan lockout per user. Audit JSONL mencatat login,
logout, authorization denial, query action, status, dan SHA-256 query tanpa
menyimpan password, bearer token, atau teks query. Lindungi dan rotasikan file
audit menggunakan kebijakan host/operator.

Setiap query dibatasi waktu eksekusi, jumlah row hasil, dan ukuran response JSON;
ubah batas dengan `--max-query-seconds`, `--max-result-rows`, dan
`--max-response-body`. Stacktrace tidak dikirim kepada client; `--verbose` hanya
menulis detail diagnosis pada stderr server.
