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
satisfies one invariant: flushing the store degrades to slower convergence, never
to incorrect state. Presence keys are rewritten by the next heartbeat, sweep
locks gate work that is idempotent, and losing a reservation reopens a race
rather than corrupting anything.

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

## Desired state: pull plus a broadcast doorbell

Desired state is **fetched by the agent**, not pushed to it (ADR 0001 stage 10,
STR-146). The agent long-polls `GET /agent/desired-state` on the Envoy SVID-mTLS
listener; whichever replica the load balancer picks assembles the sync from
PostgreSQL and serves it. There is no routing directory in this path at all —
which replica an agent's socket happens to be on is simply not a question the
mutation path has to answer.

- **On mutation** the serving replica writes desired state to PostgreSQL, acts
  on it locally (waking a poll parked here, pushing over a locally held socket
  if the agent is still push-mode), and publishes the agent's key on the one
  `agent:doorbell` channel. Every replica evaluates that broadcast against its
  own parked polls and sockets; at most one can act, and the rest no-op. The
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

Live byte streams — console, exec, log forwarding — do stay imperative by
design (ADR 0001: session lifetime is a browser tab, not cluster intent), but
they are **not** correlated request/response and never travelled this path:
`ConsoleSessionManager` and `SandboxExecSessionManager` write straight to the
local socket and fail if this replica does not hold it, which is the
single-replica limitation `docs/architecture/sandboxes.md` records.

v34 left the forwarding path with no sender at all, and STR-152 (ADR stage 11)
deleted it: `AgentService.sendMessageToAgentWithResponse` and the
pending-request continuations behind it, `ReplicaMessageBridge.call` and the
`replica:{id}:rpc` / `rpc-replies` channels, and the `agent:{name}:replica`
routing key that told a requester where to forward. The `success`/`error`
frames survive, but only as uncorrelated control-plane → agent
acknowledgements: nothing awaits a `requestId` on either side.

What that buys is the point of the whole ADR. Every remaining Valkey key and
channel is a latency optimization or a duplicate-work guard, so a coordination
outage now costs convergence latency and nothing else — there is no directory
whose staleness can make a request fail, and no in-memory request state that a
process boundary can lose.

## Failure and deploy behavior

- **Replica crash**: its agents' sockets drop; agents reconnect (existing
  backoff + jitter) to surviving replicas. There is nothing to take over — no
  routing directory survives (STR-152), and presence expires within one TTL
  (60s). The registration-triggered sync converges any drift; until reconnect
  the agent is effectively offline, and in-flight mutations settle via
  reconciliation or the stuck-convergence sweep. One cosmetic edge: a socket
  close delivered after the agent has already reconnected elsewhere marks it
  `offline` in the database until the holding replica's next heartbeat, since
  the guard that used to consult the routing key is gone.
- **Rolling deploy**: same as a crash, one replica at a time. In-flight
  mutations are not lost — the desired state and its convergence deadline live
  in PostgreSQL, and they settle from observed-state reports (or are degraded
  by the sweep and surfaced to the client, never silently dropped).
- **Coordination-store outage**: coordination fails open (issue #258 policy).
  Pull-mode agents keep converging on their own unconditional re-fetch (the
  poll endpoint needs only PostgreSQL), and push-mode agents via their
  socket-holding replica's periodic sync; desired-state doorbells are
  unavailable until Valkey returns, so convergence falls back to the agent's own
  poll interval. `/health/ready` reports `coordination: degraded` and keeps
  serving traffic.
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

Version ≥ 29 additionally enables the desired-state pull transport. It is a
floor, not a requirement: a pre-v29 agent registers normally and keeps being
pushed to, and a v29 agent against a pre-v29 control plane never starts polling.

## Scaling

Set `replicaCount` in the Helm chart (`helm/strato-control-plane/values.yaml`).
Valkey and PostgreSQL are required regardless of replica count. Console
sessions are pinned to the replica that accepted the frontend's WebSocket and
the agent socket; with multiple replicas, console connections work when both
sockets land on the same replica (client retry re-resolves through the
service), which is a known limitation tracked separately.
