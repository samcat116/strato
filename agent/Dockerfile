# ================================
# Build image
# ================================
FROM swift:6.3.2-noble AS build

# Set to the artifacts subdirectory (e.g. "artifacts/agent") when CI supplies
# a prebuilt release binary; skips the in-image Swift build.
ARG PREBUILT_ARTIFACTS=""

# Install OS updates + the jemalloc headers the release build links against.
# Skipped in prebuilt-artifacts mode: nothing is compiled in this stage then,
# so the build image only serves as the source of the Swift runtime .so files.
RUN if [ -z "$PREBUILT_ARTIFACTS" ]; then \
        export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
        && apt-get -q update \
        && apt-get -q dist-upgrade -y \
        && apt-get install -y libjemalloc-dev; \
    fi

# Set up a build area
WORKDIR /build

# Copy local path dependencies first
COPY ./shared ./shared
COPY ./SwiftFirecracker ./SwiftFirecracker

# Copy agent package files
COPY ./agent/Package.* ./agent/

# First just resolve dependencies.
# This creates a cached layer that can be reused
# as long as your Package.swift/Package.resolved
# files do not change.
WORKDIR /build/agent
# Update Package.swift to use absolute paths for local packages in Docker
RUN sed -i \
    -e 's|.package(path: "../shared")|.package(path: "/build/shared")|' \
    -e 's|.package(path: "../SwiftFirecracker")|.package(path: "/build/SwiftFirecracker")|' \
    Package.swift
# Resolving fetches all dependency checkouts (shared, SwiftFirecracker, and
# their transitive deps) purely to feed the compile, so skip it in
# prebuilt-artifacts mode where nothing is compiled here.
RUN if [ -z "$PREBUILT_ARTIFACTS" ]; then \
        swift package resolve \
            $([ -f ./Package.resolved ] && echo "--force-resolved-versions" || true); \
    fi

# Copy entire agent repo into container
COPY ./agent .

# Copy prebuilt artifacts if present. The [s] glob keeps plain
# `docker build -f agent/Dockerfile .` working when ./artifacts doesn't
# exist (a zero-match glob COPY succeeds and copies nothing).
COPY ./artifact[s] /build/artifacts/

# Build the application only if not using prebuilt artifacts
RUN if [ -z "$PREBUILT_ARTIFACTS" ]; then \
        swift build -c release --product StratoAgent -Xlinker -ljemalloc; \
    fi

# Switch to the staging area
WORKDIR /staging

# If using prebuilt artifacts, copy them, otherwise copy from build
RUN if [ -n "$PREBUILT_ARTIFACTS" ]; then \
        echo "Using prebuilt artifacts mode"; \
        if [ -d "/build/artifacts/agent/bin" ]; then \
            cp /build/artifacts/agent/bin/* ./; \
        else \
            echo "Error: PREBUILT_ARTIFACTS specified but no artifacts found"; \
            exit 1; \
        fi; \
        ([ -d "/build/artifacts/agent/resources" ] && cp -Ra /build/artifacts/agent/resources/* ./ || true); \
    else \
        echo "Building from source"; \
        cp "$(swift build --package-path /build/agent -c release --show-bin-path)/StratoAgent" ./ && \
        (cp "/usr/lib/swift/linux/swift-backtrace-static" ./ 2>/dev/null || \
         cp "/usr/libexec/swift/linux/swift-backtrace-static" ./ 2>/dev/null || \
         echo "Warning: swift-backtrace-static not found") && \
        find -L "$(swift build --package-path /build/agent -c release --show-bin-path)/" -regex '.*\.resources$' -exec cp -Ra {} ./ \; ; \
    fi

# CI artifact upload/download drops the execute bit
RUN chmod +x ./StratoAgent && \
    (chmod +x ./swift-backtrace-static 2>/dev/null || true)

# ================================
# Run image
# ================================
FROM ubuntu:noble

# OCI image labels. `image.source` links the GHCR package to this repo (and
# grants the publishing workflow its package permissions); description and
# licenses populate the package page. See
# https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#labelling-container-images
LABEL org.opencontainers.image.source="https://github.com/samcat116/strato"
LABEL org.opencontainers.image.title="strato-agent"
LABEL org.opencontainers.image.description="Strato agent: manages VMs on hypervisor nodes (QEMU, Firecracker) for the Strato private cloud platform."
LABEL org.opencontainers.image.licenses="FSL-1.1-MIT"

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
    # OVN/OVS for software-defined networking. Hypervisors run only the
    # chassis side (ovn-controller + OVS); the NB/SB/northd central is a
    # separate per-site deployment (deploy/ovn-central/), never this image.
    ovn-host \
    ovn-common \
    openvswitch-switch \
    openvswitch-common \
    # If your app or its dependencies import FoundationNetworking, also install `libcurl4`.
    # libcurl4 \
    # If your app or its dependencies import FoundationXML, also install `libxml2`.
    # libxml2 \
    && rm -r /var/lib/apt/lists/*

# The binary links the Swift runtime dynamically (same as the control-plane
# image), so copy the runtime libraries from the build stage.
COPY --from=build /usr/lib/swift/linux/*.so /usr/lib/

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