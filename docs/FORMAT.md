# Format `.aires` v0.1.0

Versi aplikasi AiresDB dan versi container biner dipisahkan. AiresDB v0.1.0
menulis **WAL container format 1.0** dengan magic `AIRESWAL`. Semua integer
multibyte disimpan little-endian. File `.aires` adalah authority untuk state
committed; `.aires.pages` adalah page-store turunan yang dapat dibangun ulang,
sedangkan `.aires.lock` hanya identitas lock OS dan tidak berisi state database.

Codec ditulis di proyek ini dan tidak menggunakan format database lain atau Julia
Serialization. SHA-256 mendeteksi korupsi tidak disengaja. Hash tersebut bukan
tanda tangan digital, MAC, enkripsi, atau pertahanan terhadap penyerang yang dapat
menulis ulang file dan checksum sekaligus.

## Container WAL

Sebuah `.aires` v0.1 terdiri dari satu header file dan satu atau lebih frame:

```text
WAL header 80 byte
frame LSN 1: checkpoint awal
frame LSN 2: transaksi committed
frame LSN 3: transaksi committed
...
ekor frame parsial opsional setelah crash
```

Record LSN 1 wajib merupakan checkpoint. Checkpoint berikutnya tidak diappend ke
generasi yang sama; `checkpoint!` membuat container baru dengan file ID baru dan
state committed terkini sebagai LSN 1, lalu memublikasikannya secara durable.

### Header file, 80 byte

| Offset | Panjang | Isi |
|---:|---:|---|
| 0 | 8 | ASCII `AIRESWAL` |
| 8 | 2 | major = 1 |
| 10 | 2 | minor = 0 |
| 12 | 4 | ukuran header = 80 |
| 16 | 16 | file ID acak UInt128 dalam representasi byte |
| 32 | 8 | flags = 0 |
| 40 | 8 | reserved = 0 |
| 48 | 32 | SHA-256 byte 0–47 |

Pembaca menolak magic, versi, ukuran, flags/reserved, dan checksum yang salah.
File ID mengidentifikasi satu generasi WAL; cache incremental wajib reload penuh
bila ID berubah setelah checkpoint.

### Header frame, 96 byte

| Offset relatif | Panjang | Isi |
|---:|---:|---|
| 0 | 8 | ASCII `AIRTXN01` |
| 8 | 8 | LSN record |
| 16 | 8 | LSN record sebelumnya |
| 24 | 8 | panjang payload |
| 32 | 16 | file ID, harus sama dengan header file |
| 48 | 8 | flags = 0 |
| 56 | 8 | reserved = 0 |
| 64 | 32 | SHA-256 byte header 0–63 |

Representasi heksadesimal record magic adalah
`41 49 52 54 58 4E 30 31`.

LSN harus dimulai dari 1, bertambah satu, dan menunjuk LSN sebelumnya secara tepat.
Panjang payload per frame dibatasi 256 MiB pada layer WAL. API engine juga
menerapkan batas total file dari `BinaryRowStore`, default 256 MiB.

### Footer commit, 48 byte

| Offset relatif | Panjang | Isi |
|---:|---:|---|
| 0 | 8 | `AIRCMT01` |
| 8 | 8 | LSN yang sama dengan header |
| 16 | 32 | SHA-256 atas header frame lengkap dan payload |

Frame baru dianggap committed hanya jika seluruh header, payload, dan footer
tersedia; magic, sequence, file ID, panjang, dan kedua checksum valid. Pembaca
tidak mencari frame selanjutnya setelah korupsi.

## Payload checkpoint MVCC

Payload checkpoint diawali tag UInt8 `1`, lalu:

```text
UInt64   commit sequence number (CSN)
UInt64   catalog epoch
Blob     snapshot catalog/row bertipe (length-prefixed)
UInt32   jumlah tabel
  untuk setiap tabel, urut nama:
    String   nama tabel
    UInt64   table epoch
    UInt64   schema epoch
    UInt32   jumlah row
      untuk setiap row dalam urutan fisik:
        UInt128  stable row ID
        UInt64   row version stamp
```

Blob snapshot memakai codec row store 1.0 yang sama dengan format legacy v0.1:
magic `AIRESDB\0`, versi, panjang, SHA-256, nama database, timestamp, tabel,
schema, sequence, row bertipe, dan definisi view. Container legacy itu berada di
dalam payload WAL sebagai blob yang di-checksum lagi; file `.aires` v0.1 sendiri
selalu dimulai `AIRESWAL`.

Decoder mencocokkan jumlah/nama tabel, jumlah row, stable row ID, stamp, epoch,
schema, tipe, constraint, sequence, dan view. Byte tambahan ditolak.

## Payload transaksi MVCC

Payload delta diawali tag UInt8 `2`, kemudian CSN baru, UUID transaksi, catalog
epoch, dan daftar tabel yang berubah. CSN payload wajib tepat satu di atas state
yang sedang direplay.

Operasi per tabel mempunyai tiga bentuk:

| Tag | Arti | Data utama |
|---:|---|---|
| 0 | Drop tabel | nama tabel |
| 1 | DDL replacement | snapshot satu tabel, row IDs, stamps |
| 2 | Patch row | row ID, expected old stamp, present flag, nilai row, sequence |

Patch `present=0` adalah delete/tombstone; `present=1` adalah insert atau update.
Expected old stamp harus cocok dengan state replay. Insert baru mengharapkan stamp
nol. Semua kolom row dibaca menurut schema yang sedang berlaku. Urutan perubahan
mempertahankan urutan row hidup dan append sehingga perilaku `LIMIT` tidak berubah
setelah reopen.

Setelah operasi tabel, payload dapat menyertakan seluruh catalog view bila catalog
berubah. Definisi view disimpan sebagai AiresQL, di-parse kembali, lalu divalidasi
terhadap catalog hasil. Duplicate table operation, row ID, sequence key, view,
flag invalid, byte tambahan, atau constraint yang rusak ditolak.

## Representasi nilai row

Setiap cell memiliki UInt8 `present`: 0 untuk NULL, 1 untuk nilai. Bila present,
representasinya adalah:

| Kode | Tipe | Byte nilai |
|---:|---|---|
| 1 | D | Int128 coefficient + UInt8 scale 0–18 |
| 2 | B | UInt8 0/1 |
| 3 | F | 8 byte IEEE-754 Float64 |
| 4 | I | Int64 |
| 5 | C | UInt32 panjang byte + UTF-8 |
| 6 | T | Int64 jumlah hari sejak 1970-01-01 |
| 7 | W | Int64 nanodetik sejak tengah malam |
| 8 | Tw | Int64 milidetik sejak 1970-01-01 |
| 9 | U | Int128 minor units |

D dinormalisasi dengan membuang nol pecahan di belakang. U selalu memiliki 100
minor units per satuan. State next Auto memakai Int128 agar kondisi Int64 habis
dapat direpresentasikan, sedangkan nilai kolom I tetap Int64.

Nama/string dibatasi dan wajib UTF-8 valid. Schema memuat flags unique, primary,
nullable, dan auto. Composite primary key dibentuk dari tuple seluruh kolom P;
constraint unique kolom tetap terpisah.

## Recovery

Full open memvalidasi header dan seluruh frame committed. Sebuah frame terakhir
yang secara fisik belum lengkap diperlakukan sebagai torn tail dan tidak direplay.
Header parsial tetap harus cocok dengan prefix record magic yang tersedia. Recovery
read tidak memotong file. Append berikutnya, sambil memegang lock OS, memotong
torn tail ke batas commit terakhir, menyinkronkan truncation, lalu menulis frame
baru.

Frame yang panjangnya lengkap tetapi checksum/footer/sequence-nya rusak adalah
korupsi dan selalu menghasilkan Storage Error. Kebijakan ini menghindari kehilangan
commit yang diam-diam. Record lengkap yang baru dilihat proses pembaca melewati
durability barrier sebelum dipublikasikan ke snapshot lokal.

Engine dapat refresh dari end offset commit terakhir. Incremental refresh tidak
menghash ulang payload lama pada setiap statement; open penuh dan audit file penuh
tetap memvalidasi sejarah.

## Lock dan publikasi checkpoint

`<database>.aires.lock` adalah file kosong stabil. Windows membuka file itu dengan
`CreateFileW` sharing mode nol; POSIX memakai `flock`. Lock dilepas OS ketika handle
ditutup atau proses mati. Jangan unlink sidecar sementara proses mana pun mungkin
masih memiliki path database tersebut karena inode/file baru dapat memecah domain
lock pada POSIX dan identitas path dapat berubah pada platform lain.

Commit menahan lock sejak refresh dan sertifikasi hingga append tersinkron selesai.
Checkpoint menulis file sementara di direktori yang sama, menyinkronkan isinya,
dan memublikasikan melalui `MoveFileExW` dengan `WRITE_THROUGH` pada Windows atau
rename + `fsync` direktori pada POSIX. Hanya `.aires` tujuan yang authoritative;
file sementara tidak boleh dipromosikan manual tanpa validasi.

## Migrasi format legacy

Saat `Pilih` membuka file yang dimulai `AIRESDB\0`, engine membaca dan memvalidasi
snapshot legacy, memberi stable row ID/stamp awal, lalu menulis container WAL baru
ke file `.aires` yang sama melalui publikasi durable. Nama dan ekstensi tetap.

Migrasi ini **satu arah**. Setelah sukses, writer/reader format legacy tidak dapat
membuka file `AIRESWAL`. Buat backup sebelum pembukaan pertama dan hentikan semua
proses lama. Jangan menjalankan writer legacy dan writer rilis ini bersamaan karena
protokol lock dan format commit berbeda.

## Batas decoder dan keamanan

Default engine membatasi file total pada 256 MiB. Decoder juga membatasi panjang
string, jumlah kolom, tabel/view, row, dan payload agar integer overflow dan
alokasi tak berbatas dapat ditolak lebih awal. Batas tersebut merupakan hardening
dasar, bukan sandbox untuk file bermusuhan.

Tidak ada repair otomatis untuk frame committed yang korup. Pulihkan dari backup
yang diketahui baik. Jangan menonaktifkan checksum atau menyunting byte database.
Kontrak I/O, failure injection, dan detail low-level lengkap ada di [WAL.md](WAL.md).
