# Rate Limiting

The control plane throttles inbound HTTP traffic to blunt brute-force /
credential-stuffing against the authentication and passkey endpoints and to keep
unthrottled API or registration traffic from exhausting resources. Implemented by
`RateLimitMiddleware`, registered right after the session/bearer authenticators so
it can bucket by the resolved user, and ahead of authorization and the
controllers so throttled requests are rejected before doing real work.

## What gets limited

Two fixed-window policies are enforced per identity:

- **Auth** — `/auth/*` and `POST /api/users/register`. Strict: **10 requests / 60s**
  by default.
- **API** — every other route. Looser: **300 requests / 60s** by default.

Health probes (`/health`, `/health/*`) and WebSocket upgrades are never
throttled.

**Identity** is the authenticated user (`user:<uuid>`) when the request carries a
valid session or API key, otherwise the client IP (`ip:<addr>`). The client IP is
taken from `X-Forwarded-For` / `X-Real-IP` when present (the control plane is
expected to sit behind a trusted ingress), falling back to the socket peer.

## Exponential backoff on repeated auth failures

On top of the fixed window, an identity that keeps *failing* authentication
(`401`/`403` on an auth route) is locked out for a window that doubles with each
failure past a threshold — 2s, 4s, 8s, … capped at 300s. A successful
authentication clears the failure state, so a legitimate user who mistyped a few
times isn't penalised. Locked-out requests get a `429` with a `Retry-After`
header.

## Response headers

Throttled responses carry standard headers:

- `X-RateLimit-Limit` — the policy's ceiling for the window
- `X-RateLimit-Remaining` — requests left in the current window
- `X-RateLimit-Reset` — seconds until the window resets
- `Retry-After` — sent on `429` responses (both limit and lockout)

A rejected request returns `429 Too Many Requests` with a JSON body
(`{ "error": true, "reason": ... }`).

## Storage backend

Counters live in **Valkey/Redis** when it's configured (`VALKEY_HOST`), so the
limit is enforced consistently across every control-plane replica. Without Valkey
the limiter falls back to a **process-local** counter — correct for a single
instance, but with multiple replicas each enforces its own counters (roughly N×
the effective limit). Prefer Valkey for multi-node deployments.

If the backend errors, the limiter **fails open** (allows the request) rather than
taking down the API.

## Configuration

All limits are environment variables, so they can be tuned without a rebuild.
Defaults in parentheses.

| Variable | Default | Meaning |
|---|---|---|
| `RATE_LIMIT_ENABLED` | on outside `.testing` | Master switch (`true`/`false`). |
| `RATE_LIMIT_AUTH_MAX` | `10` | Auth requests allowed per window. |
| `RATE_LIMIT_AUTH_WINDOW` | `60` | Auth window, seconds. |
| `RATE_LIMIT_API_MAX` | `300` | API requests allowed per window. |
| `RATE_LIMIT_API_WINDOW` | `60` | API window, seconds. |
| `RATE_LIMIT_FAILURE_THRESHOLD` | `5` | Consecutive auth failures tolerated before lockout. |
| `RATE_LIMIT_FAILURE_BASE_DELAY` | `2` | First lockout duration, seconds (doubles thereafter). |
| `RATE_LIMIT_FAILURE_MAX_DELAY` | `300` | Cap on the lockout duration, seconds. |
| `RATE_LIMIT_FAILURE_WINDOW` | `900` | How long a run of failures is remembered, seconds. |
| `RATE_LIMIT_TRUST_FORWARDED_FOR` | `true` | Trust `X-Forwarded-For` for the client IP. Disable if clients can reach the control plane directly and could spoof it. |
| `RATE_LIMIT_TRUSTED_PROXY_HOPS` | `1` | Number of trusted proxies in front of the control plane. The client is read that many entries in from the **right** of `X-Forwarded-For`. Use `2` when a TLS terminator sits in front of nginx (`setup.sh` sets this for HTTPS deployments). |

::: warning These two variables describe the proxy chain, not just rate limiting
Despite the `RATE_LIMIT_` prefix (kept so existing deployments keep working), they
also govern the client address recorded in **audit events** (`sourceIP`) and on an
API key's **`lastUsedIP`**. Setting the hop count too low attributes every request
to your inner proxy; setting it too high lets a client forge its own address in the
audit trail. `X-Real-IP` is deliberately never consulted — behind a TLS terminator
nginx sets it to the terminator's address, which would collapse every client onto
one value.
:::
