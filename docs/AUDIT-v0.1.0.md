# Audit teknis AiresDB v0.1.0

Audit ini memisahkan klaim implementasi, bukti pengujian, benchmark perangkat,
dan batas yang belum diuji. Hasil TPC-derived di repository ini bukan audit resmi
TPC. Forced process termination juga bukan pengganti uji kehilangan daya fisik.

## Target audit

Rilis diterima hanya bila seluruh area berikut lulus bersama:

1. regresi perilaku AiresQL dan tipe/constraint v0.1;
2. atomicity transaksi beberapa tabel dan rollback statement/transaksi;
3. snapshot isolation plus serializable conflict detection;
4. WAL checksum, urutan LSN, torn-tail recovery, dan durable sync;
5. concurrency beberapa task, Engine, dan proses;
6. checkpoint, version GC, reopen, dan migrasi legacy;
7. operator relasional dan arithmetic/NULL semantics;
8. lima transaksi TPC-C-derived dengan invariant state;
9. 22 query TPC-H-derived terhadap oracle SQL independen;
10. page manager, slotted page, RID, buffer pool, dan B+Tree persistent
    ARSP-4;
11. rolling scheduler empat fase/empat lane, termasuk backpressure dan lane
    yang diblokir;
12. benchmark berulang pada perangkat yang disebutkan tanpa proses uji bersaing.

Gate final pada 4 September 2026 menjalankan tepat:

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```

dan gate optimasi terakhir pada 7 September 2026 selesai dengan exit status 0
serta **2.438/2.438 assertion lulus**. Baseline internal sebelum tambahan sintaks
dan storage ARSP-4 berjumlah 2.273 assertion; inventaris final adalah:

| Kelompok gate final | Assertion |
|---|---:|
| Core/regresi AiresQL | 314 |
| Operator relasional | 250 |
| MVCC adversarial | 89 |
| WAL low-level | 1.400 |
| TPC-derived correctness | 115 |
| Integrasi WAL/MVCC | 82 |
| Source audit | 23 |
| AiresQL logical/order | 54 |
| ARSP-4 storage primitive | 55 |
| ARSP-4 rolling scheduler | 28 |
| ARSP-4 PageStore integration | 24 |
| Large-table persistent-index memory | 4 |
| **Total** | **2.438** |

## Ringkasan ACID yang diaudit

| Sifat | Mekanisme | Bukti yang diwajibkan | Batas interpretasi |
|---|---|---|---|
| Atomicity | satu frame WAL memuat seluruh delta row/schema/catalog transaksi; footer commit menentukan replay | transfer beberapa tabel pada failpoint sebelum/sesudah header, payload, footer, dan sync membuka kembali state seluruhnya sebelum atau sesudah | tidak mengoordinasikan side effect di luar AiresDB |
| Consistency | coercion bertipe, PK/composite/unique index, sequence, schema dan view validation sebelum publikasi | duplicate/null/type/schema/view failure tidak mengubah state committed; recovery memvalidasi ulang payload | tidak ada foreign key atau constraint aplikasi umum |
| Isolation | snapshot CSN/COW, key+stamp read set, table/catalog/schema epoch, first-committer-wins | dirty/nonrepeatable read, lost update, negative key, phantom, write skew, DDL/catalog race, dan independent-key writer | scan conflict konservatif per tabel; tidak ada distributed transaction |
| Durability | append-only WAL, SHA-256, `FlushFileBuffers`/`fsync`, durable checkpoint replace | reopen lintas proses, forced process termination di tahapan WAL, lengkap-vs-torn corruption audit | bukan cabut daya; firmware/filesystem dapat melanggar flush |

## Audit berlapis

### 1. Audit format dan WAL low-level

`test/wal_lowlevel.jl` memeriksa:

- setiap batas truncation pada final frame;
- korupsi setiap byte header file dan frame committed lengkap;
- checksum header/commit, magic, file ID, previous LSN, duplicate/stale LSN;
- panjang payload berlebih, offset incremental invalid, dan byte tambahan;
- torn tail yang hanya dipotong pada append berikutnya;
- nested lock, concurrent task/process, timeout, dan release setelah process kill;
- publication/migration serta exception dan crash failpoint.

Audit komponen selama pengembangan terakhir mencatat **1.400/1.400 assertion
lulus dalam 30,7 detik** pada perangkat Windows pengembangan. Angka ini adalah
focused component run; hasil `Pkg.test()` paket final tetap menjadi gate utama.

### 2. Audit MVCC dan serializability

Test adversarial membangun dua atau lebih session/Engine dengan urutan operasi
yang disengaja. Kasus wajib meliputi:

- pinned snapshot dan read-your-own-writes;
- salinan hasil tidak dapat mengubah row sumber;
- writer key berbeda, writer row sama, delete/update, dan key swap;
- negative lookup lalu insert, table scan lalu insert/update (phantom);
- write skew dan first-committer-wins;
- create/drop/recreate table, catalog/view/schema race, dan Auto sequence;
- rollback, readonly snapshot, long-lived snapshot, GC, checkpoint, dan reopen;
- proses berbeda yang mengulang read-modify-write hanya setelah conflict yang
  teridentifikasi.

Audit memeriksa state sebelum dan sesudah reopen, bukan hanya object in-memory.
Conflict yang diharapkan dihitung sebagai pass bila state akhirnya sesuai urutan
serial; error lain tetap failure.

### 3. Audit transaksi-WAL end-to-end

Driver child-process menjalankan transfer beberapa tabel dan dihentikan paksa pada
failpoint WAL. Setelah setiap proses, parent membuka database melalui API publik.
Sebelum footer lengkap, seluruh saldo harus state lama. Setelah sync selesai,
seluruh saldo harus state baru. Pada titik di sekitar footer/sync ketika caller
tidak menerima acknowledgement, recovery boleh menemukan state lama atau baru
sesuai batas fisik yang tercapai, tetapi tidak boleh menemukan transfer separuh.

Kasus terpisah memeriksa commit-outcome-unknown, checkpoint generation change,
session lama, multiprocess increments dengan retry conflict, serta full reopen.

### 4. Audit operator relasional

`test/relational_tests.jl` memeriksa seluruh operator publik, NULL three-valued
logic, Unicode LIKE, exact numeric equivalence, overflow fallback, stable sort,
empty aggregate, distinct/union, dan semua jenis join. Hash join dibandingkan
dengan implementasi nested-loop referensi pada data yang memiliki duplicate dan
NULL.

Focused run selama pengembangan mencatat **250/250 assertion lulus dalam 31,1
detik**, termasuk **144 differential join cases**.

### 5. Audit workload TPC-derived

`test/benchmark_tests.jl` menguji expected state kelima transaksi C-derived:
New-Order, Payment, Order-Status, Delivery, dan Stock-Level. Pemeriksaan mencakup
remote row, lower-median last-name lookup, accounting totals, delivery references,
serta rollback seluruh New-Order setelah missing final item.

Semua 22 plan H-derived dijalankan di AiresDB dan dibandingkan dengan SQL terpisah
di SQLite in-memory. Perbandingan memakai seluruh multiset hasil serta declared
sort keys; oracle tidak berada di measured path. Gate paket final mencatat
**115/115 assertion lulus dalam 2 menit 1,9 detik** untuk fixture correctness
TPC-derived, termasuk importer DBGEN opsional.

Detail seluruh penyimpangan dari spesifikasi resmi terdapat di
[BENCHMARKS.md](BENCHMARKS.md). Tidak ada klaim TPC compliance, certification,
`tpmC`, atau `QphH`.

### 6. Full regression dan review source

Full `Pkg.test()` harus dijalankan dari source paket yang sama dengan artefak
rilis. Audit source tambahan mencari:

- mutasi row yang dapat menembus snapshot COW;
- jalur write tanpa WAL/transaction manager;
- refresh atau certification di luar lock epoch;
- exception setelah append yang salah dilaporkan sebagai rollback pasti;
- decoder length/count yang dapat overflow atau mengalokasikan tanpa batas;
- penggunaan database/backend eksternal di core atau measured path;
- perbedaan versi antara metadata, banner, error publik, dan dokumentasi.

Temuan harus diperbaiki dan gate diulang; audit bukan sekadar pembacaan source
sekali.

### 7. Audit storage ARSP-4

`test/arsp_storage_tests.jl` memeriksa page manager fixed-size, checksum,
reopen, slotted-page insert/update/delete/compact, RID dan forwarding,
buffer-pool Clock, heap record codec, read-ahead, serta B+Tree persistence,
split, lookup, delete, range traversal, dan bulk-load bottom-up. Gate final
menjalankan **55/55 assertion** untuk kelompok ini.

`test/arsp_pipeline_tests.jl` memeriksa urutan rolling empat tick, penggunaan
empat lane generik, queue bounded/backpressure, completion history, dan kondisi
lane yang diblokir tanpa menghentikan lane lain. Ia mencakup kasus empat lane
async yang memarkir P2 dan satu request antrean yang menunggu `Base.Event`
scheduler tanpa busy-spin; gate final menjalankan **28/28 assertion**.

`test/pagestore_integration_tests.jl` memeriksa sidecar `.aires.pages` yang
dibuat dari state WAL, lookup/scan melalui halaman, pengurutan `M:` yang memakai
B+Tree, update/delete, checkpoint/reopen, failure injection sekitar publication,
dan pertukaran key unik atomik. Ia juga memeriksa cold reopen yang memicu P2
asinkron dan memastikan semua wait sudah drain; gate final menjalankan **23/23
assertion** pada gate awal; gate optimasi final menjalankan **24/24**, termasuk
hasil scan fisik yang tetap detached dari penyimpanan page.

Audit ini membedakan scheduler inti dari facade saat ini. `RollingScheduler`
memang dapat menempatkan empat work unit yang independen dalam empat lane. P2
cache miss sekarang diparkir dan dijalankan oleh worker, lalu worker memberi
sinyal `Base.Event` scheduler ketika lane siap lagi, sehingga lane siap lain
dapat maju. Namun API PageStore masih memegang mutex store selama satu work unit
fisik dijalankan. Karena itu test scheduler membuktikan rolling engine; gate
akhir tetap memverifikasi jalur async ini, sedangkan integrasi belum mengklaim
empat request API fisik berjalan bersamaan. Detail desain, routing, dan batasnya ada di [ARSP4.md](ARSP4.md),
[STORAGE.md](STORAGE.md), dan [ARSP4-AUDIT.md](ARSP4-AUDIT.md).

## Temuan yang ditutup selama audit

Audit berulang menemukan dan menutup beberapa masalah sebelum kandidat final:

| Temuan | Risiko | Perbaikan dan regression gate |
|---|---|---|
| Object row lama dapat termutasi oleh perubahan schema tertentu | snapshot aktif ikut berubah | add/remove column membangun row baru; pinned-snapshot tests membandingkan nilai sebelum/sesudah DDL |
| Replay delta semantik dapat mulai mengubah history sebelum error ditemukan | state cache separuh berubah setelah WAL rusak | replay memakai shadow database/history lalu publish setelah payload penuh valid; source audit menginjeksi payload semantik rusak |
| Error setelah WAL sync tetapi saat publikasi memory/acknowledgement | caller salah menganggap rollback | acknowledgement dialokasikan sebelum durable point; setiap kegagalan setelah barrier menjadi Commit Outcome Unknown dan handle dipaksa full recovery |
| Checkpoint/migrasi membuat sidecar lock sementara | debris file/registry bertambah | sidecar private dihapus setelah handle dilepas dan registry dilupakan; failpoint checkpoint memeriksa tidak ada debris |
| Pergantian generasi/checkpoint dapat memutus history snapshot lokal | versi lama hilang sebelum snapshot selesai | history lama dipertahankan dan disambung ke state replacement; test lintas Engine/checkpoint memverifikasi anchor/tombstone |
| DDL create/drop no-op dan lookup tabel baru memakai schema snapshot lama | konflik/codec salah pada transaksi sendiri | DDL net no-op dinormalisasi dan key read tabel baru ditangani oleh sertifikasi DDL penuh |
| Replay perubahan row dapat mengubah urutan hasil | hasil `LIMIT` berubah setelah reopen | encoder memakai urutan row hidup/append yang deterministik; reopen tests membandingkan urutan |
| Formatter `.mvcc` menerima counter UInt64 yang tidak cocok tipe cell | perintah observasi gagal | counter dikonversi ke representasi tabel publik; regression CLI menjalankan `.mvcc`, `.checkpoint`, dan `.vacuum` |
| P2 cache miss dapat selesai sebelum waiter memutuskan untuk tidur | cold scan/page lookup dapat menunggu event yang sudah dikonsumsi | keputusan blocked/async dan `Base.Event` reset dibuat di bawah mutex scheduler; regression cold reopen serta lane/queue async dijalankan pada satu dan empat thread |

Setiap perbaikan di atas masuk ke test permanen, sehingga perubahan berikutnya
tidak hanya bergantung pada ingatan reviewer.

## Bukti perangkat final 4 September 2026

Pengukuran berikut berjalan pada Windows NT, Intel Core i5-2400S 2,50 GHz,
8.559.091.712 byte RAM, Julia 1.12.7, dan empat Julia thread. Semua artefak
mentah berada di `verification/`; run dijalankan berurutan. `process cold`
hanya berarti session/page manager dibuka kembali, bukan cache disk sistem
operasi yang dipaksa dingin.

| ARSP-4 batch | Bulk rows/s | Cold scan rows/s | Warm scan rows/s | Peak RSS |
|---:|---:|---:|---:|---:|
| 10.000 | 2.019,98 | 20.137,97 | 202.957,08 | 1.087.524.864 B |
| 100.000 | 2.258,96 | 100.146,45 | 153.251,26 | 2.327.973.888 B |
| 250.000 | 2.102,64 | 140.308,33 | 190.531,98 | 4.828.901.376 B |

Skala 100K dan 250K memakai satu sampel latency untuk menjaga waktu dan memori
terukur; tabel tidak menganggap p95/p99 dari satu sampel bermakna. Production
PageStore tetap 8 KiB. Raw report: `arsp4-device-2026-09-04-final.toml`,
`arsp4-100k-device-2026-09-04-final.toml`, dan
`arsp4-250k-device-2026-09-04-final.toml`.

TPC-C-derived reduced profile (1 warehouse, 2 district, 30 customer per district,
100 item) memuat data dalam 8,8160 detik dan menyelesaikan 100 transaksi ukur
setelah 10 warmup dalam 10,2331 detik atau 9,77218 transaksi/detik: 100 commit,
0 error, 0 retry, dan enam invariant committed snapshot lulus. TPC-H-derived
synthetic scale 0,0001 memuat data dalam 5,9620 detik; Q01--Q22 seluruhnya lulus
terhadap oracle SQLite independen untuk dataset tersebut. Kedua report tetap
exploratory/TPC-derived, bukan hasil compliant, certified, `tpmC`, atau `QphH`.
Lihat `tpcc-arsp-device-2026-09-04-final.toml`,
`tpch-arsp-device-2026-09-04-final.toml`, dan
`work/tpch_arsp_20260904_final/oracle-report.json`.

Gate optimasi 7 September memakai workload 250.000 row yang sama dan selesai
dengan peak RSS **659.251.200 byte**, turun 86,35% dari 4.828.901.376 byte,
serta reopen tepat 250.000 row. Profil transaksi O1 terpisah menyelesaikan 500
transaksi TPC-C-derived pada **97,18465 transaksi/detik**, 500 commit, 0 error,
0 retry, dan enam invariant lulus. Bukti mentah berada di
`arsp4-250k-final-v17-stream.toml`, `tpcc-memory-final-500.toml`, dan
`pkg-test-memory-final.log`. Profil RSS mengutamakan bounded allocation dan
bulk-load-nya 23,7595 row/detik; angka transaksi tidak diklaim sebagai hasil
simultan dari flag O0 tersebut.

TPC-H-derived final pada source yang sama menjalankan Q01--Q22 pada skala
sintetis 0,001, satu warmup dan satu repetisi ukur. Proses exit 0 dan oracle SQL
SQLite independen menerima seluruh result set. Report mentahnya adalah
`tpch-memory-final.toml` dan `tpch-memory-final-oracle.json`; satu
sampel per query dipakai sebagai gate correctness/reproduksi, bukan statistik
tail latency.

## Evidence baseline sebelum ARSP-4 pada perangkat ini

Bagian bertanda `RELEASE_RESULTS` di bawah adalah bukti historis pengukuran
3 September 2026 sebelum tambahan storage ARSP-4. Angka 2.327 assertion dan
angka benchmark di dalamnya tidak mengukur jalur PageStore baru dan tidak boleh
dibaca sebagai hasil final ARSP-4. Evidence ARSP-4 dicatat terpisah di
[ARSP4-AUDIT.md](ARSP4-AUDIT.md) setelah gate dan benchmark perangkat diulang
pada source yang sama.

<!-- RELEASE_RESULTS_START -->

Pengukuran final dilakukan 3 September 2026 pada Windows 10 Pro 10.0.19045,
filesystem NTFS, Intel Core i5-2400S 2,50 GHz (4 core/4 thread logis), RAM
8.559.091.712 byte (7,97 GiB), Julia 1.12.7 64-bit, dan satu thread Julia.
Benchmark dijalankan berurutan setelah proses test berat selesai. IDE memiliki
proses language service ringan; tidak ada proses benchmark/test Julia lain yang
bersaing selama sampel diambil.

`Pkg.test()` pasca penambahan AiresQL logical/order pada source kandidat final
melaporkan **2.327/2.327 assertion lulus**:

| Kelompok | Lulus | Waktu |
|---|---:|---:|
| Core/regresi AiresQL | 314/314 | 3 menit 25,3 detik |
| Operator relasional | 250/250 | 39,3 detik |
| MVCC adversarial | 89/89 | 14,2 detik |
| WAL low-level | 1.400/1.400 | 30,5 detik |
| TPC-derived correctness | 115/115 | 2 menit 1,3 detik |
| Integrasi WAL/MVCC | 82/82 | 22,6 detik |
| Source audit | 23/23 | 2,5 detik |
| AiresQL logical/order | 54/54 | 4,9 detik |

Uji integrasi menjalankan child process dan mematikannya paksa sesudah header,
payload, footer commit, sync, serta acknowledgement. Transfer dua tabel selalu
pulih seluruhnya ke state sebelum atau sesudah; tidak pernah separuh. Sesudah
sync dan acknowledgement, state baru selalu muncul. Tiga proses writer juga
menyelesaikan read-modify-write dengan conflict retry, checkpoint, dan reopen
hingga jumlah akhir tepat.

Microbenchmark memakai query yang sama pada 1.000 row, 10 pasangan warmup per
run, dan tiga run per versi. Angka di bawah dihitung ulang dari gabungan 600 sampel
read dan 150 sampel write tiap versi:

| Operasi | Baseline p50/p95 | Kandidat p50/p95 | Throughput baseline → kandidat | Rasio throughput |
|---|---:|---:|---:|---:|
| Point read | 1,724 / 2,503 ms | 0,953 / 1,349 ms | 540,046 → 967,906 ops/s | 1,79× |
| Point update | 229,523 / 287,706 ms | 14,081 / 22,056 ms | 4,258 → 62,147 ops/s | 14,59× |

Writer baseline pada pembanding tidak memanggil `fsync`/`FlushFileBuffers`, sedangkan
setiap commit tulis kandidat diukur dengan `FlushFileBuffers`. Karena implementasi dan
jaminan durability berbeda, rasio ini hanya perbandingan end-to-end lokal, bukan
isolasi biaya satu optimisasi. Pada sampel ini p50 membaik 1,81× untuk read dan
16,30× untuk update.

Workload TPC-C-derived memakai seed 20260903, 1 warehouse, 10 district,
100 customer/district, 1.000 item, 25 warmup, lalu 500 transaksi dari kelima
keluarga. Data awal berisi 1.000 customer, 1.000 order, 9.969 order-line, 1.000
stock, dan 300 new-order. Hasilnya **27,215 transaksi/detik**, 498 commit,
2 expected invalid-item rollback, 0 retry, dan 0 error. Seluruh enam invariant
akuntansi/referensial driver lulus.

| Keluarga | Jumlah | p50 | p95 |
|---|---:|---:|---:|
| New-Order | 225 | 31,792 ms | 183,823 ms |
| Payment | 215 | 14,621 ms | 17,431 ms |
| Order-Status | 20 | 12,983 ms | 16,366 ms |
| Delivery | 20 | 198,553 ms | 425,131 ms |
| Stock-Level | 20 | 21,020 ms | 22,718 ms |

Workload TPC-H-derived all-22 pertama memakai skala sintetis 0,001, satu warmup
dan lima repetisi per query. Run tambahan memakai skala sintetis **0,01**, satu
warmup dan tiga repetisi per query, dengan 60.130 line-item, 15.012 order, 2.005
part, 1.507 customer, 8.030 part-supplier, dan 100 supplier. Load selesai dalam
20,703 detik; seluruh Q01–Q22 cocok dengan oracle SQL independen, termasuk declared
ordering. Median terendah pada run besar adalah Q11 14,615 ms dan tertinggi Q09
706,717 ms; tabel 22 query lengkap dan seluruh sampel ada di laporan benchmark.

Artefak sumber angka:

- `verification/pkg-test-v010-final.log` untuk gate source saat ini;
- `verification/arsp4-250k-final-v17-stream.toml` untuk workload ARSP-4;
- `verification/tpcc-memory-final-500.toml` untuk workload TPC-C-derived;
- `verification/tpch-memory-final.toml` dan report oracle JSON untuk workload
  TPC-H-derived.

Hasil TPC-derived di atas **bukan hasil patuh atau tersertifikasi TPC-C/TPC-H**,
tidak memakai seluruh prosedur/scale/terminal/stream resmi, dan bukan metrik
`tpmC` atau `QphH`.

<!-- RELEASE_RESULTS_END -->

Hasil pengukuran harus menyebut CPU/core, RAM, OS/filesystem, Julia version dan
thread count, seed, scale/cardinality, warmup, repetition, sample count, mode
durability, serta apakah oracle aktif. Raw report di `verification/` merupakan
sumber angka; angka ringkas tidak boleh dihitung dari run yang tumpang tindih
dengan compilation/test berat.

Perbandingan baseline perlu menyebut bila writer pembanding tidak memanggil durability
barrier setara, sedangkan setiap commit tulis kandidat memanggil
`FlushFileBuffers`/`fsync`. Speedup atau slowdown tidak boleh dikaitkan hanya pada
MVCC tanpa mempertimbangkan perbedaan jaminan tersebut.

## Matriks evidence rilis

| Gate | Artefak | Kriteria lulus |
|---|---|---|
| Regression penuh | `test/runtests.jl`, log final | exit 0, tanpa failing/error/broken tak terjelaskan |
| WAL byte audit | `test/wal_lowlevel.jl` | semua truncation/corruption/failpoint/lock case lulus |
| MVCC adversarial | test MVCC terintegrasi | state serializable, snapshot stabil, konflik tepat |
| Crash atomicity | integration child process | state reopen seluruhnya before/after, tak pernah parsial |
| Multiprocess | integration driver | jumlah akhir tepat, retry hanya conflict, reopen/checkpoint tepat |
| Relational | `test/relational_tests.jl` | operator dan differential oracle lulus |
| TPC-C-derived | `test/benchmark_tests.jl`, report run | lima family dan invariants lulus; error/retry dilaporkan |
| TPC-H-derived | oracle + report run | Q01–Q22 full results cocok; seluruh latency sample tercatat |
| ARSP-4 primitive | `test/arsp_storage_tests.jl` | page/slot/RID/buffer/heap/B+Tree persistent benar dan reopenable |
| ARSP-4 scheduler | `test/arsp_pipeline_tests.jl` | empat lane rolling, blocked-lane progress, dan backpressure tepat |
| ARSP-4 PageStore | `test/pagestore_integration_tests.jl` | physical current-snapshot path, WAL-before-data, failure recovery, dan key swap tepat |
| Packaging dan lisensi | `LICENSE`, `NOTICE`, checksum manifest | NCSA lengkap ikut dalam arsip; source/test/docs/report sama dengan yang diuji |

## Klaim yang tidak dibuat

Audit ini tidak menyatakan:

- sertifikasi atau kepatuhan benchmark TPC;
- jaminan terhadap kehilangan daya fisik yang belum diuji;
- ketahanan terhadap filesystem/perangkat yang mengabaikan flush;
- keamanan dari penyerang yang dapat menulis file dan checksum;
- correctness program yang melewati API atau menghapus sidecar lock;
- distributed serializability, replication, high availability, atau backup tanpa
  koordinasi;
- skala produksi besar: heap/index current-snapshot sudah page-based, tetapi
  history MVCC, write set, dan beberapa operator relasional masih memakai jalur
  logical/memory-resident;
- empat request PageStore publik yang benar-benar berjalan bersamaan, karena
  facade storage saat ini masih diserialkan per store.

Keputusan deployment perlu memakai workload, hardware, filesystem, dan prosedur
backup milik pengguna sendiri.
