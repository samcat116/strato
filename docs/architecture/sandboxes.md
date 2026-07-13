# Sandboxes

Sandboxes are a first-class workload type (umbrella issue #410): microVMs
booted from **OCI images** on Firecracker, with their own API surface
(`/api/sandboxes`) and data model, deliberately separate from VMs so the two
can diverge over time. Where a VM is a long-lived machine you manage,
a sandbox is a fast, disposable execution environment for a container-shaped
workload — an image reference, resource sizing, and overrides for
entrypoint/cmd/env/workdir.

> **Status**: phase 1 in progress. The wire protocol (issue #411), the
> generalized operation machinery (#412), the control-plane model/API (#413),
> registry pull secrets + tag→digest resolution (#414), scheduler gating
> + quota accounting (#415), and the NIC/address model + IPAM integration
> (#416) are landed; the agent runtime is tracked in issues #417–#422.
> Sections below describe the agreed design; anything not yet landed is marked
> with its issue.

## Decision: native Swift Firecracker path

Sandboxes extend the vendored `SwiftFirecracker/` package and the agent's
existing `FirecrackerService` machinery. **firecracker-containerd was
considered and rejected**: it brings a Go daemon and a devmapper thin-pool
host dependency, and fits poorly with the Swift agent's driver registry,
manifest, and reconciler. OCI pull/unpack, image caching, and vsock guest
control are built natively in the agent instead.

## Workload shape

A sandbox is described by `SandboxSpec`
(`shared/Sources/StratoShared/SandboxModels.swift`), which is deliberately
*not* a `VMSpec`:

- **Image**: an OCI reference (`registry/repo:tag`) plus the manifest digest
  it resolved to. The control plane resolves the tag at sync assembly, **at
  most once per sandbox**, and persists the pin so convergence is immutable —
  a re-tagged image never changes a sandbox out from under its generation.
  Resolution is best effort: a registry that is down never blocks the sync
  (the agent then resolves the tag itself until a later sync pins it).
- **Sizing**: vCPUs and memory bytes only.
- **Process**: optional entrypoint/cmd/workdir overrides and an env map,
  merged over the image config by the guest agent.
- **Networking**: at most one NIC on a `LogicalNetwork`, reusing the VM
  `NetworkSpec` so agents realize it through the same OVN/user-mode paths
  (#416, landed — see the control-plane section).
- **No** volumes, firmware, boot source, or hypervisor choice — sandboxes are
  Firecracker-only, and v1 has no attachable storage.

## Riding the reconciliation loop

Sandboxes reuse the level-triggered desired-state sync rather than growing a
parallel imperative path (see `docs/architecture/overview.md` for the loop
itself):

- `DesiredStateMessage.sandboxes` carries the full authoritative set of
  `DesiredSandboxState` entries for the agent, alongside `vms` and `networks`.
  Each entry has a monotonic per-sandbox `generation` with exactly the same
  drop/replay/reorder guarantees as VMs.
- Desired status is one of `running`, `stopped`, `absent` — strictly decoded,
  like `DesiredVMStatus`, because misreading a goal is destructive.
- `ObservedStateReport.sandboxes` reports observed status, the generation the
  observation reflects, a convergence phase while work is in flight, the last
  convergence error, and — new versus VMs — the workload's **exit code**.
- **Exited is not stopped.** A sandbox's workload can end on its own, which a
  VM never does from the control plane's perspective. The observed status
  `exited` satisfies both desired `running` ("the workload should have been
  started" — it ran to completion; phase 1 has no restart policy, so the
  reconciler must not relaunch one-shot workloads forever) and desired
  `stopped` (equally not-running). Exit-code surfacing to the API and richer
  lifecycle handling come with #423.
- Sandbox mutations create the same 202-Accepted async operation rows as VM
  mutations, via the operation machinery generalized in #412.

### Registry pull secrets and credentials on the wire

Private images need pull credentials agent-side (issue #414). Durable storage
is control-plane-only: a project stores at most one credential per registry
host under `/api/projects/:projectID/registry-credentials` (reads need
`view_project`, mutations `manage_project`), with the secret **encrypted at
rest** through the same `SecretsEncryptionService` machinery as OIDC client
secrets and never echoed back by the API.

`DesiredSandboxState` carries an optional `RegistryCredential` (registry host,
username, password/token, expiry, bearer flag) that the control plane mints
**fresh at every sync assembly** — the same slot where signed image URLs are
refreshed — so a long-lived desired entry never holds an expired secret. The
control plane speaks the distribution auth flow (`DistributionRegistryClient`:
challenge probe → token endpoint → manifest; Docker Hub, GHCR, and any
distribution-spec registry): when the registry has a token service it mints a
short-lived pull-scoped **bearer token** (`bearer: true`; agents present it
directly), and only for Basic-only registries — or when the token service is
unreachable — does it fall back to sending the stored credential itself
(`bearer: false`). Agents use the credential for the pull and never persist
it. Public images work with no credential and zero configuration; sandboxes
already pinned to a digest keep converging on it even if the credential is
later deleted.

### Protocol versioning

Sandbox sync is wire protocol **version 5** (`WireProtocol.swift`). The
change is additive — absent `sandboxes` lists decode to `[]` — but carries the
same asymmetric hazard as the v3 networks list:

- **Agent side**: a pre-v5 control plane omits the field entirely; the agent
  must not read the decoded-empty list as "tear down all sandboxes". Sandbox
  reconciliation is gated on `WireProtocol.supportsSandboxSync(senderVersion)`.
- **Control-plane side**: the wire version is deliberately *not* the placement
  signal. An agent built against v5 understands the fields but may predate the
  sandbox runtime (#421), and would silently ignore desired entries and report
  none back. Agents therefore advertise sandbox support explicitly at
  registration (`AgentRegisterMessage.sandboxCapable`), and the scheduler keys
  eligibility on that flag plus the version (#415) — never on the version
  alone. Agent-side, the flag comes from `SandboxRuntimeProbe`: the build must
  contain the runtime driver (`SandboxRuntimeProbe.runtimeBuilt`, hard-false
  until #421 lands — a runtime-less agent would silently ignore desired
  sandboxes), Firecracker must be usable (binary + KVM, from the hypervisor
  probe), **and** the sandbox guest base image (#419) must be present at
  `sandbox_guest_image_path` (default `/var/lib/strato/sandbox/guest`) — so
  the capability lights up exactly when a runtime-carrying agent has the
  artifacts installed on a capable host.

## Control plane (issues #412–#416)

- `Sandbox` model (`control-plane/Sources/App/Models/Sandbox.swift`) with the
  same desired/observed generation split as VMs, plus sandbox-only fields:
  the OCI ref and resolved digest, entrypoint/cmd/env/workdir overrides, a
  stored-but-unenforced `ttl_seconds` (enforcement is #424), and the reported
  exit code (#413, landed).
- `/api/sandboxes` (`SandboxController`): list/create/show/update/delete +
  start/stop/restart + status + operations. Mutations insert a
  `resource_operations` row (`resource_kind = sandbox`) and bump desired state
  in one transaction, returning **202 Accepted** — the machinery generalized
  in #412. Restart is expressed as a fresh desired-`running` generation (there
  is no imperative sandbox reboot message); its agent-side interpretation
  lands with the runtime (#421).
- `definition sandbox` in SpiceDB: a near-copy of `virtual_machine` minus
  console/pause/promote, plus `exec` for phase 2. `SpiceDBAuthMiddleware`
  guards `/api/sandboxes` through the same route-prefix → resource-type
  mapping as VMs.
- Creation runs the quota admission check in the create transaction and places
  onto an agent that advertised the sandbox runtime (#415, see the versioning
  section above). Placement rides the same `filterEligibleAgents` pipeline and
  Valkey placement reservations as VMs; the reservation releases on the same
  triggers (send failure, the agent's observed-state reports accounting for
  the sandbox, deletion confirmation, TTL backstop).
- **Quota accounting (#415)**: sandbox vCPUs and memory draw from the *same*
  `ResourceQuota` pools as VMs — `calculateActualUsage` and the reservation
  resync sum both workload kinds — while the count limit is a separate
  `max_sandboxes`/`sandbox_count` pair (backfilled from `max_vms`), so
  sandboxes never silently consume VM slots. Reservation happens in the create
  transaction (`QuotaEnforcementService.reserveSandbox`) and releases when the
  row is removed (deletion confirmed by agent report, or direct deletion for
  unplaced/agent-offline sandboxes). Sandboxes reserve no storage.
- Sandboxes reference images by OCI ref only — they do not use the
  `Image`/`ImageArtifact` model at all.

## Agent runtime (issues #417–#421)

The agent-side pipeline, all native Swift:

1. **OCI client** (#418): pull the manifest + layers for the pinned digest,
   flatten to an ext4 root filesystem, and cache it **by manifest digest** —
   v1 caches flattened images only (no layer-level dedup/snapshotter).
2. **Guest base image** (#419): a maintained kernel plus a minimal init/guest
   agent. The guest agent applies the OCI config (entrypoint/cmd/env/workdir),
   runs the workload, and reports its exit over vsock. It is written with the
   phase-4 snapshot lifecycle (drain, re-listen, re-identify) in mind from the
   start.
3. **vsock** (#420): SwiftFirecracker grows vsock device support for
   host↔guest control.
4. **`SandboxRuntimeService`** (#421): the driver that wires it together on
   the existing Firecracker machinery, registered in the agent's driver
   registry and manifest like any other backend, including orphan adoption
   after agent restarts. The reconciler and manifest are generalized over
   workload kinds first (#417, landed): the diff engine, generation guard,
   attempt cap, and per-workload serial lanes are shared across kinds — VM
   items route to hypervisor drivers, sandbox items to the
   `SandboxRuntimeService` seam (which stays nil, and the capability off,
   until #421 ships the driver) — and manifest entries carry a workload kind
   so sandbox orphans survive restarts with their resources reserved.

## Later phases

- **Phase 2**: exec/attach and stdio logs over vsock (#423); TTL/auto-expiry
  (#424).
- **Phase 3**: jailer hardening (#425).
- **Phase 4**: snapshot/checkpoint primitives and resume (#426), fork into new
  sandboxes (#427), and snapshot mobility — off-node export, cross-agent
  restore, diff snapshots (#428). Cross-agent restore is why the CPU-template
  decision is forced at sandbox create time.

## Non-goals (v1)

- Layer-level dedup or a snapshotter — flattened-image cache only.
- Warm pools / pre-booted guests (phase 4 explores snapshot warm start first).
- Volumes, disk hot-plug, or live migration for sandboxes.
- macOS agents — Firecracker is Linux/KVM-only; capability gating keeps them
  out of placement.
