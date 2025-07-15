# ================================
# Build image - only for local builds
# ================================
FROM swift:6.1.2-noble AS build

# Check if we're using prebuilt artifacts
ARG PREBUILT_ARTIFACTS=""

# Install OS updates and Node.js for TailwindCSS
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get install -y libjemalloc-dev curl \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs

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
RUN swift package resolve \
    $([ -f ./Package.resolved ] && echo "--force-resolved-versions" || true)

# Copy package.json and package-lock.json for npm dependencies
COPY ./control-plane/package*.json ./

# Install npm dependencies (including devDependencies for TailwindCSS)
RUN npm ci

# Copy entire control-plane repo into container
COPY ./control-plane .

# Build TailwindCSS
RUN npm run build-css-prod

# Build the application only if not using prebuilt artifacts
RUN if [ -z "$PREBUILT_ARTIFACTS" ]; then \
        swift build -c release --product App -Xlinker -ljemalloc; \
    fi

# Switch to the staging area
WORKDIR /staging

# If using prebuilt artifacts, copy them, otherwise copy from build
RUN if [ -n "$PREBUILT_ARTIFACTS" ]; then \
        cp -R /build/$PREBUILT_ARTIFACTS/* ./; \
    else \
        cp "$(swift build --package-path /build/control-plane -c release --show-bin-path)/App" ./ && \
        cp "/usr/libexec/swift/linux/swift-backtrace-static" ./ && \
        find -L "$(swift build --package-path /build/control-plane -c release --show-bin-path)/" -regex '.*\.resources$' -exec cp -Ra {} ./ \; && \
        ([ -d /build/control-plane/Public ] && cp -R /build/control-plane/Public ./ || true) && \
        ([ -d /build/control-plane/Resources ] && cp -R /build/control-plane/Resources ./ || true); \
    fi

# Ensure proper permissions
RUN chmod -R a-w ./Public 2>/dev/null || true && \
    chmod -R a-w ./Resources 2>/dev/null || true

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
    # If your app or its dependencies import FoundationNetworking, also install `libcurl4`.
    # libcurl4 \
    # If your app or its dependencies import FoundationXML, also install `libxml2`.
    # libxml2 \
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

# Ensure all further commands run as the vapor user
USER vapor:vapor

# Let Docker bind to port 8080
EXPOSE 8080

# Start the Vapor service when the image is run, default to listening on 8080 in production environment
ENTRYPOINT ["./App"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
