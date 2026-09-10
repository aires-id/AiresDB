# MVCC, transaksi, dan ACID AiresDB v0.1.0

Dokumen ini menjelaskan perilaku transaksi publik AiresDB. Istilah ACID di sini
berlaku pada proses AiresDB yang bekerja sama melalui lock engine, file berada di
filesystem lokal, dan API durability OS berhasil. Batas hardware dan filesystem
dijelaskan pada bagian terakhir.

## Siklus transaksi

AiresQL menyediakan tiga statement:

```text
Transaksi -:
Gabungkan -:
Kembalikan -:
```

API Julia yang setara:

```julia
begin_transaction!(session)
commit!(session)
rollback!(session)
```

Semua operasi tulis tanpa `Transaksi` eksplisit berjalan sebagai transaksi
autocommit. `with_transaction` membantu memastikan rollback dan dapat mengulang
konflik serialisasi:

```julia
with_transaction(session; retries=3) do
    row = lookup(session, "Rekening", 1)
    saldo = row[2]
    update_key!(session, "Rekening", 1, Dict("Saldo" => radd(saldo, Money(500))))
end
```

`retries` adalah jumlah percobaan ulang setelah percobaan pertama. Callback dapat
dijalankan lebih dari sekali, sehingga efek di luar database—mengirim pesan,
menagih kartu, atau menulis file lain—harus dibuat idempotent atau dilakukan
setelah commit yang diketahui sukses.

`with_snapshot(session) do ... end` memakai mekanisme transaksi yang sama. Bila
callback hanya membaca, penutup snapshot tidak menambah record WAL. Bila callback
menulis melalui API, penutupnya melakukan commit biasa.

## Snapshot dan versi row

Saat transaksi dimulai, engine mengambil state committed terbaru dan memasang
snapshot pada CSN tertentu. Catalog database disalin ringan. Row dan tabel tetap
dibagi dengan state committed sampai sebuah statement perlu mengubah tabel;
kemudian tabel tersebut disalin. Ini menjaga pembacaan snapshot stabil sekaligus
menghindari deepcopy seluruh database untuk setiap operasi.

Setiap row memiliki ID UInt128 stabil dan version stamp CSN. `DatabaseHandle`
menyimpan rantai versi row untuk snapshot lokal yang masih aktif. Commit membuat
versi baru atau tombstone. Garbage collection mempertahankan satu versi anchor
untuk snapshot lokal tertua dan menghapus versi lebih tua yang tidak mungkin
dibaca lagi. Tombstone akhir dapat dihapus setelah tidak diperlukan.

Snapshot historis ini merupakan detail transaksi. Rilis v0.1.0 belum menyediakan
query publik `AS OF`, retention lintas restart, atau ekspor change stream.

## Read set, write set, dan serializable certification

AiresDB memakai optimistic concurrency. Transaksi bekerja tanpa menahan lock file
selama seluruh durasinya. Pada commit, engine mengambil lock eksklusif, melakukan
incremental refresh, memeriksa dependensi snapshot, lalu mengappend WAL sebelum
melepas lock.

Dependensi yang diperiksa:

| Akses | Catatan transaksi | Konflik yang dicegah |
|---|---|---|
| `lookup` primary key | key, row ID, version stamp | row berubah/dihapus atau negative lookup menjadi ada |
| PK equality sederhana pada AiresQL SELECT | key dan version stamp | lost update dan phantom pada key tersebut |
| scan/filter/aggregate/join/view | epoch seluruh tabel sumber | phantom dan perubahan hasil predikat |
| `.tables` atau catalog view | catalog epoch | schema/view berubah |
| `.schema` | table/schema epoch | schema berubah |
| update/delete/DDL AiresQL | epoch tabel atau schema terkait | keputusan tulis dari state lama |
| row yang ditulis | stamp row snapshot vs terkini | first-committer-wins |
| sequence Auto_ | state sequence | ID otomatis ganda |

Sertifikasi scan bersifat konservatif per tabel. Perubahan row apa pun pada tabel
yang dipindai dapat membatalkan transaksi, walaupun row itu tidak lolos predikat.
Pendekatan ini memberi deteksi phantom yang sederhana dan aman, dengan potensi
abort lebih tinggi dibanding range index/predicate lock yang lebih presisi.

Writer pada key berbeda dapat commit bila tidak membaca atau mengubah dependensi
yang sama. DDL disertifikasi sebagai perubahan schema/catalog penuh. Perubahan
catalog, tabel, sequence, dan row dari satu transaksi masuk satu record commit.

## Konflik dan retry

Konflik optimistic menghasilkan:

```text
Transaction Conflict:
...
```

Transaksi eksplisit tetap perlu di-rollback bila caller memakai fungsi manual dan
masih aktif. `with_transaction` melakukan rollback sendiri dan hanya melakukan
retry otomatis untuk kategori `Transaction Conflict`.

Jangan membuat retry loop berdasarkan teks error. Periksa `AiresError.category`.
Constraint error, type error, storage error, dan commit dengan outcome tidak pasti
tidak aman diulang secara umum.

## Commit dan outcome yang belum pasti

Urutan commit tulis adalah:

1. ambil mutex handle dan advisory lock OS;
2. refresh record WAL baru dari proses/session lain;
3. sertifikasi read set, write set, schema, catalog, dan sequence;
4. merge perubahan row ke state committed terbaru;
5. encode satu delta transaksi;
6. append header, payload, dan footer commit dengan LSN berikutnya;
7. flush buffer dan jalankan durability barrier OS;
8. publikasikan state baru ke session dan lepaskan lock.

Caller menerima status `Transaksi digabungkan; durability barrier OS selesai.`
hanya setelah langkah sinkronisasi WAL berhasil. Kalimat ini menyatakan barrier OS
yang benar-benar dipanggil; ia tidak mengklaim verifikasi listrik padam pada media.

Kegagalan sebelum append dimulai meninggalkan transaksi belum committed. Setelah
penulisan mungkin dimulai, tidak selalu mungkin membedakan "belum commit" dari
"commit sudah durable tetapi jawaban gagal kembali". AiresDB membuang staging
lokal dan menghasilkan:

```text
Commit Outcome Unknown:
Status commit belum pasti setelah kegagalan I/O. Pilih ulang database dan periksa data sebelum mengulang transaksi.
```

Prosedur aman:

1. jangan langsung mengulang mutasi;
2. tutup atau buang session yang mengalami error;
3. buat/buka session baru dan biarkan recovery membaca `.aires`;
4. periksa business key, transaction identifier aplikasi, atau efek yang diharapkan;
5. hanya lakukan kompensasi/retry bila pemeriksaan membuktikan commit belum ada.

Untuk operasi bernilai tinggi, simpan idempotency key sebagai primary/unique key
di transaksi yang sama. Duplicate key kemudian menjadi bukti bahwa request yang
sama telah diproses, bukan alasan menggandakan efek.

## Konsistensi dan atomicity statement

Schema, tipe, primary/composite key, unique constraint, nullable flag, sequence,
dan dependensi view divalidasi sebelum commit. UPDATE mengevaluasi assignment
terhadap row lama, kemudian memvalidasi row baru sebagai satu unit. Multi-row
INSERT/UPDATE dan DDL merupakan statement atomik.

Jika sebuah statement gagal di tengah transaksi eksplisit, perubahan statement
itu dibuang sementara statement sebelumnya masih ada di staging transaksi.
Caller dapat memperbaiki input, melanjutkan, atau rollback seluruh transaksi.
Crash sebelum footer commit lengkap tidak membuat sebagian tabel terlihat.

## Session dan ownership server

TinyServer membuat satu Engine dan memakai satu Session per login. Token dari
`POST /session` harus dipakai kembali pada setiap `POST /query` dalam unit kerja
yang sama. Session yang berbeda berbagi cache database, rantai versi, dan mutex
handle melalui Engine server.

`DELETE /session/{id}`, idle timeout, dan shutdown menutup Session. Penutupan
melakukan rollback bila transaksi aktif. Transaksi tidak boleh bersarang,
berpindah database, atau menjalankan checkpoint pada session yang sama. Client
tidak membuat Engine atau membuka file storage.

## Checkpoint dan garbage collection

WAL terus bertambah satu frame per transaksi tulis. Gunakan `.mvcc` dari monitor
untuk melihat CSN, LSN, snapshot, versi row, dan ukuran WAL. Gunakan `.checkpoint`
untuk checkpoint dan `.vacuum` untuk membersihkan versi yang tidak dibutuhkan.

Checkpoint membuat file sementara di direktori yang sama, menulis header dan
checkpoint state terkini, menyinkronkannya, lalu mengganti `.aires` secara atomik
di bawah lock database. File ID generasi berubah agar session lain tahu bahwa
incremental offset lama tidak lagi valid. Snapshot yang sudah aktif pada proses
lokal tetap memegang state lamanya sampai selesai.

Vacuum menghapus rantai versi memori yang tidak lagi dibutuhkan. Operasi ini tidak
memadatkan WAL dan tidak mengganti checkpoint.

## Batas jaminan ACID

Atomicity dan isolation mengandalkan seluruh writer memakai API AiresDB dan sidecar
lock yang sama. Program yang mengubah/truncate/rename `.aires` atau sidecar secara
langsung dapat merusak protokol.

Durability berarti AiresDB menuntut `FlushFileBuffers` pada Windows atau `fsync`
pada POSIX sebelum melaporkan sukses. Publikasi checkpoint memakai
`MoveFileExW(..., WRITE_THROUGH)` pada Windows dan rename + `fsync` direktori pada
POSIX. AiresDB tidak dapat membuktikan bahwa controller, firmware, hypervisor,
filesystem jaringan, atau media fisik benar-benar menghormati barrier tersebut.

Uji crash proses memeriksa recovery ketika proses dihentikan pada tahapan WAL yang
ditentukan. Ini tidak sama dengan uji cabut daya fisik. Deployment produksi perlu
backup teruji, media andal, observability I/O, dan pengujian platform target.
