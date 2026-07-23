# Multi-Replica Control Plane

The control plane supports running multiple replicas (issue #261, phase 3 of
the reconciliation architecture — see the tracking issue #262). This document
describes how state and agent connectivity are shared across replicas, and
what happens during deploys and failures.

## State ownership

| State | Where it lives | Notes |
|---|---|---|
| Desired + observed VM state, operations | PostgreSQL | The only durable truth (issues #259, #260) |
| Agent registry (resources, status, heartbeat age) | PostgreSQL (`agents` table) | Written by whichever replica hears from the agent |
| Agent liveness | Valkey `agent:{name}:presence` (TTL 60s) | Refreshed on every heartbeat |
| Socket routing | Valkey `agent:{name}:replica` (TTL 60s) | Which replica holds the agent's WebSocket |
| Sync nudges | Valkey pub/sub `replica:{id}:nudges` | Latency optimization only |
| Imperative RPC forwarding | Valkey pub/sub `replica:{id}:rpc`, `replica:{id}:rpc-replies` | Volume operations and reboot |
| Placement reservations, sweep locks | Valkey (`resv:*`, `lock:sweep:*`) | Phase 0 (issue #258) |
| Image download grants | Valkey `imggrant:agent:{agentId}:image:{imageId}` (TTL 30m) | Written by the replica that emits the download URLs; read by whichever replica serves the fetch (issue #562) |

The cross-replica seam is `ReplicaMessageBridge` (`app.replicaBridge`): it owns
socket-route recording, the routing decision (local vs. which replica), the
sync-nudge fan-out, the correlated RPC forwarding, and the subscription
lifecycle — composing `CoordinationService` (the Valkey / in-memory
`CoordinationStore` adapters) and delegating the two operations that need the
local socket (running a forwarded exchange, turning a nudge into a local sync)
back to `AgentService` through a narrow `ReplicaBridgeDelegate`. `AgentService`
keeps only per-connection socket bookkeeping (the socket map, request
correlation for in-flight exchanges on those sockets, and per-agent report
ordering); it holds no cross-request in-memory state. Any replica can serve any
HTTP request.

## Socket routing and nudges

Each control-plane process generates a fresh `replicaID` (UUID) at startup, and
its `ReplicaMessageBridge` subscribes to that replica's own nudge and RPC
channels.

- **On WebSocket accept** the accepting replica writes
  `agent:{name}:replica = {replicaID}`. The key is refreshed alongside the
  presence key by every heartbeat and observed-state report, and expires by
  TTL if the replica crashes.
- **On mutation** (VM create/start/stop/pause/resume/delete), the serving
  replica writes desired state to PostgreSQL and then triggers a sync:
  - **Local short-circuit**: if it holds the agent's socket, it assembles the
    sync from PostgreSQL and pushes it directly — Valkey is not involved.
  - Otherwise it looks up the routing key and publishes the agent's name to
    the holding replica's `replica:{id}:nudges` channel; that replica
    assembles the sync from PostgreSQL and pushes it.
- **Lost nudges are safe by design.** The periodic desired-state sync on the
  socket-holding replica (and the sync pushed at agent registration) is the
  correctness backstop; nudges only reduce latency.

## Remaining imperative exchanges

Two kinds of agent exchanges are actions rather than states, so they cannot
ride the level-triggered sync and remain correlated request/response:

- **Volume operations** (create/delete/attach/detach/resize/snapshot/clone)
- **Reboot** (a VM that is `running` before and after has no state delta)

When the serving replica doesn't hold the agent's socket, the exchange is
forwarded to the holding replica over `replica:{id}:rpc` and the verdict comes
back on the requester's `replica:{id}:rpc-replies` channel. Timeouts and
agent errors propagate; an unroutable agent fails fast.

## Failure and deploy behavior

- **Replica crash**: its agents' sockets drop; agents reconnect (existing
  backoff + jitter) to surviving replicas, which take over the routing keys.
  The registration-triggered sync converges any drift. Stale routing keys
  expire within one TTL (60s); until reconnect the agent is effectively
  offline, and in-flight operations complete via reconciliation or the
  stuck-operation sweep.
- **Rolling deploy**: same as a crash, one replica at a time. In-flight
  operations are not lost — they live in PostgreSQL and complete from
  observed-state reports (or are failed by the sweep and surfaced to the
  client, never silently dropped).
- **Valkey outage**: coordination fails open (issue #258 policy). Agents keep
  converging via their socket-holding replica's periodic sync; cross-replica
  nudges and RPC are unavailable until Valkey returns.
- **Dropped subscription connection**: pub/sub subscriptions live on a
  dedicated connection that the client library does not restore after a drop
  (Valkey restart, failover, network blip) — and a dead subscription is
  silent. Each replica therefore publishes a probe to its own nudge channel
  every heartbeat tick (30s) and re-arms all channel subscriptions when a
  probe fails to round-trip, bounding the silent window to about two ticks.

## Protocol requirements

The imperative VM lifecycle path was removed with phase 3. Agents must speak
wire protocol version ≥ 2 (desired-state sync, agent ≥ the phase-2 release);
older agents are rejected at registration with the terminal
`unsupported_protocol_version` code so their operators know to upgrade.

## Scaling

Set `replicaCount` in the Helm chart (`helm/strato-control-plane/values.yaml`).
Valkey and PostgreSQL are required regardless of replica count. Console
sessions are pinned to the replica that accepted the frontend's WebSocket and
the agent socket; with multiple replicas, console connections work when both
sockets land on the same replica (client retry re-resolves through the
service), which is a known limitation tracked separately.
