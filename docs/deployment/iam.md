# IAM & Access Configuration

The deployment knobs that decide who can sign in and how programmatic
clients authenticate. The policy model itself — Cedar roles, bindings,
guardrails, the org → folder → project hierarchy — is documented in
[IAM architecture](/architecture/iam); this page is the operator-facing
configuration.

## Self-registration

`SELF_REGISTRATION_ENABLED` (Helm: `strato.selfRegistrationEnabled`) gates
whether visitors can create their own accounts from the sign-in screen.
The first account is always creatable, so first-run setup works with it
disabled — full semantics and the bootstrap path are in
[Self-registration](/deployment/overview#self-registration).

## WebAuthn (passkeys)

Interactive sign-in is WebAuthn only; there is no password fallback. Three
variables configure it:

| Variable | Meaning |
|---|---|
| `WEBAUTHN_RELYING_PARTY_ID` | The domain, without scheme or port |
| `WEBAUTHN_RELYING_PARTY_NAME` | Display name browsers show during registration |
| `WEBAUTHN_RELYING_PARTY_ORIGIN` | The exact URL users visit — scheme, host, and port must match |

Both deployment paths derive them from your hostname (`setup.sh`, or the
chart's `strato.webauthn.*` values). See
[WebAuthn hostname requirements](/deployment/overview#webauthn-hostname-requirements)
for the origin-must-match rules and troubleshooting.

## OIDC single sign-on

OIDC providers are configured per organization through the API or UI, not
environment variables. Beyond authentication, a provider can map ID-token
claims onto the authorization model:

- **`groupsClaim`** — the ID-token claim holding group/role values (e.g.
  `groups`). Unset disables claim mapping.
- **`groupMappings`** — `{claimValue, groupID}` pairs. Mapped groups are
  IdP-managed: every login adds/removes the user to match the token; groups
  in no mapping are never touched.
- **`adminClaimValues`** — claim values granting the org `admin` role. When
  set, the IdP is authoritative for the org role on every login (the last
  admin is never demoted, so a misconfigured IdP cannot lock the org out).
- **`roleMappings`** — claim value → custom org role, for granting roles
  beyond member/admin from IdP claims.
- **`defaultRole`** — role for just-in-time provisioned users when no claim
  matches: any role name or org-owned role ID (default `member`).

When SCIM provisioning and OIDC login share an IdP, the two paths converge
on one user record (by `sub`/`externalId` with a single provider, else by
verified email); users deactivated via SCIM are denied OIDC login.

## Programmatic credentials

- **API keys** — `sk_`-prefixed bearer tokens, created per user, with
  `read` / `write` / `admin` scopes (`admin` implies `write` implies
  `read`). Safe HTTP methods need `read`, mutations `write`.
- **SCIM tokens** — `scim_`-prefixed bearer tokens, created per
  organization, for the SCIM provisioning endpoints.
- **JWT-SVIDs** — with `SPIFFE_JWT_SVID_AUTH_ENABLED=true` (Helm:
  `spire.controlPlane.jwtSvidAuth.enabled`), registered workloads
  authenticate to the HTTP API with short-lived JWT-SVID bearer tokens
  minted by SPIRE. Off by default (it widens the credential surface from
  mTLS-only to bearer tokens); requires `SPIRE_ENABLED` and
  `SPIRE_SERVER_API_ADDRESS`. Tuning knobs (`SPIFFE_JWT_AUDIENCE`,
  `SPIFFE_JWT_BUNDLE_REFRESH_INTERVAL`) are in the control-plane
  environment table in [Deploying agents](/deployment/agents).

Session lifetime (`SESSION_TTL_SECONDS`) and session storage are covered in
the [deployment overview](/deployment/overview#session-lifetime).
