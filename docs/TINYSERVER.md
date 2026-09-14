# AiresDB TinyServer

TinyServer is the only user-facing process that owns an AiresDB Engine and its
database files.

| Setting | Default |
|---|---:|
| Host | `127.0.0.1` |
| Port | `1972` |
| Data root | `./data` |
| HTTP header | 32 KiB |
| Request body | 8 MiB |
| Concurrent requests | 128 |
| Active sessions | 64 |
| Idle timeout | 600 seconds |
| Maximum session lifetime | 3,600 seconds |
| Query result rows | 100,000 |
| Query execution time | 30 seconds |
| JSON response body | 64 MiB |
| Query memory | 64 MiB |
| Query spill | 1 GiB |
| HTTP header timeout | 10 seconds |
| TLS minimum | TLS 1.3 when enabled |
| Login lockout | 5 failures / 60 seconds |
| Audit log | `.airesdb-audit.jsonl` |
| Audit rotation | 64 MiB and one `.1` file |

Start the service with `airesdb server`. The first start asks for the `root`
password twice. AiresDB stores a random salt and PBKDF2-HMAC-SHA256 hash through
OpenSSL; it never stores the original password.

Each login creates one AiresDB Session and a monotonic connection ID. A Session
holds the selected database and transaction state. Logout, expiry, and shutdown
close it, and the transaction manager rolls back any active transaction.

The server exposes four routes: `GET /health`, `POST /session`, `POST /query`,
and `DELETE /session`. It has no custom TCP protocol, WebSocket, gRPC, GraphQL,
JWT, cookie, or complex connection pool. Authentication uses a bearer token in
the `Authorization` header. Tokens in URLs or JSON bodies are rejected.

Loopback is the default. A non-loopback listener is rejected unless the server
has a TLS certificate and private key:

```text
airesdb server --host 0.0.0.0 --tls-cert-file server.crt --tls-key-file server.key
airesdb -u root -p --host db.example --tls --tls-ca-file ca.crt
```

Native TLS rejects incomplete certificate/key configuration and requires TLS
1.3 or newer. There is no insecure bypass for a non-loopback bind. A reverse
proxy on the same host should connect to the loopback listener; a cross-host
deployment must still use native TLS.

Credential format 2 stores `root` as an `admin`. Additional users can be
created from Julia:

```julia
initialize_user_credentials!(TinyServerConfig(data_root="data"),
    "analyst", "password-minimal-8"; role=:reader)
```

The `reader` role may run read-only queries and metadata commands. Data changes,
transactions, checkpoints, vacuum, and compaction require `admin`. RBAC uses the
parsed AiresQL statement instead of keyword substring matching.

TinyServer validates the request-size limit and bearer session before parsing a
`/query` JSON body. Query execution then enforces a deadline, output-row limit,
intermediate-row limit, query-owned allocation budget, spill budget, and
response limit. JSON size is preflighted before allocating its final buffer, and
the serialized response must fit the memory left by row materialization.

Login failures use bounded per-user lockout, and both tracked usernames and
active requests are capped. Sessions have idle and absolute lifetimes. The
JSONL audit records login, logout, authorization denial, query action, status,
query SHA-256, and connection ID without storing passwords, bearer tokens, or
query text. It rotates to `.1` at the configured size and fails closed if it
cannot be written. If a mutation completed but cleanup, response generation, or
auditing prevents acknowledgement, TinyServer returns `Commit Outcome Unknown`.
Inspect state before retrying that mutation. Use an external collector when
long-term audit retention is required.

Stack traces are never sent to the client. `--verbose` writes diagnostic detail
only to the server's standard error stream.
