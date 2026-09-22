# Roadmap AiresDB setelah v0.1.0

Versi 0.1.0 menyelesaikan fondasi durability, embedded WAL, recovery, MVCC,
optimistic serializable certification, stable row identity, hash index untuk
primary/unique key, checkpoint, API relasional, benchmark correctness
TPC-derived, serta storage ARSP-4 page-based. Item di bawah merupakan rencana,
bukan fitur yang sudah tersedia.

## Status fondasi

| Area | Status v0.1.0 | Langkah lanjutan |
|---|---|---|
| WAL/durability | Embedded WAL, checksum, LSN, OS sync, torn-tail recovery, native checksummed backup/atomic restore, automatic checkpoint, immutable WAL archive, LSN PITR | off-host archive transport, retention tooling, observability I/O |
| MVCC | snapshot COW, row version stamp/history, serializable certification | predicate/range tracking lebih presisi, public time travel bila ada kontrak retention |
| Concurrency | shared Engine, multiprocess advisory lock, incremental refresh | stress lebih panjang, fairness/backoff, cancellation |
| Storage | page manager 8 KiB, slotted heap, RID, bounded Clock buffer pool, WAL page-LSN guard, scheduler 4 lane, async P2 cache miss, offline physical PageStore compact/rebuild | multi-page catalog, online vacuum/free-space map, physical snapshot history tanpa fallback legacy, async P3 traversal |
| Index | hash compatibility index plus persistent B+Tree untuk primary/unique current snapshot dan `M:` yang eligible, bottom-up bulk load, unique-index join probe | secondary index umum, delete rebalance, B-link/latch coupling |
| Analitik | generic relational API, predicate pushdown aman, multi-join greedy order, statistik tabel, spillable hash join, dan 22 query TPC-H-derived | parallel execution, projection pushdown |
| AiresQL query | kondisi `&:`/`O:`, pengurutan stabil `M:` dengan `Atas`/`Bawah`, serta Limit setelah urut | alias, IS NULL, HAVING, foreign key, prepared query |
| Benchmark | 5 transaksi C-derived, 22 query H-derived, report reproducible | skala lebih besar, long-running soak, profile disk/RAM |

## Prioritas berikutnya

1. **Integrasi pipeline fisik.** Lepaskan facade PageStore dari serialisasi satu
   request per store, kelola fetch P3 secara nonblocking, dan buktikan overlap
   empat lane melalui API sebelum mengklaim concurrency request-level.
2. **Migrasi operator fisik.** Jadikan join, aggregate, group, predicate range,
   dan mixed-order traversal berbasis page/batch sambil mempertahankan AiresQL.
3. **Catalog dan reclaim.** Pecah katalog PageStore ke beberapa page, tambahkan
   online vacuum/recycle page aman-WAL, generation sidecar yang tidak berbenturan
   dengan handle proses lain, dan tooling inspect/repair format. Offline compact
   dan sidecar replacement detection sudah tersedia sebagai baseline maintenance.
4. **B+Tree concurrency.** Tambahkan delete rebalance, root shrink, secondary
   index umum, dan protocol B-link atau latch coupling.
5. **Planner dan optimizer.** Statistik lazy, greedy join order multi-sumber,
   spillable hash join, dan `EXPLAIN` sudah tersedia. Projection pushdown,
   pilihan scan/index yang lebih luas, dan parallel execution menjadi langkah
   berikutnya. Predicate pushdown serta cardinality-aware hash build tetap
   tersedia untuk equality join.
6. **AiresQL berikutnya.** Alias, IS NULL, HAVING, foreign key, prepared query
   bertipe, bulk import, dan CSV.
7. **Operational tooling.** inspect WAL, off-host archive transport/retention,
   metrics, dan migration dry-run. Automatic checkpoint, immutable local WAL
   archive, dan LSN PITR sudah tersedia.
8. **Server mode.** TLS 1.3 native, AST-based RBAC, bounded login throttling,
   bearer-only session, absolute session lifetime, bounded request/header,
   fail-closed audit, dan query quota/cancellation guard sudah tersedia.
   Berikutnya adalah credential
   rotation, centralized audit retention, source-aware edge rate limiting,
   metrics, dan mTLS opsional.

## Gate kualitas untuk fitur storage berikutnya

Perubahan format atau page engine harus mempertahankan:

- kompatibilitas baca atau migrasi satu arah yang eksplisit dan teruji;
- atomic commit beberapa tabel dan constraint yang sama dengan v0.1;
- recovery di setiap batas tulis, korupsi byte, dan restart proses;
- model commit-outcome-unknown tanpa retry write diam-diam;
- test snapshot lama, phantom, negative key, schema/catalog, sequence, dan view;
- benchmark sebelum/sesudah dengan workload, seed, warmup, hardware, dan mode
  durability yang sama;
- test API PageStore yang membuktikan lane overlap dan blocked-I/O progress;
- `.aires` tetap authority WAL; PageStore hanya boleh dipublikasikan sesudah WAL
  durable dan harus dapat dibangun ulang dari state `.aires` yang terverifikasi.

## Batas klaim benchmark masa depan

Suite TPC-derived digunakan untuk regresi correctness dan perbandingan internal.
Angka baru harus memisahkan startup/JIT, load, warmup, latency, throughput, ukuran
WAL, checkpoint, RAM, dan error/retry. Jangan mengekstrapolasi skala kecil.

Nama TPC-C/TPC-H compliant, `tpmC`, dan `QphH` hanya dapat digunakan bila seluruh
spesifikasi, konfigurasi minimum, prosedur measurement, availability, pricing,
full-disclosure report, dan audit independen yang berlaku benar-benar dipenuhi.
Implementasi derived pada repository ini tidak memenuhi syarat tersebut.

Semantik `Integral` tetap dicadangkan sampai spesifikasi produk ditentukan secara
eksplisit; implementasi tidak akan menebaknya dari nama.
