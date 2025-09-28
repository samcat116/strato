# Migration Guide: docker-compose to Skaffold + Helm

This guide helps you migrate from the existing docker-compose development workflow to the new Skaffold + Helm setup.

## Overview

**Before**: `docker-compose up` started all services locally
**After**: `skaffold dev` deploys services to a local Kubernetes cluster

## Migration Steps

### Phase 1: Parallel Operation (Recommended)

Run both systems side-by-side during the transition:

```bash
# Keep using docker-compose while learning Skaffold
docker-compose up -d

# In another terminal, try Skaffold
minikube start --memory=4096 --cpus=2
skaffold dev --profile=minimal
```

### Phase 2: Team Migration

1. **Setup Meeting**: Review new workflow with the team
2. **Documentation**: Share this guide and development-skaffold.md
3. **Pair Sessions**: Have experienced users help others
4. **Gradual Adoption**: Start with minimal profile, add services

### Phase 3: Full Migration

1. **Update Documentation**: Change README.md to reference Skaffold
2. **Update CI/CD**: Modify build scripts to use Helm charts
3. **Deprecate docker-compose**: Add deprecation notice
4. **Remove docker-compose**: After team is comfortable

## Service Mapping

### docker-compose Services → Kubernetes Resources

| docker-compose | Kubernetes Resource | Helm Template |
|----------------|-------------------|---------------|
| `control-plane` | Deployment + Service | `templates/control-plane/` |
| `agent` | Deployment | `templates/agent/` |
| `db` | PostgreSQL subchart | Bitnami PostgreSQL |
| `permify` | Deployment + Service | `templates/permify/` |
| `ovn-northd` | Deployment | `templates/ovn/northd-deployment.yaml` |
| `ovn-nb-db` | StatefulSet + Service | `templates/ovn/nb-db-statefulset.yaml` |
| `ovn-sb-db` | StatefulSet + Service | `templates/ovn/sb-db-statefulset.yaml` |
| `openvswitch` | DaemonSet | `templates/ovs/daemonset.yaml` |

### Configuration Migration

#### Environment Variables

**Before** (docker-compose.yml):
```yaml
services:
  control-plane:
    environment:
      DATABASE_URL: postgresql://strato:password@db:5432/strato
      PERMIFY_URL: http://permify:3476
```

**After** (helm/strato/values-dev.yaml):
```yaml
controlPlane:
  env:
    WEBAUTHN_RELYING_PARTY_ORIGIN: "http://localhost:30080"
    LOG_LEVEL: "debug"
# DATABASE_URL and PERMIFY_URL auto-generated from templates
```

#### Volume Mounts

**Before** (docker-compose.yml):
```yaml
services:
  control-plane:
    volumes:
      - ./control-plane:/app
      - db_data:/var/lib/postgresql/data
```

**After**: 
- Source code: Skaffold file sync
- Database: Kubernetes PersistentVolumes
- Configuration: ConfigMaps and Secrets

#### Networking

**Before**: Docker bridge network with service names
**After**: Kubernetes service discovery with DNS

| Before | After |
|--------|-------|
| `http://permify:3476` | `http://strato-permify:3476` |
| `postgresql://db:5432` | `postgresql://strato-postgresql:5432` |
| `ws://control-plane:8080` | `ws://strato-control-plane:8080` |

## Command Migration

### Starting Services

```bash
# Before
docker-compose up

# After
skaffold dev
```

### Viewing Logs

```bash
# Before
docker-compose logs -f control-plane

# After
kubectl logs -f deployment/strato-control-plane
# Or: skaffold dev (shows all logs)
```

### Executing Commands

```bash
# Before
docker-compose exec control-plane swift run migrate

# After
kubectl exec -it deployment/strato-control-plane -- swift run migrate
```

### Stopping Services

```bash
# Before
docker-compose down

# After
skaffold delete
# Or: Ctrl+C if running skaffold dev
```

### Rebuilding Images

```bash
# Before
docker-compose build
docker-compose up

# After
# Automatic rebuild on file changes, or:
skaffold build
```

## Development Workflow Changes

### Code Changes

**Before**:
1. Edit source files
2. `docker-compose restart control-plane`
3. Check logs with `docker-compose logs`

**After**:
1. Edit source files
2. Skaffold automatically detects changes and rebuilds
3. Logs stream automatically in terminal

### Database Access

**Before**:
```bash
docker-compose exec db psql -U strato -d strato
```

**After**:
```bash
kubectl exec -it strato-postgresql-0 -- psql -U strato -d strato
```

### Debugging

**Before**:
```bash
docker-compose exec control-plane /bin/bash
```

**After**:
```bash
kubectl exec -it deployment/strato-control-plane -- /bin/bash
```

## Configuration Differences

### Resource Usage

**docker-compose**: Uses host resources directly
**Kubernetes**: Resource limits/requests defined in values.yaml

```yaml
# helm/strato/values-dev.yaml
controlPlane:
  resources:
    requests:
      memory: 256Mi
      cpu: 100m
    limits:
      memory: 512Mi
      cpu: 500m
```

### Environment Isolation

**docker-compose**: Shared host network and filesystem
**Kubernetes**: Isolated namespaces and network policies

### Service Discovery

**docker-compose**: Container names resolve automatically
**Kubernetes**: Service names with namespace suffix

## Troubleshooting Migration Issues

### "Service not accessible"

**Problem**: Can't reach services after migration

**Solution**:
```bash
# Check service status
kubectl get services
kubectl get pods

# Use port-forwarding for testing
kubectl port-forward service/strato-control-plane 8080:8080
```

### "Database connection failed"

**Problem**: Control plane can't connect to PostgreSQL

**Solution**:
```bash
# Check PostgreSQL pod
kubectl get pods | grep postgresql
kubectl logs strato-postgresql-0

# Verify connection string
kubectl describe configmap strato-control-plane-config
```

### "Performance is slower"

**Potential Causes**:
1. Insufficient minikube resources
2. Image rebuilding instead of file sync
3. Resource limits too low

**Solutions**:
```bash
# Increase minikube resources
minikube config set memory 6144
minikube config set cpus 4
minikube delete && minikube start

# Check Skaffold file sync is working
# Should see "File sync succeeded" in logs
```

### "Networking issues between services"

**Problem**: Services can't communicate

**Solution**:
```bash
# Check service discovery
kubectl exec -it deployment/strato-agent -- nslookup strato-control-plane

# Check NetworkPolicies (shouldn't be any in development)
kubectl get networkpolicies

# Verify service endpoints
kubectl get endpoints
```

## Rollback Plan

If you need to rollback to docker-compose:

```bash
# Stop Skaffold environment
skaffold delete

# Stop minikube (optional)
minikube stop

# Return to docker-compose
docker-compose up -d
```

## Benefits After Migration

1. **Production Parity**: Same Helm charts for dev and production
2. **Better Resource Management**: Kubernetes resource limits
3. **Service Isolation**: Each service in its own container/namespace
4. **Easier Scaling**: Can scale individual services
5. **Better Monitoring**: Kubernetes-native metrics and logs
6. **Team Consistency**: Everyone uses the same Kubernetes setup

## Team Training Checklist

- [ ] Install required tools (kubectl, helm, skaffold, minikube)
- [ ] Complete quick start guide
- [ ] Practice basic kubectl commands
- [ ] Test hot-reload workflow
- [ ] Learn log viewing and debugging
- [ ] Practice troubleshooting common issues
- [ ] Update local development documentation

## FAQ

**Q: Why migrate from docker-compose?**
A: Production parity, better resource management, team consistency, easier scaling.

**Q: Is this more complex than docker-compose?**
A: Initially yes, but provides more control and better matches production environment.

**Q: Can I still use docker-compose for some development?**
A: Yes, during transition period. Eventually we'll remove docker-compose.yml.

**Q: What if I don't want to run all services?**
A: Use `SKAFFOLD_PROFILE=minimal` or disable services in values-dev.yaml.

**Q: How do I reset everything?**
A: `skaffold delete && minikube delete && minikube start`