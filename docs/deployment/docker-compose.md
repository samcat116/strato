# Docker Compose Deployment

The supported way to run Strato on a single host without Kubernetes lives in
[`deploy/compose/`](https://github.com/samcat116/strato/tree/main/deploy/compose).
It is secure by default: `setup.sh` generates strong random secrets locally,
nothing insecure ships in the config, and authentication is always enforced.

::: tip Looking for local development?
This stack is a deployment, not a dev environment. For developing from
source, see [Local Development](/development/local-development).
:::

## Install

Tagged releases provide a version-pinned `strato-<version>-compose.tar.gz`
archive containing this entire directory. It replaces the retired standalone
`docker-compose.release.yml` and `nginx.conf` release assets, which did not
form a complete current deployment. Download and extract the archive when
installing a release without cloning the repository; then run the same setup
commands below from the extracted directory.

```bash
git clone https://github.com/samcat116/strato.git
cd strato/deploy/compose
./setup.sh
docker compose up -d
```

Open `http://localhost` and register — the first user becomes the system
administrator.

To keep anyone else from signing themselves up afterwards, set
`SELF_REGISTRATION_ENABLED=false` in `.env` (it can be set before first run
too — the first account is always creatable). See
[Self-registration](/deployment/overview#self-registration).

### Seeding the first administrator from the command line

`bootstrap` seeds an admin user, an organization, a project, and an
admin-scoped API key on an empty deployment. Give it `--admin-email` and the
seeded account belongs to *you*: it prints a one-time claim link you open in a
browser to register your passkey.

```bash
docker compose run --rm bootstrap bootstrap \
  --admin-email you@example.com --env production
```

Use this instead of browser registration whenever you are installing from a
terminal. Bootstrapping without `--admin-email` seeds a headless account that
has no passkey and cannot sign in, *and* consumes the
first-user-becomes-admin slot — so a person registering in the browser
afterwards gets no privileges, and the deployment's admin surfaces are
reachable only through the API key.

For CI and IaC, where nobody is going to open a link, the headless shape is
still the right one:

```bash
docker compose run --rm bootstrap        # human-readable
# key only on stdout, for scripting:
docker compose run --rm -e LOG_LEVEL=warning bootstrap bootstrap --quiet --env production
```

`--quiet` prints one secret per line: the API key, then the claim URL if one
was minted.

On the `--admin-email` path the passkey is your credential, so the API key is
an extra long-lived admin secret you may not want in scrollback — add
`--no-api-key` to skip it. (It is refused without `--admin-email`, which would
leave the seeded admin with no way in at all.)

The command hard-refuses when any user already exists, and the key is printed
exactly once. The claim link is single-use and valid for seven days; its origin
comes from `WEBAUTHN_RELYING_PARTY_ORIGIN` and must match the URL you browse
to, or the passkey ceremony fails.

### Recovering a deployment with no reachable administrator

If the admin slot went to a headless account, or an administrator's claim link
expired, promote an existing account from the control-plane container:

```bash
# promote someone who can already sign in
docker compose run --rm bootstrap grant-platform-admin \
  --email you@example.com --env production

# ...or promote and mint a fresh passkey link for an account that has none
docker compose run --rm bootstrap grant-platform-admin \
  --email bootstrap@localhost --claim --env production
```

The `bootstrap` service is just a one-shot control-plane container with the
same environment, so it is the right place to run any `App` subcommand. Prefer
it over `docker compose exec control-plane`, which would boot a second full
Vapor app — migrations, lifecycle handlers and all — inside the container that
is serving traffic. (If you do use `exec`, the binary is `./App`: the image's
`ENTRYPOINT` is what normally supplies it, and `exec` bypasses that.)

Either way you get a second process running the migration phase against the
same database as the running control plane. That is safe: the phase is
serialized fleet-wide by a Postgres advisory lock, so the one-shot container
waits if a migration is in flight and then finds nothing to do (STR-183).

`--claim` is refused for an account that already has a passkey — an unclaimed
invite blocks passkey enrollment, so minting one would take away the sign-in it
was meant to restore — and likewise for a disabled account or one provisioned
by OIDC/SCIM, where the link would be dead on arrival. The command runs on a
populated deployment (unlike `bootstrap`), writes an
`iam.platform_admin_granted` audit event, and its only guard is shell access to
the control plane, which is the same trust level a direct database write
already needed.

This recovery path is currently documented for Docker Compose only; on
Kubernetes, run the same subcommand in a control-plane pod
(`kubectl exec deploy/strato-control-plane -- ./App grant-platform-admin …`).

### With a real hostname

```bash
./setup.sh --hostname strato.example.com
```

WebAuthn (passkey login) requires HTTPS for any hostname other than
`localhost`. Terminate TLS in front of the `proxy` service — either extend
`nginx.conf` with a TLS listener, or put Caddy/Traefik/a cloud load balancer
in front. The generated `.env` sets
`WEBAUTHN_RELYING_PARTY_ORIGIN=https://strato.example.com` accordingly.

### Options

```bash
./setup.sh --hostname localhost --port 8888   # non-standard port
```

`setup.sh` is idempotent — it never overwrites an existing `.env`. To change
non-secret settings later (hostname, version pin, log level), edit `.env`
directly and run `./redeploy.sh` — a bare `docker compose up -d` recreates
the control plane on a config change without recreating the containers that
share its network namespace (see [Operations](#operations)).

## What runs

| Service | Purpose | Notes |
|---|---|---|
| `db` | PostgreSQL 16 | Control-plane DB (durable truth, including authorization data) |
| `valkey` | Coordination + sessions | Required by the control plane (agent presence, sweep locks, scheduler reservations); password-protected. Backs both stores by default — see [Splitting session storage](#splitting-session-storage) |
| `control-plane` | API + core | Runs DB migrations automatically at startup |
| `frontend` | Web UI | Next.js |
| `proxy` | nginx | Browser-facing entry point |
| `envoy` | Agent mTLS front | Terminates agent mTLS on `:8443`; shares the control-plane container's network namespace |
| `spire-server`, `spire-bootstrap`, `spire-agent-cp`, `spire-api-bridge`, `spire-bundle-refresher` | SPIRE stack | Issues the X.509 SVIDs agents authenticate with; `spire-bootstrap` is one-shot, `spire-api-bridge` shares the control-plane namespace |
| `prometheus`, `loki` | Host telemetry + VM logs | Reached only through Envoy's `/ingest/*` routes (and, for Loki, the control plane); no published ports |
| `image-storage-init` | One-shot volume chown | Makes the image volume writable by the control plane's non-root user; runs on every `up` |
| `bootstrap` | First-administrator seeding | Profile-gated; never started by `docker compose up` — see [above](#seeding-the-first-administrator-from-the-command-line) |

The one-shot services showing `Exited (0)` in `docker compose ps` is
expected.

Three host ports are published: the proxy on `${HTTP_PORT:-80}`, the Envoy
agent-mTLS listener on `${AGENT_MTLS_PORT:-8443}` (published on the
`control-plane` service, whose network namespace Envoy shares), and the
SPIRE node API on `${SPIRE_NODE_PORT:-8085}`. `:8443` and `:8085` must be
reachable from your hypervisor nodes, and TLS must **not** be terminated in
front of `:8443` — agent mTLS is end-to-end. Everything else stays on the
internal network.

## Secrets

`setup.sh` writes `.env` with mode 0600 containing:

- `POSTGRES_PASSWORD` — do not change after the database volume is
  initialized
- `VALKEY_PASSWORD`
- `STRATO_SECRET_ENCRYPTION_KEY` — encrypts stored secrets (OIDC client
  secrets, SSF stream auth tokens, registry pull secrets, webhook signing
  secrets) at rest in the database. Do not lose or change it after secrets
  are configured: stored values are unreadable without the original key
  (recover by re-entering them in the provider or stream settings).
  Deployments whose `.env` predates this key can add it at any time
  (`openssl rand -hex 32`); existing plaintext secrets are encrypted
  automatically at the next startup.

There is nothing to rotate before production use; the values never leave the
host.

### Other `.env` settings

`setup.sh` also writes non-secret settings derived from your hostname, and
`docker-compose.yml` honors a few more that `setup.sh` does not write —
add those to `.env` (or an override file) to change them:

| Variable | Default | Meaning |
|---|---|---|
| `HTTP_TLS_ENABLED` | from origin scheme | Secure session cookie + HSTS. `setup.sh` sets `true` for HTTPS origins; leave `false` for plaintext `http://` or the browser drops the cookie. |
| `RATE_LIMIT_TRUSTED_PROXY_HOPS` | `1` (http) / `2` (https) | Trusted proxies in front of the control plane, for reading the real client IP — see [Rate limiting](/deployment/rate-limiting). |
| `CONTROL_PLANE_URL` | the browser origin | Published proxy origin; used as the `BASE_URL` default. |
| `BASE_URL` | `CONTROL_PLANE_URL` | Public origin for OIDC redirect URIs; OIDC login refuses to start without it in production. |
| `STRATO_GRAVATAR_ENABLED` | `true` | Frontend Gravatar profile pictures; `false` avoids third-party requests (not written by `setup.sh`). |
| `IMAGE_STORAGE_BACKEND` / `IMAGE_S3_*` | `filesystem` | Keep image bytes in an S3-compatible bucket instead of the `image_storage` volume (not written by `setup.sh`); see [Storage](/architecture/storage). |
| `DATABASE_TLS` | `disable` | Postgres TLS mode — set `require` if you point the stack at an external database (not written by `setup.sh`). |
| `DATABASE_STATEMENT_TIMEOUT_MS` | `300000` | Maximum duration of any control-plane Postgres statement, in milliseconds. Must be an integer from 1 through 2147483647; invalid values stop startup instead of leaving queries unbounded. |
| `DATABASE_MIGRATION_STATEMENT_TIMEOUT_MS` | `900000` | Longer timeout used only while SchemaMigrator owns its pinned connection; the serving value is restored afterward. Uses the same validation range. |

## Splitting session storage

The single `valkey` service backs two stores with opposite failure contracts:

- **Coordination** (agent presence, sweep locks, scheduler reservations,
  rate-limit counters) is *fail-open*. Losing it degrades
  convergence, never correctness — agents keep converging via their
  unconditional desired-state refetch, and `/health/ready` grades it `degraded`
  while still serving traffic.
- **Session storage** cannot fail open at all. Losing it logs every signed-in
  user out at once, and since passkeys are the only interactive authentication,
  everyone re-authenticates with a security key. `/health/ready` grades it fatal.

Sharing one instance means the store that is *allowed* to fail takes down the one
that must not. To separate them, set the `SESSION_VALKEY_*` variables on the
`control-plane` service (a commented block in `docker-compose.yml` shows both
forms). Leave them unset and sessions follow the coordination endpoint, which is
the default and needs no change on upgrade.

These variables are **all-or-nothing**: `SESSION_VALKEY_HOST` does *not* inherit
`VALKEY_PORT` or `VALKEY_PASSWORD`, so a partially-set group can never produce a
half-merged endpoint. Set every field the session endpoint needs.

| Variable | Default |
|---|---|
| `SESSION_VALKEY_HOST` | unset — sessions use the coordination endpoint |
| `SESSION_VALKEY_PORT` | `6379` |
| `SESSION_VALKEY_PASSWORD` | none |
| `SESSION_VALKEY_DATABASE` | `0` |

The cheapest useful split is one server, two keyspaces — point
`SESSION_VALKEY_HOST` at the same `valkey` service with
`SESSION_VALKEY_DATABASE=1`. A coordination `FLUSHDB` then no longer logs
everyone out, at no extra infrastructure. A second instance buys full isolation.

## Version pinning

The compose file uses the published images
(`ghcr.io/samcat116/strato-control-plane`, `ghcr.io/samcat116/strato-frontend`).
The default tag is `main`, which is rebuilt on every main-branch merge. For a
reproducible deployment, pin an immutable per-commit build in `.env`:

```bash
STRATO_VERSION=main-abc123def456
```

Once versioned releases are published, a release tag (e.g. `v0.5.0`) works the
same way.

To build from source instead (e.g. before a release is published), comment
out `image:` and uncomment the `build:` block in `docker-compose.yml`.

## Operations

```bash
docker compose ps                  # status
docker compose logs -f control-plane
./redeploy.sh                      # pull + redeploy control-plane (+ sidecars)
./redeploy.sh frontend             # just the frontend; `all` for both
./smoke-test.sh --api-key sk_...   # verify the assembled stack via the proxy
docker compose down                # stop (data persists)
docker compose down -v             # stop and WIPE all data
```

To pick up a new image, use `redeploy.sh` rather than
`docker compose up -d --no-deps control-plane`: `envoy` and
`spire-api-bridge` run inside the control-plane container's network
namespace, so recreating the control plane alone orphans them into the old
container's dead namespace. The symptom is misleading — agent enrollment
fails with "SPIRE server unreachable: 127.0.0.1:8081", which reads like a
SPIRE problem rather than a container-lifecycle one. The helper always
recreates the namespace owner and its tenants together.

`smoke-test.sh` exercises the stack *through* the proxy (health, auth
rejection, image full and ranged downloads with strict header checks, the
Envoy mTLS listener). It needs a write-scoped API key, and is worth running
after every deploy: some bugs only manifest between the control plane and a
strict proxy, invisible to unit tests and direct-to-container curl.

::: tip Upgrading past Envoy v1.39.0
The agent mTLS listener prefers `X25519MLKEM768`, a hybrid post-quantum key
exchange that keeps recorded handshakes confidential against a future
quantum attacker. It requires **Envoy v1.39.0 or newer**, which
`docker-compose.yml` pins — a `docker compose pull` picks it up.

If you pinned an older Envoy in a `docker-compose.override.yml`, the proxy
will fail to start with `Failed to initialize ECDH curves`. Either drop the
override or remove `X25519MLKEM768` from `ecdh_curves` in
`spiffe/envoy.yaml`. Agents need no change: swift-nio-ssl offers the group
by default from 2.37.1 and older agents fall back to X25519, so the control
plane and agents can be upgraded in either order.
:::

`docker compose ps` reports the control plane healthy only once
`/health/ready` passes — that is, once Postgres and migrations are both
good, not merely once the process started. On `down` and on `up -d` upgrades the
control plane drains in-flight requests and agent WebSockets within
`stop_grace_period` (60s). See
[Health checks & zero-downtime deploys](/deployment/health-checks).

## Adding hypervisors

See [Deploying agents](/deployment/agents). The control plane hands agents
the URL from `EXTERNAL_HOSTNAME` in `.env`, so make sure it is reachable from
your hypervisor hosts.
