# Strato Architecture

Strato is a distributed private cloud platform. This page is the top-level
map: the components, the core control loop, and pointers into the
specialized documents that cover each subsystem in depth.

## Components

Three independently built Swift packages plus a frontend:

- **Control plane** (`control-plane/`, Vapor 4 + Fluent/PostgreSQL) — owns
  the JSON API, the database, the scheduler, authorization, and the agent
  WebSocket. Code map: [control-plane](./control-plane.md).
- **Agent** (`agent/`) — runs on every hypervisor node; connects out to the
  control plane and manages VMs and sandboxes through hypervisor drivers
  (QEMU, Firecracker). Code map: [agent](./agent.md).
- **Shared** (`shared/`, StratoShared) — the wire protocol and DTOs both
  sides speak. Reference: [wire-protocol](./wire-protocol.md).
- **Frontend** (`control-plane/web/`, Next.js) — a separate
  `strato-frontend` service consuming the JSON API. Code map:
  [frontend](./frontend.md).

```
┌────────────┐   JSON API    ┌─────────────────┐   WebSocket   ┌──────────────┐
│  Frontend   │ ────────────▶ │  Control plane   │ ◀──────────── │    Agent      │
│  (Next.js)  │               │  (Vapor)         │  /agent/ws    │  (per node)   │
└────────────┘               │                  │               │              │
                             │  PostgreSQL ◀────│── truth       │  QEMU        │
                             │  Valkey     ◀────│── coordination│  Firecracker │
                             │  SpiceDB    ◀────│── authz       │  OVN/OVS     │
                             └─────────────────┘               └──────────────┘
```

Agents always dial the control plane, never the reverse — hypervisor nodes
need no inbound connectivity.

## Desired state and reconciliation (the core control loop)

The control plane is declarative, not imperative:

- The database stores each VM's and sandbox's **desired state** (`running`,
  `shutdown`, `paused`, `absent`) alongside its observed status. API
  mutations update desired state; agents converge on it.
- The control plane periodically sends each agent a full, authoritative
  `DesiredStateMessage` covering VMs, sandboxes, and logical networks.
  Each desired record carries a monotonic **generation** counter guarding
  against reordering; syncs are level-triggered and safe to drop or replay.
  Image download URLs are control-plane-relative paths the agent fetches
  over SVID mTLS, so nothing in a sync expires.
- The agent-side reconciler diffs observed vs desired and converges via
  per-workload serial lanes, then reports observed state back — including
  the generation it converged toward and any convergence error. Absence
  from an observed-state report is what confirms a deletion.

The protocol contract (generations, level-triggered semantics, version
gates) is specified in [wire-protocol](./wire-protocol.md); the agent-side
engine in [agent](./agent.md); the control-plane side in
[control-plane](./control-plane.md).

## Async resource operations

VM and sandbox mutation endpoints (create/start/stop/delete/reboot, plus
pause/resume for VMs) insert a `ResourceOperation` row in the same
transaction as the desired-state change and return **202 Accepted** with
the operation object. The operation completes when an agent's observed
state catches up (or fails, or a stuck-operation sweep times it out after a
per-kind budget). Operation rows deliberately have no foreign key to the
resource, so delete operations survive the row's removal. The frontend
polls operations to a terminal state and refreshes the affected list.

## Multi-replica control plane

Multiple control-plane replicas are supported. PostgreSQL is the only
source of durable truth; **Valkey** holds ephemeral coordination state
(agent presence, socket routing, placement reservations, singleton sweep
locks) and the system fails open if it's unavailable — agents still
converge via the periodic sync. A mutation on one replica for an agent
socketed to another publishes a **sync nudge** over pub/sub; lost nudges
are backstopped by the periodic sync timer. Details:
[multi-replica](./multi-replica.md).

## Scheduler

`SchedulerService` places VMs on agents by resource availability with
strategies `least_loaded` (default), `best_fit`, `round_robin`, and
`random` (`SCHEDULING_STRATEGY`). Only online agents that reported support
for the VM's hypervisor and have sufficient resources are candidates;
placement uses Valkey reservations to avoid double-booking across
replicas. Details: [scheduler](./scheduler.md).

## Workload types

- **VMs** — long-lived machines on QEMU (Linux KVM / macOS HVF) or
  Firecracker, built from images with typed artifacts.
- **Sandboxes** — fast, disposable Firecracker microVMs booted from OCI
  images, with their own API surface and data model, TTL/auto-expiry, and
  interactive exec. Details: [sandboxes](./sandboxes.md).

On the agent, both route through a **hypervisor driver registry** keyed by
`HypervisorType` — adding a backend is one registration, not new switch
sites. A persisted manifest tracks which backend owns each workload,
surviving restarts and enabling orphan re-adoption.

## Networking

Each NIC is a `VMNetworkInterface` row (network name, MAC, MTU, stable
device name, ordered by index) with per-family address rows — there are no
single-NIC fields on the VM. **The control plane does IPAM**: static
IPv4/IPv6 addresses are allocated from a `LogicalNetwork`'s subnets and
passed to the agent. Agent-side, a network orchestrator resolves specs into
typed attachments consumed by the hypervisor drivers; Linux uses OVN/OVS
for real SDN, macOS falls back to user-mode SLIRP (dev/test only).
Details: [networking](./networking.md).

## Storage and images

Agents implement a `StorageBackend` protocol (currently filesystem +
qemu-img); the agent owns all paths, and the control plane stores whatever
the agent reports. A single `materializeDisk` path converts any image to
the format the hypervisor asked for, publishing via atomic rename. Volume
snapshots are external qcow2 overlays; volumes are host-local and pinned
to their VM's agent. Details: [storage](./storage.md); the replicated
design proposal is [distributed-storage](./distributed-storage.md).

Images have an architecture and a set of typed artifacts (`diskImage` for
QEMU; `rootfs`/`kernel`/`initramfs` for Firecracker/direct boot), each
with format, checksum, and size. Agents filter artifacts by supported
backend and host architecture, and download them over the Envoy mTLS
listener authenticated by their SPIFFE SVID (issue #493).

## Identity: authentication, authorization, and the org hierarchy

### Authentication

- **WebAuthn/Passkeys** (swift-server/webauthn-swift) with Vapor sessions
  is the primary human login; **API keys** (bearer tokens with scoping)
  serve programmatic access; optional **OIDC** providers federate sign-in,
  with **SCIM** provisioning for users and groups and a Shared Signals
  (SSF) receiver for revocation events.
- Agent transport security (optional): SPIFFE/SPIRE-issued mTLS terminated
  by Envoy in front of the control plane.

### Authorization (SpiceDB)

[SpiceDB](https://authzed.com/spicedb) enforces relationship-based access
control (the Zanzibar model); the schema lives in `spicedb/schema.zed`.

> A migration to an embedded Cedar policy engine is designed and in
> progress — see [iam](./iam.md) for the decision record. This section
> describes the current implementation.

The schema defines a hierarchy — `organization` → `organizational_unit` →
`project` → resources — plus `user`, `group`, `environment`,
`virtual_machine`, `sandbox`, `image`, `volume`, and related object types.
The SpiceDB type `organizational_unit` is the **folder** type; the wire-level
rename lands with the Cedar migration.
Permissions inherit down the hierarchy: a `project` attaches to its
`parent` (an organization or folder), and resource permissions resolve through
the project. Abridged excerpt:

```zed
definition project {
    relation parent: organization | organizational_unit
    relation admin: user
    relation member: user
    relation viewer: user

    permission manage_project = admin + inherited_admin
    permission create_resources = admin + member + inherited_admin
    permission view_project = admin + member + viewer + inherited_admin + inherited_member
}

definition virtual_machine {
    relation owner: user
    relation project: project
    relation viewer: user
    relation editor: user

    permission read = owner + viewer + editor + project->view_project
    permission update = owner + editor + project->manage_project
    permission delete = owner + project->manage_project
    permission start = owner + editor + project->create_resources
}
```

Integration points:

- `SpiceDBAuthMiddleware` (registered globally, including in tests)
  intercepts all HTTP requests: it skips a public allowlist (health
  checks, `/auth/*`, the agent WebSocket, image download URLs — which
  authenticate the agent's SVID or a user session in-handler), requires
  an authenticated user for everything else, lets system admins bypass
  permission checks, and for the prefix-guarded resource APIs maps HTTP
  method + path to a permission (`read`, `create`, `update`, `delete`,
  plus lifecycle verbs such as `start`, `stop`, `restart`, `pause`,
  `resume`, and sandbox `exec`) checked against that resource.
- `SpiceDBService` wraps the SpiceDB HTTP API (checks with full
  consistency, relationship writes, schema writes), authenticated with a
  preshared key.
- Controllers write ownership relationships automatically on resource
  creation (`owner` and `project` tuples), so org/folder admins inherit access
  transitively, and perform additional per-object checks in handlers.
- Schema loading: a Helm post-install/upgrade Job runs `zed schema write`;
  local development posts the schema via the HTTP API.

### Hierarchy, groups, and quotas

Organization → optional nested **folders** (materialized
path/depth) → projects (with environments). **Groups** — optionally
SCIM-provisioned — grant access. **Resource quotas** (vCPU, memory,
storage, VM count, sandbox count; optionally per-environment) attach at
org, folder, or project level and are enforced on VM and sandbox
create/delete; sandboxes draw from the same vCPU/memory pools as VMs.

## Observability

The control plane emits OTLP metrics, logs, and traces via swift-otel to
an OTel collector, which exports to Prometheus, Loki, and Jaeger
(`OTEL_METRICS_ENABLED` / `OTEL_LOGS_ENABLED` / `OTEL_TRACES_ENABLED`).
VM and sandbox console/workload logs flow from agents over the WebSocket
and are pushed to Loki. Audit events fan out to the database and optional
external backends, with retention pruning.

## Deployment shapes

- **`deploy/compose/`** — the supported single-host production deployment
  (published images, generated secrets).
- **`helm/strato-control-plane/`** — the supported Kubernetes deployment.
- Agents self-update from the control plane over the existing WebSocket —
  see [agent-updates](./agent-updates.md).

## Document index

| Document | Covers |
|---|---|
| [control-plane](./control-plane.md) | Control-plane code architecture: boot, services, request lifecycle, agent socket, sweeps, testing |
| [agent](./agent.md) | Agent code architecture: targets, driver registry, reconciler, storage, networking, self-update |
| [wire-protocol](./wire-protocol.md) | The StratoShared package: envelope, message catalog, reconciliation contract, DTOs |
| [frontend](./frontend.md) | Next.js app structure, data layer, operation polling, auth flow |
| [scheduler](./scheduler.md) | Placement strategies and integration |
| [multi-replica](./multi-replica.md) | Running multiple control-plane replicas |
| [networking](./networking.md) | OVN/OVS design, IPAM, roadmap |
| [storage](./storage.md) | StorageBackend, volumes, snapshots, image materialization |
| [distributed-storage](./distributed-storage.md) | Replicated block storage (design proposal) |
| [sandboxes](./sandboxes.md) | OCI-image Firecracker microVMs |
| [iam](./iam.md) | The Cedar migration decision record |
| [agent-updates](./agent-updates.md) | Operator-triggered and declarative agent updates |
