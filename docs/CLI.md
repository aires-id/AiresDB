# AiresDB monitor CLI

CLI resmi adalah client HTTP untuk TinyServer.

```sh
airesdb -u root -p
airesdb -h 192.168.1.20 -P 1972 -u root -p
airesdb -u root -p --no-banner --file script.txt
```

Password disembunyikan pada TTY. Banner hanya muncul pada terminal interaktif
dan dapat dimatikan dengan `--no-banner`. Prompt awal adalah
`AiresDB [(none)]>`; sesudah pemilihan database menjadi `AiresDB [Nama]>`.
Statement multiline memakai prompt `->` dan wajib berakhir dengan `-:`.

Perintah monitor: `.help`, `.databases`, `.tables`, `.schema Nama`, `.current`,
`.mvcc`, `.checkpoint`, `.vacuum`, `.compact`, `.cancel`, dan `.exit`. Perintah engine
dikirim lewat session server. `.exit` menghapus session.

`.vacuum` membersihkan history MVCC secara logis. `.compact` melakukan rebuild
fisik `.aires.pages` dan membutuhkan database maintenance dengan satu session
aktif serta satu proses AiresDB.

Jika server tidak tersedia, CLI mencetak `ERROR A1000`, keluar non-zero, dan tidak
membuka file database lokal.

Untuk query analitik besar, mode server menyediakan batas external hash spill:

```sh
airesdb server --max-query-memory-bytes 67108864 --max-query-spill-bytes 1073741824
```

Saat memory query melewati batas pertama, hash join mempartisi input ke run
sementara. Batas kedua mencegah penggunaan disk tanpa batas; run dibersihkan
setelah query selesai atau gagal.
