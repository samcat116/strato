# ================================
# Build image - only for local builds
# ================================
FROM swift:6.3.2-noble AS build

# Check if we're using prebuilt artifacts
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

# Copy shared package first
COPY ./shared ./shared

# Copy control plane package files
COPY ./control-plane/Package.* ./control-plane/

# First just resolve dependencies.
WORKDIR /build/control-plane
# Update Package.swift to use absolute path for shared package in Docker
RUN sed -i 's|.package(path: "../shared")|.package(path: "/build/shared")|' Package.swift
# Resolving fetches all ~60 dependency checkouts purely to feed the compile,
# so skip it in prebuilt-artifacts mode where nothing is compiled here.
RUN if [ -z "$PREBUILT_ARTIFACTS" ]; then \
        swift package resolve \
            $([ -f ./Package.resolved ] && echo "--force-resolved-versions" || true); \
    fi

# Copy entire control-plane repo into container
WORKDIR /build/control-plane
COPY ./control-plane .

# Copy prebuilt artifacts if present. The [s] glob keeps plain
# `docker build -f control-plane/Dockerfile .` working when ./artifacts
# doesn't exist (a zero-match glob COPY succeeds and copies nothing).
COPY ./artifact[s] /build/artifacts/

# Build the application only if not using prebuilt artifacts
RUN if [ -z "$PREBUILT_ARTIFACTS" ]; then \
        swift build -c release --product App -Xlinker -ljemalloc; \
    fi

# Switch to the staging area
WORKDIR /staging

# If using prebuilt artifacts, copy them, otherwise copy from build
RUN if [ -n "$PREBUILT_ARTIFACTS" ]; then \
        echo "Using prebuilt artifacts mode"; \
        if [ -d "/build/artifacts/control-plane" ]; then \
            echo "Found prebuilt artifacts"; \
            # Copy binaries from bin/ subdirectory
            if [ -d "/build/artifacts/control-plane/bin" ]; then \
                cp /build/artifacts/control-plane/bin/* ./; \
            else \
                cp /build/artifacts/control-plane/App ./ 2>/dev/null || (echo "Error: App executable not found in artifacts"; exit 1); \
            fi; \
            # Copy resources if they exist
            ([ -d "/build/artifacts/control-plane/resources" ] && cp -R /build/artifacts/control-plane/resources/* ./ || true) && \
            ([ -d "/build/artifacts/control-plane/Resources" ] && cp -R /build/artifacts/control-plane/Resources ./ || true); \
        else \
            echo "Error: PREBUILT_ARTIFACTS specified but no artifacts found"; \
            exit 1; \
        fi; \
    else \
        echo "Building from source"; \
        cp "$(swift build --package-path /build/control-plane -c release --show-bin-path)/App" ./ && \
        (cp "/usr/lib/swift/linux/swift-backtrace-static" ./ 2>/dev/null || cp "/usr/libexec/swift/linux/swift-backtrace-static" ./ 2>/dev/null || echo "Warning: swift-backtrace-static not found") && \
        find -L "$(swift build --package-path /build/control-plane -c release --show-bin-path)/" -regex '.*\.resources$' -exec cp -Ra {} ./ \; && \
        ([ -d /build/control-plane/Resources ] && cp -R /build/control-plane/Resources ./ || true); \
    fi

# Ensure proper permissions
RUN chmod +x ./App && \
    chmod -R a-w ./Resources 2>/dev/null || true

# ================================
# Run image
# ================================
FROM ubuntu:noble

# OCI image labels. `image.source` links the GHCR package to this repo (and
# grants the publishing workflow its package permissions); description and
# licenses populate the package page. See
# https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#labelling-container-images
LABEL org.opencontainers.image.source="https://github.com/samcat116/strato"
LABEL org.opencontainers.image.title="strato-control-plane"
LABEL org.opencontainers.image.description="Strato control plane: API, scheduler, database, and authorization for the Strato private cloud platform."
LABEL org.opencontainers.image.licenses="FSL-1.1-MIT"

# Make sure all system packages are up to date, and install only essential packages.
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get -q install -y \
    libjemalloc2 \
    ca-certificates \
    tzdata \
    libcurl4 \
    && rm -r /var/lib/apt/lists/*

# Copy Swift runtime libraries from build stage
COPY --from=build /usr/lib/swift/linux/*.so /usr/lib/

# Create a vapor user and group with /app as its home directory
RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app vapor

# Switch to the new home directory
WORKDIR /app

# Copy built executable and any staged resources from builder
COPY --from=build --chown=vapor:vapor /staging /app

# Provide configuration needed by the built-in crash reporter and some sensible default behaviors.
ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static

# Build identity, surfaced on /health/* (see BuildInfo.swift). Pass via
# `docker build --build-arg STRATO_VERSION=... --build-arg STRATO_GIT_SHA=...`.
# Helm sets these directly in the Deployment env; defaults keep local builds honest.
ARG STRATO_VERSION="dev"
ARG STRATO_GIT_SHA="unknown"
ENV STRATO_VERSION=${STRATO_VERSION}
ENV STRATO_GIT_SHA=${STRATO_GIT_SHA}

# Ensure all further commands run as the vapor user
USER vapor:vapor

# Let Docker bind to port 8080
EXPOSE 8080

# Start the Vapor service when the image is run, default to listening on 8080 in production environment
ENTRYPOINT ["./App"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
