# Helm Chart Testing Guide

This document describes how to test the Strato Control Plane Helm chart.

## Automated Testing (CI/CD)

### GitHub Actions

The chart is automatically tested on every push and pull request via GitHub Actions (`.github/workflows/helm-test.yml`). The CI pipeline includes:

#### 1. Lint Job
- Helm chart syntax validation
- Dependency validation
- Chart structure verification

#### 2. Template Validation Job
- Template generation with different value sets
- YAML validation with kubeval
- Configuration scenario testing

#### 3. Integration Test Job
- Real Kubernetes deployment using kind
- Pod readiness verification
- Service connectivity testing
- Basic functionality validation

#### 4. Security Scan Job
- Security policy validation with Checkov
- Hardcoded secret detection
- RBAC permission review

#### 5. Upgrade Test Job
- Chart upgrade scenario testing
- Configuration migration validation
- Rollback functionality testing

### Test Coverage

The CI tests validate:
- ✅ Chart linting and syntax
- ✅ Template generation with various configurations
- ✅ Kubernetes resource validation
- ✅ Real deployment in kind cluster
- ✅ Database connectivity
- ✅ SpiceDB service availability
- ✅ Security best practices
- ✅ Chart upgrade scenarios

## Local Testing

### Prerequisites

Install required tools:

```bash
# Helm 3.8+
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# kubectl (optional, for real cluster testing)
# kind (optional, for local Kubernetes testing)
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind

# kubeval (optional, for template validation)
curl -L https://github.com/instrumenta/kubeval/releases/latest/download/kubeval-linux-amd64.tar.gz | tar xz
sudo mv kubeval /usr/local/bin
```

### Quick Test Script

Run the comprehensive test script:

```bash
./scripts/test-helm-chart.sh
```

This script performs all local validation tests automatically.

### Manual Testing Steps

#### 1. Basic Validation

```bash
# Add repositories
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Build dependencies
cd helm/strato-control-plane
helm dependency build

# Lint chart
helm lint .
```

#### 2. Template Validation

Test template generation with different configurations:

```bash
# Default configuration
helm template strato-test . > /tmp/default.yaml

# Production configuration
helm template strato-prod . -f ci/production-values.yaml > /tmp/production.yaml

# External database configuration
helm template strato-external . -f ci/external-db-values.yaml > /tmp/external.yaml

# Minimal configuration
helm template strato-minimal . -f ci/minimal-values.yaml > /tmp/minimal.yaml

# Validate generated YAML
kubeval /tmp/default.yaml
kubeval /tmp/production.yaml
kubeval /tmp/external.yaml
kubeval /tmp/minimal.yaml
```

#### 3. Local Kubernetes Testing

Using kind for local testing:

```bash
# Create kind cluster
kind create cluster --name strato-test

# Install chart
helm install strato-test . -f ci/default-values.yaml --wait --timeout=5m

# Verify deployment
kubectl get pods
kubectl get services
kubectl get secrets

# Test connectivity
kubectl port-forward svc/strato-test-postgresql 5432:5432 &
kubectl port-forward svc/strato-test-strato-control-plane-spicedb 8080:8080 &

# Cleanup
helm uninstall strato-test
kind delete cluster --name strato-test
```

## Test Configurations

### Available Test Value Files

| File | Purpose | Features Tested |
|------|---------|----------------|
| `ci/default-values.yaml` | Basic functionality | Standard deployment with all features |
| `ci/production-values.yaml` | Production readiness | High availability, security, monitoring |
| `ci/external-db-values.yaml` | External database | PostgreSQL disabled, external DB config |
| `ci/minimal-values.yaml` | Resource constraints | Minimal resources, disabled features |

### Configuration Scenarios

#### Scenario 1: Default Deployment
- PostgreSQL enabled
- SpiceDB enabled with schema
- Standard resource limits
- Basic security configuration

#### Scenario 2: Production Deployment
- High availability settings
- Enhanced security (NetworkPolicy)
- Monitoring enabled
- Production resource limits

#### Scenario 3: External Database
- PostgreSQL subchart disabled
- External database configuration
- Connection validation

#### Scenario 4: Minimal Resources
- Reduced resource requirements
- Optional features disabled
- Suitable for development/testing

## Security Testing

### Automated Security Checks

The CI pipeline includes security validation:

```bash
# Check for hardcoded secrets
grep -r "password.*:" templates/ | grep -v "secretKeyRef"

# Validate secret references
grep -r "secretKeyRef\|valueFrom" templates/

# Check security contexts
grep -r "securityContext\|runAsNonRoot" templates/
```

### Manual Security Review

1. **Secret Management**
   - Verify no hardcoded passwords
   - Confirm proper secret references
   - Check secret rotation capabilities

2. **Network Security**
   - Review NetworkPolicy rules
   - Validate service isolation
   - Check ingress/egress restrictions

3. **Pod Security**
   - Verify security contexts
   - Check for privileged containers
   - Validate resource limits

4. **RBAC**
   - Review ServiceAccount permissions
   - Check for minimal privilege principle
   - Validate role bindings

## Performance Testing

### Resource Usage

Monitor resource consumption during testing:

```bash
# Check resource requests/limits
helm template test . | grep -A 2 -B 2 "resources:"

# Monitor actual usage (in running cluster)
kubectl top pods
kubectl top nodes
```

### Load Testing

For performance testing in real deployments:

```bash
# Port forward to access application
kubectl port-forward svc/strato-test-strato-control-plane 8080:8080

# Use your preferred load testing tool
# Example with curl for basic testing
for i in {1..100}; do
  curl -s http://localhost:8080/health/live > /dev/null &
done
wait
```

## Troubleshooting Tests

### Common Test Failures

#### Template Generation Fails
- Check `Chart.yaml` syntax
- Verify `values.yaml` structure
- Ensure dependencies are built

#### Pod Start Failures
- Check resource availability
- Verify image availability
- Review init container logs

#### Connectivity Issues
- Validate service configurations
- Check NetworkPolicy rules
- Verify DNS resolution

### Debug Commands

```bash
# Chart debugging
helm template --debug test .
helm lint --debug .

# Deployment debugging
kubectl describe pod <pod-name>
kubectl logs <pod-name> --all-containers
kubectl get events --sort-by=.metadata.creationTimestamp

# Service debugging
kubectl get svc
kubectl describe svc <service-name>
kubectl port-forward svc/<service-name> <local-port>:<service-port>
```

## Test Environments

### CI Environment
- **Platform**: Ubuntu 22.04 (GitHub Actions)
- **Kubernetes**: kind v0.20.0 with Kubernetes v1.27.3
- **Resources**: 2 CPU, 7GB RAM
- **Duration**: ~10-15 minutes per full test suite

### Recommended Local Environment
- **Platform**: Linux/macOS/Windows with Docker
- **Kubernetes**: kind, minikube, or k3d
- **Resources**: Minimum 2 CPU, 4GB RAM
- **Duration**: ~5-10 minutes for full test suite

## Continuous Improvement

### Adding New Tests

When adding features to the chart:

1. Add corresponding test cases to `helm-test.yml`
2. Create test value files in `ci/` directory
3. Update this testing documentation
4. Verify tests pass in CI environment

### Test Maintenance

Regular maintenance tasks:
- Update test dependencies (Helm, kubectl, kind versions)
- Review and update security test policies
- Add tests for new configuration options
- Validate tests with different Kubernetes versions

## Reporting Issues

When reporting test failures:

1. Include full error output
2. Specify environment details (OS, Kubernetes version, Helm version)
3. Provide test configuration used
4. Include relevant logs and describe steps
5. Mention if issue is reproducible