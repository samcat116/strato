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

# Swift toolchain version. Must be >= the swift-tools-version in the package
# manifests (6.2); pinned to match the swift:6.3.2-noble container CI builds in.
SWIFT_VERSION="6.3.2"

# Check if a new enough Swift is already installed. A preinstalled older
# toolchain can't build the packages, so fall through and install ours.
if command -v swift &> /dev/null; then
    INSTALLED_VERSION=$(swift --version | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -n 1)
    if [ -n "$INSTALLED_VERSION" ] \
        && [ "$(printf '%s\n%s\n' "$SWIFT_VERSION" "$INSTALLED_VERSION" | sort -V | head -n 1)" = "$SWIFT_VERSION" ]; then
        echo "Swift already installed: $INSTALLED_VERSION (>= $SWIFT_VERSION)"
        exit 0
    fi
    echo "Installed Swift ${INSTALLED_VERSION:-unknown} is older than $SWIFT_VERSION; installing $SWIFT_VERSION..."
fi

# Resolve the host Ubuntu release and architecture so we fetch a matching
# toolchain rather than assuming 22.04/x86_64.
UBUNTU_VERSION_ID=$(. /etc/os-release && echo "$VERSION_ID")
case "$UBUNTU_VERSION_ID" in
    24.04) SWIFT_PLATFORM="ubuntu24.04"; SWIFT_PLATFORM_DIR="ubuntu2404"; PYTHON_LIB="libpython3.12" ;;
    22.04) SWIFT_PLATFORM="ubuntu22.04"; SWIFT_PLATFORM_DIR="ubuntu2204"; PYTHON_LIB="libpython3.10" ;;
    *)
        echo "Unsupported Ubuntu release '$UBUNTU_VERSION_ID'; expected 22.04 or 24.04" >&2
        exit 1
        ;;
esac

case "$(uname -m)" in
    x86_64) ;;
    aarch64) SWIFT_PLATFORM="${SWIFT_PLATFORM}-aarch64"; SWIFT_PLATFORM_DIR="${SWIFT_PLATFORM_DIR}-aarch64" ;;
    *)
        echo "Unsupported architecture '$(uname -m)'; expected x86_64 or aarch64" >&2
        exit 1
        ;;
esac

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
    "$PYTHON_LIB" \
    wget \
    ca-certificates

echo "Installing Swift ${SWIFT_VERSION} (${SWIFT_PLATFORM})..."
SWIFT_PACKAGE="swift-${SWIFT_VERSION}-RELEASE-${SWIFT_PLATFORM}"

# Download Swift
cd /tmp
wget -q "https://download.swift.org/swift-${SWIFT_VERSION}-release/${SWIFT_PLATFORM_DIR}/swift-${SWIFT_VERSION}-RELEASE/${SWIFT_PACKAGE}.tar.gz"

# Extract Swift
tar xzf "${SWIFT_PACKAGE}.tar.gz" -C /opt

# Symlink the whole toolchain bin directory, not just swift/swiftc: `swift
# format` (CI-enforced lint) and the other `swift-*` subcommand binaries have to
# be on PATH too.
for tool in "/opt/${SWIFT_PACKAGE}/usr/bin/"*; do
    ln -sf "$tool" "/usr/local/bin/$(basename "$tool")"
done

# Cleanup
rm "${SWIFT_PACKAGE}.tar.gz"

# Verify installation
echo "Verifying Swift installation..."
swift --version

echo "=== Swift and dependencies installed successfully ==="
