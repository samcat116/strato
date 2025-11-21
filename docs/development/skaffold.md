# Development Setup with Skaffold and Helm

This guide covers setting up a local development environment using Skaffold and Helm instead of docker-compose.

## Prerequisites

### Required Software

```bash
# Install Kubernetes cluster (choose one)
brew install minikube                # Recommended for development
# OR brew install kind
# OR enable Kubernetes in Docker Desktop

# Install development tools
brew install skaffold helm kubectl docker

# For macOS users, also install:
brew install colima                  # Alternative to Docker Desktop
```

### System Requirements

- **Memory**: 6GB+ available RAM (4GB for cluster, 2GB for Docker)
- **CPU**: 2+ cores recommended
- **Storage**: 10GB+ free disk space
- **Network**: Internet access for image pulls

## Quick Start

### 1. Start Kubernetes Cluster

```bash
# Using minikube (recommended)
minikube start --memory=4096 --cpus=2 --driver=docker

# Enable required addons
minikube addons enable ingress
minikube addons enable storage-provisioner
minikube addons enable metrics-server

# Verify cluster is ready
kubectl cluster-info
kubectl get nodes
```

### 2. Prepare Dependencies

```bash
# Navigate to project root
cd /path/to/strato

# Build Helm dependencies
cd helm/strato
helm dependency build
cd ../..

# Verify Skaffold configuration
skaffold config list
```

### 3. Start Development Environment

```bash
# Full development environment
skaffold dev --port-forward

# Or minimal environment (Control Plane only)
SKAFFOLD_PROFILE=minimal skaffold dev --port-forward

# Or debug mode with verbose logging
SKAFFOLD_PROFILE=debug skaffold dev --port-forward
```

### 4. Access Services

```bash
# Get service URLs (when using --port-forward)
echo "Control Plane: http://localhost:8080"

# Or use minikube service (without port-forward)
minikube service strato-control-plane --url

# Open web interface
open http://localhost:8080
```

## Development Workflows

### Code Changes and Hot Reload

Skaffold automatically detects changes and rebuilds/redeploys:

```bash
# Make changes to Swift source files
vim control-plane/Sources/App/Controllers/HomeController.swift

# Skaffold will automatically:
# 1. Detect the file change
# 2. Sync files to the running container
# 3. Restart the affected service
# 4. Display new logs
```

### Building Specific Services

```bash
# Build all images
skaffold build

# Build and tag for local registry
skaffold build --default-repo=localhost:5000

# Build specific artifacts
skaffold build -b strato-control-plane
```

### Debugging and Logs

```bash
# Stream logs from all services
skaffold dev --tail

# View logs for specific service
kubectl logs -f deployment/strato-control-plane
kubectl logs -f deployment/strato-agent

# Debug pods
kubectl get pods
kubectl describe pod <pod-name>
kubectl exec -it <pod-name> -- /bin/bash
```

### Managing the Environment

```bash
# Stop development environment (Ctrl+C or)
skaffold delete

# Clean up everything
skaffold delete
kubectl delete namespace default --force

# Restart cluster
minikube stop
minikube start --memory=4096 --cpus=2
```

## Profiles

### Debug Profile

```bash
SKAFFOLD_PROFILE=debug skaffold dev
```

- Enables debug logging for all services
- Builds Swift code in debug configuration
- Adds debug build flags to containers

### Minimal Profile

```bash
SKAFFOLD_PROFILE=minimal skaffold dev
```

- Deploys only Control Plane, PostgreSQL, and Permify
- Disables Agent and networking services
- Faster startup for frontend/API development

### Production Profile

```bash
SKAFFOLD_PROFILE=production skaffold run
```

- Uses production values.yaml
- Deploys to `strato` namespace
- Production-ready resource limits

## Configuration

### Environment Variables

Override development values by modifying `helm/strato/values-dev.yaml`:

```yaml
controlPlane:
  env:
    LOG_LEVEL: "trace"
    WEBAUTHN_RELYING_PARTY_ORIGIN: "http://localhost:3000"
```

### Resource Limits

Adjust resources for your development machine:

```yaml
# helm/strato/values-dev.yaml
controlPlane:
  resources:
    requests:
      memory: 128Mi  # Reduce for slower machines
      cpu: 50m
```

### Service Selection

Enable/disable services as needed:

```yaml
# helm/strato/values-dev.yaml
agent:
  enabled: false        # Disable agent for API-only development
ovn:
  enabled: false        # Disable networking for simple testing
```

## Troubleshooting

### Common Issues

#### Pods Stuck in Pending
```bash
# Check node resources
kubectl top nodes
kubectl describe nodes

# Check storage
kubectl get pv,pvc

# Solution: Increase minikube resources
minikube config set memory 6144
minikube config set cpus 4
minikube delete && minikube start
```

#### Image Pull Errors
```bash
# Check image status
skaffold build
docker images | grep strato

# For development, use local images
eval $(minikube docker-env)
skaffold build
```

#### Service Won't Start
```bash
# Check pod status
kubectl get pods
kubectl describe pod strato-control-plane-xxx

# Check logs
kubectl logs strato-control-plane-xxx

# Common fixes:
# 1. Check database connectivity
# 2. Verify environment variables
# 3. Check resource limits
```

#### Port Conflicts
```bash
# If port 8080 is busy
minikube service strato-control-plane --url
# Use the returned URL instead of localhost:8080
```

### Performance Tips

1. **Resource Allocation**: Give minikube enough resources
2. **Image Caching**: Keep Docker images cached locally
3. **File Sync**: Use file sync instead of full rebuilds when possible
4. **Selective Services**: Use minimal profile for faster iteration

### Migration from docker-compose

1. **Environment Variables**: Now configured in Helm values
2. **Service Discovery**: Uses Kubernetes DNS instead of container names
3. **Networking**: Services communicate via ClusterIP
4. **Storage**: Uses PersistentVolumes instead of bind mounts
5. **Logs**: Access via `kubectl logs` instead of `docker logs`

## Next Steps

- See [Migration Guide](./migration-guide.md) for detailed migration steps
- See [Troubleshooting Guide](./troubleshooting-k8s.md) for advanced debugging
- Check the repository root for updated development commands