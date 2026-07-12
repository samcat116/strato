# Docker Compose Deployment

The supported way to run Strato on a single host without Kubernetes lives in
[`deploy/compose/`](https://github.com/samcat116/strato/tree/main/deploy/compose).
It is secure by default: `setup.sh` generates strong random secrets locally,
nothing insecure ships in the config, and there is no development auth bypass.

::: warning
The `docker-compose.yml` at the repository root is for local development
only — it uses fixed dev credentials and an in-memory authorization store.
Always deploy from `deploy/compose/`.
:::

## Install

```bash
git clone https://github.com/samcat116/strato.git
cd strato/deploy/compose
./setup.sh
docker compose up -d
```

Open `http://localhost` and register — the first user becomes the system
administrator.

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
directly and `docker compose up -d` again.

## What runs

| Service | Purpose | Notes |
|---|---|---|
| `db` | PostgreSQL 16 | Control-plane DB plus a separate `spicedb` database |
| `spicedb-migrate` | one-shot | Migrates the SpiceDB datastore, exits 0 |
| `spicedb` | Authorization | Persisted to PostgreSQL |
| `spicedb-schema` | one-shot | Loads the authorization schema on every `up`, exits 0 |
| `valkey` | Coordination + sessions | Required by the control plane (agent presence, sweep locks, scheduler reservations); password-protected |
| `control-plane` | API + core | Runs DB migrations automatically at startup |
| `frontend` | Web UI | Next.js |
| `proxy` | nginx | The only service with a published port |

The one-shot services showing `Exited (0)` in `docker compose ps` is
expected.

## Secrets

`setup.sh` writes `.env` with mode 0600 containing:

- `POSTGRES_PASSWORD` — do not change after the database volume is
  initialized
- `SPICEDB_PRESHARED_KEY`
- `VALKEY_PASSWORD`
- `STRATO_SECRET_ENCRYPTION_KEY` — encrypts OIDC client secrets at rest in
  the database. Do not lose or change it after providers are configured:
  stored client secrets are unreadable without the original key (recover by
  re-entering them in the provider settings). Deployments whose `.env`
  predates this key can add it at any time (`openssl rand -hex 32`); existing
  plaintext secrets are encrypted automatically at the next startup.

There is nothing to rotate before production use; the values never leave the
host.

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
docker compose pull && docker compose up -d   # upgrade
docker compose down                # stop (data persists)
docker compose down -v             # stop and WIPE all data
```

## Adding hypervisors

See [Deploying agents](/deployment/agents). The control plane hands agents
the URL from `EXTERNAL_HOSTNAME` in `.env`, so make sure it is reachable from
your hypervisor hosts.
