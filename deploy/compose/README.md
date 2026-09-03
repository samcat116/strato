# Strato single-host deployment

Docker Compose is the supported way to run Strato on one machine without
Kubernetes. The canonical installation, configuration, TLS, storage, upgrade,
and recovery instructions are in the
[Docker Compose deployment guide](../../docs/deployment/docker-compose.md).

## Quick start

```bash
./setup.sh
docker compose up -d
open http://localhost
```

Use `./setup.sh --hostname strato.example.com` for a real hostname. The setup
script creates `.env` once with strong random credentials and never overwrites
it.

For a scripted fresh deployment, `docker compose run --rm bootstrap` creates
the first administrator, organization, project, and API key. To update an
existing stack, use `./redeploy.sh`; it recreates the control plane together
with the sidecars that share its network namespace.

Run `./smoke-test.sh --api-key sk_...` after deployment to verify the assembled
proxy, API, image download, and agent-mTLS paths.

To build from a working tree, create an untracked
`docker-compose.override.yml`; do not edit the tracked Compose file.
