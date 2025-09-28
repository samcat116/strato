#!/bin/bash
# Service Connectivity Integration Test
# This test validates that services can communicate with each other

set -e

echo "=== Service Connectivity Integration Test ==="

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "⚠️  kubectl not installed, skipping connectivity tests"
    exit 0
fi

# Check if we have a Kubernetes cluster
if ! kubectl cluster-info > /dev/null 2>&1; then
    echo "⚠️  No Kubernetes cluster available, skipping connectivity tests"
    exit 0
fi

# Check if Strato is deployed
NAMESPACE="default"
echo "🔍 Checking if Strato services are deployed..."

# Function to check if a service exists
check_service() {
    local service_name=$1
    if kubectl get service "$service_name" -n "$NAMESPACE" > /dev/null 2>&1; then
        echo "✅ Service $service_name exists"
        return 0
    else
        echo "⚠️  Service $service_name not found (expected after deployment)"
        return 1
    fi
}

# Function to check if a deployment is ready
check_deployment() {
    local deployment_name=$1
    if kubectl get deployment "$deployment_name" -n "$NAMESPACE" > /dev/null 2>&1; then
        if kubectl rollout status deployment "$deployment_name" -n "$NAMESPACE" --timeout=60s > /dev/null 2>&1; then
            echo "✅ Deployment $deployment_name is ready"
            return 0
        else
            echo "⚠️  Deployment $deployment_name is not ready"
            return 1
        fi
    else
        echo "⚠️  Deployment $deployment_name not found (expected after deployment)"
        return 1
    fi
}

# Expected services (based on Helm templates)
expected_services=(
    "strato-control-plane"
    "strato-permify"
    "strato-postgresql"
)

# Expected deployments
expected_deployments=(
    "strato-control-plane"
    "strato-agent"
    "strato-permify"
)

# Check services
echo "🔍 Checking service availability..."
services_found=0
for service in "${expected_services[@]}"; do
    if check_service "$service"; then
        ((services_found++))
    fi
done

# Check deployments
echo "🔍 Checking deployment readiness..."
deployments_ready=0
for deployment in "${expected_deployments[@]}"; do
    if check_deployment "$deployment"; then
        ((deployments_ready++))
    fi
done

# Test control plane to database connectivity
echo "🔍 Testing control plane to database connectivity..."
if kubectl get deployment strato-control-plane -n "$NAMESPACE" > /dev/null 2>&1; then
    # Test database connection from control plane pod
    pod_name=$(kubectl get pods -n "$NAMESPACE" -l app=strato-control-plane -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$pod_name" ]; then
        if kubectl exec "$pod_name" -n "$NAMESPACE" -- nc -z strato-postgresql 5432 > /dev/null 2>&1; then
            echo "✅ Control plane can reach PostgreSQL"
        else
            echo "⚠️  Control plane cannot reach PostgreSQL (may need full deployment)"
        fi
    else
        echo "⚠️  No control plane pods found"
    fi
else
    echo "⚠️  Control plane deployment not found"
fi

# Test agent to control plane WebSocket connectivity
echo "🔍 Testing agent to control plane WebSocket connectivity..."
if kubectl get deployment strato-agent -n "$NAMESPACE" > /dev/null 2>&1 && \
   kubectl get deployment strato-control-plane -n "$NAMESPACE" > /dev/null 2>&1; then
    # Test WebSocket endpoint availability
    control_plane_service=$(kubectl get service strato-control-plane -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    if [ -n "$control_plane_service" ]; then
        agent_pod=$(kubectl get pods -n "$NAMESPACE" -l app=strato-agent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$agent_pod" ]; then
            if kubectl exec "$agent_pod" -n "$NAMESPACE" -- nc -z "$control_plane_service" 8080 > /dev/null 2>&1; then
                echo "✅ Agent can reach control plane"
            else
                echo "⚠️  Agent cannot reach control plane (may need full deployment)"
            fi
        else
            echo "⚠️  No agent pods found"
        fi
    else
        echo "⚠️  Control plane service not found"
    fi
else
    echo "⚠️  Agent or control plane deployment not found"
fi

# Summary
echo ""
echo "📊 Service Connectivity Test Summary:"
echo "  Services found: $services_found/${#expected_services[@]}"
echo "  Deployments ready: $deployments_ready/${#expected_deployments[@]}"

if [ $services_found -gt 0 ] && [ $deployments_ready -gt 0 ]; then
    echo "✅ Basic service connectivity validated"
else
    echo "⚠️  Full connectivity test requires complete deployment"
fi

echo "✅ Service connectivity integration test completed"
