# Contoh AiresDB v0.1.0

Contoh CLI mempertahankan rasa AiresQL:

```powershell
airesdb server --data-root work/demo-server
airesdb -u root -p --no-banner --file examples/demo.txt
airesdb -u root -p --no-banner --file examples/reopen.txt
```

Perintah kedua membuka session server baru dan membaca database yang sama melalui
TinyServer.

Contoh API HTTP dengan dua session dan satu transaksi beberapa row:

```powershell
$env:AIRESDB_PASSWORD = "password-root"
julia --project=. examples/tinyserver_api.jl
```

Server harus sudah berjalan. Alamat default adalah `http://127.0.0.1:1972` dan
dapat diganti tanpa mengubah source:

```powershell
$env:AIRESDB_URL = "http://192.168.1.20:1972"
julia --project=. examples/tinyserver_api.jl
```

Contoh ini tidak mengimpor core engine dan tidak membuka file database. Kedua
session, state transaksi, dan eksekusi AiresQL dimiliki TinyServer.

Pada CLI, `.mvcc`, `.checkpoint`, dan `.vacuum` menyediakan operasi observasi dan
maintenance yang sama tanpa mengubah sintaks AiresQL.
