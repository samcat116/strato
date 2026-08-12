#!/usr/bin/env bash
# Control-plane-side SPIRE agent entrypoint.
#
# Waits for the bootstrap handoff (join token + trust bundle), writes the agent
# config, and runs spire-agent. Its only job is to serve Envoy's SDS: the
# control-plane server SVID (spiffe://strato.local/control-plane) and the trust
# bundle used to validate agent client certs. Attests Envoy by unix uid.
set -euo pipefail

TRUST_DOMAIN=strato.local
HANDOFF=/handoff
DATA_DIR=/var/lib/spire/agent
RUN_DIR=/run/spire/agent
SOCKET_DIR=/run/spire/agent/sockets
ADMIN_SOCKET=/var/run/spire/admin.sock
CONF="$RUN_DIR/agent.conf"

log() { echo "==> $*"; }

log "Waiting for bootstrap handoff at ${HANDOFF}/ready"
for _ in $(seq 1 120); do [ -f "$HANDOFF/ready" ] && break; sleep 1; done
[ -f "$HANDOFF/ready" ] || { echo "error: handoff never became ready" >&2; exit 1; }

mkdir -p "$DATA_DIR" "$SOCKET_DIR" "$RUN_DIR"
cp "$HANDOFF/bundle.pem" "$RUN_DIR/bundle.pem"
JOIN_TOKEN="$(cat "$HANDOFF/cp-agent-token")"

GUEST_IDENTITY_CONFIG=""
case "${ENABLE_GUEST_IDENTITY:-false}" in
  true|1)
    # Keep this root-only socket in the spire-agent container's filesystem. The
    # Compose file shares only SOCKET_DIR with Envoy; do not add ADMIN_SOCKET to
    # that volume or any other container.
    mkdir -p "$(dirname "$ADMIN_SOCKET")"
    chown root:root "$(dirname "$ADMIN_SOCKET")"
    chmod 0700 "$(dirname "$ADMIN_SOCKET")"
    GUEST_IDENTITY_CONFIG="$(cat <<EOF
    # SPIRE refuses an admin socket in or below the Workload API socket
    # directory. /run/spire/agent/sockets/admin.sock is therefore invalid.
    admin_socket_path = "$ADMIN_SOCKET"
    authorized_delegates = ["spiffe://${TRUST_DOMAIN}/control-plane"]
EOF
)"
    ;;
  false|0|"") ;;
  *)
    echo "error: ENABLE_GUEST_IDENTITY must be true or false" >&2
    exit 1
    ;;
esac

# discover_workload_path is off: we select Envoy by uid only, so there is no
# need to read the caller's executable path. Resolving the caller's uid still
# requires /proc access to its PID, which is why this agent runs with
# pid: host (see docker-compose.override.yml).
cat > "$CONF" <<EOF
agent {
    data_dir = "$DATA_DIR"
    log_level = "INFO"
    server_address = "spire-server"
    server_port = "8085"
    socket_path = "$SOCKET_DIR/workload.sock"
$GUEST_IDENTITY_CONFIG
    trust_domain = "$TRUST_DOMAIN"
    join_token = "$JOIN_TOKEN"
    trust_bundle_path = "$RUN_DIR/bundle.pem"

    sds {
        default_svid_name = "default"
        default_bundle_name = "ROOTCA"
    }
}

plugins {
    NodeAttestor "join_token" {}

    KeyManager "disk" {
        plugin_data {
            directory = "$DATA_DIR"
        }
    }

    WorkloadAttestor "unix" {
        plugin_data {
            discover_workload_path = false
        }
    }
}
EOF

log "Starting spire-agent (control-plane side)"
exec spire-agent run -config "$CONF"
