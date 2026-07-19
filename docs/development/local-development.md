# Local Development

Strato is developed as three independent Swift packages plus a Next.js
frontend. Building and testing needs no infrastructure at all; running the
full stack goes through the same Docker Compose deployment operators use.

## Prerequisites

- **Swift 6.2 or later** — for `control-plane/`, `agent/`, and `shared/`
- **Bun** — for the frontend in `control-plane/web/` (not npm)
- **Docker** — only needed to run the full stack

Platform notes for running VMs:

- **Linux**: KVM (`/dev/kvm`), `qemu-system-x86_64`, `qemu-utils`, and for
  real networking `ovn-host` / `openvswitch-switch` (hypervisors run only the
  chassis side — see `deploy/ovn-central/`)
- **macOS**: macOS 14+, `brew install qemu`, Xcode Command Line Tools.
  Networking is QEMU user-mode only (outbound NAT, no VM-to-VM), so macOS is
  suitable for development but not production.

## Build and test

The three Swift packages build and test separately. **Tests need no running
services** — the control-plane suite runs against in-memory SQLite:

```bash
swift build --package-path control-plane
swift test  --package-path control-plane

swift build --package-path agent
swift test  --package-path agent

swift test  --package-path shared
```

While iterating, run a single suite:

```bash
swift test --package-path control-plane --filter <SuiteName>
```

Run the full suite before opening a pull request. Tests use
[swift-testing](https://github.com/swiftlang/swift-testing) (`@Test` /
`#expect`), not XCTest.

::: tip Cold builds are slow
A fresh checkout starts from an empty `.build` and can take 10+ minutes to
compile. Give builds a generous timeout rather than assuming they hung.
:::

CI additionally runs the control-plane suite against PostgreSQL, so
migrations must work on **both** SQLite and Postgres. In particular, SQLite
cannot combine multiple actions in one `ALTER TABLE` step — use separate
`.update()` calls.

## Frontend

The frontend uses Bun for all package and script work:

```bash
cd control-plane/web
bun install
bun run lint     # CI-enforced
bun run build    # CI-enforced
bun run dev      # dev server on http://localhost:3000
```

`bun run dev` serves the UI only; it needs a control plane to talk to. Bring
one up with the compose stack below.

## Formatting

Both are enforced in CI:

```bash
# Swift — .swift-format at the repo root (4-space indent, 120 columns)
swift format --in-place --recursive <changed dirs>
swift format lint --strict --recursive <dirs>

# Frontend
cd control-plane/web && bun run lint
```

## Running the full stack

There is no separate development compose file — use the single-host
deployment in `deploy/compose`, which is the same stack operators run:

```bash
cd deploy/compose
./setup.sh              # generates .env with strong random secrets
docker compose up -d
```

This starts PostgreSQL, SpiceDB (schema loaded automatically), Valkey, Loki,
Prometheus, SPIRE, the control plane, the frontend, and an nginx proxy.
Database migrations run automatically at control-plane startup — there is no
separate migrate step. Visit `http://localhost` and register; the first user
becomes the system administrator.

See the [Docker Compose deployment guide](/deployment/docker-compose) for
hostnames, TLS, and configuration.

### Running your own code

By default the stack pulls published images from GHCR
(`ghcr.io/samcat116/strato-control-plane:main`). To build the control plane
from your working tree instead, comment out `image:` in the `control-plane`
service and uncomment the `build:` block below it:

```yaml
  control-plane:
    # image: ghcr.io/samcat116/strato-control-plane:${STRATO_VERSION:-main}
    build:
      context: ../..
      dockerfile: control-plane/Dockerfile
```

The `frontend` service takes the same treatment with
`control-plane/web/Dockerfile`. Put changes like these in an untracked
`deploy/compose/docker-compose.override.yml` rather than editing the tracked
compose file.

::: warning Backing services are not reachable from the host
`deploy/compose` deliberately publishes only the proxy's port — PostgreSQL,
SpiceDB, and Valkey stay on the internal network. Running the control plane
natively (`swift run`) against them therefore requires publishing those ports
yourself in an override file.
:::

### Adding an agent

VMs need a hypervisor host. In the web UI go to **Agents → Enroll node**,
then run the generated bootstrap command on the host — it installs the
agent, attests it to SPIRE, and starts it. Enrollment needs the control
plane configured for SPIRE (`SPIRE_ENABLED=true` plus
`SPIRE_SERVER_API_ADDRESS`); `deploy/compose` sets this up for you.

To run an agent from source against a local control plane, copy
`config.toml.example` and point `control_plane_url` at your stack:

```bash
swift run --package-path agent StratoAgent --config-file ./config.toml
```

CLI arguments override config-file values. `control_plane_url` is required;
other common options are `qemu_socket_dir`, `log_level`, `network_mode`
(`ovn` or `user`), and `firecracker_binary_path`. See
[Deploying agents](/deployment/agents) for the full reference.

## Kubernetes

To develop against the Helm chart, install it into a local cluster:

```bash
minikube start --memory=4096 --cpus=2
cd helm/strato-control-plane
helm dependency build
helm install strato .
kubectl port-forward service/strato-strato-control-plane 8080:8080
```

Iterating means rebuilding images and running `helm upgrade`. See the
[Kubernetes deployment guide](/deployment/kubernetes) and
[Kubernetes troubleshooting](/development/troubleshooting-k8s).

## Documentation site

The docs are a [VitePress](https://vitepress.dev) site:

```bash
npm run docs:dev     # from the repo root
npm run docs:build
```

## Next steps

- [Architecture Overview](/architecture/overview)
- [Kubernetes troubleshooting](/development/troubleshooting-k8s)
- [Deployment overview](/deployment/overview)
