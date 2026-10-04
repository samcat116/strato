# Agent Updates

Strato updates hypervisor agents from the control plane — no SSH, no
configuration management run. An agent's build is desired state like anything
else: the control plane records which version an agent should run, the version
rides that matching-version agent's desired-state sync as `desiredAgentUpdate`, and the agent
converges on it. There are two ways a version gets assigned:

- **Fleet auto-update** (issue #434): enrolled agents are advanced to the
  deployment's target version one agent at a time, with health gating.
- **Operator-triggered** (issue #432): `POST /api/agents/:id/actions/update`
  assigns one agent now, enrolled or not.

Both write the same field, so they share every mechanism below — the
convergence preconditions, the health budget, the reported blocked/failure
reasons, and the one-agent-at-a-time property (an in-flight manual update holds
the fleet rollout, and vice versa). The end is always the same: the agent
downloads the artifact, verifies its SHA-256, atomically swaps its own binary
(preserving the old one as `<binary>.prev`), exits with a restart code for its
supervisor, and proves the update by re-registering with the new build's
version.

Until wire v28 the operator path was a separate imperative `agent_update`
message answered synchronously over the socket. It is gone (ADR 0001 stage 6):
one path, one set of preconditions, and an intent that survives a disconnected
agent or a restarted control plane instead of dying with the request.

## Version identity and artifacts

- Agents report their build version at registration
  (`AgentRegisterMessage.version`, baked into release binaries; issue #430).
- The **target version** is the control plane's own build version, or the
  `AGENT_TARGET_VERSION` override. Comparison is canonical: `v1.2.3`,
  `1.2.3`, and `main`/`main-<sha>` aliases collapse before comparing, so a
  same-artifact deployment never flags a false update. A `dev` build has no
  meaningful target and never triggers updates.
- Each release publishes an `agent-manifest.json` (issue #431) mapping
  OS/arch to a tarball URL, SHA-256, and the member holding the agent binary.
  `AgentUpdateArtifacts` resolves the manifest at assignment and sync-assembly
  time;
  releases predating the manifest fall back to the
  `strato-<os>-<arch>.tar.gz` + `.sha256` sidecar convention.
  `AGENT_UPDATE_ARTIFACT_BASE_URL` points both at a mirror for air-gapped
  deployments.

## The update mechanism (agent side)

`AgentUpdater` (in `StratoAgentCore`) performs the swap:

1. Refuse when containerized (`AgentInstallMode.detect`: the
   `STRATO_INSTALL_MODE` marker or standard container fingerprints) — a
   container's binary is an immutable image layer; updates ship as new
   images.
2. Download into a hidden workspace next to the running binary (same
   filesystem, so the final `rename(2)` is atomic).
3. Verify the artifact's SHA-256 before touching anything.
4. Extract (tarball) or use directly (bare binary), `chmod 0755`, and probe
   the staged binary (`--version` must exit 0).
5. Hard-link the current binary to `<binary>.prev`, then atomically rename
   the staged binary into place.
6. The caller stops the agent cleanly and exits with code 75
   (`EX_TEMPFAIL`); the systemd unit that `install.sh` writes uses
   `Restart=on-failure`, so the supervisor starts the new build.

Any failure before the final rename leaves the running binary untouched.

Running VMs survive the restart: QEMU VMs expose a deterministic per-VM QMP
socket and Firecracker VMs a deterministic API socket (issue #433), both of
which the new agent process re-adopts. Sandboxes do not yet, which is the one
caveat the update endpoint asks an operator to acknowledge with `force`.

## Operator-triggered updates

`POST /api/agents/:id/actions/update` (permission: `agent#manage`) assigns the
update and returns **202** — the assignment is the update, and it is durable on
the agent row. Progress is on the agent resource: `updateDesiredVersion` clears
on convergence, `updateBlockedReason` carries the agent's reason for waiting,
`updateFailureReason` a terminal failure.

- Refuses offline agents, agents on a pre-v7 wire protocol (they decode the
  sync but ignore `desiredAgentUpdate`, so the assignment would converge on
  nothing), agents that have not reported their OS/architecture, and — without
  `force` — agents hosting sandboxes, whose runtime does not yet re-adopt them
  after a restart. Hosted VMs need no acknowledgement: QEMU and Firecracker
  VMs alike are re-adopted (issue #433).
- Refuses an agent **already at the target**, and `force` does not waive it:
  an update converges on a version, so an agent already running it has nothing
  to do. Reinstalling the same build would need an edge-as-nonce the protocol
  does not carry (ADR 0001 stage 9); until then, reinstalling means pointing
  the agent at a different version.
- Needs no auto-update enrollment, and does not create one. Withdrawing an
  agent from auto-update clears the *rollout's* assignment, never an
  operator's.
- Is cancellable: `DELETE /api/agents/:id/actions/update` (or **Cancel** on the
  agent's auto-update card) drops the assignment, the pinned artifact, the
  budget clock, and any recorded failure. Deliberately not gated on the agent
  being online, unlike assigning — an update that can never converge is usually
  one whose agent is gone, and re-issuing it would be refused for exactly that
  reason. Without this an assignment had no withdrawal path at all: it never
  converges, and it is exempt from the rollout's stale reset by design.
- System admins may override the artifact (`artifactUrl` + `sha256`) for
  air-gapped or one-off builds; delegated admins may not — an explicit
  artifact is arbitrary code on the host. An override is pinned to the agent
  row (there is no release to re-resolve it from), and its `targetVersion`
  label is load-bearing rather than informational: convergence is "the agent
  re-registered at this version", so a label the artifact's binary does not
  report leaves the update stuck until the health budget records it failed.

## Fleet auto-update

Desired state is converged like everything else — level-triggered, idempotent,
safe to drop or replay. What the fleet rollout adds on top is *which* enrolled
agent gets assigned next, and when.

### Opt-in

Auto-update is per-agent and default-off: `PATCH /api/agents/:id` with
`{"autoUpdate": true}` (permission: `agent#manage`), or the toggle on the
agent detail page. Withdrawing clears an in-flight rollout assignment — but not
an operator's own, which never needed enrollment.

### Fleet rollout (control plane)

A cluster-singleton sweep (`lock:sweep:agent_auto_update`, same Valkey
pattern as the other background sweeps) advances the rollout each heartbeat
tick. All rollout state lives on the agent rows, so any replica can continue
where another stopped:

- The sweep assigns the target version to **one agent at a time**
  (deterministic name order), only to enrolled, online, wire-v7+ agents whose
  platform artifact actually resolves. An agent already carrying an assignment
  — including one an operator made by hand — counts as in flight, so only one
  agent in the fleet is ever restarting.
- The assignment (`update_desired_version`) rides the agent's periodic
  desired-state sync as `desiredAgentUpdate`, with the artifact URL and
  checksum re-resolved on every assembly so a long-desired update never
  carries a stale link.
- The next agent is assigned only after the previous one **re-registers at
  the target version**. Outcomes per assigned agent:
  - **Converged** — re-registered at the target (or updated by hand):
    assignment cleared, rollout advances.
  - **Blocked** — the agent reports why it will not act yet (see
    preconditions below). Past the health budget (10 minutes) the agent is
    *parked*: its assignment stays, so it converges whenever the blocker
    clears, but the rollout stops waiting on it.
  - **Failed** — the agent reported a terminal failure (download, checksum,
    probe, or swap), or went silent past the health budget. A *rollout*
    failure **halts** the fleet — no further agents are assigned — until an
    operator intervenes (re-enable auto-update on the failed agent to retry,
    which also restarts its budget clock; re-issue the update, which
    overwrites the assignment with a fresh artifact; or cancel it) or the
    target version moves on, which resets stale rollout assignments and
    failures.

    A *manual* failure does not halt the fleet. One operator action on one
    agent — possibly not even an enrolled one — must not stop every other
    agent's auto-update, and a manual assignment's own escapes are precisely
    what a terminal failure closes: it never converges, and it is never reset
    as stale (the deployment target has no opinion about a version an operator
    chose). Cancelling is what clears it.

    Either way the failure drops the pinned artifact, so a presigned
    credential does not outlive the update that needed it; re-issuing supplies
    a fresh one.

### Convergence preconditions (agent)

On each sync carrying a `desiredAgentUpdate`, the agent evaluates
(`AutoUpdateGate`), in order:

1. **Not containerized** — permanent for the install; reported so the
   operator can un-enroll the agent.
2. **No in-flight reconcile work** — the update runs as its own step once
   the per-VM lanes have drained; a busy agent waits for a later sync.

Running VMs are deliberately not a precondition: QEMU and Firecracker VMs
alike are re-adopted after the restart (issue #433), so hosting live
workloads is exactly the situation auto-update must work in.

A blocked agent reports the current reason on its observed-state reports
(`agentUpdateStatus`) and re-evaluates every sync. A failed artifact is
attempted only once per process lifetime — retrying on every sync would loop
downloads (or restart-loop on an artifact whose binary reports the wrong
version) — and the failure is pushed immediately so the rollout halts on the
real error rather than a timeout.

### Stable bridge exchange (STR-340)

The bridge release implements `GET /agent/update/v1` on both peers. Its frozen
JSON contains `exchangeVersion: 1`, the control plane's `workloadWireVersion`,
and an optional artifact (`targetVersion`, `artifactURL`, `sha256`,
`artifactKind` as `binary`/`tarball`, optional `tarballMember`). It has no
workload envelopes, resources, or newly issued credentials. It does not create a
workload registration session. The existing authenticator may persist the
principal mapping for an already enrolled identity in the workload registry.
Changes to the workload contract must preserve this v1 exchange; incompatible
changes to the exchange require another path and another staged bridge release.

The route uses the existing SVID mTLS identity, trust-domain mapping, workload
registry, and administrative revocation checks. It looks up the authenticated
agent's existing assignment and reuses artifact resolution. It never assigns an
update, enrolls an agent, or makes a disconnected agent eligible for a manual
update. With no assignment it returns no artifact. Authentication errors and
malformed exchanges fail closed. A missing route (404) on a prebridge control
plane falls back only to the ordinary exact-version registration handshake.

The agent authenticates the server's exact configured control-plane SPIFFE ID
with the same chain-and-identity verifier as its WebSocket. Each probe derives
client credentials and peer-domain roots (including federation) from one fresh
SVID snapshot. The bridge requires HTTPS, does not follow redirects, bounds the
body to 64 KiB and the whole request to 15 seconds, and closes the connection on
completion, cancellation or failure. An unverified 404 cannot enable fallback.

Before registration the bridge agent probes this route. A failed probe during
network capability refresh leaves the existing exact-version session and its
poller active; explicit skew stops polling before an update is applied.
Matching workload versions retain ordinary registration, desired-state updates, and status
reports. Under skew, it stops workload polling, refuses to send a workload
registration DTO or update status report, and applies only the staged artifact
through `AgentUpdater`, including SHA-256 verification and the existing local
restart gates. Every bridge desired-state poll also advertises
`Strato-Workload-Wire-Version`; mismatches return 409 before workload assembly,
including polls that survive a control-plane cutover. Legacy clients retain the
registration-only contract while versions match; they are not supported across
wire cutover. No general workload DTO compatibility window is introduced.

#### Upgrade order and bootstrap limit

1. While workload versions still match, install the paired bridge release on
   the control plane first, then every agent. A prebridge control plane may
   default-deny the unknown v1 route with 403; that denial never falls back. Existing matching agents can receive the
   bridge artifact through ordinary updates. If they cannot use that path,
   install the verified bridge artifact out of band. Confirm all nodes actually
   run a bridge-capable binary before crossing a workload-version boundary.
2. Resolve and explicitly assign the intended next release to the agents while
   they are still online and matching. Keep the existing authorization and
   sandbox `force` acknowledgement. For a next-release artifact before the
   deployment target changes, use the existing explicit override fields
   (`artifactUrl`, `sha256`, `targetVersion`, `artifactKind`, `tarballMember`)
   with the existing `agent:updateArtifact` authorization; do not grant new
   permissions to perform staging. Assignment may immediately start the
   upgrade; a bridge-capable newer agent can wait in update-only mode against
   the older control plane. The target release must also preserve v1. Do not
   rely on the fleet sweep to assign updates to already disconnected agents.
3. Replace the control plane with the corresponding target release. Any
   still-old bridge agents obtain their already staged assignment via v1;
   already-updated agents register when workload equality is restored. Perform
   the cutover within the existing assignment health budget; this exchange
   does not redesign fleet health gating or restart policy.
4. Verify each agent re-registers at the target before ordinary workload
   reconciliation resumes. A skewed node logs its required update-only mode;
   the server logs its identity, both wire versions, and whether an artifact
   assignment is available. No assignment, failed verification, or a blocked
   restart requires operator intervention; logs do not claim convergence.

Already deployed binaries that lack v1 do not learn it from a server change.
They must first receive the bridge while matching, or require explicit
out-of-band installation. Containerized agents require replacement images.

#### Rollback order

Keep a verified previous bridge-capable artifact or `<binary>.prev`. While the
current peers still match, explicitly assign the rollback artifact before
replacing the control plane with the corresponding older bridge-capable
release. Either side can then wait in update-only mode until equality returns.
A disconnected node with no assignment, or a rollback to a prebridge binary,
requires out-of-band installation. Automatic downgrade is not introduced, and
schema rollback safety remains a separate deployment requirement.

### Historical workload wire fields

Version 7 adds both fields, additively and backward-tolerantly:
`DesiredStateMessage.desiredAgentUpdate` (nil = "no opinion", never
"downgrade") and `ObservedStateReport.agentUpdateStatus`. The gate matters on
the control-plane side: a pre-v7 agent ignores the field, so neither the
rollout nor the update endpoint assigns to one — it would burn its health
budget against silence.

Version 28 removed the imperative `agent_update` message, leaving these fields
as the only workload-channel update path. A control plane at v28 never sends the old message to
any agent; the only skew that regresses is an *older* control plane driving a
v28 agent, whose manual update would time out against an envelope the agent no
longer decodes. Use the staged bridge procedure above for subsequent wire transitions.

### Rollback

v1 is deliberately halt-and-recover: a failed update stops the rollout, the
previous binary stays at `<binary>.prev` for manual recovery, and nothing
downgrades automatically. Automated downgrade-on-crash-loop needs an on-host
supervisor helper and is out of scope until halting proves insufficient.

## Observability

- `strato_agent_auto_update_assignments_total`,
  `..._converged_total`, `..._failures_total{reason}` (`agent_reported` |
  `health_budget`), `..._parked_total`. `assignments_total` counts what the
  fleet rollout assigned; the rest are recorded by the sweep, which since
  STR-145 classifies operator-assigned updates too, so they cover both.
- Version transitions log at `notice` on registration ("Agent re-registered
  with a new version") and on every rollout state change; blocked reasons
  and failures surface on `AgentResponse`
  (`updateBlockedReason`/`updateFailureReason`) and in the UI, for
  operator-assigned updates as much as rollout ones —
  `updateAssignmentSource` says which.
