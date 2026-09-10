# Security Policy

## Supported version

AiresDB 0.1.x adalah jalur yang saat ini dipelihara.

## Reporting a vulnerability

Laporkan kerentanan melalui **Private vulnerability reporting** pada tab
Security repository GitHub. Jangan membuka issue publik untuk laporan yang
memuat exploit, credential, data privat, atau langkah reproduksi yang berisiko.

Sertakan versi Julia dan AiresDB, sistem operasi, dampak, langkah reproduksi
minimal, serta apakah masalah menyentuh parser, WAL, recovery, MVCC, atau format
page. Jangan menyertakan database produksi atau secret asli.

## TinyServer

TinyServer bind ke `127.0.0.1:1972` secara default. Binding non-loopback harus
dipilih eksplisit dan memerlukan LAN/firewall tepercaya atau TLS reverse proxy.
HTTP plaintext tidak ditujukan untuk internet publik.

Password `root` disimpan sebagai hash PBKDF2-HMAC-SHA256 dengan salt acak melalui
OpenSSL. Token session berasal dari random source sistem operasi. Health endpoint
tidak mengungkap data root, path WAL, username OS, atau internal process.

Client tidak pernah membuka `.aires`, `.aires.pages`, atau `.aires.lock`. Laporkan
sebagai kerentanan bila CLI dapat mengakses database tanpa TinyServer.
