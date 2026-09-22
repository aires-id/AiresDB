# Website integration

TinyServer is an HTTP/JSON database service, so it can sit behind a website.
For a production deployment, keep TinyServer and its data directory private to
your infrastructure and put the application's backend or reverse proxy at the
public boundary.

## Recommended architecture

```text
Browser  -- HTTPS -->  Website backend / reverse proxy  -- HTTPS or loopback -->  TinyServer
```

The browser authenticates to the website. The website backend manages its own
short-lived AiresDB session and maps user actions to the narrowly scoped
AiresQL statements it needs. This keeps database passwords and bearer tokens
out of browser JavaScript, local storage, URLs, analytics, and referrer logs.

Run TinyServer on loopback when the website backend is on the same host:

```text
airesdb server --data-root ./data
```

The backend can call `http://127.0.0.1:1972`; no CORS configuration is needed
for this server-to-server route. Use the documented login, query, and logout
sequence in [HTTP API](HTTP_API.md).

## Direct browser API access

Direct `fetch` access is supported only when all of these conditions are true:

1. TinyServer listens with TLS 1.3 or newer.
2. Every website origin is explicitly listed with `--cors-allow-origin`.
3. The browser is given a purpose-specific credential or short-lived token;
   never the `root` password or an administrator session.
4. The application treats session tokens as secrets and keeps them only in
   memory for the shortest practical time.

For example, a deployment for one web application can start TinyServer with:

```text
airesdb server --host 0.0.0.0 --tls-cert-file server.crt --tls-key-file server.key --cors-allow-origin https://app.example
```

For local browser development, add the local frontend origin separately:

```text
airesdb server --cors-allow-origin http://localhost:3000
```

The option may be repeated. Origins must be exact `http` or `https` origins,
including their port when present. Paths, wildcard origins, user credentials,
and query strings are rejected. CORS remains disabled when no origin is listed.
TinyServer answers browser preflight requests only for `GET`, `POST`, and
`DELETE` with the `Authorization` and `Content-Type` headers.

CORS controls which browser origins can read responses; it is not
authentication and does not replace TLS, RBAC, input validation, rate limiting,
or a website's own authorization checks.

## Browser request shape

Once a trusted login flow has provided an in-memory session token, a browser
request has this shape:

```javascript
async function airesQuery(apiBase, session, query) {
  const response = await fetch(`${apiBase}/query`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${session}`,
    },
    body: JSON.stringify({ query }),
  });
  const body = await response.json();
  if (!response.ok || body.ok !== true) throw new Error(body.error?.message ?? "AiresDB query failed");
  return body;
}
```

Close the session when the browser's unit of work ends:

```javascript
await fetch(`${apiBase}/session`, {
  method: "DELETE",
  headers: { Authorization: `Bearer ${session}` },
});
```

Do not place the token in the JSON body or use `/session/{token}`; those forms
are intentionally rejected. Mutating AiresQL statements are not automatically
retry-safe. If TinyServer reports `Commit Outcome Unknown`, inspect application
state before deciding whether to retry.
