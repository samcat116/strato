# Shared Signals (SSF)

Strato can act as a [Shared Signals Framework](https://openid.net/specs/openid-sharedsignals-framework-1_0.html) *receiver*: organizations subscribe to CAEP/RISC security events from an external transmitter (typically an identity provider) and Strato responds automatically — revoking sessions, deactivating API keys, or disabling accounts.

## How it works

Each organization configures one or more **SSF streams**. A stream points at a transmitter's base URL (discovery happens against `<url>/.well-known/ssf-configuration`) and uses either delivery method:

- **Push (RFC 8935)** — the transmitter POSTs Security Event Tokens to `https://<strato>/ssf/events/<stream-id>`, authenticated with a per-stream bearer token that Strato generates at registration (stored hashed; shown once).
- **Poll (RFC 8936)** — Strato periodically drains the transmitter's poll endpoint (every `SSF_POLL_INTERVAL_SECONDS`, default 60; cluster-singleton across replicas).

Inbound SETs are signature-verified against the transmitter's JWKS, and their issuer/audience validated, before any action is taken.

## Signal responses

The SET subject (`email`, `iss_sub` via the user's OIDC link, `opaque` Strato user id, plus `aliases`/`complex` wrappers) is resolved to a user, and the action only applies if that user is a member of the stream's organization.

| Event | Action |
| --- | --- |
| CAEP `session-revoked`, RISC `sessions-revoked` | Revoke all of the user's sessions |
| RISC `account-credential-change-required` | Revoke all of the user's sessions |
| RISC `credential-compromise` | Revoke sessions and deactivate the user's API keys |
| RISC `account-disabled`, `account-purged` | Disable the account and revoke sessions |
| RISC `account-enabled` | Re-enable the account |
| SSF `verification` | Mark the stream verified |
| Anything else | Audited, no action |

Purge events never delete data — deletion stays a human decision. Every received event and applied action is recorded in the audit log (`ssf.*` event types).

## API

All management endpoints are organization-scoped (`/api/organizations/:orgID/ssf-streams`); reads require membership, mutations require org admin.

```
GET/POST           /api/organizations/:orgID/ssf-streams
GET/PUT/DELETE     /api/organizations/:orgID/ssf-streams/:id
POST               /api/organizations/:orgID/ssf-streams/:id/register
POST               /api/organizations/:orgID/ssf-streams/:id/verify
GET                /api/organizations/:orgID/ssf-streams/:id/status
POST               /api/organizations/:orgID/ssf-streams/:id/poll
```

Create a stream with the transmitter's URL, an optional management-API bearer token, and the delivery method, then `register` it. Registration creates the stream at the transmitter; for push streams the response includes the inbound bearer token (`pushToken`) exactly once — the transmitter is configured with it automatically via the stream's `authorization_header`.

## Configuration

| Variable | Purpose | Default |
| --- | --- | --- |
| `SSF_CALLBACK_BASE_URL` | Public base URL for push delivery endpoints | `WEBAUTHN_RELYING_PARTY_ORIGIN` |
| `SSF_POLL_INTERVAL_SECONDS` | Poll sweep cadence | `60` |
| `SSF_POLL_ENABLED` | Force the poll sweep on/off | on (off under tests) |

## Session revocation semantics

Revocation is epoch-based: each user carries a `session_epoch`, stamped into the session at login. A signal bumps the epoch, and every request from an older session is rejected (401) and its session destroyed. Sessions created before this feature carry no stamp and count as epoch 0, so they are revoked by the first bump too. Disabled accounts are rejected (403) for both session and API-key authentication.
