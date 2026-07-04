# Strato Control Plane Helm Chart

This Helm chart deploys the Strato control plane application with all its dependencies including PostgreSQL database and SpiceDB authorization service.

## Prerequisites

- Kubernetes 1.20+
- Helm 3.8+
- PV provisioner support in the underlying infrastructure

## Installation

### Add Dependencies

First, add the required Helm repositories:

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add spicedb-operator-chart https://bushelpowered.github.io/spicedb-operator-chart/
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
random credentials (PostgreSQL passwords and the SpiceDB preshared key) in the
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
`postgresql.auth.password`, `postgresql.auth.postgresPassword`, and/or
`spicedb.presharedKey`; explicit values always win and are stored in the same
credentials secret so every consumer stays in sync.

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

spicedb:
  resources:
    limits:
      cpu: 1000m
      memory: 1Gi
    requests:
      cpu: 250m
      memory: 256Mi

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

#### Disable SpiceDB

If you don't need authorization features:

```yaml
spicedb:
  enabled: false
```

## Values Reference

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `image.repository` | string | `"strato-control-plane"` | Container image repository |
| `image.tag` | string | `""` | Container image tag (defaults to chart appVersion) |
| `image.pullPolicy` | string | `"IfNotPresent"` | Image pull policy |
| `replicaCount` | int | `1` | Number of replicas |
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
| `spicedb.enabled` | bool | `true` | Enable SpiceDB authorization |
| `spicedb.operator.enabled` | bool | `true` | Install the SpiceDB Operator dependency |
| `spicedb.presharedKey` | string | `""` | SpiceDB preshared key (auto-generated when empty) |
| `spicedb.resources.limits.cpu` | string | `"500m"` | SpiceDB CPU limit |
| `spicedb.resources.limits.memory` | string | `"512Mi"` | SpiceDB memory limit |
| `ingress.enabled` | bool | `false` | Enable ingress |
| `networkPolicy.enabled` | bool | `false` | Enable network policies |
| `podDisruptionBudget.enabled` | bool | `false` | Enable pod disruption budget |
| `monitoring.serviceMonitor.enabled` | bool | `false` | Enable ServiceMonitor for Prometheus |

## Testing

### Automated Testing

The chart includes comprehensive CI/CD testing via GitHub Actions that runs:

- Helm chart linting
- Template validation with different configurations
- Kubernetes integration tests with kind
- Security scanning
- Upgrade testing

### Local Testing

Use the provided test script to validate the chart locally:

```bash
./scripts/test-helm-chart.sh
```

This script performs:
- Chart linting
- Template validation with multiple configurations
- Security checks
- Dependency validation

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
kubectl logs <pod-name> -c wait-for-spicedb
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

#### SpiceDB Authorization Issues

Check SpiceDB logs and schema:

```bash
# Check SpiceDB logs
kubectl logs -l app.kubernetes.io/component=spicedb

# Get the SpiceDB preshared key (auto-generated on first install)
kubectl get secret <release-name>-strato-credentials -o jsonpath="{.data.spicedb-preshared-key}" | base64 -d

# Verify schema is loaded
kubectl port-forward svc/<release-name>-spicedb 8080:8080 &
curl -H "Authorization: Bearer <preshared-key>" http://localhost:8080/v1/schema/read
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
- Allow egress to database and SpiceDB services
- Allow DNS resolution
- Deny all other traffic by default

## Monitoring and Observability

### Metrics

The control plane exposes Prometheus metrics on `/metrics` when enabled:

```yaml
monitoring:
  metrics:
    enabled: true
    port: 9090
```

### ServiceMonitor

For Prometheus Operator integration:

```yaml
monitoring:
  serviceMonitor:
    enabled: true
    interval: 30s
    labels:
      prometheus: kube-prometheus
```

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
4. Run tests: `./scripts/test-helm-chart.sh`
5. Test deployment in a real cluster
6. Submit PR with clear description of changes

## Support

For issues and questions:
- GitHub Issues: [repository issues](https://github.com/samcat116/strato/issues)
- Documentation: [project docs](https://github.com/samcat116/strato/tree/main/docs)

## License

This chart is licensed under the same license as the Strato project.
