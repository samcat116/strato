# Health Checks and Zero-Downtime Deploys

The control plane exposes three unauthenticated endpoints under `/health`. They
are the contract a load balancer, `readinessProbe`, or blue/green cutover script
depends on, so it is worth being precise about what each one promises.

## The endpoints

| Endpoint | Touches dependencies? | Use it for |
| --- | --- | --- |
| `GET /health` | No | Human/scripted "who is answering?" — returns build identity |
| `GET /health/live` | No | Liveness probes: is the process wedged? |
| `GET /health/ready` | Yes | Routing decisions: should this replica receive traffic? |

All three return the same JSON shape:

```json
{
  "status": "healthy",
  "timestamp": "2026-07-20T18:22:04Z",
  "checks": [
    { "name": "database",   "status": "up" },
    { "name": "migrations", "status": "up" },
    { "name": "valkey",     "status": "up" }
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
- **valkey** — **degraded only**. Coordination is deliberately fail-open (see
  [multi-replica](../architecture/multi-replica.md)); agents still converge via
  the periodic sync. Pulling every replica out of rotation because Valkey blipped
  would be a worse outage than the blip.

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
  periodSeconds: 5
  failureThreshold: 60      # allow 5 minutes for migrations on boot

terminationDrain:
  enabled: true
  seconds: 15               # preStop delay before SIGTERM

terminationGracePeriodSeconds: 60
```

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

With the above in place the sequence is:

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
