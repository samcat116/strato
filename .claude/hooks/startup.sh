#!/bin/bash
# Claude Code startup hook for Strato repository
# This hook installs Swift and other dependencies in the Claude remote environment

set -e

# Only run in Claude remote environment (web)
if [ "$CLAUDE_CODE_REMOTE" != "true" ]; then
    echo "Not running in Claude remote environment, skipping dependency installation"
    exit 0
fi

echo "=== Claude Code Remote Environment Detected ==="
echo "Installing Swift and dependencies for Strato..."

# Check if Swift is already installed
if command -v swift &> /dev/null; then
    SWIFT_VERSION=$(swift --version | head -n 1)
    echo "Swift already installed: $SWIFT_VERSION"
    exit 0
fi

# Update package lists
echo "Updating package lists..."
apt-get update -qq

# Install system dependencies needed for Swift
echo "Installing system dependencies..."
apt-get install -y -qq \
    binutils \
    git \
    gnupg2 \
    libc6-dev \
    libcurl4-openssl-dev \
    libedit2 \
    libsqlite3-0 \
    libxml2 \
    libz3-4 \
    pkg-config \
    tzdata \
    unzip \
    zlib1g-dev \
    libssl-dev \
    libsqlite3-dev \
    libncurses6 \
    libpython3.12 \
    wget \
    ca-certificates

# Install Swift 6.0 (latest stable version as of knowledge cutoff)
echo "Installing Swift 6.0..."
SWIFT_VERSION="6.0.2"
SWIFT_PLATFORM="ubuntu22.04"
SWIFT_PLATFORM_DIR="ubuntu2204"
SWIFT_PACKAGE="swift-${SWIFT_VERSION}-RELEASE-${SWIFT_PLATFORM}"

# Download Swift
cd /tmp
wget -q "https://download.swift.org/swift-${SWIFT_VERSION}-release/${SWIFT_PLATFORM_DIR}/swift-${SWIFT_VERSION}-RELEASE/${SWIFT_PACKAGE}.tar.gz"

# Extract Swift
tar xzf "${SWIFT_PACKAGE}.tar.gz" -C /opt

# Create symlinks
ln -sf "/opt/${SWIFT_PACKAGE}/usr/bin/swift" /usr/local/bin/swift
ln -sf "/opt/${SWIFT_PACKAGE}/usr/bin/swiftc" /usr/local/bin/swiftc
ln -sf "/opt/${SWIFT_PACKAGE}/usr/bin/swift-package" /usr/local/bin/swift-package

# Cleanup
rm "${SWIFT_PACKAGE}.tar.gz"

# Verify installation
echo "Verifying Swift installation..."
swift --version

echo "=== Swift and dependencies installed successfully ==="
