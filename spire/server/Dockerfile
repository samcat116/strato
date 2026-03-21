# SPIRE Server Dockerfile for Strato
# Based on official SPIRE image with custom configuration

FROM ghcr.io/spiffe/spire-server:1.9.6

# Create directories for data and keys
RUN mkdir -p /var/lib/spire/server/keys

# Copy server configuration
COPY server.conf /etc/spire/server/server.conf

# Expose ports
# 8081 - SPIRE Server API (gRPC)
# 8080 - Health checks
# 8443 - Federation bundle endpoint
EXPOSE 8081 8080 8443

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q --spider http://localhost:8080/ready || exit 1

# Run SPIRE Server
ENTRYPOINT ["/opt/spire/bin/spire-server", "run", "-config", "/etc/spire/server/server.conf"]
