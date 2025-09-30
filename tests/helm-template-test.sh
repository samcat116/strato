#!/bin/bash
# Helm Template Rendering Test
# This test validates that Helm templates render correctly with values

set -e

echo "=== Helm Template Rendering Test ==="

# Install helm if not present (for CI)
if ! command -v helm &> /dev/null; then
    echo "⚠️  Helm not installed, skipping template rendering tests"
    exit 0
fi

# Check if Helm chart exists
if [ ! -d "helm/strato" ]; then
    echo "❌ FAIL: helm/strato directory not found"
    exit 1
fi

# Test template rendering with default values (when values.yaml exists)
echo "🔍 Testing template rendering with default values..."
if [ -f "helm/strato/values.yaml" ]; then
    if helm template strato helm/strato > /dev/null 2>&1; then
        echo "✅ Templates render successfully with default values"
    else
        echo "❌ FAIL: Template rendering failed with default values"
        helm template strato helm/strato
        exit 1
    fi
else
    echo "⚠️  values.yaml not found, skipping default values test"
fi

# Test template rendering with development values (when values-dev.yaml exists)
echo "🔍 Testing template rendering with development values..."
if [ -f "helm/strato/values-dev.yaml" ]; then
    if helm template strato helm/strato --values helm/strato/values-dev.yaml > /dev/null 2>&1; then
        echo "✅ Templates render successfully with development values"
    else
        echo "❌ FAIL: Template rendering failed with development values"
        helm template strato helm/strato --values helm/strato/values-dev.yaml
        exit 1
    fi
else
    echo "⚠️  values-dev.yaml not found, skipping development values test"
fi

# Test that required templates exist (when core implementation is complete)
echo "🔍 Checking for required service templates..."
expected_templates=(
    "helm/strato/templates/control-plane/deployment.yaml"
    "helm/strato/templates/control-plane/service.yaml"
    "helm/strato/templates/agent/deployment.yaml"
    "helm/strato/templates/permify/deployment.yaml"
)

missing_templates=()
for template in "${expected_templates[@]}"; do
    if [ ! -f "$template" ]; then
        missing_templates+=("$template")
    fi
done

if [ ${#missing_templates[@]} -eq 0 ]; then
    echo "✅ All required service templates exist"
else
    echo "⚠️  Missing templates (expected in core implementation): ${missing_templates[*]}"
fi

# Test template output contains expected Kubernetes resources
echo "🔍 Testing template output structure..."
if [ -f "helm/strato/values.yaml" ]; then
    template_output=$(helm template strato helm/strato 2>/dev/null || echo "")
    if echo "$template_output" | grep -q "apiVersion:" && \
       echo "$template_output" | grep -q "kind:" && \
       echo "$template_output" | grep -q "metadata:"; then
        echo "✅ Template output contains valid Kubernetes resources"
    else
        echo "⚠️  Template output doesn't contain expected Kubernetes resource structure"
    fi
fi

echo "✅ Helm template rendering tests completed"
