# Kubernetes Troubleshooting Guide

This guide covers common issues and solutions when developing with Skaffold and Helm.

## Quick Diagnostic Commands

```bash
# Check cluster status
kubectl cluster-info
kubectl get nodes

# Check all resources
kubectl get all
kubectl get pods,services,deployments,statefulsets

# Check resource usage
kubectl top nodes
kubectl top pods

# Check events
kubectl get events --sort-by=.metadata.creationTimestamp
```

## Pod Issues

### Pod Stuck in Pending

**Symptoms**: `kubectl get pods` shows `Pending` status

**Diagnosis**:
```bash
kubectl describe pod <pod-name>
kubectl get events | grep <pod-name>
```

**Common Causes & Solutions**:

1. **Insufficient Resources**
   ```bash
   # Check node capacity
   kubectl describe nodes
   kubectl top nodes
   
   # Solution: Increase minikube resources
   minikube config set memory 6144
   minikube config set cpus 4
   minikube delete && minikube start
   ```

2. **Storage Issues**
   ```bash
   # Check persistent volumes
   kubectl get pv,pvc
   
   # Solution: Enable storage addon
   minikube addons enable storage-provisioner
   ```

3. **Image Pull Issues**
   ```bash
   # Check image pull policy
   kubectl describe pod <pod-name> | grep -A 5 "Image"
   
   # Solution: Build local images
   eval $(minikube docker-env)
   skaffold build
   ```

### Pod Stuck in CrashLoopBackOff

**Symptoms**: Pod repeatedly restarts

**Diagnosis**:
```bash
kubectl logs <pod-name> --previous
kubectl describe pod <pod-name>
```

**Common Solutions**:

1. **Check Application Logs**
   ```bash
   kubectl logs deployment/strato-control-plane --tail=50
   ```

2. **Check Dependencies**
   ```bash
   # Verify database is running
   kubectl get pods | grep postgresql
   kubectl logs strato-postgresql-0
   ```

3. **Check Resource Limits**
   ```bash
   kubectl describe pod <pod-name> | grep -A 10 "Limits"
   
   # Increase limits in values-dev.yaml
   resources:
     limits:
       memory: 1Gi  # Increase from 512Mi
   ```

### Pod Stuck in Init

**Symptoms**: Pod shows `Init:0/1` or similar

**Diagnosis**:
```bash
kubectl describe pod <pod-name>
kubectl logs <pod-name> -c <init-container-name>
```

**Solutions**:
1. **Check Init Container Dependencies**
   ```bash
   # Control plane waiting for PostgreSQL
   kubectl logs <control-plane-pod> -c wait-for-postgresql
   
   # Verify PostgreSQL is accessible
   kubectl exec -it strato-postgresql-0 -- pg_isready
   ```

## Service Connectivity Issues

### Can't Access Control Plane Web UI

**Diagnosis**:
```bash
# Check service and pods
kubectl get service strato-control-plane
kubectl get pods | grep control-plane
kubectl describe service strato-control-plane
```

**Solutions**:

1. **Use Port Forwarding**
   ```bash
   kubectl port-forward service/strato-control-plane 8080:8080
   open http://localhost:8080
   ```

2. **Use minikube service**
   ```bash
   minikube service strato-control-plane --url
   # Use the returned URL
   ```

3. **Check NodePort (if configured)**
   ```bash
   minikube ip  # Get cluster IP
   # Access via http://<minikube-ip>:30080
   ```

### Services Can't Communicate

**Symptoms**: Agent can't connect to Control Plane, or Control Plane can't reach database

**Diagnosis**:
```bash
# Test DNS resolution
kubectl exec -it deployment/strato-agent -- nslookup strato-control-plane

# Test port connectivity
kubectl exec -it deployment/strato-agent -- nc -zv strato-control-plane 8080
```

**Solutions**:

1. **Check Service Names**
   ```bash
   kubectl get services
   # Ensure services use correct names in environment variables
   ```

2. **Check Network Policies**
   ```bash
   kubectl get networkpolicies
   # Should be empty for development
   ```

3. **Verify Service Endpoints**
   ```bash
   kubectl get endpoints
   # Ensure services have valid endpoints
   ```

## Storage Issues

### Database Data Loss

**Symptoms**: Database loses data between restarts

**Diagnosis**:
```bash
kubectl get pv,pvc
kubectl describe pvc data-strato-postgresql-0
```

**Solutions**:

1. **Check Persistent Volume**
   ```bash
   # Ensure PVC is bound
   kubectl get pvc
   
   # Check storage class
   kubectl get storageclass
   ```

2. **For minikube, ensure storage addon**
   ```bash
   minikube addons enable storage-provisioner
   ```

### Disk Space Issues

**Symptoms**: Pods fail to start due to disk space

**Diagnosis**:
```bash
# Check node disk usage
kubectl describe nodes | grep -A 5 "Conditions"

# Check Docker disk usage
docker system df
```

**Solutions**:
```bash
# Clean up Docker
docker system prune -a

# Clean up minikube
minikube ssh -- docker system prune -a

# Increase minikube disk size
minikube config set disk-size 20GB
minikube delete && minikube start
```

## Image Issues

### Image Pull Errors

**Symptoms**: `ErrImagePull` or `ImagePullBackOff`

**Diagnosis**:
```bash
kubectl describe pod <pod-name> | grep -A 10 "Events"
```

**Solutions**:

1. **Use Local Images**
   ```bash
   # Point Docker to minikube
   eval $(minikube docker-env)
   
   # Build images locally
   skaffold build
   
   # Ensure imagePullPolicy is correct
   # In values-dev.yaml:
   global:
     imagePullPolicy: Never
   ```

2. **Check Image Names**
   ```bash
   # List available images
   docker images | grep strato
   
   # Verify Skaffold configuration
   skaffold config list
   ```

### Slow Image Builds

**Solutions**:
```bash
# Use Docker buildx cache
export DOCKER_BUILDKIT=1

# Configure Skaffold cache
export SKAFFOLD_CACHE_ARTIFACTS=true

# Use multi-stage builds efficiently
# Check Dockerfile for optimal layer caching
```

## Performance Issues

### Slow Startup Times

**Diagnosis**:
```bash
# Check resource usage
kubectl top pods
kubectl top nodes

# Check startup times
kubectl get events | grep Started
```

**Solutions**:

1. **Increase minikube Resources**
   ```bash
   minikube config set memory 8192
   minikube config set cpus 6
   minikube delete && minikube start
   ```

2. **Optimize Resource Requests**
   ```yaml
   # In values-dev.yaml - reduce for faster startup
   controlPlane:
     resources:
       requests:
         memory: 128Mi
         cpu: 50m
   ```

3. **Use Faster Storage**
   ```bash
   # For macOS with Docker Desktop
   minikube start --driver=hyperkit --disk-size=20GB
   ```

### High Memory Usage

**Diagnosis**:
```bash
kubectl top pods --sort-by=memory
kubectl describe node minikube | grep -A 10 "Allocated resources"
```

**Solutions**:

1. **Reduce Resource Limits**
   ```yaml
   # values-dev.yaml
   postgresql:
     resources:
       limits:
         memory: 256Mi  # Reduce from 512Mi
   ```

2. **Disable Unused Services**
   ```yaml
   # values-dev.yaml
   agent:
     enabled: false
   ovn:
     enabled: false
   openvswitch:
     enabled: false
   ```

## Skaffold Issues

### Skaffold Build Failures

**Diagnosis**:
```bash
skaffold diagnose
skaffold config list
```

**Solutions**:

1. **Check Docker Context**
   ```bash
   docker context list
   eval $(minikube docker-env)
   ```

2. **Clear Skaffold Cache**
   ```bash
   skaffold cache purge
   ```

3. **Verbose Logging**
   ```bash
   skaffold dev -v info
   ```

### File Sync Not Working

**Symptoms**: Code changes don't trigger updates

**Diagnosis**:
```bash
# Check Skaffold file watchers
skaffold dev -v debug | grep sync
```

**Solutions**:

1. **Check Sync Configuration**
   ```yaml
   # skaffold.yaml
   sync:
     manual:
       - src: "Sources/**/*.swift"
         dest: /app/Sources
   ```

2. **File Permissions**
   ```bash
   # Ensure files are accessible
   ls -la control-plane/Sources/
   ```

## Helm Issues

### Template Rendering Errors

**Diagnosis**:
```bash
helm template strato helm/strato --values helm/strato/values-dev.yaml
helm lint helm/strato
```

**Solutions**:

1. **Check Values Syntax**
   ```bash
   # Validate YAML syntax
   yamllint helm/strato/values-dev.yaml
   ```

2. **Debug Template Rendering**
   ```bash
   helm template strato helm/strato --values helm/strato/values-dev.yaml --debug
   ```

3. **Check Dependencies**
   ```bash
   cd helm/strato
   helm dependency build
   ```

## Network Debugging

### DNS Resolution Issues

**Diagnosis**:
```bash
# Test DNS from inside pods
kubectl exec -it deployment/strato-control-plane -- nslookup strato-postgresql
kubectl exec -it deployment/strato-control-plane -- cat /etc/resolv.conf
```

**Solutions**:
```bash
# Check CoreDNS
kubectl get pods -n kube-system | grep coredns
kubectl logs -n kube-system deployment/coredns
```

### Port Conflicts

**Diagnosis**:
```bash
# Check what's using port 8080
lsof -i :8080
netstat -tulpn | grep 8080
```

**Solutions**:
```bash
# Use different local port
kubectl port-forward service/strato-control-plane 8081:8080

# Or configure different NodePort
# In values-dev.yaml:
controlPlane:
  service:
    nodePort: 30081
```

## Emergency Procedures

### Complete Reset

```bash
# Stop everything
skaffold delete
minikube stop

# Reset minikube
minikube delete
minikube start --memory=4096 --cpus=2

# Rebuild dependencies
cd helm/strato
helm dependency build
cd ../..

# Restart development
skaffold dev
```

### Backup Development Data

```bash
# Backup PostgreSQL data
kubectl exec strato-postgresql-0 -- pg_dump -U strato strato > backup.sql

# Restore data (to new cluster)
kubectl exec -i strato-postgresql-0 -- psql -U strato strato < backup.sql
```

### Resource Monitoring

```bash
# Continuous monitoring
watch kubectl top pods
watch kubectl top nodes

# Resource alerts
kubectl get events --watch | grep -i "failed\|error\|warning"
```

## Getting Help

1. **Check Logs First**
   ```bash
   kubectl logs deployment/strato-control-plane --tail=100
   ```

2. **Check Recent Events**
   ```bash
   kubectl get events --sort-by=.metadata.creationTimestamp | tail -20
   ```

3. **Gather Debug Info**
   ```bash
   kubectl get all > debug-resources.txt
   kubectl describe pods > debug-pods.txt
   kubectl top nodes > debug-usage.txt
   ```

4. **Community Resources**
   - Kubernetes Slack: #kubectl channel
   - Skaffold GitHub issues
   - Helm GitHub issues