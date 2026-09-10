# Berkontribusi ke AiresDB

Gunakan Julia 1.12 dan buat perubahan sekecil mungkin tanpa mengubah rasa
AiresQL. Perubahan pada storage atau transaksi harus mempertahankan batas MVCC,
WAL-before-data, recovery, dan `Commit Outcome Unknown`.

1. Buat branch dari `main`.
2. Jalankan `julia --startup-file=no --project=. -e 'using Pkg; Pkg.test()'`.
3. Tambahkan test yang membuktikan bug atau perilaku baru bila diperlukan.
4. Jangan commit database `.aires`, folder `work/`, sysimage, cache, atau hasil
   benchmark sementara.
5. Jelaskan perubahan perilaku, alasan, hasil test, dan risiko tersisa pada pull
   request.

Dengan mengirim kontribusi, Anda menyetujui bahwa kontribusi tersebut
didistribusikan di bawah University of Illinois/NCSA Open Source License yang
tercantum pada `LICENSE`, kecuali ada persetujuan tertulis lain dari maintainer.
File produk baru di `src/` atau `bin/` harus diawali dengan:

```text
# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA
```

Contributor boleh menambahkan baris `SPDX-FileCopyrightText` miliknya sendiri.
Jangan menyalin seluruh teks lisensi ke setiap file.

Benchmark TPC-C/TPC-H dalam proyek ini bersifat TPC-derived. Jangan menyebut
hasilnya tersertifikasi, compliant, `tpmC`, atau `QphH`.
