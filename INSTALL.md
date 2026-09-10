# Instalasi AiresDB

AiresDB membutuhkan Julia 1.12. Semua akses pengguna berlangsung melalui
AiresDB TinyServer.

Setelah repository ini di-clone, jalankan dari root checkout:

```sh
julia --project=. -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"
julia --project=. -e "using Pkg; Pkg.test()"
```

Jalankan dari checkout:

```sh
julia --project=. -m AiresDB server
julia --project=. -m AiresDB -u root -p
```

Launcher pengembangan setara tersedia sebagai `bin/airesdb.jl`. Project juga
mendeklarasikan aplikasi `airesdb` melalui `[apps]` Julia 1.12. Setelah app
dipasang dan direktori app Julia masuk `PATH`, gunakan `airesdb server` dan
`airesdb -u root -p`.

Tidak ada workflow resmi yang membuka `.aires` langsung dari client.
