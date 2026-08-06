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
                             │                  │               │  OVN/OVS     │
                             └─────────────────┘               └──────────────┘
```

Agents always dial the control plane, never the reverse — hypervisor nodes
need no inbound connectivity.

## Desired state and reconciliation (the core control loop)

The control plane is declarative, not imperative:

- The database stores each VM's **desired state** (`running`, `shutdown`,
  `paused`, `absent`) — and each sandbox's (`running`, `stopped`, `absent`)
  — alongside its observed status. API mutations update desired state;
  agents converge on it.
- Each agent gets a full, authoritative `DesiredStateMessage` covering its
  VMs, sandboxes, and logical networks. Each desired record carries a
  monotonic **generation** counter guarding against reordering; syncs are
  level-triggered and safe to drop or replay. Image download URLs are
  control-plane-relative paths the agent fetches over SVID mTLS, so nothing
  in a sync expires.
- The agent **fetches** that sync by long-poll (`GET /agent/desired-state`,
  wire v29), rather than the control plane pushing it. Mutations ring a
  contentless broadcast doorbell so a parked poll answers immediately; the
  agent also re-fetches unconditionally on a slow timer, which is the
  correctness invariant behind every optimization in the path. Agents that
  predate v29 are still pushed to, per agent, through the transition.
- The agent-side reconciler diffs observed vs desired and converges via
  per-workload serial lanes, then reports observed state back — including
  the generation it converged toward and any convergence error. Absence
  from an observed-state report is what confirms a deletion.

The protocol contract (generations, level-triggered semantics, version
gates) is specified in [wire-protocol](./wire-protocol.md); the agent-side
engine in [agent](./agent.md); the control-plane side in
[control-plane](./control-plane.md).

## Async resource mutations

VM and sandbox lifecycle endpoints (create/start/stop/delete, VM
pause/resume/resize, sandbox restart) write the desired-state change and
return **202 Accepted** with `{resource, targetGeneration, mutationId}`.
Clients refetch the resource and read its `conditions` block: done once the
owning agent has confirmed `targetGeneration` and the desired state is
satisfied, failed when a `degraded` reason names that same generation. A
**stuck-convergence sweep** degrades a resource that misses the deadline the
mutation stamped, and runs lock-free on every replica.

There is no "operation already pending" refusal: desired state is
level-triggered, so overlapping mutations converge on the last write.

The same transaction appends a `resource_events` row — who mutated what, to
which target generation — an append-only trail that is never updated and
never swept, with a database trigger enforcing it. It is where mutation
attribution lives (ADR 0001), and, for a **delete**, where completion is
recorded: a delete succeeds by its resource ceasing to exist, which the
resource itself cannot report, so the reap appends a terminal event and
clients poll `GET /api/operations/:id` with the `mutationId`.

VM **restart** and the **snapshot** verbs are still imperative agent commands
with no generation to converge on: they keep `ResourceOperation` rows, the
`409` double-submit guard, and the operation-polling contract until ADR 0001
converts them. The operations API otherwise survives as a read-only façade
synthesized from `resource_events` plus the resource's conditions, so older
clients keep working.

## Multi-replica control plane

Multiple control-plane replicas are supported. PostgreSQL is the only
source of durable truth; **Valkey** holds ephemeral coordination state
(agent presence, socket routing for the remaining imperative RPCs,
placement reservations, singleton sweep locks) and the system fails open if
it's unavailable — agents still converge on their own re-fetch. A mutation
on any replica publishes a contentless **doorbell** on one fleet-wide
channel; every replica checks whether it holds that agent's parked poll (or
socket), at most one does, and lost doorbells are backstopped by the
agent's unconditional re-fetch. Details:
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

Name resolution is a separate, control-plane-owned model: project-scoped
`DNSZone`s attach many-to-many to logical networks, each network optionally
naming one as the zone its VMs register into. A zone's contents are
**derived ∪ authored** — VM hostname → allocated addresses plus PTR, unioned
with user-written records — assembled on demand and never stored, so
realization is a swappable driver. Details: [dns](./dns.md).

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

**WebAuthn/Passkeys** (swift-server/webauthn-swift) with Vapor sessions is
the primary human login; **API keys** (bearer tokens with scoping) serve
programmatic access; optional **OIDC** providers federate sign-in, with
**SCIM** provisioning for users and groups and a Shared Signals (SSF)
receiver for revocation events. Agent transport security is
SPIFFE/SPIRE-issued mTLS terminated by Envoy in front of the control plane
(the only agent auth path); the listener prefers **X25519MLKEM768**, a
hybrid post-quantum key exchange, so a recorded handshake cannot be
decrypted retroactively once quantum computers arrive, while the classical
X25519 half keeps the connection safe if ML-KEM is ever broken (agents
negotiate it from swift-nio-ssl 2.37.1 onward; it needs Envoy >= v1.39.0).

### Authorization (built-in Cedar IAM)

Authorization is a built-in IAM system evaluated **in-process** by an
embedded [Cedar](https://www.cedarpolicy.com/) policy engine — there is no
external authorization service. Postgres is the only authorization store
(role bindings, guardrails, the resource tree), which makes grants
transactional with the resources they protect. Access derives from walking
up the resource hierarchy — `organization` → folder (`organizational_unit`
on the wire, pending rename) → `project` → resource; explicit `forbid`
beats explicit `permit` beats default deny. The full design — the model,
roles, guardrails, decision logging — is documented in [iam](./iam.md); why
it replaced the earlier SpiceDB deployment, and the migration that did, is
recorded in [ADR 0004](../adr/0004-cedar-for-authorization.md).

Integration points, briefly: `AuthorizationMiddleware` (registered globally,
tests included) is **structurally default-deny** — every route must fall
into exactly one class (public allowlist, login-only, resource-mapped, or
handler-checked), an unclassified route fails boot, and an unmatched path is
denied. Checks funnel into `IAMAuthorizer`; handlers use `req.can` /
`req.authorize` for per-object checks, and system admins are allowed by a
tier-1 policy inside the evaluator, not by a bypass. **Roles** are nested
global action groups (`viewer ⊂ operator ⊂ editor ⊂ admin`) bound at org,
folder, project, or resource level, with the creator's binding written in
the same transaction as the resource. **Guardrails** are forbid-only
ceilings that inherit downward and bind system admins like everyone else.
Every decision lands in the decision log, and the **can-i / who-can** API
(`/api/authorization/*`) answers hypothetical and reverse queries.

### Hierarchy, groups, and quotas

Organization → optional nested **folders** (materialized
path/depth) → projects (with environments). **Groups** — optionally
SCIM-provisioned — grant access. **Resource quotas** (vCPU, memory,
storage, VM count, sandbox count; optionally per-environment) attach at
org, folder, or project level and are enforced on VM and sandbox
create/delete; sandboxes draw from the same vCPU/memory pools as VMs.

## Observability

The control plane emits OTLP metrics, logs, and traces via swift-otel
(`OTEL_METRICS_ENABLED` / `OTEL_LOGS_ENABLED` / `OTEL_TRACES_ENABLED`). The
Helm chart ships an OTel collector that exports metrics to Prometheus (a
remote-write to the bundled instance, plus a scrape endpoint) and traces to
a configurable OTLP endpoint; collected logs go to the debug exporter. The
compose deployment leaves OTLP export off and runs Loki directly. VM and
sandbox console/workload logs flow from agents over the WebSocket and are
pushed to Loki. Audit events fan out to the database and optional external
backends, with retention pruning.

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
| [frontend](./frontend.md) | Next.js app structure, data layer, refetch-until-converged, auth flow |
| [scheduler](./scheduler.md) | Placement strategies and integration |
| [multi-replica](./multi-replica.md) | Running multiple control-plane replicas |
| [networking](./networking.md) | OVN/OVS design, IPAM, roadmap |
| [dns](./dns.md) | Zones, hostnames, record assembly, and the realization layers |
| [storage](./storage.md) | StorageBackend, volumes, snapshots, image materialization |
| [distributed-storage](./distributed-storage.md) | Replicated block storage (design proposal) |
| [sandboxes](./sandboxes.md) | OCI-image Firecracker microVMs |
| [iam](./iam.md) | Cedar-based authorization: invariants, tiers, roles, guardrails, enforcement |
| [authorization-edge-audit](./authorization-edge-audit.md) | Point-in-time audit of the authorization enforcement edge (July 2026) |
| [guest-identity](./guest-identity.md) | SPIFFE SVIDs for guest VMs and sandboxes (design proposal) |
| [webhooks](./webhooks.md) | User-managed event notifications: event catalog, signing, transactional outbox |
| [agent-updates](./agent-updates.md) | Operator-triggered and declarative agent updates |
