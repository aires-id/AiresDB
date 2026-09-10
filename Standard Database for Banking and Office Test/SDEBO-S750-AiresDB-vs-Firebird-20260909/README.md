# SDEBO-S750: AiresDB 0.1.0 vs Firebird 5.0.4

Direktori ini memuat hasil publik SDEBO 1.0 yang dijalankan pada 9–11 September
2026. Dataset logis berisi 750.000 row dengan seed `1999` dan digest SHA-256
`abb9654f1a69e5cd47b0ce546116b377ca59d3ec0b83077a7a48d1d2a8669799`.

| Engine | Score | Class | Medium Office | Small Bank Technical |
|---|---:|---|---|---|
| AiresDB 0.1.0 | 3.7353 | Excellent | PASS | PASS |
| Firebird 5.0.4.1812 | 3.9338 | Excellent | PASS | PASS |

Mulai dari `SDEBO_Report.pdf` untuk laporan yang mudah dibaca. `result.json` dan
`result.csv` adalah hasil final terstruktur, `environment.json` mendeskripsikan
host dan konfigurasi engine, `raw/` menyimpan metrik lima run, dan `recovery/`
menyimpan bukti resilience. Gunakan `SHA256SUMS` untuk memverifikasi evidence
final dan harness yang dipakai menghasilkan laporan.

Database kerja, backup, dataset PSV hasil generate, dan direktori eksekusi
`runs/` serta `resilience/` berukuran beberapa GiB dan sengaja dikecualikan dari
Git. Dataset dapat dibuat ulang dan pengujian dapat dijalankan kembali memakai
script di `../harness/` berdasarkan
`../SDEBO_Test_Specification_v1.0_publication.docx`.

Penyimpangan dan percobaan yang dibatalkan dicatat di `result.json` serta
`raw/harness-notes/`. Label Small Bank Technical adalah gate teknis SDEBO, bukan
sertifikasi atau rekomendasi penggunaan perbankan.
