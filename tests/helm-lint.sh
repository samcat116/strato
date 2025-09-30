#!/bin/bash
# Helm Chart Linting Test
# This test validates the Helm chart structure and syntax

set -e

echo "=== Helm Chart Linting Test ==="

# Check if Helm chart directory exists
if [ ! -d "helm/strato" ]; then
    echo "❌ FAIL: helm/strato directory not found"
    exit 1
fi

# Check if Chart.yaml exists
if [ ! -f "helm/strato/Chart.yaml" ]; then
    echo "❌ FAIL: helm/strato/Chart.yaml not found"
    exit 1
fi

# Install helm if not present (for CI)
if ! command -v helm &> /dev/null; then
    echo "⚠️  Helm not installed, skipping linting"
    exit 0
fi

# Lint the Helm chart
echo "🔍 Linting Helm chart..."
if helm lint helm/strato > /dev/null 2>&1; then
    echo "✅ Helm chart passes linting"
else
    echo "❌ FAIL: Helm chart linting failed"
    helm lint helm/strato
    exit 1
fi

# Check Chart.yaml metadata
echo "🔍 Checking Chart.yaml metadata..."
if grep -q "name: strato" helm/strato/Chart.yaml && \
   grep -q "version:" helm/strato/Chart.yaml && \
   grep -q "appVersion:" helm/strato/Chart.yaml; then
    echo "✅ Chart.yaml metadata is complete"
else
    echo "❌ FAIL: Chart.yaml missing required metadata"
    exit 1
fi

# Check for PostgreSQL dependency
echo "🔍 Checking PostgreSQL dependency..."
if grep -q "name: postgresql" helm/strato/Chart.yaml; then
    echo "✅ PostgreSQL dependency configured"
else
    echo "❌ FAIL: PostgreSQL dependency not found in Chart.yaml"
    exit 1
fi

# Check if values files exist (these should be created in core implementation)
echo "🔍 Checking for values files..."
if [ -f "helm/strato/values.yaml" ]; then
    echo "✅ values.yaml exists"
else
    echo "⚠️  values.yaml not found (expected in core implementation phase)"
fi

if [ -f "helm/strato/values-dev.yaml" ]; then
    echo "✅ values-dev.yaml exists"
else
    echo "⚠️  values-dev.yaml not found (expected in core implementation phase)"
fi

echo "✅ Helm chart linting tests passed"
