# Deployment Overview

Strato has two supported deployment paths, both secure by default — strong
secrets are generated on first run, with no insecure fallbacks to remember to
turn off:

- **[Docker Compose](/deployment/docker-compose)** — a single host, the
  fastest way to a real deployment.
- **[Kubernetes (Helm)](/deployment/kubernetes)** — clusters and HA.

VMs run on **[agents](/deployment/agents)** — hypervisor hosts joined with a
one-line command.

## Session lifetime

Browser sessions live in Valkey and expire after a period of inactivity — every
request a session makes slides its expiry, so only abandoned sessions are
reclaimed. The idle window defaults to 7 days and is set with
`SESSION_TTL_SECONDS` (seconds; values under 60 are ignored). Shorten it for
stricter re-authentication; note it bounds inactivity, not total session age.

## WebAuthn hostname requirements

Strato authenticates users exclusively with WebAuthn/Passkeys, which browsers
gate behind strict origin rules. Misconfiguring this is the most common
first-run problem ("Passkeys not supported"):

1. **HTTPS is required** for any hostname except `localhost`.
2. **The configured origin must exactly match the URL in the browser** —
   scheme, host, and port. Both deployment paths configure
   `WEBAUTHN_RELYING_PARTY_ID` and `WEBAUTHN_RELYING_PARTY_ORIGIN` from your
   hostname; change them (and re-register users) if the hostname changes.
3. **Credentials are bound to the origin**: users registered under one
   hostname cannot log in under another.

### Troubleshooting

- **"Passkeys not supported"** — origin mismatch or HTTP on a non-localhost
  hostname.
- **"Invalid domain"** — relying party ID doesn't match the URL's domain.
- **Registration fails silently** — check the browser console for WebAuthn
  errors, and see [WebAuthn Debugging](/debugging/webauthn).
- **Existing users can't log in after a hostname change** — expected;
  credentials are origin-bound.
