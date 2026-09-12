# AiresDB TinyServer

TinyServer adalah satu-satunya process pengguna yang memiliki AiresDB Engine dan
file database.

| Konfigurasi | Default |
|---|---:|
| Host | `127.0.0.1` |
| Port | `1972` |
| Data root | `./data` |
| HTTP header | 32 KiB |
| Request body | 8 MiB |
| Concurrent requests | 128 |
| Active sessions | 64 |
| Idle timeout | 600 detik |
| Maximum session lifetime | 3.600 detik |
| Query result rows | 100.000 |
| Query execution time | 30 detik |
| JSON response body | 64 MiB |
| HTTP header timeout | 10 detik |
| TLS minimum | TLS 1.3 bila TLS diaktifkan |
| Login lockout | 5 kegagalan / 60 detik |
| Audit log | `.airesdb-audit.jsonl` |
| Audit rotation | 64 MiB, satu file `.1` |

Mulai dengan `airesdb server`. Start pertama meminta password `root` dua kali.
Salt dan hash PBKDF2-HMAC-SHA256 dibuat melalui OpenSSL; password asli tidak
disimpan.

Satu login menghasilkan satu AiresDB Session dan connection ID monotonik.
Session menyimpan database terpilih dan transaction state. Logout, expiry, atau
shutdown menutup session; transaction manager me-rollback transaksi aktif.

Server hanya menyediakan empat route. Tidak ada protocol TCP custom, WebSocket,
gRPC, GraphQL, JWT, cookie, atau connection pool kompleks. Authentication
session memakai bearer token; token wajib dikirim lewat header
`Authorization: Bearer ...` dan tidak boleh ditaruh di URL.

Loopback adalah default. Binding non-loopback ditolak kecuali server dijalankan
dengan TLS certificate dan private key:

```text
airesdb server --host 0.0.0.0 --tls-cert-file server.crt --tls-key-file server.key
airesdb -u root -p --host db.example --tls --tls-ca-file ca.crt
```

TLS native menolak konfigurasi certificate/key yang tidak lengkap dan hanya
mengizinkan TLS 1.3 atau lebih baru. Tidak ada insecure bypass untuk binding
non-loopback. Reverse proxy pada host yang sama harus mengakses listener
loopback; deployment antar-host tetap wajib memakai TLS native.

Credential file format 2 menyimpan user root sebagai `admin` dan user tambahan
bisa dibuat dari Julia:

```julia
initialize_user_credentials!(TinyServerConfig(data_root="data"),
    "analyst", "password-minimal-8"; role=:reader)
```

Role `reader` hanya boleh menjalankan query baca dan metadata; role `admin`
diperlukan untuk perubahan data, transaksi, checkpoint, vacuum, dan compact.
Login gagal dilimit dengan lockout per user dan jumlah username yang dilacak
dibatasi. Request aktif dan ukuran header juga dibatasi untuk menahan antrean
kerja serta input metadata yang berlebihan. Session mempunyai idle timeout
serta umur absolut. Audit JSONL
mencatat login, logout, authorization denial, query action, status, dan SHA-256
query serta connection ID tanpa menyimpan password, bearer token, atau teks
query. Log berotasi ke `.1` saat mencapai batas ukuran. Server menolak request
bila audit log tidak dapat ditulis; bila mutasi sudah selesai tetapi
acknowledgement gagal, responsnya `Commit Outcome Unknown` dan state harus
diperiksa sebelum retry. Gunakan collector eksternal bila membutuhkan retensi
panjang.

Setiap query dibatasi waktu eksekusi, jumlah row hasil, dan ukuran response JSON;
ubah batas dengan `--max-query-seconds`, `--max-result-rows`, dan
`--max-response-body`. Stacktrace tidak dikirim kepada client; `--verbose` hanya
menulis detail diagnosis pada stderr server.
