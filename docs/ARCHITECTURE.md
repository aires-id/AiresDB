# Arsitektur AiresDB

Arsitektur pengguna AiresDB bersifat server-mandatory.

```text
Clients -> HTTP/JSON -> AiresDB TinyServer -> one Engine / many Sessions
                                              |
                  MVCC -> WAL -> ARSP-4 -> PageStore/B+Tree -> Buffer Pool -> Disk
```

TinyServer membuat satu `Engine` untuk satu controlled data root. Login membuat
satu `Session`; query berikutnya memakai session yang sama sehingga database
terpilih, snapshot, dan transaksi tetap konsisten. Logout, timeout, atau shutdown
menutup session dan me-rollback transaksi aktif.

CLI hanya mempunyai HTTP client. Source CLI tidak membuat engine, session, atau
path database. Core API tetap ada untuk implementasi server dan regression test
internal, bukan sebagai jalur penggunaan aplikasi.
