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
COPY ../shared ./shared

# First just resolve dependencies.
# This creates a cached layer that can be reused
# as long as your Package.swift/Package.resolved
# files do not change.
COPY ./Package.* ./
RUN swift package resolve \
    $([ -f ./Package.resolved ] && echo "--force-resolved-versions" || true)

# Copy entire agent repo into container
COPY . .

# Build the application, with optimizations and using jemalloc
RUN swift build -c release \
    --product StratoAgent \
    -Xlinker -ljemalloc

# Switch to the staging area
WORKDIR /staging

# Copy main executable to staging area
RUN cp "$(swift build --package-path /build -c release --show-bin-path)/StratoAgent" ./

# Copy static swift backtracer binary to staging area
RUN cp "/usr/libexec/swift/linux/swift-backtrace-static" ./

# Copy resources bundled by SPM to staging area
RUN find -L "$(swift build --package-path /build -c release --show-bin-path)/" -regex '.*\.resources$' -exec cp -Ra {} ./ \;

# ================================
# Run image
# ================================
FROM ubuntu:noble

# Make sure all system packages are up to date, and install only essential packages.
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get -q install -y \
    libjemalloc2 \
    ca-certificates \
    tzdata \
    socat \
    # If your app or its dependencies import FoundationNetworking, also install `libcurl4`.
    # libcurl4 \
    # If your app or its dependencies import FoundationXML, also install `libxml2`.
    # libxml2 \
    && rm -r /var/lib/apt/lists/*

# Copy Swift runtime libraries from build stage
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
CMD ["--control-plane-url", "ws://control-plane:8080/agent/ws", "--hypervisor-socket", "/var/run/cloud-hypervisor/cloud-hypervisor.sock"]