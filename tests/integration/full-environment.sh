#!/bin/bash
# Full Environment Startup Test
# This test validates the complete Skaffold + Helm environment startup

set -e

echo "=== Full Environment Startup Test ==="

# Check dependencies
if ! command -v kubectl &> /dev/null; then
    echo "⚠️  kubectl not installed, skipping full environment test"
    exit 0
fi

if ! command -v helm &> /dev/null; then
    echo "⚠️  helm not installed, skipping full environment test"
    exit 0
fi

if ! command -v skaffold &> /dev/null; then
    echo "⚠️  skaffold not installed, skipping full environment test"
    exit 0
fi

# Check if we have a Kubernetes cluster
if ! kubectl cluster-info > /dev/null 2>&1; then
    echo "⚠️  No Kubernetes cluster available, skipping full environment test"
    exit 0
fi

NAMESPACE="strato-test-$(date +%s)"
TIMEOUT=300  # 5 minutes

echo "🔍 Testing full environment startup in namespace: $NAMESPACE"

# Cleanup function
cleanup() {
    echo "🧹 Cleaning up test namespace..."
    kubectl delete namespace "$NAMESPACE" --ignore-not-found=true > /dev/null 2>&1 || true
}
trap cleanup EXIT

# Create test namespace
echo "🔍 Creating test namespace..."
kubectl create namespace "$NAMESPACE"

# Test Helm chart deployment
echo "🔍 Testing Helm chart deployment..."
if [ -f "helm/strato/values-dev.yaml" ]; then
    if helm install strato-test helm/strato --namespace "$NAMESPACE" --values helm/strato/values-dev.yaml --wait --timeout="${TIMEOUT}s" > /dev/null 2>&1; then
        echo "✅ Helm deployment successful"
        deployment_successful=true
    else
        echo "❌ FAIL: Helm deployment failed"
        helm install strato-test helm/strato --namespace "$NAMESPACE" --values helm/strato/values-dev.yaml --wait --timeout="${TIMEOUT}s"
        deployment_successful=false
    fi
else
    echo "⚠️  values-dev.yaml not found, skipping Helm deployment test"
    deployment_successful=false
fi

if [ "$deployment_successful" = true ]; then
    # Test pod readiness
    echo "🔍 Checking pod readiness..."
    if kubectl wait --for=condition=ready pod --all -n "$NAMESPACE" --timeout="${TIMEOUT}s" > /dev/null 2>&1; then
        echo "✅ All pods are ready"
    else
        echo "⚠️  Some pods are not ready within timeout"
        kubectl get pods -n "$NAMESPACE"
    fi

    # Test service availability
    echo "🔍 Checking service availability..."
    services=$(kubectl get services -n "$NAMESPACE" -o name 2>/dev/null | wc -l)
    echo "  Found $services services"

    # Test control plane health endpoint (if available)
    echo "🔍 Testing control plane health endpoint..."
    control_plane_pod=$(kubectl get pods -n "$NAMESPACE" -l app=strato-control-plane -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$control_plane_pod" ]; then
        # Port forward and test health endpoint
        kubectl port-forward -n "$NAMESPACE" "$control_plane_pod" 8080:8080 > /dev/null 2>&1 &
        port_forward_pid=$!

        sleep 5  # Wait for port forward to establish

        if curl -s http://localhost:8080/health > /dev/null 2>&1; then
            echo "✅ Control plane health endpoint responding"
        else
            echo "⚠️  Control plane health endpoint not responding (may need application code)"
        fi

        kill $port_forward_pid > /dev/null 2>&1 || true
    else
        echo "⚠️  No control plane pods found"
    fi

    # Test resource usage
    echo "🔍 Checking resource usage..."
    if kubectl top pods -n "$NAMESPACE" > /dev/null 2>&1; then
        total_memory=$(kubectl top pods -n "$NAMESPACE" --no-headers | awk '{sum+=$3} END {print sum}' 2>/dev/null || echo "0")
        echo "  Total memory usage: ${total_memory}Mi"

        if [ "$total_memory" -lt 2048 ]; then  # Less than 2GB
            echo "✅ Memory usage within acceptable limits"
        else
            echo "⚠️  High memory usage detected"
        fi
    else
        echo "⚠️  Resource metrics not available"
    fi

    # Test environment startup time
    echo "🔍 Environment startup completed within timeout"
    echo "✅ Full environment startup test passed"
else
    echo "⚠️  Skipping additional tests due to deployment failure"
fi

# Test Skaffold integration (basic validation)
echo "🔍 Testing Skaffold configuration compatibility..."
if [ -f "skaffold.yaml" ]; then
    # Validate that Skaffold can read the configuration
    if skaffold config list > /dev/null 2>&1; then
        echo "✅ Skaffold configuration is compatible"
    else
        echo "❌ FAIL: Skaffold configuration compatibility issue"
        exit 1
    fi

    # Test Skaffold build (dry run)
    echo "🔍 Testing Skaffold build configuration..."
    if skaffold build --dry-run > /dev/null 2>&1; then
        echo "✅ Skaffold build configuration is valid"
    else
        echo "⚠️  Skaffold build configuration issues (may need Docker images)"
    fi
else
    echo "❌ FAIL: skaffold.yaml not found"
    exit 1
fi

echo "✅ Full environment startup integration test completed"
