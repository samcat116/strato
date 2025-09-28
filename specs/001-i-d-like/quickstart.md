# Quickstart Guide: Skaffold and Helm Development

**Phase**: 1 - Design  
**Date**: 2025-09-25  
**Purpose**: Validate development environment setup and basic workflows

## Prerequisites

### Required Software
```bash
# Kubernetes cluster (choose one)
brew install minikube              # Recommended for development
# OR brew install kind
# OR enable Kubernetes in Docker Desktop

# Development tools
brew install skaffold helm kubectl

# Container runtime
brew install docker                # Docker Desktop or colima
```

### System Requirements
- **RAM**: Minimum 6GB free (4GB for minikube + 2GB for Docker)
- **CPU**: 2+ cores recommended
- **Storage**: 10GB free space for images and volumes

## Environment Setup

### 1. Start Kubernetes Cluster
```bash
# Using minikube (recommended)
minikube start --memory=4096 --cpus=2
minikube addons enable ingress
minikube addons enable storage-provisioner

# Verify cluster
kubectl cluster-info
```

### 2. Configure Local Environment
```bash
# Navigate to project root
cd /path/to/strato

# Verify Skaffold configuration
skaffold config list

# Verify Helm chart
helm lint helm/strato
helm template strato helm/strato --values helm/strato/values-dev.yaml
```

## Development Workflows

### Full Environment Startup
```bash
# Start all services in development mode
skaffold dev --profile=debug

# Expected output:
# - Building control-plane and agent images
# - Deploying Helm chart with development values
# - Setting up file watching for hot reload
# - All services healthy and accessible
```

### Minimal Environment (Control Plane Only)
```bash
# Start only control plane and dependencies
skaffold dev --profile=minimal

# Use when agent development not needed
```

### Build and Deploy Without File Watching
```bash
# One-time deployment
skaffold run --profile=debug

# Check deployment status
kubectl get pods -n strato
kubectl get services -n strato
```

## Validation Tests

### 1. Service Health Checks
```bash
# Check all pods are running
kubectl get pods -n strato
# Expected: All pods in Running/Ready state

# Check services are accessible
kubectl get services -n strato
# Expected: ClusterIP services with proper ports
```

### 2. Control Plane Accessibility
```bash
# Get service URL (minikube)
minikube service strato-control-plane --url -n strato

# Test HTTP endpoint
curl $(minikube service strato-control-plane --url -n strato)/health
# Expected: {"status": "ok"}

# Test web interface
open $(minikube service strato-control-plane --url -n strato)
# Expected: Strato web interface loads
```

### 3. Database Connectivity
```bash
# Check PostgreSQL pod
kubectl get pods -l app.kubernetes.io/name=postgresql -n strato

# Test database connection from control plane
kubectl exec -it deployment/strato-control-plane -n strato -- \
  swift run --skip-build strato-control-plane database-check
# Expected: Database connection successful
```

### 4. Agent-Control Plane Communication
```bash
# Check agent logs for WebSocket connection
kubectl logs deployment/strato-agent -n strato

# Should see:
# - WebSocket connection established to control plane
# - Agent registration successful
# - Heartbeat messages

# Test from control plane side
kubectl logs deployment/strato-control-plane -n strato | grep -i websocket
# Expected: Agent connection and registration logs
```

### 5. File Sync and Hot Reload
```bash
# Make a change to control plane source
echo "// Test change" >> control-plane/Sources/App/routes.swift

# Watch Skaffold output
# Expected: 
# - File change detected
# - Swift build triggered
# - Pod restarted with new code
# - Service accessible within 30 seconds
```

## Troubleshooting

### Common Issues

#### Pods Stuck in Pending State
```bash
# Check resource constraints
kubectl describe nodes
kubectl top nodes

# Check storage issues
kubectl get persistentvolumes
kubectl get persistentvolumeclaims -n strato

# Solution: Increase minikube resources or clean old volumes
```

#### Image Pull Failures
```bash
# Check image build status
skaffold build --quiet

# For local development, ensure images are built locally
eval $(minikube docker-env)
docker images | grep strato

# Solution: Rebuild images or check registry access
```

#### Service Not Accessible
```bash
# Check service and endpoint status
kubectl get endpoints -n strato
kubectl describe service strato-control-plane -n strato

# Check pod readiness
kubectl describe pod -l app=strato-control-plane -n strato

# Solution: Check health check endpoints and resource limits
```

#### WebSocket Connection Issues
```bash
# Check networking policies
kubectl get networkpolicies -n strato

# Check service discovery
kubectl exec -it deployment/strato-agent -n strato -- nslookup strato-control-plane

# Solution: Verify service names match configuration
```

### Performance Issues

#### Slow Build Times
```bash
# Enable build cache
export SKAFFOLD_CACHE_ARTIFACTS=true

# Use local registry for faster pulls
minikube addons enable registry

# Check disk space
df -h
docker system df
```

#### High Memory Usage
```bash
# Check resource usage
kubectl top pods -n strato
kubectl top nodes

# Reduce resource limits in values-dev.yaml if needed
# Or increase minikube memory allocation
```

## Development Commands Reference

### Skaffold Operations
```bash
# Development mode with file watching
skaffold dev

# Build images only
skaffold build

# Deploy without file watching  
skaffold run

# Clean up deployment
skaffold delete

# Debug configuration
skaffold config list
skaffold diagnose
```

### Kubectl Operations
```bash
# View all resources
kubectl get all -n strato

# Stream logs from all pods
kubectl logs -f -l app=strato-control-plane -n strato

# Execute commands in pods
kubectl exec -it deployment/strato-control-plane -n strato -- bash

# Port forwarding for debugging
kubectl port-forward service/strato-control-plane 8080:8080 -n strato
```

### Helm Operations
```bash
# View rendered templates
helm template strato helm/strato --values helm/strato/values-dev.yaml

# Check release status
helm status strato -n strato

# Upgrade configuration
helm upgrade strato helm/strato --values helm/strato/values-dev.yaml -n strato

# Rollback changes
helm rollback strato 1 -n strato
```

## Success Criteria

### Environment Ready When:
- [ ] All pods show Running/Ready status
- [ ] Control plane web interface accessible via browser
- [ ] Database connections established successfully
- [ ] Agent registers with control plane via WebSocket
- [ ] File changes trigger automatic rebuilds within 30 seconds
- [ ] No error messages in pod logs
- [ ] Services respond to health checks

### Migration Complete When:
- [ ] All docker-compose functionality replicated
- [ ] Development workflow documentation updated
- [ ] Team trained on new commands and troubleshooting
- [ ] docker-compose.yml deprecated and removed
- [ ] CI/CD updated to use new configuration