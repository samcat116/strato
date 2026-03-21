# SPIRE Agent Dockerfile for Strato Hypervisor Nodes
# Runs alongside Strato Agent to provide SVID identity

FROM ghcr.io/spiffe/spire-agent:1.9.6

# Create directories for data and workload socket
RUN mkdir -p /var/lib/spire/agent /var/run/spire/sockets

# Copy agent configuration
COPY agent.conf /etc/spire/agent/agent.conf

# Expose health check port
EXPOSE 8080

# Volume for workload API socket (shared with Strato Agent container)
VOLUME ["/var/run/spire/sockets"]

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD wget -q --spider http://localhost:8080/ready || exit 1

# Run SPIRE Agent
# Note: Join token should be passed via SPIRE_JOIN_TOKEN environment variable
ENTRYPOINT ["/opt/spire/bin/spire-agent", "run", "-config", "/etc/spire/agent/agent.conf"]
