# Helm Chart Testing Guide

This guide distinguishes the checks that run in GitHub Actions from cluster
tests that operators run manually.

## Automated checks

`.github/workflows/helm-test.yml` runs for relevant chart changes on pushes and
pull requests, and can also be started with `workflow_dispatch`. It has three
jobs:

1. **Helm Chart Linting** runs `helm lint` and validates chart dependencies.
2. **Template Validation** renders the default chart, every `ci/*.yaml` values
   scenario, chart-owned and external Gateway API configurations, SPIRE
   variants, and other focused configurations. It checks route parity, secrets,
   session-store wiring, Gateway resources, and every rendered YAML document.
3. **Security Scanning** renders the chart, runs Checkov, checks templates for
   hardcoded secrets, and reports RBAC resources. Checkov findings are
   informational because the workflow uses `--soft-fail`; failures to install or
   execute the scanner still fail the job.

CI does **not** create a Kubernetes cluster or test database connectivity,
schema migration behavior, upgrades, rollbacks, or load. Those checks require
real Strato images and stateful dependencies and are intentionally manual.

## Local lint and render checks

From `helm/strato-control-plane`, install Helm 3, add the chart dependency
repository, then run:

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm dependency build
helm lint .

render_dir=$(mktemp -d)
helm template strato-default . > "$render_dir/default.yaml"

for values in ci/*.yaml; do
  scenario=$(basename "$values" .yaml)
  helm template "strato-$scenario" . -f "$values" \
    > "$render_dir/$scenario.yaml"
done

# Chart-owned Gateway and GatewayClass.
helm template strato-managed-gateway . \
  --set gateway.enabled=true \
  --set gateway.create=true \
  --set gateway.gatewayClass.create=true \
  --set strato.externalHostname=strato.example.test \
  > "$render_dir/managed-gateway.yaml"

# Routes attached to an infrastructure-owned Gateway.
helm template strato-external-gateway . \
  --set gateway.enabled=true \
  --set gateway.name=infra-gateway \
  --set gateway.namespace=envoy-gateway-system \
  --set strato.externalHostname=strato.example.test \
  > "$render_dir/external-gateway.yaml"
```

From the repository root, validate the workflow itself when changing it:

```bash
actionlint .github/workflows/helm-test.yml
```

## Checked-in values scenarios

| File | Purpose |
| --- | --- |
| `ci/default-values.yaml` | Basic low-resource configuration |
| `ci/production-values.yaml` | Multiple replicas, disruption budget, and production resources |
| `ci/external-db-values.yaml` | External PostgreSQL configuration |
| `ci/external-monitoring-values.yaml` | External Prometheus with chart scrape endpoints |
| `ci/minimal-values.yaml` | Optional features and probes reduced |
| `ci/session-valkey-values.yaml` | Separate coordination and session Valkey endpoints |

These files are render fixtures. A successful render does not prove that the
referenced external services are reachable.

## Manual cluster checks

Use a disposable cluster or staging namespace with real Strato images and valid
Gateway API, PostgreSQL, and Valkey dependencies. The checked-in CI values use
placeholder images or endpoints and are not installation fixtures.

For a fresh install:

```bash
helm install strato . -n strato-test --create-namespace -f staging-values.yaml
kubectl rollout status deployment/strato-strato-control-plane -n strato-test
kubectl get pods -n strato-test
kubectl logs deployment/strato-strato-control-plane -n strato-test \
  -c strato-control-plane
```

To exercise a multi-replica upgrade with a pending migration, upgrade from the
previous release to an image that contains a known new migration and request at
least two replicas:

```bash
helm upgrade strato . -n strato-test -f staging-values.yaml \
  --set replicaCount=2 --set image.tag=<new-version>
kubectl rollout status deployment/strato-strato-control-plane -n strato-test
kubectl logs deployment/strato-strato-control-plane -n strato-test \
  -c strato-control-plane --prefix=true
```

The pod logs should show one replica applying the pending batch under the
advisory lock and the other observing an up-to-date schema. Helm hook status is
not part of this flow.

For the failure path, deploy a test-only image containing an intentionally
failing migration. The new pod must remain unready, rollout status must fail,
and the pod log must contain the migration error:

```bash
helm upgrade strato . -n strato-test -f staging-values.yaml \
  --set image.tag=<failing-migration-test-image>
kubectl get pods -n strato-test
kubectl logs <new-unready-pod> -n strato-test -c strato-control-plane
```

Clean up the disposable installation when finished:

```bash
helm uninstall strato -n strato-test
kubectl delete namespace strato-test
```

When diagnosing a failure, capture `helm get values`, `helm get manifest`, pod
descriptions, container logs, and namespace events before cleanup.
