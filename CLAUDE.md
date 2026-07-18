# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Working in worktrees (IMPORTANT)

- Sessions almost always run in a git worktree under `.claude/worktrees/<name>/`. Other Claude sessions may be active in sibling worktrees and in the main checkout at the same time.
- NEVER `cd` into or edit `/Users/sam/Projects/Active/strato/` (the main checkout) directly. Derive all paths from your own session's tree (`git rev-parse --show-toplevel`).
- The shell cwd resets between Bash calls: always use absolute paths rooted in your worktree, never bare relative commands like `cd control-plane && ...` chained across calls.
- If you see uncommitted changes you didn't make, they belong to another session's tree — do not fix, complete, or revert them; check `pwd` and re-root yourself first.

## Pull request conventions

- Before creating a PR (and again before declaring work done), run `git fetch origin main && git merge origin/main` and resolve conflicts locally. Parallel sessions land PRs frequently, so branches go stale within hours — don't wait for the merge-conflict notification.
- Review comments from `chatgpt-codex-connector[bot]` that only report Codex usage limits are noise: do not reply, push, or take any action on them.
- Use `/pr-comments` to fetch and address unresolved review threads on the current branch's PR.

## Development Commands

### Building and testing (Swift)

Three independent Swift packages: `control-plane/`, `agent/`, `shared/` (plus vendored `SwiftFirecracker/`). Each builds and tests separately:

- `swift build --package-path <pkg>` / `swift test --package-path <pkg>`
- `swift test --package-path control-plane --filter <SuiteName>` — run a single suite while iterating; run the full suite once before creating or updating a PR
- Tests use swift-testing (`@Test`/`#expect`), not XCTest

Build & test notes:
- Swift builds in a fresh worktree start from a cold `.build` and can take 10+ minutes. Run builds/tests with a generous timeout or in the background — never the default 2-minute timeout.
- Control-plane tests run against in-memory SQLite locally — no Postgres/SpiceDB services needed. CI additionally runs the suite against Postgres, so migrations must work on BOTH (SQLite `ALTER TABLE` cannot combine multiple actions in one migration step; use separate `.update()` calls).
- Known CI flake: the "Test Control Plane (Postgres)" step of the Test Control Plane job can crash with Vapor's `ServeCommand did not shutdown before deinit` teardown race. If a failure doesn't reproduce locally and matches this signature, rerun with `gh run rerun <run-id> --failed` instead of debugging.
- Swift CI (PR build/test and main-branch release binaries) runs on the `swift-runners-strato` runner scale set managed by actions-runner-controller; Docker image builds still run on the static self-hosted runner on the strato-dev VM (`/home/sam/actions-runner`). If Swift CI fails with missing-symbol errors your diff can't explain, suspect a stale build cache in the runner's persistent `RUNNER_TOOL_CACHE` volume — reproduce locally before debugging source.

### Formatting and linting (CI-enforced)

- **Swift**: CI runs `swift format lint --strict --recursive` over all `Sources/` and `Tests/` directories, using the `.swift-format` config at the repo root (4-space indent, 120-col lines). Format before pushing: `swift format --in-place --recursive <changed dirs>`.
- **Frontend**: `cd control-plane/web && bun run lint` and `bun run build` — CI runs both with Bun (`bun install --frozen-lockfile`). The frontend uses Bun, not npm.
- Legacy JS in `control-plane/Public/js`: `cd control-plane && npm run lint` (eslint).

### Local development environment (Taskfile — primary flow)

`task` (go-task) drives local development; see `Taskfile.yml` and DEV-SETUP.md:

- `task dev` — start the full backend: Postgres, SpiceDB (schema auto-loaded), Valkey, Loki, OTel collector in Docker; then builds/starts the control plane and agent natively, creates an agent registration token, test admin user/org/project, and a test VM. Sets `DEV_AUTH_BYPASS=true`.
- `task dev-frontend` — Next.js dev server at http://localhost:3000 (run in a separate terminal)
- `task status` / `task logs` / `task stop` / `task clean` — inspect, stop, or tear down everything
- `task dev-linux` — Linux variant (KVM + Firecracker ready); `task install-firecracker` installs the Firecracker binary
- `task dev-spiffe` — mTLS variant with SPIRE server/agent + Envoy proxy (agent connects via wss://localhost:8443)
- Control plane API: http://localhost:8080; logs at `/tmp/strato-control-plane.log` and `/tmp/strato-agent.log`
- Database migrations run automatically at control-plane startup — there is no separate migrate step.

### Running services directly

- `cd control-plane && swift run` — control plane (needs Postgres/SpiceDB env vars; `task dev` handles this)
- `cd agent && swift run StratoAgent --config-file ./config.toml` — agent (TOML config; CLI args override config values; `control_plane_url` is required; key options: `qemu_socket_dir`, `log_level`, `network_mode` = `ovn`|`user`, `firecracker_binary_path`). See `config.toml.example`.
- First-time agent registration uses a one-time token URL: `--registration-url 'ws://host:8080/agent/ws?token=...&name=...'`; the agent persists a rotated reconnect token afterwards.

### Other environments

- **Skaffold + Helm (Kubernetes)**: `minikube start`, `cd helm/strato-control-plane && helm dependency build` (once), then `skaffold dev` (`--profile=minimal` for no observability stack, `--profile=debug` for debug builds).
- **Root `docker-compose.yml`**: local development only (fixed dev credentials, `DEV_AUTH_BYPASS`). `docker compose up control-plane` starts the control plane with dependencies.
- **`deploy/compose/`**: the supported single-host production deployment. `./setup.sh` generates `.env` with strong random secrets, then `docker compose up -d`. Published images, persistent SpiceDB, no auth bypass.
- **Docs site**: VitePress under `docs/` — `npm run docs:dev` / `docs:build` at the repo root.

### strato-dev VM (remote sessions at /home/sam/strato)

When running on the strato-dev Linux VM (Ubuntu, headless):
- The user browses from their Mac — never say "open localhost". The UI is served at `https://strato-dev.tail21c16.ts.net` (tailscale serve → nginx :80). k3s occupies :443, so don't try to bind it.
- There are no published container images for this environment; the compose stack builds from source (long Swift build — always run in the background).
- Deployment overrides go in `deploy/compose/docker-compose.override.yml`, never in the tracked compose file.
- Control-plane tests need Postgres: user `strato` / password `strato_password` / db `strato_test`, on port 5433 to avoid colliding with the compose stack.
- First-user registration is a WebAuthn passkey flow that only the user can complete in their browser — hand it off rather than attempting it.
- `sudo` requires a password on this host. If a command needs root, give the user the exact command to run instead of retrying.
- This is a disposable dev VM: when asked to "clean up" deployments, removing all strato-* containers and volumes is in scope.

## Architecture

Strato is a distributed private cloud platform. The **Control Plane** (Vapor 4 + Fluent/PostgreSQL) owns the API, database, scheduler, and authorization; **Agents** run on hypervisor nodes and manage VMs through hypervisor drivers (QEMU, Firecracker). They communicate over a WebSocket (`/agent/ws`). The **shared/** package defines the wire protocol and DTOs used by both. Design docs live in `docs/architecture/` and are kept current: `overview.md` is the top-level map; `control-plane.md`, `agent.md`, `wire-protocol.md`, and `frontend.md` document the code architecture of each component; the rest cover individual subsystems (scheduler, networking, storage, sandboxes, multi-replica, IAM, agent updates).

### Desired state and reconciliation (the core control loop)

The control plane is declarative, not imperative:

- The database stores each VM's **desired state** (`running`, `shutdown`, `paused`, `absent`) alongside observed status. API mutations update desired state; agents converge on it.
- The control plane periodically sends each agent a full, authoritative `DesiredStateMessage` (see `shared/Sources/StratoShared/ReconciliationProtocol.swift`). Each `DesiredVMState` carries a monotonic `generation` counter guarding against reordering; syncs are level-triggered and safe to drop/replay. Signed image URLs are refreshed at sync-assembly time.
- The agent-side reconciler (`agent/Sources/StratoAgentCore/Reconciliation.swift`) diffs observed vs desired and converges via per-VM serial lanes, and reports observed state back.

### Async resource operations

VM and sandbox mutation endpoints (create/start/stop/delete/reboot, plus pause/resume for VMs) insert a `ResourceOperation` row (`resource_kind` discriminator: `virtual_machine` or `sandbox`; issue #412 generalized the machinery) in the same transaction as the desired-state change and return **202 Accepted** with the operation object. The operation completes when the agent reports success/error, or a stuck-operation sweep fails it after a per-resource-kind budget. Operation rows deliberately have no FK to the resource so delete operations survive row removal; the frontend polls operations to terminal state.

### Multi-replica control plane (Valkey coordination)

Multiple control-plane replicas are supported (see `docs/architecture/multi-replica.md`; `CoordinationService.swift`):

- PostgreSQL is the only source of truth for desired state; Valkey holds ephemeral coordination state and fails open (agents still converge via periodic sync if Valkey is down).
- Agent liveness: `agent:{name}:presence` keys with 60s TTL. Socket routing: `agent:{name}:replica` records which replica holds the agent's WebSocket.
- **Sync nudges**: a mutation on replica A for an agent socketed to replica B publishes to B's `replica:{id}:nudges` pub/sub channel; B pushes a fresh sync. Lost nudges are backstopped by the periodic sync timer.
- Imperative actions that aren't states (volume ops, reboot) forward over `replica:{id}:rpc` channels. Scheduler placement reservations (`resv:*`) and singleton sweep locks (`lock:sweep:*`) also live in Valkey.

### Scheduler

`SchedulerService` places VMs on agents by resource availability with strategies `least_loaded` (default), `best_fit`, `round_robin`, `random` (`SCHEDULING_STRATEGY` env var). Only online agents with sufficient resources are candidates; placement uses Valkey reservations to avoid double-booking across replicas. Details in `docs/architecture/scheduler.md`.

### Agent: hypervisor driver registry

All VM message handling routes through a driver registry keyed by `HypervisorType` (`agent/Sources/StratoAgent/Agent.swift`) — adding a backend means one registration, not new switch sites:

- **QEMU** (`QEMUService`, via SwiftQEMU): Linux (KVM) and macOS (HVF). Same-arch VMs only for acceleration; cross-arch falls back to slow TCG.
- **Firecracker** (`FirecrackerService`, via the vendored `SwiftFirecracker/` package at the repo root): Linux only, kernel+rootfs boot.
- **Mock** (`MockHypervisorService`): testing.

A persisted VM manifest tracks which backend owns each VM (survives restarts, enables orphan detection). `agent/Sources/StratoAgentCore/` holds the testable core (no SwiftQEMU dependency); `StratoAgent` is the executable.

### Networking

- Each NIC is a `VMNetworkInterface` row (there are no single-NIC fields on VM anymore): network name, MAC, IP, MTU, stable device name (`net0`, `net1`, ...) ordered by `orderIndex`.
- **The control plane does IPAM** (`IPAMService`): allocates static IPs/netmask/gateway from a `LogicalNetwork`'s subnet and passes them to the agent.
- Agent-side, `NetworkOrchestrator` routes to a platform driver behind `NetworkServiceProtocol`; hypervisor drivers receive typed `NetworkAttachment` values (TAP path + driver type) rather than assuming a format.
- Linux: OVN/OVS (via SwiftOVN) for real SDN — TAP interfaces, VM-to-VM traffic, isolation. macOS: QEMU user-mode SLIRP only (outbound NAT, no inbound, no VM-to-VM) — dev/test only.

### Storage and images

- Agents implement the `StorageBackend` protocol (`agent/Sources/StratoAgentCore/StorageBackend.swift`); the current backend is filesystem + qemu-img. The agent owns all paths — the control plane stores whatever paths the agent reports and passes them back verbatim.
- **Single image-materialization path**: `materializeDisk(at:from:format:)` converts any image to the format the hypervisor asked for (e.g. qcow2 → raw for Firecracker), writing to a staging path and publishing via atomic rename.
- Volume snapshots are external qcow2 overlays with detected (not assumed) backing formats. Volumes and their VM must be on the same agent; volumes only place on QEMU-capable agents.
- Images have an architecture and a set of typed `ImageArtifact`s (`diskImage` for QEMU, `rootfs`/`kernel`/`initramfs` for Firecracker/direct boot), each with format, checksum, and size. Agents filter artifacts by supported backend + host architecture, giving per-hypervisor image compatibility.

### AuthZ, authN, and the org hierarchy

- **SpiceDB** (schema in `spicedb/schema.zed`) enforces relationship-based access control; `SpiceDBAuthMiddleware` intercepts requests, `SpiceDBService` wraps the HTTP API. Ownership relationships are written automatically on resource creation.
- **Authentication** is WebAuthn/Passkeys (swift-server/webauthn-swift) with Vapor sessions, plus API keys for programmatic access and optional OIDC providers. WebAuthn env vars: `WEBAUTHN_RELYING_PARTY_ID`, `WEBAUTHN_RELYING_PARTY_NAME`, `WEBAUTHN_RELYING_PARTY_ORIGIN` (origin must exactly match the browser URL).
- Hierarchy: Organization → optional nested **Organizational Units** (materialized `path`/`depth`) → Projects (with environments). **Groups** (optionally SCIM-provisioned, see `SCIMToken`/`SCIMExternalID`) grant access; **ResourceQuotas** (vCPU/memory/storage/VM count/sandbox count, optionally per-environment) attach at org, OU, or project level and are enforced on VM and sandbox create/delete; sandboxes draw from the same vCPU/memory pools as VMs.
- Agent transport security (optional): SPIFFE/SPIRE-issued mTLS terminated by Envoy in front of the control plane (`envoy/standalone/`, `task dev-spiffe`).

### Observability

The control plane emits OTLP metrics/logs/traces via swift-otel to an OTel collector (`observability/`), which exports to Prometheus/Loki/Jaeger. Toggled with `OTEL_METRICS_ENABLED` / `OTEL_LOGS_ENABLED` / `OTEL_TRACES_ENABLED` (disabled in `task dev`'s control plane, but the collector and Loki still run for VM console logs).

### Frontend

Next.js App Router app in `control-plane/web/src/` (React 19, TanStack Query for server state, Zustand for client state, shadcn/ui on Radix, TailwindCSS v4 via PostCSS, xterm.js for VM consoles), deployed as a separate `strato-frontend` service consuming the control-plane JSON API. Use Bun for all frontend package/scripting work.

### Project structure

```
strato/
├── control-plane/        # Vapor app: API, models, migrations, services, scheduler
│   └── web/              # Next.js frontend (separate strato-frontend service)
├── agent/                # Hypervisor node agent
│   ├── Sources/StratoAgentCore/   # testable core (reconciler, storage, manifest)
│   └── Sources/StratoAgent/       # executable (drivers, WebSocket client)
├── shared/               # Wire protocol, DTOs (StratoShared)
├── SwiftFirecracker/     # Vendored Swift wrapper for the Firecracker API
├── spicedb/schema.zed    # Authorization schema
├── deploy/compose/       # Supported single-host deployment
├── helm/ + skaffold.yaml # Kubernetes deployment / dev
├── envoy/, observability/ # mTLS proxy config, OTel collector config
├── docs/                 # VitePress site incl. docs/architecture/*.md
└── Taskfile.yml          # Primary local dev entry point (task dev)
```
