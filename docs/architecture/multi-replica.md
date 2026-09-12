# Multi-Replica Control Plane

The control plane supports running multiple replicas (issue #261, phase 3 of
the reconciliation architecture — see the tracking issue #262). This document
describes how state and agent connectivity are shared across replicas, and
what happens during deploys and failures.

## State ownership

| State | Where it lives | Notes |
|---|---|---|
| Desired + observed VM state, mutation trail | PostgreSQL | The only durable truth (issues #259, #260) |
| Agent registry (resources, status, heartbeat age) | PostgreSQL (`agents` table) | Written by whichever replica hears from the agent |
| Agent liveness | Valkey `agent:{name}:presence` (TTL 60s) | Refreshed on every heartbeat |
| Desired-state doorbell | Valkey pub/sub `agent:doorbell` | A single fleet-wide broadcast, not `replica:{id}:`-scoped. Latency optimization only (STR-146) |
| Policy-set change broadcast | Valkey pub/sub `policy-set:version` | A broadcast, not `replica:{id}:`-scoped — every replica refreshes its compiled Cedar policy set; backstopped by a 30s periodic re-read |
| Placement reservations, sweep locks | Valkey (`resv:*`, `lock:sweep:*`) | Phase 0 (issue #258) |

The stuck-**convergence** sweep is deliberately absent from that table
(STR-147). Marking a resource degraded past its deadline is idempotent and
convergent, so every replica runs it lock-free; the one non-idempotent effect —
the completion webhook — is claimed by a conditional `UPDATE` on the deadline
column rather than by a cluster singleton. The stuck-*operation* sweep it
replaced, and the `lock:sweep:stuck_operations` singleton it needed because its
verdict was a state transition two writers could disagree about, went with the
operations table in STR-152.
| Image download grants | Valkey `imggrant:agent:{agentId}:image:{imageId}` (TTL 30m) | Written by the replica that emits the download URLs; read by whichever replica serves the fetch (issue #562) |
| Browser sessions | Valkey `vrs-{sessionID}` (idle TTL, `SESSION_TTL_SECONDS`) | **Not** coordination state — a separate store with the opposite failure contract (below) |

Everything above the session row is coordination state, and every key in it
satisfies one invariant: flushing the store cannot make durable state or a
hypervisor's physical capacity incorrect. Presence keys are rewritten by the
next heartbeat, sweep locks gate idempotent work, and losing a placement
reservation can at worst send a create to a node that filled after selection.
That node refuses the create; its admission ledger, not Valkey, prevents host
overcommit.

Sessions satisfy nothing of the sort — losing them logs every signed-in user out
at once, and passkeys are the only interactive authentication. So the two stores
are **separately configurable** (issue #855): coordination uses `VALKEY_*`,
sessions use `SESSION_VALKEY_*` and fall back to the coordination endpoint when
unset. One instance by default; two clients whenever the endpoints differ. Until
an operator splits them, a coordination-store problem still logs everyone out —
that is the coupling the split exists to let you remove.

The cross-replica seam is `ReplicaMessageBridge` (`app.replicaBridge`): it owns
the desired-state doorbell and the subscription lifecycle — composing
`CoordinationService` (the Valkey / in-memory `CoordinationStore` adapters) and
delegating the one operation that needs local state (acting on a doorbell) back
to `AgentService` through a narrow `ReplicaBridgeDelegate`. It used to own two
more things, socket-route recording and correlated RPC forwarding, and both went
with the exchanges that read them (STR-152). `AgentService` keeps only
per-connection socket bookkeeping (the socket map and per-agent report
ordering); it holds no cross-request in-memory state. Any replica can serve any
HTTP request.

## Cluster time

PostgreSQL is also the source of truth for durable time. Each 30-second
maintenance pass reads `clock_timestamp()` once and threads that `ClusterInstant` through
heartbeat staleness, convergence, retention, finalizer, command, and rollout
decisions. Accepting transactions use the same database clock when they stamp
deadlines, sampling it after admission and row locks so lock waits do not spend
the resulting convergence budget. A replica-local `Date()` is not a valid clock
for durable state.

The maintenance read also measures PostgreSQL-minus-replica wall-clock offset.
`control_plane_clock_offset_seconds` exports the signed value per process; the
control plane warns beyond 1 second and declines sandbox expiry, snapshot
retention, and orphaned-resource reaping beyond 30 seconds. The predicates
already use database time, so the 30-second fence is a fail-closed backstop,
not the primary correctness mechanism.

Hosts and Kubernetes nodes that run control-plane replicas must therefore have
working time synchronization. Some request-path credential checks (API keys,
SCIM tokens, OAuth device codes, role bindings, and WebAuthn challenges) avoid
a database clock round trip and compare against the local clock. Keep every
replica within the 1-second warning tolerance and alert on the offset gauge.

## Desired state: pull plus a broadcast doorbell

Desired state is **fetched by the agent**, not pushed to it (ADR 0001 stage 10,
STR-146). The agent long-polls `GET /agent/desired-state` on the Envoy SVID-mTLS
listener; whichever replica the load balancer picks assembles the sync from
PostgreSQL and serves it. There is no routing directory in this path at all —
which replica an agent's socket happens to be on is simply not a question the
mutation path has to answer.

- **On mutation** the serving replica writes desired state to PostgreSQL, acts
  on it locally (waking a poll parked here), and publishes the agent's key on the one
  `agent:doorbell` channel. Every replica evaluates that broadcast against its
  own parked polls; at most one can act, and the rest no-op. The
  payload carries the publisher's replica id so a replica ignores its own echo.
- **Fleet-wide mutations** (security groups, networks, site topology, floating
  IPs) ring the wildcard key `*` rather than enumerating the fleet. Before
  STR-146 these reached only the agents socketed to the calling replica, so in
  a multi-replica deployment the rest waited out the forced periodic pass.
- **Parked polls answer `304`** when nothing changed, validated by an ETag that
  is a **SHA-256 digest of the assembled payload** — not a per-replica counter.
  A counter would either collide across replicas (a wrong `304`, stranding the
  agent) or miss on every cross-replica poll (a full payload every time, so the
  agent re-polls immediately and the fleet spins). A digest is replica-
  independent and has no missed-bump failure mode.
- **Lost doorbells are safe by design**, and so is a wrong ETag: the agent
  re-fetches **unconditionally** every `desired_state_full_refetch_seconds`
  (default 300), sending no validator at all, and the control plane must answer
  that with a full payload. Doorbells and ETags are latency and bandwidth; the
  unconditional re-fetch is the correctness invariant.

### Side effects stay on the serving replica

Sync assembly is not side-effect free: it records image-download grants
(`imggrant:*`, issue #562) and mints registry credentials. Both stay at
response-assembly time on the replica serving the poll, never cached — which is
why assembled payloads are not cached anywhere, and why a conditional poll
assembles at least once even when it ends in `304`. Recording a grant for a
payload that is then discarded is safe because a grant is purely **additive**
and scoped to the placement the assembly just read; the rejected
cache-the-payload alternative is different in kind, because it would grant
against a *stale* placement and serve stale credentials.

## No remaining imperative exchanges

**No durable-resource exchange is imperative any more.** Volume operations left
this list in STR-148 (wire v31), every snapshot artifact's capture, delete and
export in STR-150 (v33) — including `sandbox_snapshot_export`, which is a
placement fact now rather than a verb — and the last three in STR-151 (v34):
VM reboot, VM restore and sandbox restore.

Those three were the hard ones, because they genuinely are *actions*: a VM that
is `running` before and after has no state delta, and "this VM should be at
checkpoint C" cannot be re-converged on, since the guest starts writing the
moment it resumes. What converted them was not a re-description but a **count**
— `kubectl rollout restart`'s trick of making the edge a state by recording how
many times it was asked for. The agent applies a nonce once, against a record it
keeps in its own durable manifest, so the exchange needs neither a reply nor a
socket.

Live frontend byte streams — console and interactive exec — do stay imperative
by design (ADR 0001: session lifetime is a browser tab, not cluster intent),
but they are **not** correlated request/response and never travelled this path:
`ConsoleSessionManager` and `GuestExecSessionManager` write straight to the
local socket and fail if this replica does not hold it, which is the
single-replica limitation the interactive guest-exec and console surfaces
record. Recorded VM commands are different: the browser does not own their
lifetime, PostgreSQL owns the operation, and the same agent process re-offers a
bounded authoritative result after reconnect until whichever replica holds the
socket durably commits and acknowledges it. A monotonic agent revision and a
payload compare-and-write in PostgreSQL prevent a delayed replica from
overwriting newer recorded state.

STR-152 (ADR stage 11) deleted the operation-specific request/response path:
`AgentService.sendMessageToAgentWithResponse`, its pending continuations, and
`ReplicaMessageBridge.call`. The TTL-bound `agent:{name}:replica` directory
and `replica:{id}:rpc` channel remain for one-way delivery when the API request
lands on a replica other than the one holding the agent socket. Guest exec and
recorded VM commands use that path; desired-state changes do not.

What that buys is the point of the whole ADR. Every remaining Valkey key and
channel is a latency optimization or a duplicate-work guard. A coordination
outage costs convergence latency and may cause an individual create to be
refused when its selected node has filled since the last heartbeat; it cannot
overcommit that node because agent admission is authoritative. There is no
directory whose staleness loses in-memory request state across a process
boundary.

## Failure and deploy behavior

- **Replica crash**: its agents' sockets drop; agents reconnect (existing
  backoff + jitter) to surviving replicas. The old socket route and presence
  entries expire within one TTL
  (60s). The registration-triggered sync converges any drift; until reconnect
  the agent is effectively offline, and in-flight mutations settle via
  reconciliation or the stuck-convergence sweep. One cosmetic edge: a socket
  close delivered after the agent has already reconnected elsewhere marks it
  `offline` in the database until the holding replica's next heartbeat, since
  the guard that used to consult the routing key is gone.
- **Deployment replacement**: the Helm chart uses `Recreate`, so every replica
  drains and stops before the replacement set starts. STR-275 requires that
  process boundary because legacy and current advisory locks occupy disjoint
  PostgreSQL keyspaces. Agents reconnect as they do after a crash. In-flight
  mutations are not lost — desired state and its convergence deadline live in
  PostgreSQL, and they settle from observed-state reports (or are degraded by
  the sweep and surfaced to the client, never silently dropped).
- **Coordination-store outage**: coordination fails open (issue #258 policy).
  Agents keep converging on their own unconditional re-fetch (the poll
  endpoint's Valkey grant bookkeeping is bounded and fail-open). Every
  coordination command has a two-second deadline, so the fail-open path does not
  inherit the client's 30-second command timeout. Desired-state doorbells are
  unavailable until Valkey returns, so convergence falls back to the agent's own
  poll interval. Missing placement reservations can let two replicas select the
  same last-reported capacity; the node admits one and refuses the other rather
  than overcommitting, so that create becomes degraded and can be retried.
  `/health/ready` reports `coordination: degraded` and keeps serving traffic.
- **Session-store outage**: no fail-open path exists for browser auth. Every
  signed-in user is logged out and must re-authenticate with a passkey. Agents
  (SPIFFE mTLS) and API-key/CLI clients are unaffected, and the reconciler needs
  only Postgres. `/health/ready` grades this fatal (503) **only when session
  storage has its own endpoint** — that failure is replica-local, so leaving the
  rotation sends browser auth to a healthy replica. When both stores share one
  instance (the default), every replica fails together and 503 would shift
  traffic nowhere, so it is graded `degraded` instead.
- **Dropped subscription connection**: pub/sub subscriptions live on a
  dedicated connection that the client library does not restore after a drop
  (Valkey restart, failover, network blip) — and a dead subscription is
  silent. Each replica therefore publishes a self-addressed probe on the
  doorbell channel every heartbeat tick (30s) and re-arms the subscription when
  a probe fails to round-trip, bounding the silent window to
  about two ticks. Probes are matched on the publisher's replica id: the
  doorbell channel is fleet-wide, so counting a neighbor's probe would make a
  dead subscription look alive on someone else's traffic.

## Protocol requirements

The imperative VM lifecycle path was removed with phase 3. Agents must speak
wire protocol version ≥ 2 (desired-state sync, agent ≥ the phase-2 release);
older agents are rejected at registration with the terminal
`unsupported_protocol_version` code so their operators know to upgrade.

The current control plane requires an exact wire-version match at registration,
so every accepted agent uses the desired-state pull transport. Mixed-version
fleet transition behavior is not part of the live protocol.

## Scaling

Set `replicaCount` in the Helm chart (`helm/strato-control-plane/values.yaml`).
Valkey and PostgreSQL are required regardless of replica count. Console
sessions are pinned to the replica that accepted the frontend's WebSocket and
the agent socket; with multiple replicas, console connections work when both
sockets land on the same replica (client retry re-resolves through the
service), which is a known limitation tracked separately.
