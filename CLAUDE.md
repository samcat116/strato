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
- `docs/development/code-review.md` is the review checklist — what to check when reviewing, and the author's pre-review pass. Its "Strato-specific traps" section lists the invariants that break most often (generation bumps, verdict paths, Valkey failing open, agent-owned paths).

## Development Commands

### Building and testing (Swift)

Independent Swift packages: `control-plane/`, `agent/`, `shared/`, `cli/`, `clients/swift/` (plus vendored `SwiftFirecracker/`). Each builds and tests separately:

- `swift build --package-path <pkg>` / `swift test --package-path <pkg>`
- `swift test --package-path control-plane --filter <SuiteName>` — run a single suite while iterating
- Tests use swift-testing (`@Test`/`#expect`), not XCTest

**CI does not run tests.** PR validation is a compile check only — it builds each package without `--build-tests`, so test targets are not even type-checked, and nothing on `main` runs them either. Running the full suite for every package you touched, before creating or updating a PR, is on you. The `Full Test Suite (manual)` workflow (`gh workflow run main-tests.yaml --ref <branch>`) runs everything on the CI runners if you want a second opinion.

Build & test notes:
- Swift builds in a fresh worktree start from a cold `.build` and can take 10+ minutes. Run builds/tests with a generous timeout or in the background — never the default 2-minute timeout.
- Control-plane tests run against Postgres everywhere (the SQLite backend was removed). They expect a reachable server via `DATABASE_*` env vars — defaults `localhost:5432`, user `strato`, password `strato_password`, database `strato_test`; `docs/development/local-development.md` has a `docker run` one-liner matching the defaults. The harness clones a migrated template database per test, so parallel worktrees can share one server.
- Known flake in the control-plane suite: it can crash with Vapor's `ServeCommand did not shutdown before deinit` teardown race. If a failure matches that signature and doesn't reproduce on a rerun, it's the race, not your diff.
- Swift CI (the PR compile check and main-branch release binaries) runs on the `swift-runners-strato` runner scale set managed by actions-runner-controller; the static self-hosted runner on the strato-dev VM (`/home/sam/actions-runner`) is no longer used by any workflow. If Swift CI fails with missing-symbol errors your diff can't explain, suspect a stale build cache in the runner's persistent `RUNNER_TOOL_CACHE` volume — reproduce locally before debugging source.

### Formatting and linting (CI-enforced)

- **Swift**: CI runs `swift format lint --strict --recursive` over all `Sources/` and `Tests/` directories, using the `.swift-format` config at the repo root (4-space indent, 120-col lines). Format before pushing: `swift format --in-place --recursive <changed dirs>`.
- **Frontend**: `cd control-plane/web && bun run lint` and `bun run build` — CI runs both with Bun (`bun install --frozen-lockfile`). The frontend uses Bun, not npm.

### Local development

There is no turnkey dev environment — no Taskfile, no root `docker-compose.yml`,
no Skaffold. The inner loop is `swift build` / `swift test` (which need no
running services), and full-stack runs go through `deploy/compose`. See
`docs/development/local-development.md`.

### Running services directly

- `cd control-plane && swift run` — control plane. Needs Postgres/Valkey env vars pointed at reachable services; `deploy/compose` does **not** publish those ports, so this requires a `docker-compose.override.yml` that does.
- `cd agent && swift run StratoAgent --config-file ./config.toml` — agent (TOML config; CLI args override config values; `control_plane_url` is required; key options: `log_level`, `network_mode` = `ovn`|`user`, `firecracker_binary_path`). Copy `config.toml.example` to start.
- Agents authenticate only by SPIFFE/SPIRE X.509 SVID over mTLS. Enroll a node with `POST /api/agent-enrollments` (or **Agents → Add Agent** in the UI), which provisions it in SPIRE and returns a one-liner `bootstrapCommand`; the agent then dials its configured `control_plane_url` with `?name=<agent-name>` and no bearer credential.
- Authentication is always on: there is no development bypass. Local development registers a real WebAuthn passkey user (see `docs/development/local-development.md`).

### Deployment environments (the two supported paths)

- **`deploy/compose/`**: single-host Docker Compose. `./setup.sh` generates `.env` with strong random secrets, then `docker compose up -d`. Published GHCR images by default; comment out `image:` and uncomment `build:` on the `control-plane` service to build from source. Published ports: the proxy (`${HTTP_PORT:-80}`), the Envoy agent-mTLS listener (`${AGENT_MTLS_PORT:-8443}`), and SPIRE node attestation (`${SPIRE_NODE_PORT:-8085}`). Put local changes in an untracked `deploy/compose/docker-compose.override.yml`, never in the tracked compose file.
- **`helm/strato-control-plane/`**: Kubernetes. `helm dependency build` once, then `helm install strato .`. Example values live in `helm/strato-control-plane/ci/`; `.github/workflows/helm-test.yml` templates and installs against them.
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
- Each agent gets a full, authoritative `DesiredStateMessage` (see `shared/Sources/StratoShared/ReconciliationProtocol.swift`). Each `DesiredVMState` carries a monotonic `generation` counter guarding against reordering; syncs are level-triggered and safe to drop/replay. Image download URLs are control-plane-relative paths the agent fetches over SVID mTLS, so nothing in a sync expires.
- **The agent pulls that sync** (`GET /agent/desired-state`, STR-146) — the only sync transport since wire v38, when the pushed `desired_state` frame was deleted along with every per-feature version gate (`WireProtocol.minimumSupportedVersion`: both sides refuse older peers at registration; control plane and agents deploy in lockstep). Mutations ring a contentless broadcast doorbell (`agent:doorbell`) that wakes whichever replica holds the agent's parked poll; the ETag is a digest of the assembled payload, and the agent's unconditional periodic re-fetch — which sends no `If-None-Match` — is the correctness invariant behind both.
- The agent-side reconciler (`agent/Sources/StratoAgentCore/Reconciliation.swift`) diffs observed vs desired and converges via per-VM serial lanes, and reports observed state back.

### Async resource mutations

VM and sandbox lifecycle endpoints (create/start/stop/delete, VM pause/resume/resize, sandbox restart) write the desired-state change plus an append-only `resource_events` row in one transaction and return **202 Accepted** with `{resource, targetGeneration, mutationId}` (ADR 0001 stage 4, STR-147). Clients refetch the resource and read its `conditions`: done ⇔ `converged` at or past `targetGeneration`, failed ⇔ `degraded.sinceGeneration == targetGeneration`. The two are mutually exclusive — `converged` also requires `failedGeneration ≠ generation` (STR-191), because an agent advances `observedGeneration` per work item and plans more than one per generation, so a converged boot and a failed same-generation resize would otherwise both answer. One derivation feeds both readers: `ConvergenceDerived` supplies `conditions` and `isConverged` over a per-family `desiredSatisfied`, and `Volume.bytesAtRest` is the deliberate exception `canSnapshot`/`canClone` read instead. There is no "operation already pending" `409` — desired state is level-triggered, so overlapping writes are safe. `ResourceMutation.accept` locks the row and re-reads the reconciliation-owned columns first, so a handler's pre-request snapshot cannot regress `observedGeneration` or drop a racing mutation's bump; both convergence outcomes commit their row write with their webhook in one transaction. A **stuck-convergence sweep** marks a resource degraded past its `convergence_deadline` (stamped as `max(existing, now + budget(kind))` so a short mutation never shortens a long one's runway) and runs lock-free on every replica.

Volumes joined this flow in STR-148 — `Volume` is a `ConvergingResource` and a `FinalizableResource` like `VM` and `Sandbox` — and snapshot artifacts in STR-150, where all three families (`VolumeSnapshot`, `VMSnapshot`, `SandboxSnapshot`) became the same, sharing behavior through `SnapshotArtifactResource`. The last three exceptions — VM **restart** and VM/sandbox **restore** — converted in STR-151 as **edge-nonces** (wire v34): a reboot has no state delta and a restore cannot be re-converged on, so what rides the sync is a monotonic count of how many times each was asked for, applied once against a record the agent keeps in `VMManifestStore`. ADR stage 11 (STR-152) then deleted what was left: the `resource_operations` table and its model, `ResourceOperationCoordinator`, the cluster-singleton stuck-operation sweep, the generic pending-request apparatus in `AgentService`, and the cross-replica RPC bridge. `GET /api/operations/:id` survives as a compatibility façade that synthesizes a response from `resource_events` + the resource's conditions. **Delete** is the one mutation whose outcome the resource cannot report — its success is the row's absence — so the finalizer reap appends a terminal `resource_events` row and clients poll the façade with `mutationId`. A delete's verdict comes only from that evidence, never from conditions: past its deadline it reads `pending`, not `failed`, because a slow teardown is not a failed one.

### Multi-replica control plane (Valkey coordination)

Multiple control-plane replicas are supported (see `docs/architecture/multi-replica.md`; `CoordinationService.swift`):

- PostgreSQL is the only source of truth for desired state; Valkey holds ephemeral coordination state and fails open (agents still converge via periodic sync if Valkey is down).
- Agent liveness: `agent:{name}:presence` keys with 60s TTL. There is no socket-routing directory: the `agent:{name}:replica` key and the `replica:{id}:rpc` forwarding channels it served were deleted in STR-152, once volumes (STR-148), snapshot artifacts (STR-150) and VM reboot / VM+sandbox restore (STR-151) had all become desired state. Console and exec write straight to the local socket.
- **Doorbell**: a mutation rings the contentless fleet-wide `agent:doorbell` broadcast; whichever replica holds that agent's parked poll or socket acts on it, and the rest no-op. A lost doorbell is backstopped by the agent's own unconditional re-fetch. Scheduler placement reservations (`resv:*`) and singleton sweep locks (`lock:sweep:*`) still live in Valkey.
- **Sessions are a separate Valkey store, not coordination state** (issue #855). Coordination fails open; session storage cannot — losing it logs every user out, and passkeys are the only interactive auth. Coordination reads `VALKEY_*`, sessions read `SESSION_VALKEY_*` and fall back *wholesale* (never per-field) to the coordination endpoint, sharing one client when the endpoints match. `/health/ready` grades `coordination` degraded-only, and `session-store` fatal *only when it has its own endpoint* — a shared endpoint fails on every replica at once, so 503 would shift traffic nowhere.

### Scheduler

`SchedulerService` places VMs on agents by resource availability with strategies `least_loaded` (default), `best_fit`, `round_robin`, `random` (`SCHEDULING_STRATEGY` env var). Only online agents with sufficient resources are candidates; placement uses Valkey reservations to avoid double-booking across replicas. Details in `docs/architecture/scheduler.md`.

### Agent: hypervisor driver registry

All VM message handling routes through a driver registry keyed by `HypervisorType` (`agent/Sources/StratoAgent/Agent.swift`) — adding a backend means one registration, not new switch sites:

- **QEMU** (`LibvirtService`, via swift-libvirt): domains defined and driven through libvirtd at `qemu:///system`. **Linux only**, libvirt ≥ 11.5; off Linux the agent registers a mock and reports `.qemu` unavailable (STR-136). Same-arch VMs only for acceleration; cross-arch falls back to slow TCG.
- **Firecracker** (`FirecrackerService`, via the vendored `SwiftFirecracker/` package at the repo root): Linux only, kernel+rootfs boot.
- **Mock** (`MockHypervisorService`): testing.

A persisted VM manifest tracks which backend owns each VM (survives restarts, enables orphan detection). `agent/Sources/StratoAgentCore/` holds the testable core (no native hypervisor SDKs, though it does link the pure-Swift swift-libvirt for the domain XML builder and state mapping); `StratoAgent` is the executable.

### Networking

- Each NIC is a `VMNetworkInterface` row (there are no single-NIC fields on VM anymore): network name, MAC, IP, MTU, stable device name (`net0`, `net1`, ...) ordered by `orderIndex`.
- **The control plane does IPAM** (`IPAMService`): allocates static IPs/netmask/gateway from a `LogicalNetwork`'s subnet and passes them to the agent.
- Agent-side, `NetworkOrchestrator` routes to a platform driver behind `NetworkServiceProtocol`; hypervisor drivers receive typed `NetworkAttachment` values (TAP path + driver type) rather than assuming a format.
- Linux: OVN/OVS (via SwiftOVN) for real SDN — TAP interfaces, VM-to-VM traffic, isolation. macOS: QEMU user-mode SLIRP only (outbound NAT, no inbound, no VM-to-VM) — dev/test only.
- **DNS** (`docs/architecture/dns.md`) is a separate control-plane-owned model: project-scoped `DNSZone`s attach many-to-many to networks, each network optionally naming one as its **primary** (the zone its VMs register into). A zone's contents are **derived ∪ authored** — `VM.hostname` → allocated addresses plus PTR, unioned with `DNSRecord` rows — assembled on demand by `DNSZoneAssembler` and never stored, so realization stays a swappable driver. The first driver landed in STR-39 (wire v36): `DesiredStateMessage.dnsZones` carries each zone attached to a network the receiving agent authors, and the agent realizes the **A/AAAA/PTR** subset into the OVN `DNS` table, referenced from `Logical_Switch.dns_records`. Two things are load-bearing. Zones ride the **network carrier, not `NetworkSpec`** — DNS edits don't bump VM generations, so only the level-triggered network reconcile reaches them — and only the **topology authority** is sent zones (nil, never `[]`, for everyone else), while their *records* are assembled fleet-wide, because a zone's names span every agent's VMs. An unchanged zone costs no OVSDB transaction: the control plane's `recordsHash` is stamped in `external_ids` and compared, with the flattened records compared too so a drifted row still heals. **Phase 4 (STR-40, wire v37) put a resolver behind it**: every network can have one on a link-local pair of its own — `169.254.<hi>.<lo>` / `fd00:ec2:1::<index>`, both derived from a fleet-wide `resolver_index` the control plane allocates — realizing CNAME/TXT/SRV *and* forwarding everything else upstream. It runs in the **host** namespace, on a localport of its own beside metadata's, as a **single** CoreDNS per host with one server block per network (ADR 0008, which supersedes ADR 0007's chassis-namespace design: that namespace has only link-local addresses and no egress, so it could not forward, which was the bug the phase was filed for). Metadata **stays** in the namespace — source-IP attribution is its security model and it needs no egress. Four things are load-bearing. Replies are routed by **per-network policy routing** (`ip rule from <addr> lookup 20000+index`), which is the one job the namespace did for free; the foot is fenced with forwarding off and loose `rp_filter`. `LogicalNetwork.dnsServers` is **redefined, not replaced** — it becomes the resolver's upstream forwarders and the DHCP `dns_server` option becomes the link-local address. `dnsZones` **widens past the topology authority**, because the resolver answers wherever the guests are while OVN `DNS` rows stay switch-scoped. And enabling it is a **site-wide** admission decision (`AgentRegisterMessage.resolverCapable` folded across every agent in the site), because one DHCP row points guests at an address a per-host process answers.

### Storage and images

- Agents implement the `StorageBackend` protocol (`agent/Sources/StratoAgentCore/StorageBackend.swift`); the current backend is filesystem + qemu-img. The agent owns all paths — the control plane stores whatever paths the agent reports and passes them back verbatim.
- **Single image-materialization path**: `materializeDisk(at:from:format:)` converts any image to the format the hypervisor asked for (e.g. qcow2 → raw for Firecracker), writing to a staging path and publishing via atomic rename.
- **Volumes are desired state** (ADR 0001 stage 5, STR-148): `DesiredVolumeState` carries exists/size/format/attachment plus a clone-or-image **create strategy**, and `ObservedVolumeState`'s full-list omission confirms a deletion. Create/delete/attach/detach/resize/clone answer `202` and converge; the six imperative `volume_*` messages were deleted at wire v31. `volume_info` was deleted outright at wire v32 (stage 7, STR-149) — it had no sender, and its fields were already on the observed report or in the database. No volume frame is left on the wire at all: both snapshot verbs became desired artifacts at v33 (stage 8, STR-150).
- **Volumes and volume snapshots are charged against `maxStorage`** (STR-181). They were the only storage objects nothing counted, and the blocker was scoping rather than accounting: `QuotaScope.predicate` filters every workload table on `project_id` *and* `environment`, and neither table had one — both do now, denormalized onto the snapshot exactly as `VMSnapshot` does. A volume is charged the size it **asked for**, not `observed_size_bytes`, because a refused grow is blocked rather than withdrawn and would otherwise be free until it lands. A snapshot is admitted against — and keeps reserved — the parent volume's *whole* size: an overlay can grow toward that bound with no later API call to admit it, so replacing the reservation with a small first footprint would let sequential snapshots oversubscribe the pool. A v39 agent still re-`stat`s the live footprint on every report and exposes it as `ObservedSnapshotFacts.currentSizeBytes` for observability and billing, separate from the capture-time `sizeBytes`. Volume snapshots stay out of `enforceStorageQuota`'s auto-delete because the durable parent-sized reservation already protects admission and a figure that changes every report must not repeatedly arm destructive enforcement. A migrated boot volume is skipped whenever its `storage_path` matches a VM's `disk_path`, even after detachment clears `vm_id`, since `SUM(vms.disk)` already charges that file. The migration backfills both `volume_count` and the complete `reserved_storage` cache from the canonical aggregate.
- **A grow the agent refuses is blocked, not permanent** (STR-199). Growing a volume attached to a guest that is not confirmed shut down is refused with a reason naming a remedy ("stop the guest, or detach"), and `FailureClassification.blocked` is what makes applying that remedy work: the reason is *reported* like a permanent failure but burns no attempt, so every level-triggered sync retries and the grow lands when the guest stops — no new generation needed. Classified permanent, the first refusal exhausted the budget and the volume stayed short of a size nothing had withdrawn. The size a volume actually has now travels too (wire v38): `ObservedVolumeState.sizeBytes` → `volumes.observed_size_bytes` → `VolumeResponse.observedSize`, because `size` alone is desired state and reporting it for a refused grow reads as one that worked. Nil is "the agent said nothing", never zero, and never clears the column.
- Volume snapshots are external qcow2 overlays with detected (not assumed) backing formats. Volumes and their VM must be on the same agent; volumes only place on online, QEMU-capable agents speaking wire v31+ — enforced at accept time by the controller and at placement time by `selectVolumeAgent`, because there is no imperative fallback left.
- **Reboot and restore are edge-nonces** (ADR 0001 stage 9, STR-151, wire v34): `DesiredVMState.rebootGeneration`, `DesiredVMState.restore` and `DesiredSandboxState.restore` count how many times each verb was asked for, and the agent acts only when the count outranks the one it recorded in `VMManifestStore`. **No record is not zero** — an entry from an older build is adopted (written down, unperformed) rather than replayed, or a re-registered agent would rewind a live guest to a checkpoint from weeks ago; adoption is eager, on the first sync after upgrade, because a lazy record would be swallowed by the very request that finally bumped the generation. A *reboot* is consumed by being superseded (a stop, or a boot) as much as by being performed; a *restore* is not — it is about state rather than power, so it waits for the workload to be wanted running again. `supportsEdgeNonces` refuses the three endpoints with `409` against a pre-v34 agent, which would otherwise ignore the field and report the generation as converged.
- **Snapshots and checkpoints are desired artifacts** (ADR 0001 stage 8, STR-150, wire v33): one kind-tagged `DesiredSnapshotState` list covers volume snapshots, VM checkpoints and sandbox snapshots, and the captured metadata (footprint, QEMU/Firecracker version, fork layout, CPU template) comes back on `ObservedSnapshotState` instead of an RPC reply that a dropped socket could lose. A **capture is a create strategy**, read only while the artifact is absent from the host — that is what stops a replayed sync re-checkpointing a live guest. Export is a **placement fact**, not a verb. Retention is an absolute `expires_at` plus a cluster-singleton sweep (`SNAPSHOT_DEFAULT_TTL_SECONDS`, unset by default). With no imperative fallback left, `supportsSnapshotSync` gates *capture admission* rather than placement — an artifact inherits its parent's host, so there is no scheduling decision to gate. The agent's durable inventory is `SnapshotRecordStore`; a record file it cannot read makes it report `snapshots: nil`, never an empty list.
- Images have an architecture and a set of typed `ImageArtifact`s (`diskImage` for QEMU, `rootfs`/`kernel`/`initramfs` for Firecracker/direct boot), each with format, checksum, and size. Agents filter artifacts by supported backend + host architecture, giving per-hypervisor image compatibility.

### AuthZ, authN, and the org hierarchy

- **Authorization** is a built-in Cedar policy engine — no external authz service. The in-process evaluator (`IAMAuthorizer`) evaluates compiled Cedar policy sets against `role_bindings` rows and the relational org hierarchy in Postgres; the default-deny `AuthorizationMiddleware` gates every API route, and admin access flows through the evaluator too (no controller-local fast paths).
- **Authentication** is WebAuthn/Passkeys (swift-server/webauthn-swift) with Vapor sessions, plus API keys for programmatic access and optional OIDC providers. WebAuthn env vars: `WEBAUTHN_RELYING_PARTY_ID`, `WEBAUTHN_RELYING_PARTY_NAME`, `WEBAUTHN_RELYING_PARTY_ORIGIN` (origin must exactly match the browser URL).
- Hierarchy: Organization → optional nested **Folders** (materialized `path`/`depth`) → Projects (with environments). Folders are still named `OrganizationalUnit` on the wire and in the database (models, routes); the user-facing term is "folder" and the wire rename is still pending. **Groups** (optionally SCIM-provisioned, see `SCIMToken`/`SCIMExternalID`) grant access; **ResourceQuotas** (vCPU/memory/storage/VM count/sandbox count/optional volume count, optionally per-environment) attach at org, folder, or project level and are enforced on VM, sandbox and volume create/delete; sandboxes draw from the same vCPU/memory pools as VMs, and volumes from the same storage pool as VM disks.
- Agent transport security: SPIFFE/SPIRE-issued mTLS terminated by Envoy in front of the control plane — the only agent authentication path. Config lives in `deploy/compose/spiffe/` (SPIRE server, Envoy, bootstrap) and is wired into the compose stack by default.

### Observability

The control plane emits OTLP metrics/logs/traces via swift-otel, toggled with `OTEL_METRICS_ENABLED` / `OTEL_LOGS_ENABLED` / `OTEL_TRACES_ENABLED`. The Helm chart ships an OTel collector whose config is inlined in `templates/otel-collector-configmap.yaml` (gated on `opentelemetry.enabled`). `deploy/compose` leaves OTLP export off and runs Loki directly for VM console logs, plus Prometheus for SPIRE issuance metrics.

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
├── clients/swift/        # Generated Swift API client (spec symlinked from control-plane)
├── SwiftFirecracker/     # Vendored Swift wrapper for the Firecracker API
├── deploy/compose/       # Supported single-host deployment (incl. spiffe/ mTLS config)
├── helm/                 # Kubernetes Helm chart
└── docs/                 # VitePress site incl. docs/architecture/*.md
```

## Agent skills

### Issue tracker

Issues and PRDs are tracked as GitHub issues in `samcat116/strato` via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
