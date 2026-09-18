# Local Development

Strato is developed as independent Swift packages plus a Next.js frontend.
Four packages see active development — `control-plane/`, `agent/`, `shared/`,
and `cli/` — alongside the generated API client (`clients/swift/`) and the
vendored `SwiftFirecracker/` package. Most package tests need no running
services; control-plane tests require PostgreSQL. Running the full stack uses the same Docker Compose deployment
operators use.

## Prerequisites

- **Swift 6.3 or later** — for `control-plane/`, `agent/`, `cli/`, and `shared/`.
  6.2 no longer resolves: swift-toml (a dependency of `agent/` and `cli/`)
  declares `swift-tools-version:6.3`, and an older toolchain rejects the
  manifest before it builds anything. CI and the Dockerfiles pin 6.3.2.
- **Bun** — for the frontend in `control-plane/web/` (not npm)
- **Docker** — only needed to run the full stack
- **cvc5** — optional locally, needed to run the IAM symbolic-analysis suites
  (see below)

Platform notes for running VMs:

- **Linux**: KVM (`/dev/kvm`), libvirt ≥ 11.5 (`libvirt-daemon-system`,
  `libvirt-clients` — the agent drives QEMU through libvirtd at
  `qemu:///system`, plus `swtpm`/`swtpm-tools` for TPM-backed guests),
  `qemu-utils`, `ceph-common` for Ceph-backed volumes, and for real networking
  `ovn-host` / `openvswitch-switch`
  (hypervisors run only the chassis side — see `deploy/ovn-central/`)
  The 11.5 floor covers local QEMU disks. Namespaced RBD attached through QEMU
  requires libvirt 11.6+; Firecracker/krbd-only Ceph clients do not require a
  reachable libvirt daemon.
- **macOS**: macOS 14+, Xcode Command Line Tools, `brew install qemu` for
  `qemu-img`. Best-effort only: no CI builds the agent for macOS, and without
  libvirt it registers a mock QEMU driver and reports the backend
  unavailable — control-plane and frontend development is the supported use;
  running real VMs is not.

## Build and test

The Swift packages build and test separately. The agent, shared, and cli
suites need no running services. The control-plane suite runs against
PostgreSQL — the engine production uses — and expects one reachable via the
standard `DATABASE_*` env vars (defaults: `localhost:5432`, user `strato`,
password `strato_password`, database `strato_test`). A disposable container
matching the defaults:

```bash
docker run -d --name strato-test-postgres \
  -e POSTGRES_DB=strato_test -e POSTGRES_USER=strato \
  -e POSTGRES_PASSWORD=strato_password \
  --tmpfs /var/lib/postgresql/data -p 5432:5432 postgres:15
```

The harness migrates a template database once per run and hands each test a
server-side clone, so the suite is safe to run in parallel worktrees against
the same server.

```bash
swift build --package-path control-plane
swift test  --package-path control-plane

swift build --package-path agent
swift test  --package-path agent

swift build --package-path cli
swift test  --package-path cli

swift test  --package-path shared
```

While iterating, run a single suite:

```bash
swift test --package-path control-plane --filter <SuiteName>
```

### Validation scope

Choose checks for the behavior and consumers affected by the change. Focused
suites are sufficient for a localized fix when they cover the affected paths;
run complete affected package suites for broad changes, shared contracts,
dependencies, or test-harness changes. For documentation-only edits, check
links and the relevant documentation build rather than running Swift suites.
After checks pass, repeat or broaden them only for new changes, failures, or
unresolved risks. An explicit request for full validation still means full
validation.

Swift PR CI compiles production targets; it does not compile or run Swift
tests. The manual `.github/workflows/main-tests.yaml` runs the full Swift
suite. Frontend and other checks have their own workflow coverage; see
`.github/workflows/README.md`. Report the actual package,
platform, and test scope; a build or a macOS run cannot prove Linux VM behavior.

Tests use [swift-testing](https://github.com/swiftlang/swift-testing)
(`@Test` / `#expect`), not XCTest. Keep control-plane tests in the template
clone harness and point `DATABASE_*` at a disposable test server.
Treat `ServeCommand did not shutdown before deinit` as the known Vapor teardown
race only after a clean rerun.

::: tip Cold builds are slow
A fresh checkout starts from an empty `.build` and can take 10+ minutes to
compile. Give builds a generous timeout rather than assuming they hung.
:::

### The IAM symbolic-analysis suites

The write-time guardrail report and the role-nesting subsumption proof
(`docs/architecture/iam.md`) drive an SMT solver, and their suites skip
themselves when there is none. The rest of the suite is unaffected — the test
harness installs a permissive analyzer, so writing a binding in an unrelated
test needs no solver.

```bash
./scripts/install-cvc5.sh ~/.local/bin
IAM_SYMCC_SOLVER_PATH=~/.local/bin/cvc5 swift test --package-path control-plane
```

The script downloads the pinned, checksum-verified cvc5 1.3.1 build for your
platform; `cvc5` anywhere on `PATH` works too. Without it those suites skip
themselves silently, so if you don't install it nothing covers them — CI won't
catch it for you automatically (see [validation scope](#validation-scope)). The shipped control-plane image carries the
solver, because without one a grant is written with no explanation of the
ceilings that narrow it.

## Frontend

The frontend uses Bun for all package and script work:

```bash
cd control-plane/web
bun install
bun run lint     # CI-enforced
bun run test     # CI-enforced unit and component tests
bun run test:e2e # CI-enforced browser smoke tests
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

This starts PostgreSQL, Valkey, Loki, Prometheus, SPIRE, the control plane,
the frontend, and an nginx proxy.
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
`deploy/compose` deliberately publishes only the proxy's port — PostgreSQL
and Valkey stay on the internal network. Running the control plane natively
(`swift run`) against them therefore requires publishing those ports
yourself in an override file.
:::

### Adding an agent

VMs need a hypervisor host. In the web UI go to **Agents → Add Agent**,
then run the generated bootstrap command on the host — it installs the
agent, attests it to SPIRE, and starts it. Enrollment needs the control
plane configured for SPIRE (`SPIRE_ENABLED=true` plus
`SPIRE_SERVER_API_ADDRESS`); `deploy/compose` sets this up for you.

To run an agent from source against a local control plane, copy
`config.toml.example` (at the repository root) and point `control_plane_url`
at your stack:

```bash
swift run --package-path agent StratoAgent --config-file ./config.toml
```

CLI arguments override config-file values. `control_plane_url` is required;
other common options are `log_level`, `network_mode` (`ovn` or `user`), and
`firecracker_binary_path`. See
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
