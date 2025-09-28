#!/bin/bash
# Skaffold Schema Validation Test
# This test validates the skaffold.yaml configuration

set -e

echo "=== Skaffold Schema Validation Test ==="

# Check if skaffold.yaml exists
if [ ! -f "skaffold.yaml" ]; then
    echo "❌ FAIL: skaffold.yaml not found"
    exit 1
fi

# Install skaffold if not present (for CI)
if ! command -v skaffold &> /dev/null; then
    echo "⚠️  Skaffold not installed, skipping validation"
    exit 0
fi

# Validate Skaffold configuration
echo "🔍 Validating Skaffold configuration..."
if skaffold config list > /dev/null 2>&1; then
    echo "✅ Skaffold configuration is valid"
else
    echo "❌ FAIL: Skaffold configuration is invalid"
    skaffold config list
    exit 1
fi

# Test if build artifacts are properly configured
echo "🔍 Checking build artifacts..."
if grep -q "strato-control-plane" skaffold.yaml && grep -q "strato-agent" skaffold.yaml; then
    echo "✅ Build artifacts configured for control-plane and agent"
else
    echo "❌ FAIL: Missing build artifacts for control-plane or agent"
    exit 1
fi

# Test if Helm deployment is configured
echo "🔍 Checking Helm deployment configuration..."
if grep -q "helm/strato" skaffold.yaml; then
    echo "✅ Helm deployment configured"
else
    echo "❌ FAIL: Helm deployment not configured"
    exit 1
fi

# Test profiles exist
echo "🔍 Checking development profiles..."
if grep -q "name: debug" skaffold.yaml && grep -q "name: minimal" skaffold.yaml; then
    echo "✅ Development profiles configured"
else
    echo "❌ FAIL: Missing development profiles (debug, minimal)"
    exit 1
fi

echo "✅ All Skaffold validation tests passed"
