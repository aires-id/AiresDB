# Catatan rilis AiresDB v0.1.0

AiresDB v0.1.0 mengubah mesin transaksi dan penyimpanan sambil mempertahankan
identitas AiresDB: AiresQL berbahasa Indonesia, terminator `-:`, tipe D/U presisi,
monitor CLI berbasis TinyServer, dan file database resmi `.aires` milik server.

## Lisensi distribusi

Source, test, benchmark, contoh, dokumentasi, skrip, evidence verifikasi, dan
arsip rilis didistribusikan di bawah **University of Illinois/NCSA Open Source
License** (SPDX: `NCSA`), hak cipta (c) 2026 Aires Zam Wibisono. Pembaca harus
menyertakan pemberitahuan hak cipta, syarat, dan disclaimer saat redistribusi;
nama AiresDB, Aires Zam Wibisono, atau kontributor tidak boleh dipakai untuk
endorsement tanpa izin tertulis. Teks yang mengikat tersedia pada
[`../LICENSE`](../LICENSE), dengan pernyataan cakupan pada [`../NOTICE`](../NOTICE).

## Perubahan utama

### MVCC dan isolation

- snapshot konsisten dengan CSN, stable row ID, row version stamp, dan history;
- copy-on-write pada catalog dan tabel yang disentuh;
- read-your-own-writes dan snapshot lama tetap stabil selama transaksi;
- optimistic serializable certification untuk primary-key read, negative key,
  table/predicate scan, schema, catalog, sequence, dan write set;
- first-committer-wins pada row yang sama;
- perubahan row berbeda dapat di-merge bila dependensinya tidak berkonflik;
- API `Engine`, `with_snapshot`, `with_transaction`, `lookup`, `scan_rows`,
  `bulk_insert!`, `update_key!`, dan `delete_key!`.

### ACID, WAL, dan recovery

- embedded append-only WAL di dalam file `.aires`;
- satu frame checksummed untuk seluruh perubahan transaksi beberapa tabel;
- LSN/previous-LSN dan file ID generasi untuk replay yang ketat;
- `FlushFileBuffers` pada Windows dan `fsync` pada POSIX sebelum commit diakui;
- recovery mengabaikan hanya frame akhir yang fisiknya belum lengkap;
- frame lengkap yang korup selalu ditolak;
- advisory lock lintas proses yang dilepas OS ketika proses mati;
- incremental WAL refresh untuk session/engine/proses lain;
- error `Commit Outcome Unknown` bila commit mungkin sudah tertulis;
- `checkpoint!`, `vacuum!`, dan `mvcc_stats`.

### Performa dan analitik

- hash index internal untuk primary, composite-primary, dan unique key;
- fast path AiresQL untuk equality pada single-column primary key;
- WAL menyimpan delta row/DDL, sehingga commit biasa tidak menulis ulang seluruh
  database;
- generic relational API: inner/left/semi/anti hash join, aggregation, distinct,
  union, stable sort, limit+offset, LIKE, SQL three-valued logic, exact arithmetic;
- driver kelima transaksi TPC-C-derived dan seluruh 22 query TPC-H-derived;
- oracle SQLite in-memory independen untuk correctness query analitis, di luar
  backend dan di luar jalur timing.

### Compatibility

- grammar dan statement AiresQL yang telah didukung tetap tersedia;
- seluruh test regresi menjadi bagian gate rilis;
- snapshot database legacy yang valid dapat dibaca dan dimigrasikan otomatis;
- format hasil query dan tagline tetap dipertahankan.

## Perubahan format yang perlu diperhatikan

File baru dimulai dengan magic `AIRESWAL`, bukan lagi `AIRESDB\0`. Snapshot catalog
legacy tetap dipakai sebagai codec internal di dalam payload checkpoint. Pembukaan
pertama atas file legacy menggantinya dengan container WAL secara durable.

Migrasi bersifat satu arah. Reader format legacy tidak dapat membuka file yang
sudah dimigrasikan. Sebelum upgrade:

1. hentikan seluruh proses yang memakai database;
2. salin setiap `.aires` ke backup yang tidak akan dibuka writer lama;
3. jalankan test aplikasi dengan salinan data;
4. buka menggunakan rilis ini dan verifikasi schema serta query utama;
5. simpan backup lama sampai kebijakan rollback tidak lagi diperlukan.

Jangan menjalankan writer legacy dan writer rilis ini pada file yang sama karena
protokol lock dan format commit berbeda.

## Sidecar lock

Engine membuat file kosong `<nama>.aires.lock`. Ini bukan file database kedua dan
tidak berisi WAL. File sengaja stabil agar semua proses mengunci objek OS yang
sama. Jangan menghapusnya saat database dapat dipakai proses lain. Process crash
tidak memerlukan penghapusan manual karena OS melepaskan lock handle.

Gunakan `backup_database!` untuk backup operasional. API ini mengambil prefix WAL
yang konsisten di bawah lock, memvalidasi checksum, dan mempublikasikan artifact
secara atomic. `.aires.pages` sengaja tidak disalin karena merupakan sidecar
turunan; restore membangunnya ulang pada open berikutnya. Restore membutuhkan
semua session/proses target dihentikan, lalu memvalidasi seluruh WAL sebelum
atomic replace.

## Perubahan perilaku transaksi

Session sekarang refresh state committed pada awal snapshot. Session lama tidak
perlu dipilih ulang hanya untuk melihat commit baru, selama setiap unit baca
memulai snapshot baru. Transaksi yang sudah aktif tetap melihat CSN lamanya.

Konflik concurrency menggunakan kategori `Transaction Conflict`. API helper hanya
mengulang kategori tersebut. Kegagalan I/O setelah append mungkin menghasilkan
`Commit Outcome Unknown`; state harus diperiksa dari session baru sebelum retry.

Read-only transaction tidak menambahkan record WAL. Setiap mutasi autocommit tetap
menyelesaikan durability barrier OS. Perbandingan kinerja harus menyatakan mode
durability pembanding agar hasilnya dapat ditafsirkan dengan benar.

## Checklist upgrade aplikasi

- Ganti pemeriksaan magic/header custom yang mengharapkan `AIRESDB\0`.
- Izinkan sidecar file `.aires.lock` berada di direktori database.
- Tangani `Transaction Conflict` dengan transaksi baru dan batas retry.
- Tangani `Commit Outcome Unknown` dengan verifikasi idempotency/business key.
- Pakai shared `Engine` untuk beberapa session dalam proses yang sama.
- Pantau `mvcc_stats(session).wal_bytes` dan jadwalkan `checkpoint!`.
- Selalu `close(session)` atau rollback transaksi yang tidak diselesaikan.
- Jalankan `Pkg.test()` dan workload aplikasi pada filesystem target.

## Compatibility yang belum dijanjikan

- Tidak ada jalur downgrade writer ke format legacy.
- Binary format internal delta/checkpoint belum menjadi API eksternal stabil.
- Tidak ada shared-file access untuk writer yang mengabaikan advisory lock.
- Filesystem network/cloud-sync dan device yang mengabaikan flush berada di luar
  kontrak durability.
- Tidak ada public time-travel query atau version retention lintas restart.

Lihat [TRANSACTIONS.md](TRANSACTIONS.md), [FORMAT.md](FORMAT.md), [WAL.md](WAL.md),
dan [AUDIT-v0.1.0.md](AUDIT-v0.1.0.md) sebelum deployment.
