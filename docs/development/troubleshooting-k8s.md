# Kubernetes Troubleshooting Guide

This guide covers common issues when running Strato on Kubernetes via the
Helm chart, whether in a local cluster or in production.

## Resource names

The chart names resources `<release>-strato-control-plane`. For a release
named `strato` (as in the docs' `helm install strato .`), expect:

| Resource | Name |
| --- | --- |
| Control-plane Deployment/Service | `strato-strato-control-plane` |
| Frontend Deployment/Service | `strato-strato-control-plane-frontend` |
| PostgreSQL StatefulSet pod | `strato-postgresql-0` |
| SPIRE server StatefulSet | `strato-strato-control-plane-spire-server` |
| SPIRE agent DaemonSet | `strato-strato-control-plane-spire-agent` |
| SPIRE entry-bootstrap Job | `strato-strato-control-plane-spire-entry-bootstrap` |
| Credentials Secret | `strato-strato-credentials` |

There is **no agent workload in the chart** — Strato agents run on enrolled
hypervisor hosts outside the cluster and connect in over SPIFFE mTLS. See
[Deploying agents](/deployment/agents).

## Quick diagnostics

```bash
kubectl get pods
kubectl get events --sort-by=.metadata.creationTimestamp | tail -20
kubectl logs deployment/strato-strato-control-plane --tail=100
```

## Pod issues

### Pod stuck in Init

The control-plane pod runs two init containers: `wait-for-db` and
`wait-for-valkey`, which block until PostgreSQL and Valkey answer on their
ports.

```bash
kubectl logs <control-plane-pod> -c wait-for-db
kubectl logs <control-plane-pod> -c wait-for-valkey

# Verify PostgreSQL is up
kubectl get pods | grep postgresql
kubectl exec -it strato-postgresql-0 -- pg_isready
```

If the init container loops forever, the backing service isn't running (check
its pod) or the chart is pointed at an external host that isn't reachable
from the cluster.

### Pod stuck in CrashLoopBackOff

```bash
kubectl logs <pod-name> --previous
kubectl describe pod <pod-name>
```

Common causes:

- **Database not ready or credentials wrong** — check
  `kubectl logs strato-postgresql-0`. Database passwords are auto-generated
  on first install and stored in the `strato-strato-credentials` secret,
  which is kept across `helm uninstall` precisely so a reinstall keeps
  matching a retained PostgreSQL PVC. A mismatch means the secret was
  deleted by hand while the PVC survived — delete the PVC too and reinstall.
- **OOMKilled** — raise the top-level `resources.limits.memory` in your
  values file.

### Pod stuck in Pending

```bash
kubectl describe pod <pod-name>
```

Usually insufficient node resources or an unbound PVC (`kubectl get pvc`;
check your cluster has a default StorageClass).

## Accessing the web UI

The frontend and control plane are separate services. For local clusters
without an Ingress/Gateway, port-forward both:

```bash
kubectl port-forward service/strato-strato-control-plane-frontend 3000:3000
kubectl port-forward service/strato-strato-control-plane 8080:8080
```

Remember that WebAuthn requires the browser origin to exactly match the
configured relying-party origin; see
[Debugging WebAuthn](/debugging/webauthn).

## Image issues

`ErrImagePull` / `ImagePullBackOff`:

```bash
kubectl describe pod <pod-name> | grep -A 10 "Events"
helm get values strato   # confirm the repository/tag the chart is using
```

To run locally built images in a local cluster, build them into the cluster's
container runtime and stop Kubernetes from pulling:

```bash
# minikube example
eval $(minikube docker-env)
docker build -t strato-control-plane:dev -f control-plane/Dockerfile .
docker build -t strato-frontend:dev -f control-plane/web/Dockerfile .
```

```yaml
# my-values.yaml
image:
  repository: strato-control-plane
  tag: dev
  pullPolicy: Never
frontend:
  image:
    repository: strato-frontend
    tag: dev
    pullPolicy: Never
```

## Code Changes Not Taking Effect

There is no file-sync or hot-reload path into a cluster. Applying a source
change means rebuilding the image and rolling the deployment:

```bash
eval $(minikube docker-env)
docker build -t strato-control-plane:dev -f control-plane/Dockerfile .
helm upgrade strato helm/strato-control-plane -f my-values.yaml
kubectl rollout restart deployment/strato-strato-control-plane
```

If the tag didn't change, Kubernetes won't pull a new image — either use a
unique tag per build or `kubectl rollout restart` as above.

For a fast inner loop, prefer `swift build` / `swift test` locally and the
Docker Compose stack; see [Local Development](/development/local-development).

## SPIRE issues

SPIRE is mandatory (`spire.enabled=true` — the chart refuses to render
without it, because a SPIRE-issued SVID over mTLS is the only way agents
authenticate). The chart deploys a SPIRE server StatefulSet, a SPIRE agent
DaemonSet, an `envoy-sidecar` container in the control-plane pod that
terminates agent mTLS, and a `spire-entry-bootstrap` Job that registers the
control plane's workload entry.

```bash
kubectl logs statefulset/strato-strato-control-plane-spire-server
kubectl logs daemonset/strato-strato-control-plane-spire-agent
kubectl logs job/strato-strato-control-plane-spire-entry-bootstrap
kubectl logs deployment/strato-strato-control-plane -c envoy-sidecar
```

If agents can't connect, check the entry-bootstrap Job completed and the
`envoy-sidecar` container is Ready (its `agent-mtls` port is where agent
WebSockets terminate). Full setup details:
[Kubernetes deployment](/deployment/kubernetes) and
[Deploying agents](/deployment/agents).

## Helm issues

### Template rendering errors

```bash
helm template strato helm/strato-control-plane
helm lint helm/strato-control-plane
```

The chart ships example values files under `helm/strato-control-plane/ci/`
(`default-values.yaml`, `minimal-values.yaml`, `production-values.yaml`,
`external-db-values.yaml`, `external-monitoring-values.yaml`,
`session-valkey-values.yaml`) — the same ones CI templates against:

```bash
helm template strato helm/strato-control-plane \
  --values helm/strato-control-plane/ci/minimal-values.yaml
```

If templating fails on a missing subchart, run `helm dependency build` in
`helm/strato-control-plane` first.

## Database backup and restore

The chart's PostgreSQL defaults are user `vapor_username`, database
`vapor_database`, with the password in the release credentials secret:

```bash
PGPASSWORD=$(kubectl get secret strato-strato-credentials \
  -o jsonpath='{.data.db-password}' | base64 -d)

kubectl exec strato-postgresql-0 -- \
  env PGPASSWORD="$PGPASSWORD" pg_dump -U vapor_username vapor_database > backup.sql

kubectl exec -i strato-postgresql-0 -- \
  env PGPASSWORD="$PGPASSWORD" psql -U vapor_username vapor_database < backup.sql
```

## Complete reset

```bash
helm uninstall strato
kubectl delete pvc -l app.kubernetes.io/instance=strato   # drops all data
kubectl delete secret strato-strato-credentials           # kept on uninstall by design

cd helm/strato-control-plane
helm dependency build
helm install strato .
```

## Getting help

1. Check logs first: `kubectl logs deployment/strato-strato-control-plane --tail=100`
2. Check recent events: `kubectl get events --sort-by=.metadata.creationTimestamp | tail -20`
3. [Strato issues](https://github.com/samcat116/strato/issues)
