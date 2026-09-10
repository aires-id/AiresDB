# Bukti verifikasi AiresDB v0.1.0

Direktori ini menyimpan bukti final yang ringkas dan dapat diaudit. Laporan
benchmark memuat konfigurasi, metrik, dan batas interpretasi masing-masing.

- `arsp4-250k-final-v17-stream.toml`: workload ARSP-4 250 ribu baris.
- `tpcc-memory-final-500.toml`: workload transaksi TPC-C-derived.
- `tpch-memory-final.toml`: workload analitik TPC-H-derived.
- `tpch-memory-final-oracle.json`: pembanding oracle untuk hasil analitik.
- `pkg-test-server-mandatory-final.log`: hasil `Pkg.test()` setelah refactor
  TinyServer; seluruh 2.491 test lulus.
- `FINAL-SHA256SUMS.txt`: checksum SHA-256 seluruh bukti final.

Label TPC-C-derived dan TPC-H-derived tidak menyatakan hasil resmi atau
tersertifikasi TPC.
