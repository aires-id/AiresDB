# Eksekusi analitis internal AiresDB

> Dokumen ini adalah referensi implementasi dan regression test internal.
> Aplikasi pengguna menjalankan analitik melalui AiresQL pada TinyServer HTTP API.

AiresDB menyediakan API relasional Julia sebagai pasangan AiresQL. Sintaks
berbahasa Indonesia, tipe `U`/`D` yang presisi, format `.aires`, dan terminator
`-:` tetap digunakan. API ini membantu aplikasi menyusun rencana analitis yang
memerlukan beberapa join, subquery terdekorrelasi, pengelompokan, dan pengurutan.
Ini bukan parser SQL tambahan dan tidak menjalankan `eval` terhadap input.
Callback Julia merupakan kode aplikasi tepercaya, bukan teks dari pengguna.

## Membaca satu snapshot

```julia
using AiresDB.Internal # internal engine API for TinyServer and regression tests

with_snapshot(session) do
    pesanan = relation(session, "Pesanan"; columns=["Pelanggan", "Total"])
    pelanggan = relation(session, "Pelanggan"; columns=["Id", "Nama"])
    cocok = hashjoin(pesanan, pelanggan; on=[:Pelanggan => :Id])
    total = groupby(cocok, [:Nama], [:Belanja => Sum(:Total), :Jumlah => Count()])
    hasil = rlimit(rsort(total, [:Belanja => :desc, :Nama => :asc]), 10)
    println(format_table(query_result(hasil)))
end
```

`relation` menggunakan `scan_rows`, sehingga pembacaan tetap mengikuti snapshot
dan pencatatan dependensi transaksi engine. Seluruh rencana multitable harus
dijalankan dalam `with_snapshot` atau transaksi eksplisit agar semua scan
melihat versi yang konsisten. Baris keluaran berbentuk `NamedTuple` yang dapat
diakses dengan `row.Nama`; perubahan koleksi hasil tidak mengubah tabel sumber.

`relation(session, "T"; prefix="t_")` menambahkan awalan pada nama kolom hasil.
Awalan ini berguna ketika tabel yang sama bergabung lebih dari sekali.

## Operator

| API | Perilaku |
| --- | --- |
| `RelTable([:a, :b], [(1, "x")])` | Membuat relasi dari data aplikasi. |
| `rfilter(t, r -> sqlcmp(:gt, r.Total, Money(100)))` | Menyimpan baris dengan predikat tepat `true`; `nothing` dibuang. |
| `rmap(t, [:Nilai], r -> (rmul(r.Harga, r.Jumlah),))` | Proyeksi terhitung; callback mengembalikan tuple. |
| `rproject(t, [:Nama, :Total])` | Memilih serta mengurutkan kolom. |
| `rrename(t, [:Nama => :Pelanggan])` | Mengganti nama kolom. |
| `hashjoin(a, b; on=[:Id => :Id], kind=:inner)` | Hash join inner/left/semi/anti. |
| `groupby(t, [:Wilayah], [:Total => Sum(:Nilai)])` | Agregasi hash sekali jalan. |
| `raggregate(t, Avg(:Nilai))` | Agregat skalar tanpa membentuk relasi antara. |
| `rsort(t, [:Total => :desc, :Nama => :asc])` | Pengurutan stabil dengan arah per kolom. |
| `rlimit(t, 20; offset=10)` | Limit dan offset nonnegatif. |
| `rdistinct(t)` | Menghapus baris duplikat dengan semantik NULL SQL. |
| `rdistinct(t; columns=[:Id])` | Menyimpan baris pertama setiap kunci yang dipilih. |
| `runion(a, b; all=true)` | Menggabungkan menurut posisi kolom; `all=false` menghapus duplikat. |
| `query_result(t)` | Mengubah hasil menjadi `QueryResult` untuk formatter AiresDB. |

Hash join membangun indeks pada sisi kanan. Pilih sisi kanan yang lebih kecil
untuk mengurangi memori. `predicate=(left, right) -> ...` menambahkan kondisi
setelah kecocokan kunci. Kondisi ini merupakan bagian dari join: pada left join,
baris kiri yang semua kandidatnya gagal tetap muncul dengan nilai kanan NULL.
Semi join menghasilkan satu baris kiri ketika ada kecocokan; anti join
menghasilkan baris kiri tanpa kecocokan. Operator ini cukup untuk implementasi
`EXISTS`/`NOT EXISTS` yang tidak melakukan scan tabel penuh per baris.

Kunci join boleh terdiri atas beberapa pasangan. `on=Pair{Symbol,Symbol}[]`
menghasilkan produk Cartesian. Kolom kanan dengan nama bertabrakan mendapat
akhiran `_right`, diulang sampai unik. NULL pada salah satu komponen kunci tidak
pernah cocok dengan NULL lain dalam join biasa.

## Agregat dan NULL

`Count()` menghitung semua baris. `Count(:kolom)`, `CountDistinct(:kolom)`,
`Sum`, `Avg`, `Min`, dan `Max` mengabaikan NULL. Semua agregat dengan selector
menerima nama kolom atau fungsi seperti `Sum(r -> rmul(r.Harga, r.Jumlah))`.
`groupby(t, Symbol[], [...])` adalah agregasi skalar: selalu mengembalikan satu
baris walaupun sumber kosong. Count menghasilkan nol; SUM/AVG/MIN/MAX
menghasilkan `nothing`. Group biasa dengan sumber kosong menghasilkan nol
baris. Semua NULL pada kolom grup masuk kelompok yang sama.

`nothing` adalah NULL AiresDB. `sqlcmp(:eq/:ne/:lt/:le/:gt/:ge, a, b)`,
`sqland`, `sqlor`, `sqlnot`, dan `sqlin` menyediakan logika tiga nilai.
`sqlin(x, nilai)` mengembalikan NULL jika tidak ada kecocokan tetapi daftar
memuat NULL. Ini berbeda dengan anti join yang mengikuti `NOT EXISTS`.

`SqlLike("PROMO%")` mengompilasi pola sekali dan dapat dipanggil sebagai fungsi.
`%` mencocokkan nol atau lebih karakter; `_` satu karakter Unicode. Backslash
meng-escape karakter berikutnya. Misalnya `SqlLike(raw"a\%b")` mencocokkan
persen literal. `sqllike(teks, pola)` juga menerima string pola langsung.

`rsort` menempatkan NULL terakhir untuk kedua arah; gunakan `nulls=:first`
untuk mengubahnya. Nilai dengan kunci urutan sama mempertahankan urutan input.

## Angka presisi dan batas implementasi

Gunakan `radd`, `rsub`, `rmul`, dan `rdiv` untuk ekspresi yang melibatkan
`Money` atau `Decimal`. Jalur cepat penjumlahan cents/decimal dan perkalian
cents dengan integer menggunakan pemeriksaan overflow. Nilai yang melampaui
kapasitasnya beralih ke aritmetika rasional `BigInt`; nilai uang tidak diubah
menjadi floating point. Rata-rata dan pembagian tidak membulatkan diam-diam.

Kunci hash, DISTINCT, dan GROUP BY menyamakan representasi angka eksak yang
bernilai sama, misalnya `1`, `Money(100)`, dan `Decimal("1.0")`. Boolean tidak
disamakan dengan angka 1 atau 0. Nilai Float64 dibandingkan berdasarkan nilai
biner sebenarnya; karena itu `0.1` Float64 tidak identik dengan desimal eksak
`0.1`. Gunakan satu domain angka yang konsisten untuk kunci aplikasi.

Operator menghasilkan relasi di memori. Belum ada spilling ke disk, optimizer
berbasis biaya, parallel hash aggregation, atau batas memori per query. API
ini mengeksekusi rencana yang ditulis aplikasi; tidak mengklaim dukungan penuh
SQL TPC-H di parser AiresQL. Pengujian analitis dan benchmark menggunakan
operator engine yang sama, bukan hasil jawaban yang ditanam langsung.

## Verifikasi

`test/relational_tests.jl` menguji bentuk hasil, Unicode LIKE, logika NULL,
angka presisi dan overflow, empty-set aggregate, mixed-direction stable sort,
UNION/DISTINCT, seluruh jenis join, serta 144 perbandingan join melawan
implementasi nested-loop referensi pada data dengan duplikat dan NULL.
