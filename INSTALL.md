# Instalasi AiresDB

AiresDB membutuhkan Julia 1.12. Semua akses pengguna berlangsung melalui
AiresDB TinyServer.

## Instalasi dari General

Setelah rilis `v0.1.0` masuk registry General, instal paket dengan salah satu
cara berikut.

Di Julia package REPL (tekan `]`):

```julia-repl
pkg> add AiresDB
```

Atau langsung dari shell:

```sh
julia -e 'using Pkg; Pkg.add("AiresDB")'
```

Untuk Windows PowerShell 5, escape tanda kutip yang diteruskan ke Julia:

```powershell
julia -e 'using Pkg; Pkg.add(\"AiresDB\")'
```

Instalasi paket memungkinkan CLI dijalankan melalui entry point modul:

```sh
julia -m AiresDB server
julia -m AiresDB -u root -p
```

Opsi `-e` dipakai untuk mengevaluasi kode Julia, jadi bentuk
`julia -e airesdb -u root -p` bukan sintaks launcher AiresDB.

## Instalasi sebagai app

Julia 1.12 dapat memasang executable `airesdb` dari deklarasi `[apps]` di
`Project.toml`:

```julia-repl
pkg> app add AiresDB
```

Perintah shell yang setara:

```sh
julia -e 'using Pkg; Pkg.Apps.add("AiresDB")'
```

Untuk Windows PowerShell 5:

```powershell
julia -e 'using Pkg; Pkg.Apps.add(\"AiresDB\")'
```

Pastikan direktori app Julia masuk ke `PATH`:

```sh
# Linux/macOS
export PATH="$HOME/.julia/bin:$PATH"
```

```powershell
# Windows PowerShell, untuk sesi saat ini
$env:Path += ";$HOME\.julia\bin"
```

Setelah itu jalankan:

```sh
airesdb server
airesdb -u root -p
```

Dukungan app di Pkg Julia 1.12 masih eksperimental. App memakai executable
Julia yang dipakai saat instalasi; instal ulang app bila executable tersebut
dipindahkan atau dihapus.

## Instalasi langsung dari GitHub

Sebelum AiresDB tersedia di General, paket dan app dapat dipasang dari URL:

```sh
julia -e 'using Pkg; Pkg.add(url="https://github.com/aires-id/AiresDB")'
julia -e 'using Pkg; Pkg.Apps.add(url="https://github.com/aires-id/AiresDB")'
```

Untuk Windows PowerShell 5:

```powershell
julia -e 'using Pkg; Pkg.add(url=\"https://github.com/aires-id/AiresDB\")'
julia -e 'using Pkg; Pkg.Apps.add(url=\"https://github.com/aires-id/AiresDB\")'
```

## Pengembangan dari checkout

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
mendeklarasikan aplikasi `airesdb` melalui `[apps]` Julia 1.12.

Tidak ada workflow resmi yang membuka `.aires` langsung dari client.

Checklist maintainer untuk penerbitan ke General tersedia di
[docs/REGISTRATION.md](docs/REGISTRATION.md).
