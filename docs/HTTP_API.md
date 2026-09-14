# AiresDB TinyServer HTTP API

TinyServer exposes a JSON API for supported AiresDB clients. The default base
URL is `http://127.0.0.1:1972`. Requests that include a body must use
`Content-Type: application/json`; all JSON responses use UTF-8.

The service does not use cookies, JWTs, query-string tokens, or a custom TCP
protocol. A login returns a random bearer token. Send it only in the
`Authorization` header, keep it out of logs and URLs, and delete the session
when the unit of work is complete.

## `GET /health`

This unauthenticated endpoint verifies that TinyServer is accepting requests.

```json
{"ok":true,"server":"AiresDB","version":"0.1.0"}
```

## `POST /session`

Authenticate a local AiresDB user and create one server session.

```http
POST /session
Content-Type: application/json

{"user":"root","password":"replace-this-password"}
```

A successful login returns HTTP `201`:

```json
{"ok":true,"session":"64-hex-character-token","connection_id":1}
```

The token has an idle and absolute expiry. Login failures are rate limited and
lock out the affected username temporarily. The plaintext password is never
written to the credential file or audit log.

## `POST /query`

Run one AiresQL statement, or one supported monitor command, in the authenticated
server session. The JSON body contains only `query`; the bearer token belongs in
the header.

```http
POST /query
Authorization: Bearer 64-hex-character-token
Content-Type: application/json

{"query":"Pilih 'Demo' -:"}
```

A query response contains `ok`, `columns`, `types`, `rows`, `row_count`,
`elapsed_ms`, the active `database`, and transaction state. Command responses
use `message` instead of table columns. Decimal and Money values are tagged
objects such as `{"type":"decimal","value":"12.34"}`; SQL `NULL` is JSON
`null`.

The `admin` role can run reads, writes, and maintenance commands. The `reader`
role can run only read-only queries and metadata commands. AiresQL statements
that mutate data should be treated as non-idempotent. If the response reports
`Commit Outcome Unknown`, inspect the database state before retrying.

## `DELETE /session`

Close the session identified by the bearer token and roll back an active
transaction.

```http
DELETE /session
Authorization: Bearer 64-hex-character-token
```

The successful response is `{"ok":true}`. There is no `/session/{token}`
route, and the token is not accepted in a JSON body.

## Errors

Errors use a stable JSON shape:

```json
{"ok":false,"error":{"code":"A3001","category":"Transaction Conflict","message":"..."}}
```

| HTTP status | Code | Meaning |
|---:|---|---|
| 400 | `A1003` or `A2000` | Invalid request or AiresQL error |
| 401 | `A1001` or `A1002` | Login denied, invalid, or expired session |
| 403 | `A1006` | Role or CORS preflight authorization denied |
| 409 | `A3001` | Serializable transaction conflict |
| 413 | `A1004` | Request exceeds the configured body limit |
| 429 | `A1005` | Request, login, query, or result resource limit |
| 503 | `A3002` or `A5001` | Commit outcome unknown or audit service unavailable |

TinyServer never returns stack traces to clients.

## CORS and browser clients

CORS is disabled by default. Same-origin browser traffic through a reverse
proxy does not require a TinyServer CORS setting. A direct browser integration
must use HTTPS and an explicit origin allowlist; see [Website integration](WEB.md).
Do not put an AiresDB administrator password or long-lived bearer token in
browser JavaScript.

## Server-side client sketch

Use the same sequence in any HTTP library: login, send the bearer token on each
query, then delete the session.

```javascript
const baseUrl = process.env.AIRESDB_URL;

async function airesFetch(path, options = {}) {
  const response = await fetch(`${baseUrl}${path}`, options);
  const body = await response.json();
  if (!response.ok || body.ok !== true) throw new Error(body.error?.message ?? "AiresDB request failed");
  return body;
}

const login = await airesFetch("/session", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ user: process.env.AIRESDB_USER, password: process.env.AIRESDB_PASSWORD }),
});

try {
  const result = await airesFetch("/query", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${login.session}` },
    body: JSON.stringify({ query: "Pilih 'Demo' -:" }),
  });
  console.log(result.rows);
} finally {
  await fetch(`${baseUrl}/session`, { method: "DELETE", headers: { Authorization: `Bearer ${login.session}` } });
}
```
