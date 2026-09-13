<p align="center">
  <img src="AiresDB.png" alt="Logo AiresDB" width="180">
</p>

<h1 align="center">AiresDB v0.1.0</h1>

<p align="center">
  Database transaksional dengan AiresQL berbahasa Indonesia.<br>
  <strong>Ringan. Cepat. Mudah. Murah.</strong>
</p>

<p align="center">
  <img alt="Versi 0.1.0" src="https://img.shields.io/badge/version-0.1.0-ffc107">
  <img alt="Julia 1.12" src="https://img.shields.io/badge/Julia-1.12-9558b2">
  <img alt="Lisensi NCSA" src="https://img.shields.io/badge/license-NCSA-blue">
</p>

AiresDB adalah database server karya **Aires Zam Wibisono**. AiresDB menyimpan
data dalam file `.aires`, menjalankan transaksi serializable berbasis MVCC, dan
menyediakan antarmuka resmi melalui **TinyServer HTTP/JSON** serta monitor CLI.

> [!IMPORTANT]
> **v0.1.0 adalah technical preview.** Ia cocok untuk evaluasi, pembelajaran,
> prototipe, dan aplikasi internal berisiko rendah yang memiliki backup serta
> pengujian sendiri. Hasil SDEBO menunjukkan fondasi correctness dan recovery
> yang kuat, tetapi rilis ini belum direkomendasikan untuk data finansial
> produksi. Lihat [status dan batasan](#status-v010) sebelum melakukan deployment.

## Mengapa AiresDB

- **AiresQL berbahasa Indonesia** dengan terminator `-:` dan input multiline;
- **ACID dan durability** melalui embedded WAL, checksum, OS sync, checkpoint,
  native backup/restore, serta torn-tail recovery;
- **optimistic serializable MVCC**, read-your-writes, dan first-committer-wins;
- **storage page-based ARSP-4** dengan page 8 KiB, slotted heap, RID, bounded
  Clock buffer pool, dan persistent B+Tree;
- **tipe exact** untuk Decimal dan Money agar nilai tidak melewati konversi
  floating-point pada API JSON;
- **satu jalur akses resmi** melalui TinyServer, sehingga client tidak membuka
  file database sebagai fallback;
- **resource guard server** untuk membatasi waktu query, jumlah row hasil, dan
  ukuran response JSON, memori query, dan byte spill sementara;
- **optimizer tahap berikutnya** dengan multi-join greedy order, statistik tabel,
  external hash join spill, serta `EXPLAIN` read-only;
- **suite correctness, recovery, concurrency, dan benchmark** yang dapat
  dijalankan ulang dari repository.

## Mulai cepat

AiresDB membutuhkan **Julia 1.12**.

> **Instalasi satu perintah:** setelah rilis tersedia di General, pasang app
> `airesdb` dengan `Pkg.Apps.add`. App ini sekaligus menyediakan package dan
> executable CLI.

```sh
julia -e 'using Pkg; Pkg.Apps.add("AiresDB")'
```

Sebelum masuk General, gunakan URL GitHub:

```sh
julia -e 'using Pkg; Pkg.Apps.add(url="https://github.com/aires-id/AiresDB")'
```

Jalankan server di terminal pertama:

```sh
airesdb server
```

Pada start pertama, server meminta password untuk user `root`. TinyServer bind
ke `127.0.0.1:1972` dan menyimpan data di `./data` secara default.

Buka terminal kedua untuk menjalankan monitor dengan command yang tetap:

```sh
airesdb -u root -p
```

Linux/macOS perlu menambahkan `~/.julia/bin` ke `PATH`. Windows CMD dapat
menambahkan `%USERPROFILE%\.julia\bin` untuk sesi terminal saat ini:

```bat
set "PATH=%PATH%;%USERPROFILE%\.julia\bin"
```

Dukungan app di Julia 1.12 masih berstatus eksperimental.

Selama paket belum masuk General, instalasi langsung dari GitHub tersedia di
[petunjuk instalasi](INSTALL.md). Untuk pengembangan dari checkout:

```sh
julia --project=. -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"
julia --project=. -m AiresDB server
```

## Backup dan restore native

Backup native mengambil prefix WAL yang konsisten di bawah lock, menghitung
SHA-256, lalu mempublikasikannya secara atomic. Sidecar `.aires.pages` tidak
disalin karena hanya cache turunan; sidecar akan dibangun ulang saat database
hasil restore dibuka.

Untuk job maintenance atau cron, gunakan API path-based:

```sh
julia --project=. -e 'using AiresDB; AiresDB.backup_database!("./data", "Perusahaan", "./backup/Perusahaan.aires.bak")'
julia --project=. -e 'using AiresDB; AiresDB.restore_database!("./data-restored", "Perusahaan", "./backup/Perusahaan.aires.bak")'
```

Restore ke database yang sudah ada membutuhkan `overwrite=true` dan seluruh
session/proses yang memakai target harus dihentikan terlebih dahulu:

```julia
using AiresDB
AiresDB.restore_database!("./data", "Perusahaan", "./backup/Perusahaan.aires.bak";
    overwrite=true)
```

Hasil backup sudah divalidasi dari header, ukuran, checksum, dan seluruh frame
WAL sebelum dianggap berhasil. Nama database di dalam backup harus sama dengan
nama target restore; ini mencegah backup tertukar secara diam-diam.

Untuk reclaim fisik `.aires.pages` setelah banyak update/delete, jalankan
maintenance saat hanya ada satu session dan satu proses AiresDB yang aktif:

```julia
using AiresDB
AiresDB.compact_page_store!("./data", "Perusahaan")
```

`vacuum!`/`.vacuum` tetap membersihkan history MVCC secara logis. Compact fisik
adalah operasi maintenance terpisah dan dapat mengganti sidecar dari WAL yang
authoritative.

## AiresQL dalam satu menit

Setiap statement diakhiri dengan `-:`.

```text
Buat 'Perusahaan' -:
Pilih 'Perusahaan' -:

Buat Tabel 'Karyawan'
Isi 'No & Nama & Gaji & Email & Divisi'
Dengan 'No = I(P) & Nama = C(225&Not Null) & Gaji = U & Email = C(225&N) & Divisi = C'
Auto_No -:

Isi Tabel 'Karyawan'
'Aires & 7500000 & aires@example.test & Teknik'
'Fami & 6500000 & fami@example.test & Teknik' -:

Pilih 'Nama & Gaji'
Dari 'Karyawan'
Dengan 'Gaji > 6000000'
M: 'Gaji Bawah' -:

Transaksi -:
Tabel_Upt 'Karyawan' Isi 'Gaji = 9000000' Dengan 'No = 1' -:
Gabungkan -:
```

Lihat [referensi AiresQL](docs/AIRESQL.md) dan
[contoh script](examples/demo.txt).

## Arsitektur

```text
CLI / Browser / Python / PHP / C# / Go / Java / Julia
                            |
                        HTTP/JSON
                            |
                            v
               AiresDB TinyServer :1972
                            |
                  one Engine, many Sessions
                            |
          MVCC + WAL + ARSP-4 + PageStore + B+Tree
                            |
                           Disk
```

Client resmi tidak membuka `.aires`, `.aires.pages`, atau `.aires.lock`. Jika
TinyServer tidak tersedia, client berhenti dengan error koneksi; tidak ada
fallback embedded. API engine berlevel rendah berada di `AiresDB.Internal` untuk
test dan benchmark, bukan kontrak aplikasi yang stabil.

Empat endpoint publik tersedia pada v0.1.0:

| Method | Endpoint | Fungsi |
|---|---|---|
| `GET` | `/health` | Status dan versi server |
| `POST` | `/session` | Login dan membuat session |
| `POST` | `/query` | Menjalankan AiresQL pada session |
| `DELETE` | `/session/{id}` | Menutup session dan rollback transaksi aktif |

Nilai Decimal dan Money dikirim sebagai object bertanda, misalnya
`{"type":"decimal","value":"12.34"}`, sementara `NULL` menjadi JSON `null`.
Contract lengkap dan contoh client tersedia di
[dokumentasi HTTP API](docs/HTTP_API.md).

## Hasil SDEBO-S750

Pengujian **SDEBO 1.0 / SDEBO-S750** dijalankan pada 9–11 September 2026 terhadap
AiresDB 0.1.0 dan Firebird 5.0.4.1812. Dataset logis yang sama berisi 750.000 row
dengan seed `1999`; kedua engine memakai mode embedded dan durability sinkron
pada host Windows 10, Intel Core i5-2400S 4 core/4 thread, RAM 8 GiB, dan SSD.

| Engine | Skor tertimbang | Kelas | Medium Office | Small Bank Technical |
|---|---:|---|---|---|
| **AiresDB 0.1.0** | **3,74 / 4,00** | Excellent | PASS | PASS |
| Firebird 5.0.4.1812 | 3,93 / 4,00 | Excellent | PASS | PASS |

Ringkasan median dari lima run performa:

| Workload | Metrik | AiresDB | Firebird | Hasil relatif |
|---|---|---:|---:|---|
| Q01 bulk load | row/detik, lebih tinggi lebih baik | **23.102,86** | 1.808,66 | AiresDB 12,77× |
| Q02 point lookup | p95 ms, lebih rendah lebih baik | 2,5221 | **0,4062** | Firebird 6,21× |
| Q03 range query | p95 ms, lebih rendah lebih baik | 2,5378 | **0,3107** | Firebird 8,17× |
| Q04 ordered query | p95 ms, lebih rendah lebih baik | **2,4700** | 3,8637 | AiresDB 1,56× |
| Q05 aggregate | p50 ms, lebih rendah lebih baik | 1.094,0640 | **995,9056** | Firebird 1,10× |
| Q06 join | p50 ms, lebih rendah lebih baik | 27,8837 | **5,4890** | Firebird 5,08× |
| Q07 full scan | row/detik, lebih tinggi lebih baik | **159.818,51** | 41.399,76 | AiresDB 3,86× |
| T01 insert transaction | p95 ms, lebih rendah lebih baik | 3,6527 | **1,9083** | Firebird 1,91× |
| T02 update transaction | p95 ms, lebih rendah lebih baik | 3,4907 | **1,6259** | Firebird 2,15× |

Gate correctness AiresDB lulus untuk 1.000 transfer atomik plus lima crash
boundary, 200 siklus rollback, concurrency empat worker tanpa lost update, lima
process-kill recovery, reopen/index verification, dan tiga skenario korupsi tanpa
silent mismatch. Soak 15 menit menyelesaikan 20.298 operasi tanpa error; memory
growth tercatat 13,90% dan memperoleh grade B.

Interpretasi hasil ini mempunyai batas penting:

- host mempunyai 4 logical CPU, di bawah rekomendasi dokumen 8 thread;
- hard power-off VM tidak tersedia, sehingga tiap engine diuji dengan lima
  external process termination;
- R01 dijalankan sebelum backup native tersedia sehingga memakai offline
  checkpoint dan file copy; API native di source tree sekarang memvalidasi WAL
  dan restore secara atomic;
- percobaan T05 awal yang tidak diberi skor menemukan gangguan lifecycle ketika
  beberapa `Engine` terpisah dalam satu proses ditutup saat worker lain commit;
  ownership lease PageStore dan regression test sekarang menutup kasus itu;
- label “Small Bank Technical PASS” adalah gate teknis SDEBO, bukan sertifikasi,
  audit keamanan, atau persetujuan penggunaan perbankan.

Bukti publik yang ringan disimpan di repository:

- [laporan PDF](Standard%20Database%20for%20Banking%20and%20Office%20Test/SDEBO-S750-AiresDB-vs-Firebird-20260909/SDEBO_Report.pdf);
- [hasil terstruktur JSON](Standard%20Database%20for%20Banking%20and%20Office%20Test/SDEBO-S750-AiresDB-vs-Firebird-20260909/result.json) dan
  [CSV](Standard%20Database%20for%20Banking%20and%20Office%20Test/SDEBO-S750-AiresDB-vs-Firebird-20260909/result.csv);
- [environment](Standard%20Database%20for%20Banking%20and%20Office%20Test/SDEBO-S750-AiresDB-vs-Firebird-20260909/environment.json),
  [raw metrics](Standard%20Database%20for%20Banking%20and%20Office%20Test/SDEBO-S750-AiresDB-vs-Firebird-20260909/raw/), dan
  [recovery evidence](Standard%20Database%20for%20Banking%20and%20Office%20Test/SDEBO-S750-AiresDB-vs-Firebird-20260909/recovery/);
- [spesifikasi SDEBO 1.0](Standard%20Database%20for%20Banking%20and%20Office%20Test/SDEBO_Test_Specification_v1.0_publication.docx).

Database kerja, backup, dataset hasil generate, dan file sementara berukuran
besar sengaja tidak dilacak Git. Semua bukti memiliki daftar SHA-256 dan dapat
direproduksi memakai [harness SDEBO](Standard%20Database%20for%20Banking%20and%20Office%20Test/harness/).

## Status v0.1.0

Gunakan rilis ini dengan satu shared `Engine` per data root di dalam proses
server, backup native yang sudah diuji restore, penyimpanan lokal yang
mendukung durable flush, dan TinyServer pada loopback. TinyServer kini
menyediakan TLS native (TLS 1.3+), role `admin`/`reader`, login lockout, dan
audit JSONL fail-closed. Akses LAN/public wajib memakai certificate dan private
key; tidak tersedia insecure bypass untuk binding non-loopback.

Pekerjaan utama sebelum rekomendasi produksi finansial:

1. memperluas stress concurrency, fault injection, hard power-off, dan audit
   eksternal;
2. menambah rotasi credential, centralized audit retention, mTLS opsional, dan
   hardening jaringan lanjutan;
3. menekan penggunaan memory dan tail latency pada soak serta mixed workload;
4. memperluas planner, physical operator, dan observability I/O.

Binary format internal delta/checkpoint belum menjadi API eksternal yang stabil,
dan migrasi format legacy bersifat satu arah. Baca
[catatan rilis v0.1.0](docs/RELEASE-v0.1.0.md) sebelum upgrade serta
[roadmap](docs/ROADMAP.md) untuk pekerjaan berikutnya.

## Keamanan dan operasi

TinyServer bind ke loopback secara default. Binding non-loopback memerlukan
TLS native:

```text
airesdb server --host 0.0.0.0 --tls-cert-file server.crt --tls-key-file server.key
airesdb -u root -p --host db.example --tls --tls-ca-file ca.crt
```

Tanpa TLS, binding non-loopback selalu ditolak. Reverse proxy lokal harus
mengakses listener loopback; koneksi antar-host tetap wajib memakai TLS native.

Password `root` disimpan sebagai hash PBKDF2-HMAC-SHA256 dengan salt acak;
credential file mendukung role `admin` dan `reader`. Reader hanya dapat
menjalankan query baca/metadata, sedangkan mutasi dan maintenance memerlukan
admin. Login gagal dilimit dengan lockout per user, session memiliki idle dan
umur absolut, request aktif serta ukuran header dibatasi, dan keputusan RBAC
memakai AST hasil parser. Audit JSONL default
`.airesdb-audit.jsonl` mencatat event, user, role, action, status, dan hash
query serta connection ID—tanpa password, bearer token, atau teks query. Audit
berotasi ke `.1` pada 64 MiB dan request ditolak bila log tidak dapat ditulis.
Jika mutasi selesai tetapi acknowledgement gagal, client menerima
`Commit Outcome Unknown` dan wajib memeriksa state sebelum retry. Token session
berasal dari random source sistem operasi dan hanya diterima lewat
`Authorization: Bearer`.

Default resource limit:

| Batas | Default |
|---|---:|
| HTTP header | 32 KiB |
| Request body | 8 MiB |
| Concurrent requests | 128 |
| Active sessions | 64 |
| Idle session timeout | 10 menit |
| Maximum session lifetime | 60 menit |
| Query result rows | 100.000 |
| Query execution time | 30 detik |
| JSON response body | 64 MiB |
| Query memory before spill | 64 MiB |
| Query spill budget | 1 GiB |
| Audit log rotation | 64 MiB |

Laporkan kerentanan sesuai [SECURITY.md](SECURITY.md).

## Pengembangan dan verifikasi

```sh
julia --startup-file=no --project=. -e "using Pkg; Pkg.test()"
```

Suite mencakup lexer/parser, AiresQL, tipe exact, MVCC, WAL/recovery, ARSP-4,
PageStore, B+Tree, TinyServer, autentikasi, resource limit, persistence,
transaksi, serta benchmark correctness. Workload TPC-C-derived dan TPC-H-derived
di repository bukan hasil resmi atau tersertifikasi TPC.

Dokumen utama:

- [Arsitektur](docs/ARCHITECTURE.md)
- [AiresQL](docs/AIRESQL.md)
- [Transaksi dan MVCC](docs/TRANSACTIONS.md)
- [Format file](docs/FORMAT.md)
- [Storage ARSP-4](docs/STORAGE.md)
- [WAL dan recovery](docs/WAL.md)
- [TinyServer](docs/TINYSERVER.md)
- [HTTP API](docs/HTTP_API.md)
- [CLI](docs/CLI.md)
- [Benchmark](docs/BENCHMARKS.md)
- [Audit teknis v0.1.0](docs/AUDIT-v0.1.0.md)
- [Panduan kontribusi](CONTRIBUTING.md)

## Lisensi

AiresDB didistribusikan di bawah **University of Illinois/NCSA Open Source
License** dengan identifier SPDX `NCSA`. Teks lisensi lengkap dipusatkan di
[LICENSE](LICENSE), dan cakupan distribusinya dijelaskan di [NOTICE](NOTICE).
File source produk memakai header SPDX singkat; seluruh teks lisensi tidak perlu
diulang pada setiap file.

Redistribusi source harus mempertahankan copyright notice, syarat, dan
disclaimer. Distribusi binary harus mereproduksinya dalam dokumentasi atau
material distribusi. Nama AiresDB, pemegang hak cipta, dan kontributor tidak
boleh digunakan untuk endorsement tanpa izin tertulis.

Made by open aires Team, Institut Teknologi Sumatera
Team Leader: Aires Zam Wibisono
Benchmarking Specialist: I Made Raditya Mahardika
Support Engineer : Suma Yasa