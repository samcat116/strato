# Small helper image: the two SPIRE binaries on a shell base.
#
# The official ghcr.io/spiffe/spire-{server,agent} images are distroless (no
# shell), so they can't run the bootstrap orchestration (mint a join token,
# create the control-plane workload entry, export the trust bundle) or a
# config-generating entrypoint. This image layers both static binaries onto a
# slim Debian base with bash + curl so one image serves the server, the
# one-shot bootstrap, and the control-plane-side agent.
FROM ghcr.io/spiffe/spire-server:1.9.6 AS server
FROM ghcr.io/spiffe/spire-agent:1.9.6 AS agent

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=server /opt/spire/bin/spire-server /opt/spire/bin/spire-server
COPY --from=agent  /opt/spire/bin/spire-agent  /opt/spire/bin/spire-agent
ENV PATH="/opt/spire/bin:${PATH}"
