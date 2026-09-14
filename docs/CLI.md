# AiresDB monitor CLI

The official CLI is an HTTP client for TinyServer.

```sh
airesdb -u root -p
airesdb -h 192.168.1.20 -P 1972 -u root -p
airesdb -u root -p --no-banner --file script.txt
```

Passwords are hidden on an interactive terminal. The banner appears only in an
interactive session and can be disabled with `--no-banner`. The initial prompt
is `AiresDB [(none)]>` and changes to `AiresDB [Name]>` after selecting a
database. Multiline statements use the `->` prompt and must end with `-:`.

Monitor commands are `.help`, `.databases`, `.tables`, `.schema Name`,
`.current`, `.mvcc`, `.checkpoint`, `.vacuum`, `.compact`, `.cancel`, and
`.exit`. Engine commands run through the server session. `.exit` deletes the
remote session.

`.vacuum` removes obsolete MVCC history logically. `.compact` physically
rebuilds `.aires.pages` and requires database maintenance with one active
session and one AiresDB process.

If the server is unavailable, the CLI prints `ERROR A1000`, exits with a nonzero
status, and never opens a local database file as a fallback.

For larger analytical queries, server mode provides external hash-join spill
limits:

```sh
airesdb server --max-query-memory-bytes 67108864 --max-query-spill-bytes 1073741824
```

The query memory budget limits query-owned row materialization and determines
when a hash join partitions its build input into temporary runs. The spill
budget prevents unbounded temporary disk use. TinyServer removes runs after the
query succeeds or fails.
