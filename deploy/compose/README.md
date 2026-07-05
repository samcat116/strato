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
- **Valkey** — session storage, password-protected.
- **Control plane + frontend** — published images
  (`ghcr.io/samcat116/strato-*`). Database migrations run automatically at
  startup. Pin a version with `STRATO_VERSION` in `.env`.
- **nginx proxy** — the only service with a published port.
- **Image storage** — downloaded base images are written to the
  `image_storage` volume (`IMAGE_STORAGE_PATH`). A one-shot
  `image-storage-init` service chowns the volume to the non-root control-plane
  user on each `up` so imports can write to it. Agents fetch images via
  `CONTROL_PLANE_URL`, which setup.sh points at the proxy origin.

## Adding a hypervisor

In the web UI, go to Agents → Create Registration Token, then run the shown
`strato-agent join` command on the hypervisor host. See the agent
documentation for details.

## Notes

- `setup.sh` is idempotent: it never overwrites an existing `.env`. The
  PostgreSQL password cannot be changed after the volume is initialized
  without also updating the database.
- `docker compose down` keeps data; `docker compose down -v` wipes it.
- For local development from source, use the compose file at the repository
  root instead.
