# Strato single-host deployment (Docker Compose)

The supported way to run Strato on one machine without Kubernetes. Secrets
are generated locally on first run; nothing insecure ships in the config.

## Quick start

```bash
./setup.sh                 # generates .env with strong random secrets
docker compose up -d
open http://localhost      # the first registered user becomes system admin
```

For a real hostname (WebAuthn then requires HTTPS in front of the proxy):

```bash
./setup.sh --hostname strato.example.com
```

## What's included

- **PostgreSQL** — control-plane database plus a separate `spicedb` database.
- **SpiceDB** — authorization, persisted to PostgreSQL. Datastore migration
  and schema loading run automatically as one-shot services on every `up`
  (they show as `Exited (0)` in `docker compose ps`, which is expected).
- **Valkey** — control-plane coordination (agent presence, singleton sweeps,
  scheduler reservations) and session storage; required, password-protected.
- **Control plane + frontend** — published images
  (`ghcr.io/samcat116/strato-*`). Database migrations run automatically at
  startup. Pin a version with `STRATO_VERSION` in `.env`.
- **SPIRE + Envoy (mTLS agent auth, on by default)** — a SPIRE server issues
  X.509 SVIDs; an Envoy front terminates agent mTLS on `:8443` and forwards the
  verified client identity to the control plane. A one-shot `spire-bootstrap`
  provisions the Envoy server cert and trust bundle. The small helper image
  (`strato-spire-helper:local`) is built locally from `./spiffe/` on first `up`.
  See [`spiffe/`](spiffe/) for the SPIRE/Envoy config.
- **nginx proxy** — the browser-facing service.

## Published ports

| Port | Service | For |
|------|---------|-----|
| `${HTTP_PORT:-80}` | nginx proxy | browser UI + API |
| `${AGENT_MTLS_PORT:-8443}` | Envoy | agent mTLS (`wss://host:8443/agent/ws`) |
| `${SPIRE_NODE_PORT:-8085}` | SPIRE server | agent node attestation |

mTLS is end-to-end: `:8443` and `:8085` must be reachable from your hypervisor
nodes, and you must **not** terminate TLS in front of `:8443`. The browser
origin (`:80`/`:443`) is independent and may sit behind a TLS terminator.
- **Image storage** — downloaded base images are written to the
  `image_storage` volume (`IMAGE_STORAGE_PATH`). A one-shot
  `image-storage-init` service chowns the volume to the non-root control-plane
  user on each `up` so imports can write to it. Agents fetch images via
  `CONTROL_PLANE_URL`, which setup.sh points at the proxy origin.

## Adding a hypervisor

In the web UI, go to Agents → Create Registration Token. Because mTLS is on by
default, the token also provisions the node in SPIRE and the dialog shows a
one-line `sudo strato-node-bootstrap …` command; run it on the hypervisor host.
It starts a `spire-agent` (attested with the one-time join token) and the
`strato-agent`, which connects over mTLS. See the agent documentation for
details, including the `deploy/agent/strato-node-bootstrap.sh` helper.

## Notes

- `setup.sh` is idempotent: it never overwrites an existing `.env`. The
  PostgreSQL password cannot be changed after the volume is initialized
  without also updating the database.
- `docker compose down` keeps data; `docker compose down -v` wipes it.
- For local development from source, use the compose file at the repository
  root instead.
