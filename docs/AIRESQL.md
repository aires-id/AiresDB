# Referensi AiresQL v0.1

Keyword tidak peka kapital; identifier tabel/kolom peka kapital. Setiap statement
wajib memiliki `-:`. Spasi/newline boleh memisahkan keyword. Kutip tunggal membatasi
blok nama, daftar nilai, dan ekspresi. Kutip ganda membatasi literal teks di dalam
blok tersebut. Ganti kutip yang sama dengan dua kutip untuk menyertakannya dalam teks.

## Sintaks yang didukung

| Operasi | Bentuk |
|---|---|
| Buat database | `Buat 'Nama' -:` |
| Pilih database | `Pilih 'Nama' -:` |
| Buat tabel | `Buat Tabel 'T' Isi 'A & B' Dengan 'A = I(P) & B = C' -:` |
| Auto increment | Tambahkan `Auto_A` atau `Auto_(A)` sebelum `-:` pada Buat Tabel |
| Insert | `Isi Tabel 'T' '1 & Aires' '2 & Fami' -:` |
| Seluruh kolom | `Pilih '*' Dari 'T' -:` atau `Tampilkan 'T' -:` |
| Proyeksi | `Pilih 'A & B' Dari 'T' -:` |
| Filter | `Pilih '*' Dari 'T' Dengan 'A >= 2' -:` |
| Filter logis | `Pilih '*' Dari 'T' Dengan 'A = 1 &: B = 2 O: C = 3' -:` |
| Ekspresi | `Pilih 'A * 12 & (A + 1) / 2' Dari 'T' -:` |
| Aggregate | `Pilih 'Count(*) & Countif(A > 2) & Sum(A) & Avg(A) & Min(A) & Max(A)' Dari 'T' -:` |
| Group | `Pilih 'B & Sum(A)' Dari 'T' Grup Dari 'B' -:` |
| Urut | `Pilih 'A & B' Dari 'T' M: 'B Atas & A Bawah' -:` |
| Limit | `Pilih '*' Dari 'T' Limit(10) -:` |
| Update | `Tabel_Upt 'T' Isi 'A = A + 1 & B = Nama Baru' Dengan 'A = 1' -:` |
| Add column | `Tabel_Upt 'T' + Kolom 'C' Dengan 'C = C(20&Null)' -:` |
| Remove column | `Kolom_Rmv 'T.C' -:` |
| Delete row | `Baris_Rmv 'T' Dengan 'A = 1' -:` |
| Drop table | `Tabel_Rmv 'T' -:` |
| Join | `Pilih 'T.B && U.Nama' Dari 'T &&& U' Gabung Dengan 'T.A = U.ID' -:` |
| View | `Lihat 'V' Pilih 'A & B' Dari 'T' Dengan 'A > 1' M: 'B Bawah' -:` |
| Begin | `Transaksi -:` |
| Commit | `Gabungkan -:` |
| Rollback | `Kembalikan -:` |
| Reserved | `Pilih 'Integral(A)' Dari 'T' -:` menghasilkan error reserved |

**UPDATE dan DELETE tanpa `Dengan` berlaku pada semua row.** Jumlah nilai INSERT
harus cocok dengan semua kolom non-auto dalam urutan schema; belum ada daftar
kolom INSERT opsional. Multi-row INSERT adalah satu statement atomik.

## Separator dan keyword kondisi

Kompatibilitas separator AiresQL dipertahankan:

| Bentuk | Makna |
|---|---|
| `&` | Memisahkan kolom, nilai, parameter, dan item urut |
| `&&` | Memisahkan proyeksi lintas tabel |
| `&&&` | Memisahkan sumber/tabel pada join |
| `-:` | Mengakhiri statement |
| `&:` | AND logis, hanya di dalam ekspresi/kondisi |
| `O:` | OR logis, hanya di dalam ekspresi/kondisi |
| `M:` | Klausa pengurutan hasil SELECT |
| `Atas` / `Bawah` | Arah pengurutan naik / turun pada item `M:` |

Jadi `&` **bukan** AND. Lexer membedakan `&`, `&&`, `&&&`, dan `&:` secara
longest-match. `O:` dan `M:` tidak peka kapital. `Atas` dan `Bawah` adalah kata
arah kontekstual di dalam `M:`, sehingga nama kolom lama `Atas` atau `Bawah` tetap
valid: `m: 'Gaji bawah'` setara dengan `M: 'Gaji Bawah'`. `&:` dan `O:`
tidak sah sebagai separator daftar atau di luar expression/kondisi.

## Grammar ekspresi

```text
expression  := logical_or
logical_or  := logical_and ('O:' logical_and)*
logical_and := comparison ('&:' comparison)*
comparison  := addition (('=' | '>' | '<' | '>=' | '<=') addition)*
addition    := product (('+' | '-') product)*
product     := unary (('*' | '/') unary)*
unary       := ('+' | '-') unary | primary
primary     := number | quoted_text | NULL | boolean
             | identifier | identifier '.' identifier
             | '(' expression ')' | function '(' expression ')'
             | '*'
```

Prioritas, dari tertinggi ke terendah, adalah kurung, aritmetika (`* / + -`),
perbandingan, `&:`, lalu `O:`. Karena itu `A = 1 O: B = 2 &: C = 3` dibaca
sebagai `A = 1 O: (B = 2 &: C = 3)`. Gunakan kurung untuk mengubahnya, misalnya
`(A = 1 O: B = 2) &: C = 3`. Jangan menggunakan comparison chaining seperti
`1 < A < 10`. `*` hanya wildcard pada proyeksi dan `Count(*)`; pada binary
expression berarti kali. Fungsi AiresQL v0.1 menerima satu argumen. Identifier
fungsi dinormalisasi ke huruf kecil. Nama fungsi lain ditolak. Kedalaman ekspresi
dibatasi 128 tingkat.

Literal angka ekspresi berupa integer/desimal basis 10; notasi exponent untuk
literal ekspresi belum tersedia. INSERT ke kolom F menerima notasi exponent.
Minus unary diterima pada ekspresi; insert negatif ditulis langsung `-123.45`.

## Pengurutan hasil dengan `M:`

Gunakan `M:` untuk mengurutkan SELECT dengan arah eksplisit AiresQL:

```text
Pilih 'Nama & Gaji & Divisi'
Dari 'Karyawan'
Dengan 'Gaji >= 5000000 &: (Divisi = "Teknik" O: Divisi = "Operasi")'
M: 'Gaji Bawah & Nama Atas'
Limit(10)
-:
```

```text
order_clause := M: "'" order_item ('&' order_item)* "'"
order_item := expression ('Atas' | 'Bawah')
```

`Atas` mengurutkan angka dari kecil ke besar dan teks dari A ke Z. `Bawah`
mengurutkan angka dari besar ke kecil dan teks dari Z ke A. Arah harus selalu
ditulis; AiresQL tidak menerima keyword SQL `ASC` atau `DESC`. Banyak kunci
dievaluasi dari kiri ke kanan dan pengurutan stabil, sehingga baris dengan semua
kunci sama mempertahankan urutan sebelumnya.

Nilai NULL ditangani tanpa exception: untuk `Atas`, NULL ditempatkan setelah
semua nilai non-NULL; untuk `Bawah`, NULL ditempatkan sebelum semua nilai
non-NULL. Kolom urut boleh tidak masuk proyeksi jika masih tersedia secara
semantik dari sumber query. Validator menolak kolom yang tidak ada, kolom yang
tidak tersedia pada bentuk query tersebut, atau arah selain `Atas`/`Bawah`.
Ekspresi urut boleh berupa aggregate seperti `Sum(Gaji) Bawah`. Pada hasil
`Grup Dari` atau aggregate, ekspresi itu harus berupa aggregate atau hanya
memakai kolom yang tercantum pada `Grup Dari`.

Letakkan `M:` setelah sumber, join/filter/group yang relevan dan sebelum
`Limit`. Klausa ini dapat menjadi bagian definisi `Lihat`; `Tampilkan` kemudian
mempertahankan urutan yang didefinisikan view.

## Teks, NULL, dan UPDATE

```text
Isi Tabel 'Teks' 'O''Brien' -:
Isi Tabel 'Teks' '"Riset & Pengembangan"' -:
Isi Tabel 'Teks' '"NULL"' -:
Isi Tabel 'Teks' '""' -:
Pilih '*' Dari 'Teks' Dengan 'Nama = "O''Brien"' -:
```

`NULL` dan field kosong tanpa kutip menjadi NULL. `""` tetap string kosong.
String input tidak di-trim di dalam kutip ganda, sedangkan field tanpa kutip
membuang whitespace di awal/akhir. Dalam ekspresi, nama tanpa kutip berarti kolom.

UPDATE tipe C menerima teks bebas sederhana seperti `Nama = Aires Zam`, sesuai
sintaks asli, atau satu nama yang tidak cocok dengan kolom. Gunakan kutip ganda
untuk nilai yang bisa ambigu atau berisi operator: `Nama = "Aires-Zam"`.
`Nama = NamaLain` membaca kolom NamaLain jika ada. Semua assignment satu row
dievaluasi terhadap row lama, lalu divalidasi bersama sebelum publikasi.

Tanggal, waktu, dan tanggalwaktu memakai bentuk ISO pada INSERT/UPDATE; literal
tanggal/waktu bukan fungsi, dan tidak ada aritmetika tanggal atau casting umum.

## Aggregate dan presisi

- `Count(*)` menghitung row, `Count(X)` menghitung nilai non-NULL.
- `Countif(kondisi)` menghitung nilai Boolean true; false/NULL tidak dihitung.
- `Sum`, `Avg`, `Min`, `Max` mengabaikan NULL. Bila tidak ada nilai, hasil NULL.
- `Sum` dan `Avg` membutuhkan input numerik. `Min`/`Max` juga dapat membandingkan
  teks serta tipe tanggal/waktu yang sama.
- D/U/I dihitung dengan rasional BigInt sehingga pembagian tetap eksak. Tampilan
  desimal dipakai bila hasil dapat direpresentasikan dalam batas tipe D; selain
  itu hasil ditampilkan sebagai numerator/denominator.
- F membuat operasi menjadi Float64; NaN/Inf dan hasil tidak hingga ditolak.
- Assignment hasil pecahan ke I, hasil lebih dari dua tempat desimal ke U,
  atau pecahan tidak hingga seperti 1/3 ke D akan ditolak.
- Perbandingan NULL tidak sama dengan string `"NULL"`; belum ada `IS NULL` pada v0.1.

## Urutan eksekusi SELECT

1. Validasi sumber, kolom, tipe ekspresi, join, dan group, bahkan jika tabel kosong.
2. Pecah predicate `Dengan` yang hanya memakai satu sumber dan dorong ke sumbernya.
3. Ambil row tabel atau jalankan kembali view setelah predicate sumber diterapkan.
4. Bila dua sumber: gunakan unique-index probe bila cardinality-nya lebih murah;
   jika tidak, pilih input dengan cardinality lebih kecil sebagai hash build side,
   lalu lakukan hash INNER JOIN equality sambil mempertahankan urutan kiri.
5. Terapkan residual `Dengan` sebagai filter row.
6. Bentuk group bila diperlukan; evaluasi aggregate dan proyeksi.
7. Terapkan `M:` sebagai pengurutan stabil bila klausa ada.
8. Terapkan Limit pada tabel hasil terurut.

`Gabung Dengan` menyatakan kondisi join. Klausa `Dengan` tambahan dapat digunakan
untuk filter setelah join. Klausa tidak boleh berulang. Group boleh beberapa kolom
dengan `&`. Kolom non-aggregate di luar group ditolak; tidak ada alias/group expression.
`M:` harus memakai item `Ekspresi Atas` atau `Ekspresi Bawah` di dalam satu blok
kutip tunggal, dengan beberapa item dipisahkan `&`.

## Error publik

Kategori error: `AiresQL Syntax Error`, `AiresQL Error`, `Constraint Error`,
`Type Error`, `Storage Error`, `Transaction Conflict`, dan `Commit Outcome
Unknown`. CLI tidak menampilkan stack trace normal. API melempar `AiresError`
dengan field `category` dan `message`.

`Transaction Conflict` berarti snapshot tidak lagi dapat diserialisasikan dan
operasi boleh dicoba kembali sebagai transaksi baru. `Commit Outcome Unknown`
berarti penulisan mungkin sudah mencapai WAL; buka ulang dan periksa state sebelum
memutuskan retry. Keduanya dijelaskan di [TRANSACTIONS.md](TRANSACTIONS.md).

Contoh:

```text
AiresQL Syntax Error:
Statement harus diakhiri dengan '-:'.

AiresQL Error:
Integral belum tersedia pada AiresDB v0.1.

AiresQL Error:
Kolom 'KolomTidakAda' tidak ditemukan pada tabel 'Karyawan'.

AiresQL Syntax Error:
Arah urut 'Tengah' tidak dikenal; gunakan Atas atau Bawah.
```

## Hubungan sintaks dengan MVCC

Grammar inti AiresQL dipertahankan dari v0.1. Perubahan v0.1 berada di lapisan
eksekusi: setiap statement membaca snapshot MVCC, setiap mutasi autocommit memakai
transaksi, dan `Transaksi` memasang satu snapshot sampai `Gabungkan` atau
`Kembalikan`. SELECT primary-key equality sederhana memakai indexed key read;
SELECT lain, aggregate, join, dan view mencatat scan dependency pada tabel sumber.

Semantik urutan hasil mengikuti urutan input/kemunculan bila tidak ada `M:`.
Bila ada `M:`, executor memakai pengurutan stabil sebelum `Limit`; definisi view
menyimpan klausa tersebut dan mempertahankannya saat ditampilkan. API `rsort` di
[RELATIONAL.md](RELATIONAL.md) tetap tersedia bagi kode Julia tepercaya yang
membangun relasi langsung.

Perintah `.help`, `.databases`, `.tables`, `.schema`, `.current`, `.mvcc`,
`.checkpoint`, `.vacuum`, `.cancel`, dan `.exit` adalah perintah CLI, bukan
statement AiresQL, sehingga tidak memakai terminator `-:`.
