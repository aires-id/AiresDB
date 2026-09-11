# Registrasi AiresDB di Julia General

Dokumen ini adalah checklist maintainer untuk rilis perdana `v0.1.0`. Versi di
`Project.toml` tetap `0.1.0` selama proses registrasi pertama.

## Persiapan repository

1. Merge perubahan kesiapan registrasi hanya setelah CI pull request lulus.
2. Ubah nama repository GitHub dari `AiresDB` menjadi `AiresDB.jl`. Aturan
   AutoMerge General meminta URL berbentuk
   `https://github.com/aires-id/AiresDB.jl.git`. Redirect GitHub menjaga URL
   clone lama tetap berfungsi.
3. Pastikan branch default bersifat publik dan commit yang akan didaftarkan
   dapat menjalankan `import AiresDB` pada Julia 1.12.
4. Jangan membuat tag rilis lain untuk versi `0.1.0`. Registrator menentukan
   tree yang didaftarkan dari commit tempat perintah registrasi dijalankan.

## Mengirim registrasi

1. Instal GitHub App
   [Julia Registrator](https://github.com/apps/julia-registrator) untuk
   repository `aires-id/AiresDB.jl`.
2. Buka commit hasil merge di GitHub dan buat komentar:

   ```text
   @JuliaRegistrator register

   Release notes:

   Initial technical-preview release of AiresDB, including the AiresQL engine,
   MVCC transactions, durable WAL recovery, page-based storage, TinyServer,
   and the `airesdb` Julia app.
   ```

3. Registrator akan membuka pull request di
   [JuliaRegistries/General](https://github.com/JuliaRegistries/General).
   Periksa hasil AutoMerge dan perbaiki sumber masalah pada repository ini,
   lalu jalankan ulang komentar Registrator bila diperlukan.
4. Registrasi paket baru memiliki masa tunggu tiga hari untuk tinjauan
   komunitas. Setelah PR General digabung, `Pkg.add("AiresDB")` akan tersedia
   setelah pembaruan registry mencapai pengguna.
5. Workflow TagBot membuat tag dan GitHub release dari versi yang sudah masuk
   registry. Jika GitHub menolak TagBot karena commit rilis mengubah file
   workflow, buat tag `v0.1.0` dan GitHub release secara manual pada commit yang
   tree-nya didaftarkan.

## Verifikasi setelah registrasi

Gunakan depot sementara agar pengujian tidak memakai checkout pengembangan:

```sh
julia -e 'using Pkg; Pkg.activate(; temp=true); Pkg.add("AiresDB"); import AiresDB'
julia -e 'using Pkg; Pkg.Apps.add("AiresDB")'
airesdb --help
```

Referensi resmi:

- [General registry](https://github.com/JuliaRegistries/General)
- [Registrator](https://github.com/JuliaRegistries/Registrator.jl)
- [Pkg apps](https://pkgdocs.julialang.org/v1/apps/)
- [RegistryCI AutoMerge guidelines](https://juliaregistries.github.io/RegistryCI.jl/stable/guidelines/)
