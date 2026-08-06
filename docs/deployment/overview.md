# Deployment Overview

Strato has two supported deployment paths, both secure by default — strong
secrets are generated on first run, with no insecure fallbacks to remember to
turn off:

- **[Docker Compose](/deployment/docker-compose)** — a single host, the
  fastest way to a real deployment.
- **[Kubernetes (Helm)](/deployment/kubernetes)** — clusters and HA.

VMs run on **[agents](/deployment/agents)** — hypervisor hosts joined with a
one-line command.

## What's where

| Page | Covers |
|---|---|
| [Docker Compose](/deployment/docker-compose) | The single-host stack: setup, services, secrets, upgrades |
| [Kubernetes (Helm)](/deployment/kubernetes) | The chart: Gateway exposure, credentials, SPIRE, production values |
| [Agents](/deployment/agents) | Enrolling hypervisor nodes, remote updates, mTLS, connectivity |
| [IAM & Access](/deployment/iam) | Self-registration, WebAuthn, OIDC claim mapping, programmatic credentials |
| [Health checks](/deployment/health-checks) | The `/health` endpoints, probes, graceful shutdown, blue/green |
| [Rate limiting](/deployment/rate-limiting) | Request throttling, auth lockout, proxy trust for client IPs |
| [Logging](/deployment/logging) | Getting stdout logs captured reliably; the HTTP request log |
| [Audit logging](/deployment/audit-logging) | The who-did-what trail: event types, backends, retention |
| [Shared Signals (SSF)](/deployment/shared-signals) | Receiving IdP security events (session revocation, user disable) |
| [Observability](/deployment/observability) | OTel metrics/traces, the metric catalog, the alert runbook |

## Session lifetime

Browser sessions live in Valkey and expire after a period of inactivity — every
request a session makes slides its expiry, so only abandoned sessions are
reclaimed. The idle window defaults to 7 days and is set with
`SESSION_TTL_SECONDS` (seconds; values under 60 are ignored). Shorten it for
stricter re-authentication; note it bounds inactivity, not total session age.

By default sessions share the Valkey instance the coordination layer uses. The
two can be separated with `SESSION_VALKEY_*`, which is worth doing: coordination
is fail-open, session storage is not, so sharing one instance lets a
coordination problem log everyone out. See
[docker-compose](/deployment/docker-compose#splitting-session-storage).

## Self-registration

By default anyone who can reach the sign-in screen can create an account from
it. Deployments that provision users themselves — admin invitations or SSO —
close that door with `SELF_REGISTRATION_ENABLED=false` (Helm:
`strato.selfRegistrationEnabled: false`). The sign-in screen then stops
offering account creation and `POST /api/users/register` is refused, so the
setting holds even against someone who types `/register` directly.

The first account is the exception: it can always be created, whatever the
setting says. An installation with no users has no administrator who could
invite anyone, so refusing there would lock everyone out permanently. As soon
as that account exists the door closes again — meaning you can ship the setting
disabled from day one and still complete first-run setup. To bootstrap without
a browser at all, use the `bootstrap` command instead (see
[Docker Compose](/deployment/docker-compose#without-a-browser-ci-automation)).

Existing users are unaffected: this gates account creation only, not sign-in,
invitations, SCIM provisioning, or SSO.

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
