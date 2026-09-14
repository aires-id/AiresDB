# Security Policy

## Supported version

AiresDB 0.1.x is the currently maintained release line.

## Reporting a vulnerability

Please use **Private vulnerability reporting** on the repository's GitHub
Security tab. Do not open a public issue for a report that contains an exploit,
credentials, private data, or risky reproduction steps.

Include the Julia and AiresDB versions, operating system, impact, minimal
reproduction steps, and whether the issue affects the parser, WAL, recovery,
MVCC, networking, or page format. Never attach a production database or a real
secret.

## TinyServer

TinyServer binds to `127.0.0.1:1972` by default. A non-loopback bind must be
selected explicitly and requires a native TLS certificate and private key.
There is no insecure bypass for a non-loopback listener; plaintext HTTP is
available only on loopback.

Passwords are stored as salted PBKDF2-HMAC-SHA256 hashes through OpenSSL.
Session tokens come from the operating system's secure random source and the
official client sends them only through the bearer header; tokens in a request
body or URL are rejected. The `reader` role is read-only, while mutations and
maintenance require `admin`.

Login failures use bounded per-user lockout. Sessions have idle and absolute
lifetimes. Header size, request body size, active requests, result rows, query
time, query-owned row allocations, response size, and spill bytes are bounded.
For `/query`, TinyServer validates the bearer session before parsing JSON, which
prevents unauthenticated requests from consuming the JSON parser budget.

The JSONL audit log records security events and query hashes without passwords,
tokens, or query text. It rotates at its configured size and requests fail
closed if the log cannot be written. A mutation that completed but could not be
acknowledged is reported as `Commit Outcome Unknown`; inspect database state
before retrying it. The health endpoint does not reveal the data root, WAL path,
operating-system username, or process internals.

The official CLI must never open `.aires`, `.aires.pages`, or `.aires.lock`
files. Please report it as a vulnerability if the CLI can access a database
without TinyServer.
