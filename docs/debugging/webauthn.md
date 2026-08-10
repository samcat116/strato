# WebAuthn Debugging Guide

Strato's interactive login is WebAuthn passkeys. Registration and login fail
when the relying-party configuration does not match the origin the browser
actually visits, so almost every WebAuthn problem is an origin mismatch.

## How it's configured

The control plane reads three environment variables (defaults in
parentheses):

- `WEBAUTHN_RELYING_PARTY_ID` (`localhost`) — the domain only, no scheme or
  port.
- `WEBAUTHN_RELYING_PARTY_NAME` (`Strato`) — display name shown by the
  browser.
- `WEBAUTHN_RELYING_PARTY_ORIGIN` (`http://localhost:8080`) — the **exact**
  origin in the browser's address bar: scheme + host + port (port only if
  non-standard).

Browsers additionally require a secure context: HTTPS everywhere, with plain
HTTP allowed only for `localhost`. There is no way to use WebAuthn on
`http://<some-ip>` or `http://<hostname>` — put TLS in front or use
`localhost`.

| Access method | RELYING_PARTY_ID | RELYING_PARTY_ORIGIN |
|---------------|------------------|----------------------|
| `http://localhost` (compose default) | `localhost` | `http://localhost` |
| `http://localhost:8080` (native `swift run`) | `localhost` | `http://localhost:8080` |
| `https://strato.example.com` | `strato.example.com` | `https://strato.example.com` |

## Docker Compose

`deploy/compose/setup.sh` writes all three variables into
`deploy/compose/.env`. The browser enters through the nginx proxy on
`${HTTP_PORT:-80}`, so the default origin is `http://localhost` (no `:8080`
anywhere). For a real hostname:

```bash
./setup.sh --hostname strato.example.com   # non-localhost forces https://
```

`setup.sh` is idempotent and never overwrites an existing `.env`. To change
the hostname on an existing deployment, edit `.env` directly —
`STRATO_HOSTNAME`, the three `WEBAUTHN_*` variables, plus
`CONTROL_PLANE_URL`/`BASE_URL` — then redeploy:

```bash
./redeploy.sh
```

Use `redeploy.sh`, not `docker compose up -d control-plane`: the config
change recreates the control-plane container, which strands the `envoy` and
`spire-api-bridge` containers sharing its network namespace — agent
enrollment then fails with a misleading "SPIRE server unreachable" error.
See [Operations](/deployment/docker-compose#operations).

Changing the relying-party ID orphans existing passkeys; users must
re-register.

## Helm

Set `strato.webauthn.relyingPartyId` / `relyingPartyName` /
`relyingPartyOrigin` in your values. When left empty, the chart derives the ID
and HTTPS origin from the Gateway hostname, falling back to `localhost` and
`http://localhost:8080` — which match a plain `kubectl port-forward` to the
service port.

## Native `swift run`

The defaults (`localhost` / `http://localhost:8080`) match browsing to
`http://localhost:8080` with no configuration at all.

## Debugging steps

1. **Compare origins.** Run `location.origin` in the browser console and
   check it is byte-for-byte identical to `WEBAUTHN_RELYING_PARTY_ORIGIN`.
   Watch for a missing or extra port, `http` vs `https`, and `www.`.
2. **Check the network tab** during registration/login — the control plane
   rejects a mismatched origin with an error naming the expected one.
3. **Clear site data** (developer tools → Application/Storage) after any
   configuration change, then reload and retry.

## Common issues

| Error | Cause | Solution |
|-------|-------|----------|
| "Invalid domain" / SecurityError | RELYING_PARTY_ID is not the domain being visited | Set the ID to the exact hostname (no scheme/port) |
| Ceremony rejected by server | Origin mismatch | Make RELYING_PARTY_ORIGIN exactly match the browser URL |
| Passkey prompt never appears | Non-localhost HTTP | Browsers refuse WebAuthn outside a secure context — use HTTPS or localhost |
| Login fails after a hostname change | Passkeys are bound to the old relying-party ID | Re-register users under the new hostname |
