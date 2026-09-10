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

Mulai dengan `airesdb server`. Start pertama meminta password `root` dua kali.
Salt dan hash PBKDF2-HMAC-SHA256 dibuat melalui OpenSSL; password asli tidak
disimpan.

Satu login menghasilkan satu AiresDB Session dan connection ID monotonik.
Session menyimpan database terpilih dan transaction state. Logout, expiry, atau
shutdown menutup session; transaction manager me-rollback transaksi aktif.

Server hanya menyediakan empat route. Tidak ada protocol TCP custom, WebSocket,
gRPC, GraphQL, JWT, cookie, role, atau connection pool kompleks.

Loopback adalah default. Binding LAN harus dipilih eksplisit dan menghasilkan
peringatan. Gunakan firewall tepercaya atau HTTPS reverse proxy untuk trafik di
luar host. Stacktrace tidak dikirim kepada client; `--verbose` hanya menulis
detail diagnosis pada stderr server.
