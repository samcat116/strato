# Health Checks and Controlled Deploys

The control plane exposes three unauthenticated endpoints under `/health`. They
are the contract a load balancer, `readinessProbe`, or deployment cutover script
depends on, so it is worth being precise about what each one promises.

## The endpoints

| Endpoint | Touches dependencies? | Use it for |
| --- | --- | --- |
| `GET /health` | No | Human/scripted "who is answering?" — returns build identity |
| `GET /health/live` | No | Liveness probes: is the process wedged? |
| `GET /health/ready` | Yes | Routing decisions: should this replica receive traffic? |

All three return the same JSON shape, but not the same checks: `/health`
and `/health/live` touch no dependency, so their `checks` array carries only
the application check (`{ "name": "application", "status": "up" }`); only
`/health/ready` includes the dependency checks shown here:

```json
{
  "status": "healthy",
  "timestamp": "2026-07-20T18:22:04Z",
  "checks": [
    { "name": "database",      "status": "up" },
    { "name": "migrations",    "status": "up" },
    { "name": "coordination",  "status": "up" },
    { "name": "session-store", "status": "up" }
  ],
  "identity": {
    "instanceId": "6F2C…",
    "startedAt": "2026-07-20T18:19:51Z",
    "version": "v0.14.2",
    "gitSHA": "9f46417…",
    "environment": "production"
  }
}
```

`identity.instanceId` is regenerated on every process boot. Two replicas — or a
stale duplicate that has quietly claimed the port — are distinguishable by it.

## Readiness semantics

`/health/ready` answers with the **HTTP status**, not just the body. Anything
routing traffic reads the code:

| Code | `status` | Meaning |
| --- | --- | --- |
| 200 | `healthy` | Every dependency reachable |
| 200 | `degraded` | A fail-open dependency is down; still serving |
| 503 | `unhealthy` | A required dependency is unreachable |
| 503 | `draining` | Shutdown requested; finishing in-flight work |

Checks are graded, because the dependencies are not equally fatal:

- **database** — fatal. Nothing works without Postgres. Probed with `SELECT 1`,
  not a row count, so a fleet-sized table does not turn every probe interval into
  a sequential scan.
- **migrations** — fatal. A reachable database says nothing about whether this
  process finished applying schema to it. (Authorization needs no check of its
  own: the Cedar evaluator is in-process and reads its data from the same
  Postgres the **database** check covers.)
- **coordination** — **degraded only**. The coordination store is deliberately
  fail-open (see [multi-replica](../architecture/multi-replica.md)); agents still
  converge via their unconditional desired-state refetch. Pulling every replica
  out of rotation because it blipped would be a worse outage than the blip.
- **session-store** — **fatal when session storage has its own endpoint,
  `degraded` when it shares the coordination one**. The grade follows whether the
  failure can be replica-local, because that is the only case where pulling this
  replica helps. A separate session Valkey can fail while this replica is
  otherwise healthy, and a replica that cannot read sessions cannot authenticate
  a browser — so 503 lets the load balancer send that traffic to one that can.
  A *shared* endpoint fails for every replica at once, so 503 everywhere shifts
  traffic nowhere and merely drops the traffic sessions do not back: agents
  authenticate by SPIFFE/SPIRE mTLS, API-key and CLI clients by key, and the
  reconciler needs only Postgres to converge. Absent from the payload when
  sessions are not Valkey-backed (the test environment uses Fluent sessions).

::: tip Both stores are one instance by default
Unless you set `SESSION_VALKEY_HOST`, sessions share the coordination Valkey, and
a blip there reports `degraded` at 200 — the same behavior as before the two
stores were separable. Giving sessions their own endpoint (see
[docker-compose](./docker-compose.md#splitting-session-storage)) is what makes
the fatal grade meaningful, because only then can session storage fail without
the coordination store failing too.
:::

### Liveness never follows readiness

`/health/live` stays 200 through a dependency outage and through a drain. This is
deliberate. If liveness probed Postgres, a database blip would restart every
replica simultaneously — turning a recoverable outage into a thundering-herd
cold start, and killing exactly the in-flight work a drain exists to protect.

Readiness pulls a replica from rotation. Liveness kills it. Those should not be
triggered by the same conditions.

## Graceful shutdown

On `SIGTERM` the control plane flips to `draining` immediately: `/health/ready`
starts returning 503 before the process stops accepting connections, so a load
balancer still polling gets a definitive answer instead of a connection reset.

The process cannot delay its own shutdown once Vapor has begun it, so the drain
*window* is the orchestrator's job.

### Kubernetes

The Helm chart wires this up by default:

```yaml
startupProbe:
  enabled: true
  path: /health/live        # dependency-free; boot time is what it bounds
  periodSeconds: 5
  # Keep this budget above the migration lock timeout (4 minutes by default)
  # so the named timeout reaches logs before kubelet restarts the process.
  failureThreshold: 60      # allow 5 minutes for migrations on boot

terminationDrain:
  enabled: true
  seconds: 15               # preStop delay before SIGTERM

terminationGracePeriodSeconds: 60
```

The control-plane Deployment uses `Recreate`, not `RollingUpdate`. This is a
correctness boundary for STR-275: the legacy one-argument advisory locks and the
current two-argument locks occupy disjoint PostgreSQL keyspaces, so replicas on
opposite sides of that change cannot safely serve together. Kubernetes drains
and terminates every old pod before creating the new set. The probes and drain
window still protect in-flight work, but a chart upgrade has a brief period with
no serving control-plane pod.

Endpoint removal and `SIGTERM` are delivered concurrently, and endpoint removal
is asynchronous — kube-proxy, the ingress, and any external load balancer learn
about it at their own pace. The `preStop` sleep holds `SIGTERM` back until that
propagation has happened; without it the process can stop accepting connections
while callers are still being routed to it, which surfaces as connection-refused
errors on every deploy.

Raise `terminationDrain.seconds` above your ingress's endpoint-refresh interval,
and keep `terminationGracePeriodSeconds` comfortably above
`terminationDrain.seconds` plus your longest in-flight request.

While a `startupProbe` is pending, Kubernetes suspends the liveness and readiness
probes — so `startupProbe.periodSeconds × failureThreshold` is what actually
bounds a slow boot, not `livenessProbe.initialDelaySeconds`.

### Docker Compose

The `control-plane` service ships a `healthcheck` that polls `/health/ready`
(with a 120s `start_period` covering migrations) and a `stop_grace_period` of
60s, replacing Docker's 10s default so a drain is not `SIGKILL`ed halfway
through.

## Blue/green cutover

::: warning Advisory-lock keyspace cutover
Do not use blue/green overlap when moving from a build before STR-275 to a build
that contains it. Stop every old control-plane process sharing the database,
wait for its database sessions to close, and only then start green. Moving
traffic away from blue or marking it unready is insufficient: an old process can
still run background work or receive an existing agent connection. The Helm
chart enforces this boundary for its own Deployment with `Recreate`; separately
managed Deployments, releases, and one-off containers are the operator's
responsibility.
:::

Between builds that use the same advisory-lock keyspace, an independently
managed blue/green deployment can use this sequence:

1. Bring up the green replicas. They bind their port only after migrations and
   boot-time backfills finish, and report `healthy` once every required
   dependency answers.
2. Wait for `GET /health/ready` → 200 on every green replica. Confirm
   `identity.gitSHA` matches the build you intended to ship — this is the check
   that catches a cutover to a stale image.
3. Shift traffic.
4. `SIGTERM` the blue replicas. Each reports `draining`/503 at once, the load
   balancer drops it, and in-flight requests and agent WebSockets finish inside
   the grace period.

Agents reconnect on their own and converge through the periodic
`DesiredStateMessage` sync, so an agent WebSocket cut mid-cutover costs a
reconnect, not correctness.

::: warning Migrations must be backward-compatible
Blue and green run against the same database. A migration that green applies at
boot is immediately visible to still-running blue replicas, so any schema change
deployed this way has to be readable by the previous version — add columns before
you use them, and drop them a release after the last reader is gone.
:::
