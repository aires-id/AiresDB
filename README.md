<p align="center">
  <img src="AiresDB.png" alt="AiresDB logo" width="180">
</p>

<h1 align="center">AiresDB v0.1.0</h1>

<p align="center">
  A transactional database powered by Indonesian-language AiresQL.<br>
  <strong>Lightweight. Fast. Approachable. Affordable.</strong>
</p>

<p align="center">
  <img alt="Version 0.1.0" src="https://img.shields.io/badge/version-0.1.0-ffc107">
  <img alt="Julia 1.12" src="https://img.shields.io/badge/Julia-1.12-9558b2">
  <img alt="NCSA license" src="https://img.shields.io/badge/license-NCSA-blue">
</p>

AiresDB is a database server created by **Aires Zam Wibisono**. It stores data
in `.aires` files, provides serializable transactions through MVCC, and exposes
its supported user interface through the **TinyServer HTTP/JSON service** and
the `airesdb` command-line monitor.

> [!IMPORTANT]
> Thanks for trying AiresDB! **v0.1.0 is a technical preview.** It is intended
> for evaluation, learning, prototypes, and low-risk internal applications with
> tested backups. The SDEBO results demonstrate a strong correctness and
> recovery foundation, but this release is not yet recommended for production
> financial data. Please read [Version 0.1.0 status](#version-010-status) before
> deploying it.

## Why AiresDB?

- **Indonesian-language AiresQL**, with the `-:` statement terminator and
  multiline input.
- **ACID transactions and durable storage** through an embedded WAL, checksums,
  OS-level synchronization, automatic checkpoints, immutable WAL archives,
  LSN point-in-time restore, native backup/restore, and torn-tail recovery.
- **Optimistic serializable MVCC**, read-your-writes behavior, and
  first-committer-wins conflict handling.
- **ARSP-4 page storage** with 8 KiB pages, a slotted heap, RIDs, a bounded Clock
  buffer pool, and a persistent B+Tree.
- **Exact Decimal and Money values**, avoiding floating-point conversion in the
  JSON API.
- **One supported access path through TinyServer**, so clients never open
  database files as a fallback.
- **Server resource guards** for query time, result rows, response size, query
  memory, temporary spill bytes, request concurrency, and HTTP headers.
- **A practical optimizer foundation** with greedy multi-join ordering, table
  statistics, external hash-join spilling, and read-only `EXPLAIN`.
- **Reproducible correctness, recovery, concurrency, and benchmark suites** in
  this repository.

## Quick start

These steps install the `airesdb` app, start TinyServer, open the interactive
CLI monitor, and run a first AiresQL database. Complete the steps in order and
copy the command for the terminal you are actually using.

### 1. Check Julia

AiresDB currently requires **Julia 1.12**. Check the version available in your
terminal:

```text
julia --version
```

The output should begin with `julia version 1.12`. If `julia` is not found or
you have a different version, follow the friendly
[official Julia installation guide](https://julialang.org/install/) first.

### 2. Install AiresDB from GitHub

AiresDB is not yet listed in Julia's General registry, so the GitHub URL is the
current supported installation source. `Pkg.Apps.add` creates an isolated Julia
app environment and the `airesdb` launcher. The command adds the default General
registry only when a fresh Julia installation has no reachable registry, then
installs AiresDB directly from GitHub. The repository URL is passed as a Julia
argument, avoiding nested quote escaping.

Choose the command for your terminal and copy it exactly.

**Linux, macOS, or a Unix shell**

```sh
julia -e 'using Pkg; isempty(Pkg.Registry.reachable_registries()) && Pkg.Registry.add(); Pkg.Apps.add(url=ARGS[1])' https://github.com/aires-id/AiresDB
```

**Windows PowerShell**

```powershell
julia -e 'using Pkg; isempty(Pkg.Registry.reachable_registries()) && Pkg.Registry.add(); Pkg.Apps.add(url=ARGS[1])' https://github.com/aires-id/AiresDB
```

**Windows Command Prompt (`cmd.exe`)**

```bat
julia -e "using Pkg; isempty(Pkg.Registry.reachable_registries()) && Pkg.Registry.add(); Pkg.Apps.add(url=ARGS[1])" https://github.com/aires-id/AiresDB
```

> [!NOTE]
> PowerShell uses outer single quotes; Command Prompt uses outer double quotes.
> Do not copy the Unix or PowerShell form into Command Prompt. That shell does
> not use single quotes for argument grouping and Julia reports `character
> literal contains multiple characters`.

> [!NOTE]
> A first installation can take a few minutes while Julia downloads and
> precompiles dependencies. Please keep the terminal open until it reports that
> the `airesdb` app was installed.

> [!TIP]
> The shorter `Pkg.Apps.add("AiresDB")` form will work only after General
> registration is complete. For now, please use the GitHub URL command above.

### 3. Add the Julia app directory to `PATH`

Julia places app launchers in `~/.julia/bin` (on Windows,
`C:\Users\<you>\.julia\bin`). Add that directory to the current terminal
session before running `airesdb`.

**Linux or macOS**

```sh
export PATH="$HOME/.julia/bin:$PATH"
```

**Windows PowerShell**

```powershell
$env:Path += ";$env:USERPROFILE\.julia\bin"
```

**Windows Command Prompt**

```bat
set "PATH=%PATH%;%USERPROFILE%\.julia\bin"
```

First, confirm that the launcher works:

```text
airesdb --help
```

Then check the installed AiresDB version. On Linux, macOS, or PowerShell, run:

```sh
julia -e 'using Pkg; Pkg.Apps.status()'
```

Command Prompt users should use:

```bat
julia -e "using Pkg; Pkg.Apps.status()"
```

You should see `AiresDB v0.1.0` and the `airesdb` app in the output.

> [!TIP]
> The `PATH` commands above affect only the current terminal. Add
> `~/.julia/bin` (or `%USERPROFILE%\.julia\bin` on Windows) to your shell
> profile or user environment variables when you are ready to make the command
> available permanently.

### 4. Start TinyServer

Open the first terminal and run:

```text
airesdb server
```

On the first start, AiresDB asks you to create and confirm the password for the
`root` user. By default, TinyServer listens only on `127.0.0.1:1972` and stores
data in `./data`.

Keep this terminal open while you use AiresDB.

In a second terminal, verify that the server is ready before logging in:

```text
curl http://127.0.0.1:1972/health
```

The response is `{"ok":true,"server":"AiresDB","version":"0.1.0"}`.
In PowerShell, `Invoke-RestMethod http://127.0.0.1:1972/health` is an equivalent
command.

### 5. Open the CLI monitor

Open a second terminal and run:

```text
airesdb -u root -p
```

Enter the password created in the first terminal. When the
`AiresDB [(none)]>` prompt appears, the CLI is ready.

### 6. Run your first AiresQL database

Every AiresQL statement ends with `-:`. Multiline statements are normal: paste
this complete example into the connected CLI.

```text
Buat 'Demo' -:
Pilih 'Demo' -:

Buat Tabel 'Karyawan'
Isi 'No & Nama & Gaji'
Dengan 'No = I(P) & Nama = C(225&Not Null) & Gaji = U'
Auto_No -:

Isi Tabel 'Karyawan'
'Aires & 7500000'
'Fami & 5500000' -:

Pilih 'Nama & Gaji'
Dari 'Karyawan'
Dengan 'Gaji > 6000000'
M: 'Gaji Bawah' -:
```

The final query returns the `Aires` row with `7500000`. Use `.help` to see CLI
monitor commands, `.tables` to inspect the active database, and `.exit` when
finished; those monitor commands do not use `-:`.

That is the complete installation flow. For package-only installation, updates,
source checkouts, and troubleshooting, see the
[detailed installation guide](INSTALL.md). The [AiresQL syntax guide](#airesql-syntax-guide)
below covers the language you can use in the CLI.

## AiresQL syntax guide

AiresQL uses Indonesian keywords, with English explanations here. Start with
the runnable example above, then use this section as a practical reference
while working in the CLI.

### Rules to remember

- Keywords are case-insensitive; database, table, and column names are
  case-sensitive.
- Every database statement ends with `-:`. Newlines are allowed anywhere
  between keywords, so long statements can be formatted over several lines.
- A single-quoted block holds a name, a list of columns or values, or an
  expression. Use double quotes for text inside that block, such as
  `Dengan 'Nama = "Aires"' -:`.
- `&` separates columns, values, and sort items. It is **not** logical AND.
  Use `&:` for AND and `O:` for OR inside a condition.

| Token | Meaning |
|---|---|
| `-:` | End a statement |
| `&` | Separate columns, values, schema definitions, or sort items |
| `&:` / `O:` | Logical AND / OR inside an expression |
| `&&` | Separate projected columns from different joined tables |
| `&&&` | Separate table sources in a join |
| `M:` | Sort clause; use `Atas` for ascending or `Bawah` for descending |

### Core syntax

| Goal | Copyable AiresQL |
|---|---|
| Create or select a database | `Buat 'Nama' -:` / `Pilih 'Nama' -:` |
| Create an auto-numbered table | `Buat Tabel 'Karyawan' Isi 'Id & Nama & Gaji' Dengan 'Id = I(P) & Nama = C(225&Not Null) & Gaji = U' Auto_Id -:` |
| Insert one or more rows | `Isi Tabel 'Karyawan' 'Aires & 7500000' 'Fami & 5500000' -:` |
| Show all columns | `Pilih '*' Dari 'Karyawan' -:` or `Tampilkan 'Karyawan' -:` |
| Project and filter | `Pilih 'Nama & Gaji' Dari 'Karyawan' Dengan 'Gaji >= 6000000' -:` |
| Use a compound condition | `Pilih '*' Dari 'Karyawan' Dengan 'Gaji >= 6000000 &: Nama = "Aires"' -:` |
| Aggregate and group | `Pilih 'Divisi & Count(*) & Avg(Gaji)' Dari 'Karyawan' Grup Dari 'Divisi' -:` |
| Sort and limit | `Pilih 'Nama & Gaji' Dari 'Karyawan' M: 'Gaji Bawah & Nama Atas' Limit(10) -:` |
| Update matching rows | `Tabel_Upt 'Karyawan' Isi 'Gaji = Gaji + 500000' Dengan 'Id = 1' -:` |
| Delete matching rows | `Baris_Rmv 'Karyawan' Dengan 'Id = 1' -:` |
| Add or remove a column | `Tabel_Upt 'Karyawan' + Kolom 'Email' Dengan 'Email = C(225&Null)' -:` / `Kolom_Rmv 'Karyawan.Email' -:` |
| Create a live view | `Lihat 'GajiTinggi' Pilih 'Nama & Gaji' Dari 'Karyawan' Dengan 'Gaji > 6000000' -:` |
| Join two tables | `Pilih 'Karyawan.Nama && Divisi.Nama' Dari 'Karyawan &&& Divisi' Gabung Dengan 'Karyawan.DivisiId = Divisi.Id' -:` |
| Join several tables | `Pilih '*' Dari 'A &&& B &&& C' Gabung Dengan 'A.Id = B.AId &: B.Id = C.BId' -:` |
| Inspect a read-only plan | `EXPLAIN Pilih '*' Dari 'Karyawan' -:` |

`Tabel_Upt` and `Baris_Rmv` without `Dengan` affect every row in the table.
Use a condition unless that is explicitly your intention.

### Column types and constraints

Define columns in the `Dengan` block of `Buat Tabel` or `+ Kolom`.

| Type | Meaning | Example definition |
|---|---|---|
| `I` | Integer | `Id = I(P)` |
| `U` | Exact money value | `Gaji = U` |
| `D` | Exact decimal value | `Diskon = D` |
| `F` | Floating-point value | `Skor = F` |
| `B` | Boolean | `Aktif = B` |
| `C(n)` | Text with a maximum length | `Nama = C(225&Not Null)` |
| `T` | Date | `Lahir = T` |
| `W` | Time | `Masuk = W` |
| `Tw` | Date and time | `Dibuat = Tw` |

Use `P` for a primary key, `N` for a unique value, and `Null` or `Not Null` to
set nullability. Add `Auto_Id` (or `Auto_(Id)`) after the schema to make an
integer column auto-increment.

### Transactions and CLI commands

Autocommit is used outside a transaction. Use `Transaksi` when several changes
must succeed or fail together:

```text
Transaksi -:
Tabel_Upt 'Rekening' Isi 'Saldo = Saldo - 500000' Dengan 'Id = 1' -:
Tabel_Upt 'Rekening' Isi 'Saldo = Saldo + 500000' Dengan 'Id = 2' -:
Gabungkan -:
```

Use `Kembalikan -:` instead of `Gabungkan -:` to roll back. CLI monitor commands
are not AiresQL and therefore do not need `-:`: `.help`, `.databases`,
`.tables`, `.schema Nama`, `.current`, `.mvcc`, `.checkpoint`, `.vacuum`,
`.compact`, `.cancel`, and `.exit`.

For the full grammar, expression rules, literals, result ordering, views,
multi-join requirements, and error behavior, read the complete
[AiresQL reference](docs/AIRESQL.md). A smaller runnable script is available at
[examples/demo.txt](examples/demo.txt), and the [CLI guide](docs/CLI.md) covers
interactive use.

## Native backup and restore

Native backup captures a consistent WAL prefix while holding the required lock,
calculates its SHA-256 checksum, and publishes the result atomically. The
`.aires.pages` sidecar is not copied because it is a derived cache and is rebuilt
when the restored database is opened.

For maintenance jobs or scheduled tasks, use the path-based API:

```sh
julia --project=. -e 'using AiresDB; AiresDB.backup_database!("./data", "Perusahaan", "./backup/Perusahaan.aires.bak")'
julia --project=. -e 'using AiresDB; AiresDB.restore_database!("./data-restored", "Perusahaan", "./backup/Perusahaan.aires.bak")'
```

Restoring over an existing database requires `overwrite=true`. Stop every
session and AiresDB process that uses the target before running it:

```julia
using AiresDB
AiresDB.restore_database!("./data", "Perusahaan", "./backup/Perusahaan.aires.bak";
    overwrite=true)
```

A backup is accepted only after its header, size, checksum, and every WAL frame
have been validated. Its embedded database name must match the restore target,
which helps prevent accidental backup mix-ups. Inside one AiresDB process,
restore publication and database opening share a maintenance gate, preventing a
new session from attaching between validation and atomic replacement. The WAL
lock coordinates publication between processes, but operators must still stop
every process using the target before an overwrite restore.

To reclaim physical space in `.aires.pages` after many updates or deletes, run
compaction while only one AiresDB process and one session are active:

```julia
using AiresDB
AiresDB.compact_page_store!("./data", "Perusahaan")
```

`vacuum!` and `.vacuum` remove old MVCC history logically. Physical compaction
is a separate maintenance operation that may replace the sidecar from the
authoritative WAL.

## Automatic checkpoints and point-in-time restore

TinyServer automatically archives the current verified WAL segment before it
publishes a replacement checkpoint. This keeps normal commits fast: archive
copying and checkpoint serialization run only in the maintenance timer, never
for each transaction. The default policy checkpoints an active database at
64 MiB of WAL or after 300 seconds, whichever comes first. Archives default to
`<data-root>/wal-archive`.

For a production deployment, put the archive on a separate, capacity-planned
volume and set a fail-safe capacity guard:

```text
airesdb server --data-root D:\AiresDB\data --wal-archive-directory E:\AiresDB-archive --wal-archive-max-bytes 21474836480 --auto-checkpoint-wal-bytes 67108864 --auto-checkpoint-interval 300
```

If an archive fails or reaches the configured limit, AiresDB refuses the
checkpoint and retains the authoritative WAL instead of silently shortening the
recovery window. A local archive is still not a substitute for an off-host
backup policy.

Each archive is independently restorable. List points and restore either the
latest record or an exact earlier committed LSN:

```julia
using AiresDB

points = AiresDB.list_wal_archives("E:/AiresDB-archive", "Perusahaan")
point = last(points)
AiresDB.restore_database_at!("./restored", "Perusahaan", "E:/AiresDB-archive", point.id)
AiresDB.restore_database_at!("./restored-before-change", "Perusahaan",
    "E:/AiresDB-archive", point.id; lsn=point.lsn - 1)
```

Stop all sessions and AiresDB processes that use the restore target first. The
derived `.aires.pages` sidecar is rebuilt on the next open. See
[automatic checkpoints, WAL archives, and PITR](docs/DURABILITY.md) for
capacity, timing, integrity, and timestamp-selection details.

## Architecture

```text
CLI / Browser / Python / PHP / C# / Go / Java / Julia
                            |
                        HTTP/JSON
                            |
                            v
               AiresDB TinyServer :1972
                            |
                  one Engine, many Sessions
                            |
          MVCC + WAL + ARSP-4 + PageStore + B+Tree
                            |
                           Disk
```

Supported clients never open `.aires`, `.aires.pages`, or `.aires.lock` files.
If TinyServer is unavailable, the client returns a connection error instead of
falling back to embedded access. Low-level engine APIs live in
`AiresDB.Internal` for tests and benchmarks and are not a stable application
contract.

Version 0.1.0 exposes four public routes:

| Method | Endpoint | Purpose |
|---|---|---|
| `GET` | `/health` | Return server health and version information |
| `POST` | `/session` | Authenticate and create a session |
| `POST` | `/query` | Run AiresQL in an authenticated session |
| `DELETE` | `/session` | Close the bearer-token session and roll back its active transaction |

Decimal and Money values use tagged objects such as
`{"type":"decimal","value":"12.34"}`; `NULL` is represented as JSON `null`.
See the [HTTP API documentation](docs/HTTP_API.md) for the complete contract and
client examples. For a website deployment, including a secure browser setup,
see [Website integration](docs/WEB.md).

## SDEBO-S750 results

The **SDEBO 1.0 / SDEBO-S750** evaluation ran from 9-11 September 2026 against
AiresDB 0.1.0 and Firebird 5.0.4.1812. Both engines used the same logical dataset
of 750,000 rows with seed `1999`, embedded mode, and synchronous durability on a
Windows 10 host with an Intel Core i5-2400S (4 cores/4 threads), 8 GiB RAM, and
an SSD.

| Engine | Weighted score | Class | Medium Office | Small Bank Technical |
|---|---:|---|---|---|
| **AiresDB 0.1.0** | **3.74 / 4.00** | Excellent | PASS | PASS |
| Firebird 5.0.4.1812 | 3.93 / 4.00 | Excellent | PASS | PASS |

Median summary from five performance runs:

| Workload | Metric | AiresDB | Firebird | Relative result |
|---|---|---:|---:|---|
| Q01 bulk load | rows/s, higher is better | **23,102.86** | 1,808.66 | AiresDB 12.77x |
| Q02 point lookup | p95 ms, lower is better | 2.5221 | **0.4062** | Firebird 6.21x |
| Q03 range query | p95 ms, lower is better | 2.5378 | **0.3107** | Firebird 8.17x |
| Q04 ordered query | p95 ms, lower is better | **2.4700** | 3.8637 | AiresDB 1.56x |
| Q05 aggregate | p50 ms, lower is better | 1,094.0640 | **995.9056** | Firebird 1.10x |
| Q06 join | p50 ms, lower is better | 27.8837 | **5.4890** | Firebird 5.08x |
| Q07 full scan | rows/s, higher is better | **159,818.51** | 41,399.76 | AiresDB 3.86x |
| T01 insert transaction | p95 ms, lower is better | 3.6527 | **1.9083** | Firebird 1.91x |
| T02 update transaction | p95 ms, lower is better | 3.4907 | **1.6259** | Firebird 2.15x |

AiresDB passed the correctness gate with 1,000 atomic transfers across five
crash boundaries, 200 rollback cycles, four-worker concurrency without lost
updates, five process-kill recoveries, reopen/index verification, and three
corruption scenarios without silent mismatch. The 15-minute soak completed
20,298 operations without errors; memory growth was 13.90%, earning grade B.

Please keep these limitations in mind when interpreting the results:

- The host had 4 logical CPUs, below the document's 8-thread recommendation.
- Hard VM power-off was unavailable, so each engine used five external process
  terminations.
- R01 ran before native backup was available and therefore used an offline
  checkpoint plus file copy. The current native API validates WAL and publishes
  restores atomically.
- An early, unscored T05 attempt found an engine/PageStore lifecycle issue when
  separate `Engine` objects in one process closed while another worker
  committed. PageStore ownership leases and regression tests now cover it.
- "Small Bank Technical PASS" is an SDEBO engineering gate, not a certification,
  security audit, or approval for banking use.

Lightweight public evidence is included in the repository:

- [PDF report](Standard%20Database%20for%20Banking%20and%20Office%20Test/SDEBO-S750-AiresDB-vs-Firebird-20260909/SDEBO_Report.pdf)
- [Structured JSON result](Standard%20Database%20for%20Banking%20and%20Office%20Test/SDEBO-S750-AiresDB-vs-Firebird-20260909/result.json)
  and [CSV result](Standard%20Database%20for%20Banking%20and%20Office%20Test/SDEBO-S750-AiresDB-vs-Firebird-20260909/result.csv)
- [Environment](Standard%20Database%20for%20Banking%20and%20Office%20Test/SDEBO-S750-AiresDB-vs-Firebird-20260909/environment.json),
  [raw metrics](Standard%20Database%20for%20Banking%20and%20Office%20Test/SDEBO-S750-AiresDB-vs-Firebird-20260909/raw/),
  and [recovery evidence](Standard%20Database%20for%20Banking%20and%20Office%20Test/SDEBO-S750-AiresDB-vs-Firebird-20260909/recovery/)
- [SDEBO 1.0 specification](Standard%20Database%20for%20Banking%20and%20Office%20Test/SDEBO_Test_Specification_v1.0_publication.docx)

Large working databases, backups, generated datasets, and temporary files are
intentionally excluded from Git. All evidence includes SHA-256 manifests and
can be reproduced with the
[SDEBO harness](Standard%20Database%20for%20Banking%20and%20Office%20Test/harness/).

## Version 0.1.0 status

For evaluation deployments, use one shared `Engine` per data root inside the
server process, tested native backups, local storage with durable flush support,
and TinyServer on loopback. TinyServer provides native TLS 1.3+, `admin` and
`reader` roles, login lockout, bounded requests, and fail-closed JSONL auditing.
LAN or public access requires a certificate and private key; non-loopback
plaintext has no bypass.

The main work remaining before recommending AiresDB for financial production is:

1. Broader concurrency stress, fault injection, hard-power-off testing, and an
   independent audit.
2. Credential rotation, centralized audit retention, optional mTLS, and further
   network hardening.
3. Lower memory use and tail latency under soak and mixed workloads.
4. Broader planner, physical operator, and I/O observability coverage.

The internal delta/checkpoint format is not yet a stable external API, and
legacy format migration is one-way. Please read the
[v0.1.0 release notes](docs/RELEASE-v0.1.0.md) before upgrading and the
[roadmap](docs/ROADMAP.md) for planned work.

## Security and operations

TinyServer binds to loopback by default. A non-loopback listener requires native
TLS:

```text
airesdb server --host 0.0.0.0 --tls-cert-file server.crt --tls-key-file server.key
airesdb -u root -p --host db.example --tls --tls-ca-file ca.crt
```

Without TLS, every non-loopback bind is rejected. A reverse proxy on the same
host should connect to the loopback listener; cross-host connections must still
use native TLS.

The `root` password is stored as a salted PBKDF2-HMAC-SHA256 hash. The credential
file supports `admin` and `reader` roles: readers may run read-only queries and
metadata commands, while mutations and maintenance require an administrator.
Authentication uses bounded per-user lockout, and sessions have both idle and
absolute lifetimes. RBAC decisions use the parsed AiresQL AST.

For `/query`, TinyServer checks the body-size limit and validates the bearer
session before parsing JSON. Query-owned row allocations are charged against
the memory budget, large hash joins spill to bounded temporary storage, and the
JSON response size is preflighted before its final buffer is allocated. The
response must fit both its configured limit and the query memory remaining
after row materialization.

The default `.airesdb-audit.jsonl` log records events, users, roles, actions,
statuses, query hashes, and connection IDs without storing passwords, bearer
tokens, or query text. It rotates to `.1` at 64 MiB and requests fail closed when
the log cannot be written. If a mutation finishes but its acknowledgement fails,
the client receives `Commit Outcome Unknown` and should inspect state before
retrying. Session tokens come from the operating system's secure random source
and are accepted only through `Authorization: Bearer`.

Default resource limits:

| Limit | Default |
|---|---:|
| HTTP header | 32 KiB |
| Request body | 8 MiB |
| Concurrent requests | 128 |
| Active sessions | 64 |
| Idle session timeout | 10 minutes |
| Maximum session lifetime | 60 minutes |
| Query result rows | 100,000 |
| Query execution time | 30 seconds |
| JSON response body | 64 MiB |
| Query-owned memory (also the join spill threshold) | 64 MiB |
| Query spill budget | 1 GiB |
| Audit log rotation | 64 MiB |

Please report vulnerabilities through [SECURITY.md](SECURITY.md).

## Development and verification

```sh
julia --startup-file=no --project=. -e "using Pkg; Pkg.test()"
```

The suite covers the lexer/parser, AiresQL, exact numeric types, MVCC,
WAL/recovery, ARSP-4, PageStore, B+Tree, TinyServer, authentication, resource
limits, persistence, transactions, and benchmark correctness. The TPC-C-derived
and TPC-H-derived workloads in this repository are not official or certified
TPC results. Pull-request CI runs the package suite on Ubuntu and Windows with
both one and four Julia threads, and verifies the installed app launcher on each
operating system.

Main documentation:

- [Architecture](docs/ARCHITECTURE.md)
- [AiresQL](docs/AIRESQL.md)
- [Transactions and MVCC](docs/TRANSACTIONS.md)
- [File format](docs/FORMAT.md)
- [ARSP-4 storage](docs/STORAGE.md)
- [WAL and recovery](docs/WAL.md)
- [TinyServer](docs/TINYSERVER.md)
- [HTTP API](docs/HTTP_API.md)
- [Website integration](docs/WEB.md)
- [CLI](docs/CLI.md)
- [Benchmarks](docs/BENCHMARKS.md)
- [v0.1.0 technical audit](docs/AUDIT-v0.1.0.md)
- [Contributing guide](CONTRIBUTING.md)

## License

AiresDB is distributed under the **University of Illinois/NCSA Open Source
License**, SPDX identifier `NCSA`. The complete license text is in
[LICENSE](LICENSE), and [NOTICE](NOTICE) explains its distribution scope.
Product source files use short SPDX headers instead of repeating the full
license in every file.

Source redistributions must retain the copyright notice, terms, and disclaimer.
Binary distributions must reproduce them in documentation or other included
materials. The AiresDB name and the names of copyright holders or contributors
may not be used for endorsement without written permission.

## Team

AiresDB is built by the **Open Aires Team** at Institut Teknologi Sumatera:

- **Team Lead:** Aires Zam Wibisono
- **Benchmarking Specialist:** I Made Raditya Mahardika
- **Support Engineer:** Suma Yasa
