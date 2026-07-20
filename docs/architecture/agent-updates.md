# Agent Updates

Strato updates hypervisor agents from the control plane over the existing
agent WebSocket — no SSH, no configuration management run. There are two
paths that share one installation mechanism:

- **Operator-triggered** (issue #432): `POST /api/agents/:id/actions/update`
  updates one agent now, synchronously reporting the agent's own outcome.
- **Declarative auto-update** (issue #434): enrolled agents converge on the
  version the control plane says they should be running, advanced across the
  fleet one agent at a time with health gating.

Both end the same way: the agent downloads the artifact, verifies its
SHA-256, atomically swaps its own binary (preserving the old one as
`<binary>.prev`), exits with a restart code for its supervisor, and proves
the update by re-registering with the new build's version.

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
  `AgentUpdateArtifacts` resolves the manifest at dispatch/assembly time;
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
which the new agent process re-adopts. The imperative endpoint's `force`
acknowledgement for Firecracker workloads predates re-adoption and remains
as a conservative operator confirmation.

## Operator-triggered updates

`POST /api/agents/:id/actions/update` (permission: `agent#manage`):

- Refuses offline agents, agents on a pre-v6 wire protocol (they cannot even
  decode the command), and — without `force` — agents hosting Firecracker
  VMs or sandboxes, or already at the target.
- Resolves the artifact for the agent's reported OS/arch and dispatches an
  `AgentUpdateMessage`; the agent replies only after the swap, so the HTTP
  response reports the real outcome. System admins may override the artifact
  (`artifactUrl` + `sha256`) for air-gapped or one-off builds; delegated
  admins may not — an explicit artifact is arbitrary code on the host.

## Declarative auto-update

The declarative path makes the control plane's target version part of desired
state, converged like everything else — level-triggered, idempotent, safe to
drop or replay.

### Opt-in

Auto-update is per-agent and default-off: `PATCH /api/agents/:id` with
`{"autoUpdate": true}` (permission: `agent#manage`), or the toggle on the
agent detail page. Withdrawing clears any in-flight assignment.

### Fleet rollout (control plane)

A cluster-singleton sweep (`lock:sweep:agent_auto_update`, same Valkey
pattern as the stuck-operation sweep) advances the rollout each heartbeat
tick. All rollout state lives on the agent rows, so any replica can continue
where another stopped:

- The sweep assigns the target version to **one agent at a time**
  (deterministic name order), only to enrolled, online, wire-v7+ agents whose
  platform artifact actually resolves.
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
    probe, or swap), or went silent past the health budget. The rollout
    **halts** — no further agents are assigned — until an operator
    intervenes (re-enable auto-update on the failed agent to retry, update
    it manually) or the target version moves on, which resets stale
    assignments and failures.

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

### Wire protocol

Version 7 adds both fields, additively and backward-tolerantly:
`DesiredStateMessage.desiredAgentUpdate` (nil = "no opinion", never
"downgrade") and `ObservedStateReport.agentUpdateStatus`. The gate matters on
the control-plane side: a pre-v7 agent ignores the field, so the rollout
never assigns to one — it would burn its health budget against silence.

### Rollback

v1 is deliberately halt-and-recover: a failed update stops the rollout, the
previous binary stays at `<binary>.prev` for manual recovery, and nothing
downgrades automatically. Automated downgrade-on-crash-loop needs an on-host
supervisor helper and is out of scope until halting proves insufficient.

## Observability

- `strato_agent_auto_update_assignments_total`,
  `..._converged_total`, `..._failures_total{reason}` (`agent_reported` |
  `health_budget`), `..._parked_total`.
- Version transitions log at `notice` on registration ("Agent re-registered
  with a new version") and on every rollout state change; blocked reasons
  and failures surface on `AgentResponse`
  (`updateBlockedReason`/`updateFailureReason`) and in the UI.
