# Strato Control Plane Helm Chart

This Helm chart deploys the Strato control plane application with all its dependencies including a PostgreSQL database. Authorization is handled by the control plane's built-in Cedar policy engine — no external authorization service is deployed.

## Prerequisites

- Kubernetes 1.20+
- Helm 3.8+
- PV provisioner support in the underlying infrastructure

## Installation

### Add Dependencies

First, add the required Helm repositories:

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```

### Build Dependencies

Build the chart dependencies:

```bash
cd helm/strato-control-plane
helm dependency build
```

### Install Chart

```bash
helm install strato-control-plane ./helm/strato-control-plane
```

To install with custom values:

```bash
helm install strato-control-plane ./helm/strato-control-plane -f my-values.yaml
```

## Configuration

### Required Configuration

Secrets are generated automatically: on first install the chart creates strong
random credentials (PostgreSQL passwords) in the
`<release>-strato-credentials` secret and reuses them on every upgrade. The
secret is kept on uninstall so a reinstall keeps matching a retained database
volume. A bare `helm install` is secure by default — you only need to set the
values below when deploying to production behind a real hostname:

```yaml
# Image configuration
image:
  repository: your-registry/strato-control-plane
  tag: "latest"

# WebAuthn configuration — must match the URL users visit
strato:
  webauthn:
    relyingPartyId: "your-domain.com"
    relyingPartyName: "Your Strato Instance"
    relyingPartyOrigin: "https://your-domain.com"
```

To supply your own secrets instead of the generated ones, set
`postgresql.auth.password` and/or `postgresql.auth.postgresPassword`; explicit
values always win and are stored in the same credentials secret so every
consumer stays in sync.

### Common Configuration Options

#### Production Configuration

```yaml
# Production-ready resource limits
resources:
  limits:
    cpu: 2000m
    memory: 2Gi
  requests:
    cpu: 500m
    memory: 512Mi

# High availability
replicaCount: 2
podDisruptionBudget:
  enabled: true
  minAvailable: 1

# Security
networkPolicy:
  enabled: true

# Monitoring
monitoring:
  serviceMonitor:
    enabled: true
  metrics:
    enabled: true
```

#### External Database

To use an external PostgreSQL database:

```yaml
postgresql:
  enabled: false

externalDatabase:
  host: postgres.example.com
  port: 5432
  database: vapor_database
  username: vapor_user
  password: external-db-password
```

## Values Reference

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `image.repository` | string | `"strato-control-plane"` | Container image repository |
| `image.tag` | string | `""` | Container image tag (defaults to chart appVersion) |
| `image.pullPolicy` | string | `"IfNotPresent"` | Image pull policy |
| `replicaCount` | int | `1` | Number of replicas |
| `frontend.enabled` | bool | `true` | Deploy the standalone Next.js frontend |
| `frontend.service.port` | int | `3000` | Frontend service port |
| `frontend.env.STRATO_API_URL` | string | `""` | Server-side API proxy destination; empty derives the in-cluster control-plane service URL |
| `frontend.env.STRATO_GRAVATAR_ENABLED` | string | `"true"` | Show Gravatar profile pictures; sends a hash of each user's email to gravatar.com. `"false"` falls back to initials |
| `resources.limits.cpu` | string | `"1000m"` | CPU limit |
| `resources.limits.memory` | string | `"1Gi"` | Memory limit |
| `resources.requests.cpu` | string | `"500m"` | CPU request |
| `resources.requests.memory` | string | `"512Mi"` | Memory request |
| `strato.logLevel` | string | `"info"` | Log level (debug, info, warn, error) |
| `strato.webauthn.relyingPartyId` | string | `"localhost"` | WebAuthn relying party identifier |
| `strato.webauthn.relyingPartyName` | string | `"Strato"` | WebAuthn relying party name |
| `strato.webauthn.relyingPartyOrigin` | string | `"http://localhost:8080"` | WebAuthn relying party origin |
| `postgresql.enabled` | bool | `true` | Enable PostgreSQL subchart |
| `postgresql.auth.database` | string | `"vapor_database"` | PostgreSQL database name |
| `postgresql.auth.username` | string | `"vapor_username"` | PostgreSQL username |
| `postgresql.auth.password` | string | `""` | PostgreSQL password (auto-generated when empty) |
| `ingress.enabled` | bool | `false` | Enable the legacy ingress-nginx path (superseded by `gateway`) |
| `gateway.enabled` | bool | `false` | Route external traffic via Gateway API (Envoy Gateway): HTTPRoute for UI/API + frontend, TLS-passthrough TLSRoutes for `agents.<host>` (Envoy sidecar mTLS) and `spire.<host>` (SPIRE node API), all sharing :443 by SNI |
| `gateway.create` | bool | `false` | Render the Gateway (and optional GatewayClass) instead of only attaching routes to an operator-provided one |
| `gateway.hostnames.web` / `.agents` / `.spire` | string | `""` | SNI hosts; empty derives `<host>`, `agents.<host>`, `spire.<host>` from `strato.externalHostname` |
| `gateway.tls.certManager.enabled` | bool | `false` | Add the cert-manager Gateway-shim annotation to the rendered Gateway (DNS-01 issuer required for the multi-host SAN) |
| `networkPolicy.enabled` | bool | `false` | Enable network policies |
| `podDisruptionBudget.enabled` | bool | `false` | Enable pod disruption budget |
| `opentelemetry.prometheusExport.enabled` | bool | `true` | Expose Prometheus-format scrape endpoints (collector `prometheus` exporter, SPIRE telemetry), independent of the bundled Prometheus |
| `opentelemetry.prometheusExport.serviceMonitor.enabled` | bool | `false` | Render ServiceMonitors for a Prometheus Operator install (requires the CRDs) |
| `opentelemetry.prometheusExport.serviceMonitor.labels` | object | `{}` | Extra ServiceMonitor labels — usually what the operator's `serviceMonitorSelector` matches |
| `opentelemetry.prometheusExport.podAnnotations` | bool | `false` | `prometheus.io/scrape` annotations for annotation-based discovery instead of the operator |
| `opentelemetry.prometheus.enabled` | bool | `true` | Run the chart's bundled Prometheus (StatefulSet + PVC) |
| `opentelemetry.prometheus.url` | string | `""` | External Prometheus HTTP API for the Workload Identity "Issuance" panel; empty uses the bundled one |

## Testing

### Automated Testing

The chart includes comprehensive CI/CD testing via GitHub Actions that runs:

- Helm chart linting
- Template validation with different configurations
- Kubernetes integration tests with kind
- Security scanning
- Upgrade testing

### Local Testing

Validate the chart locally with Helm's built-in tooling:

```bash
# Lint the chart (also renders every ci/*.yaml values file)
helm lint helm/strato-control-plane/

# Render templates with a given values file to inspect the output
helm template strato helm/strato-control-plane/ -f helm/strato-control-plane/ci/default-values.yaml
```

The same checks run in CI via `.github/workflows/helm-test.yml` (lint,
template validation across the `ci/*.yaml` configurations, and secret scanning).

### Test Values

The chart includes test values files for different scenarios:

- `ci/default-values.yaml` - Basic configuration for CI
- `ci/production-values.yaml` - Production-like settings
- `ci/external-db-values.yaml` - External database configuration
- `ci/minimal-values.yaml` - Minimal resource configuration

## Troubleshooting

### Common Issues

#### Pods Stuck in Init State

If pods are stuck in `Init:0/1` or `Init:0/2` state, check the init container logs:

```bash
kubectl logs <pod-name> -c wait-for-db
```

This usually indicates connectivity issues between services.

#### Database Connection Issues

Check the database connection:

```bash
# Get database password (auto-generated on first install)
kubectl get secret <release-name>-strato-credentials -o jsonpath="{.data.db-password}" | base64 -d

# Test connection
kubectl run postgresql-client --rm --tty -i --restart='Never' \
  --image docker.io/bitnami/postgresql:16 \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" \
  --command -- psql --host <release-name>-postgresql -U vapor_username -d vapor_database -c 'SELECT version();'
```

### Debug Commands

Get comprehensive deployment status:

```bash
# Pod status
kubectl get pods -l app.kubernetes.io/instance=<release-name>

# Service status
kubectl get services -l app.kubernetes.io/instance=<release-name>

# Events
kubectl get events --sort-by=.metadata.creationTimestamp

# Describe problematic pods
kubectl describe pod <pod-name>

# View logs
kubectl logs <pod-name> --all-containers=true
```

## Security Considerations

### Production Security Checklist

- [ ] Configure proper WebAuthn relying party settings
- [ ] Enable NetworkPolicy for network security
- [ ] Set appropriate resource limits
- [ ] Enable PodDisruptionBudget for availability
- [ ] Configure TLS/SSL for external access
- [ ] Review and configure RBAC permissions
- [ ] Enable monitoring and logging
- [ ] Regular security updates of base images

### Network Policies

When `networkPolicy.enabled=true`, the chart creates policies that:
- Allow ingress traffic only on application ports
- Allow egress to the database and other release services
- Allow DNS resolution
- Deny all other traffic by default

## Monitoring and Observability

### Metrics

The control plane has no `/metrics` endpoint — it exports OTLP to the chart's
OTel collector, whose `prometheus` exporter (port 8889) re-exposes everything
for scraping. That exporter is on by default and is independent of the bundled
Prometheus.

### ServiceMonitor

For Prometheus Operator integration, scraping the chart from a monitoring stack
you already run — no bundled Prometheus StatefulSet or PVC:

```yaml
opentelemetry:
  prometheusExport:
    serviceMonitor:
      enabled: true
      interval: 30s
      labels:
        release: kube-prometheus-stack   # your operator's serviceMonitorSelector
  prometheus:
    enabled: false
    # Keeps the Workload Identity "Issuance" panel working without the bundle
    url: "http://kube-prometheus-stack-prometheus.monitoring.svc:9090"
```

Without the operator, use `opentelemetry.prometheusExport.podAnnotations: true`
for `prometheus.io/scrape` annotation discovery. Full details, including which
targets carry what, are in
[Observability: Metrics & Alerts](../../docs/deployment/observability.md).

### Health Checks

The application provides health endpoints:
- `/health/live` - Liveness probe endpoint
- `/health/ready` - Readiness probe endpoint

## Upgrading

### Backup Before Upgrade

Always backup your database before upgrading:

```bash
# Backup PostgreSQL
kubectl exec -it <postgresql-pod> -- pg_dump -U vapor_username vapor_database > backup.sql
```

### Upgrade Process

```bash
# Update dependencies
helm dependency update ./helm/strato-control-plane

# Upgrade release
helm upgrade strato-control-plane ./helm/strato-control-plane \
  -f your-values.yaml \
  --wait --timeout=10m
```

### Rollback

If upgrade fails, rollback to previous version:

```bash
helm rollback strato-control-plane
```

## Contributing

When making changes to the chart:

1. Update version in `Chart.yaml`
2. Add/update values in `values.yaml`
3. Update this README
4. Run `helm lint helm/strato-control-plane/` and validate rendered templates
5. Test deployment in a real cluster
6. Submit PR with clear description of changes

## Support

For issues and questions:
- GitHub Issues: [repository issues](https://github.com/samcat116/strato/issues)
- Documentation: [project docs](https://github.com/samcat116/strato/tree/main/docs)

## License

This chart is licensed under the same license as the Strato project.
