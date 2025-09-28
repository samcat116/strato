# ================================
# Build image
# ================================
FROM swift:6.1.2-noble AS build

# Install OS updates
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get install -y libjemalloc-dev

# Set up a build area
WORKDIR /build

# Copy shared package first
COPY ./shared ./shared

# Copy agent package files
COPY ./agent/Package.* ./agent/

# First just resolve dependencies.
# This creates a cached layer that can be reused
# as long as your Package.swift/Package.resolved
# files do not change.
WORKDIR /build/agent
# Update Package.swift to use absolute path for shared package in Docker
RUN sed -i 's|.package(path: "../shared")|.package(path: "/build/shared")|' Package.swift
RUN swift package resolve \
    $([ -f ./Package.resolved ] && echo "--force-resolved-versions" || true)

# Copy entire agent repo into container
COPY ./agent .

# Build the application statically, with optimizations and using jemalloc
RUN swift build -c release \
    --product StratoAgent \
    -Xlinker -ljemalloc

# Switch to the staging area
WORKDIR /staging

# Copy main executable to staging area
RUN cp "$(swift build --package-path /build/agent -c release --show-bin-path)/StratoAgent" ./

# Copy static swift backtracer binary to staging area (try both possible locations)
RUN cp "/usr/lib/swift/linux/swift-backtrace-static" ./ 2>/dev/null || \
    cp "/usr/libexec/swift/linux/swift-backtrace-static" ./ 2>/dev/null || \
    echo "Warning: swift-backtrace-static not found"

# Copy resources bundled by SPM to staging area
RUN find -L "$(swift build --package-path /build/agent -c release --show-bin-path)/" -regex '.*\.resources$' -exec cp -Ra {} ./ \;

# ================================
# Run image
# ================================
FROM ubuntu:noble

# Make sure all system packages are up to date, and install QEMU and essential packages.
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get -q install -y \
    libjemalloc2 \
    ca-certificates \
    tzdata \
    socat \
    # QEMU and KVM for virtualization
    qemu-system-x86 \
    qemu-utils \
    # glib-2.0 development files for QEMUKit
    libglib2.0-0 \
    libglib2.0-dev \
    # OVN/OVS for software-defined networking
    ovn-central \
    ovn-host \
    ovn-common \
    openvswitch-switch \
    openvswitch-common \
    # If your app or its dependencies import FoundationNetworking, also install `libcurl4`.
    # libcurl4 \
    # If your app or its dependencies import FoundationXML, also install `libxml2`.
    # libxml2 \
    && rm -r /var/lib/apt/lists/*

# No need to copy Swift runtime libraries with static compilation

# Create a strato user and group with /app as its home directory
RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app strato

# Switch to the new home directory
WORKDIR /app

# Copy built executable and any staged resources from builder
COPY --from=build --chown=strato:strato /staging /app

# Provide configuration needed by the built-in crash reporter and some sensible default behaviors.
ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static

# Ensure all further commands run as the strato user
USER strato:strato

# Start the Strato Agent when the image is run
ENTRYPOINT ["./StratoAgent"]
CMD ["--control-plane-url", "ws://control-plane:8080/agent/ws", "--qemu-socket-dir", "/var/run/qemu"]