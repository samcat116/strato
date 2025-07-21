#!/bin/bash

# Script to prepare build context for Docker builds
# Ensures artifacts directory exists for both CI and local builds

set -e

echo "Preparing build context..."

# Create artifacts directory if it doesn't exist
mkdir -p ./artifacts

if [ -d "./artifacts/control-plane" ] && [ "$(ls -A ./artifacts/control-plane)" ]; then
    echo "✅ Found prebuilt artifacts, Docker will use them"
else
    echo "ℹ️  No prebuilt artifacts found, Docker will build from source"
fi

echo "Build context ready!"