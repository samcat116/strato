#!/usr/bin/env bash
# strato-node-bootstrap — one-command hypervisor node bootstrap.
#
# Takes the output of "Create Registration Token" (the bootstrapCommand field
# renders exactly this invocation) and brings up a fully attested node:
#
#   1. writes a spire-agent config with the one-time join token,
#   2. starts spire-agent (systemd unit when available) and waits for the
#      Workload API socket,
#   3. writes /etc/strato/config.toml with [spiffe] enabled,
#   4. joins the control plane with `strato-agent join <registration-url>`
#      (systemd unit when available).
#
# The join token is single-use: spire-agent redeems it for the node identity
# on first attestation and uses its own SVID from then on.
#
# Usage:
#   sudo strato-node-bootstrap \
#     --registration-url 'wss://cp.example.com:8443/agent/ws?token=...&name=node-a' \
#     --spire-join-token '...' \
#     --spire-server-address 'cp.example.com:8085' \
#     --trust-domain 'strato.local'
#
# Optional:
#   --trust-bundle <path>     SPIRE server trust bundle PEM. Without it the
#                             agent uses insecure_bootstrap (TOFU) — fine for
#                             labs, not for hostile networks.
#   --spire-agent-bin <path>  Defaults to spire-agent on PATH.
#   --strato-agent-bin <path> Defaults to strato-agent on PATH.
#   --no-systemd              Run both agents in the background via nohup
#                             instead of installing systemd units.

set -euo pipefail

REGISTRATION_URL=""
JOIN_TOKEN=""
SPIRE_SERVER_ADDRESS=""
TRUST_DOMAIN="strato.local"
TRUST_BUNDLE=""
SPIRE_AGENT_BIN=""
STRATO_AGENT_BIN=""
USE_SYSTEMD=1

SPIRE_CONF_DIR=/etc/spire
SPIRE_DATA_DIR=/var/lib/spire/agent
SPIRE_SOCKET_DIR=/var/run/spire/sockets
SPIRE_SOCKET="$SPIRE_SOCKET_DIR/workload.sock"
STRATO_CONF_DIR=/etc/strato

log() { echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --registration-url)     REGISTRATION_URL="$2"; shift 2 ;;
    --spire-join-token)     JOIN_TOKEN="$2"; shift 2 ;;
    --spire-server-address) SPIRE_SERVER_ADDRESS="$2"; shift 2 ;;
    --trust-domain)         TRUST_DOMAIN="$2"; shift 2 ;;
    --trust-bundle)         TRUST_BUNDLE="$2"; shift 2 ;;
    --spire-agent-bin)      SPIRE_AGENT_BIN="$2"; shift 2 ;;
    --strato-agent-bin)     STRATO_AGENT_BIN="$2"; shift 2 ;;
    --no-systemd)           USE_SYSTEMD=0; shift ;;
    -h|--help)              grep '^#' "$0" | cut -c 3-; exit 0 ;;
    *)                      die "unknown option: $1 (see --help)" ;;
  esac
done

[ -n "$REGISTRATION_URL" ] || die "--registration-url is required"
[ -n "$JOIN_TOKEN" ] || die "--spire-join-token is required"
[ -n "$SPIRE_SERVER_ADDRESS" ] || die "--spire-server-address is required"
[ "$(id -u)" -eq 0 ] || die "must run as root (writes /etc, manages services)"

SPIRE_AGENT_BIN="${SPIRE_AGENT_BIN:-$(command -v spire-agent || true)}"
[ -n "$SPIRE_AGENT_BIN" ] || die "spire-agent not found on PATH (install it or pass --spire-agent-bin)"
STRATO_AGENT_BIN="${STRATO_AGENT_BIN:-$(command -v strato-agent || true)}"
[ -n "$STRATO_AGENT_BIN" ] || die "strato-agent not found on PATH (install it or pass --strato-agent-bin)"

SPIRE_SERVER_HOST="${SPIRE_SERVER_ADDRESS%:*}"
SPIRE_SERVER_PORT="${SPIRE_SERVER_ADDRESS##*:}"
[ "$SPIRE_SERVER_HOST" != "$SPIRE_SERVER_PORT" ] || die "--spire-server-address must be host:port"

# The agent config requires a top-level control_plane_url; derive it from the
# registration URL by stripping the token/name query.
CONTROL_PLANE_URL="${REGISTRATION_URL%%\?*}"
case "$CONTROL_PLANE_URL" in
  ws://*|wss://*) ;;
  *) die "--registration-url must start with ws:// or wss://" ;;
esac

if command -v systemctl >/dev/null 2>&1 && [ "$USE_SYSTEMD" -eq 1 ]; then
  HAVE_SYSTEMD=1
else
  HAVE_SYSTEMD=0
fi

# --- spire-agent -------------------------------------------------------------

mkdir -p "$SPIRE_CONF_DIR" "$SPIRE_DATA_DIR" "$SPIRE_SOCKET_DIR" "$STRATO_CONF_DIR"

if [ -n "$TRUST_BUNDLE" ]; then
  [ -f "$TRUST_BUNDLE" ] || die "trust bundle not found: $TRUST_BUNDLE"
  cp "$TRUST_BUNDLE" "$SPIRE_CONF_DIR/bundle.pem"
  BOOTSTRAP_LINE='trust_bundle_path = "'"$SPIRE_CONF_DIR"'/bundle.pem"'
else
  log "No --trust-bundle given; using insecure_bootstrap (trust-on-first-use)"
  BOOTSTRAP_LINE='insecure_bootstrap = true'
fi

log "Writing $SPIRE_CONF_DIR/agent.conf"
cat > "$SPIRE_CONF_DIR/agent.conf" << EOF
agent {
    data_dir = "$SPIRE_DATA_DIR"
    log_level = "INFO"
    server_address = "$SPIRE_SERVER_HOST"
    server_port = "$SPIRE_SERVER_PORT"
    socket_path = "$SPIRE_SOCKET"
    trust_domain = "$TRUST_DOMAIN"
    # Single-use: redeemed on first attestation, ignored once this node has
    # its SVID. Re-provision with a fresh token if the node is wiped.
    join_token = "$JOIN_TOKEN"
    $BOOTSTRAP_LINE
}

plugins {
    NodeAttestor "join_token" {}

    KeyManager "disk" {
        plugin_data {
            directory = "$SPIRE_DATA_DIR"
        }
    }

    WorkloadAttestor "unix" {
        plugin_data {
            discover_workload_path = true
        }
    }
}
EOF
chmod 600 "$SPIRE_CONF_DIR/agent.conf"

if [ "$HAVE_SYSTEMD" -eq 1 ]; then
  log "Installing spire-agent.service"
  cat > /etc/systemd/system/spire-agent.service << EOF
[Unit]
Description=SPIRE Agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$SPIRE_AGENT_BIN run -config $SPIRE_CONF_DIR/agent.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now spire-agent.service
else
  log "Starting spire-agent in the background (no systemd)"
  nohup "$SPIRE_AGENT_BIN" run -config "$SPIRE_CONF_DIR/agent.conf" \
    >> /var/log/spire-agent.log 2>&1 &
fi

log "Waiting for the Workload API socket at $SPIRE_SOCKET"
for _ in $(seq 1 30); do
  if [ -S "$SPIRE_SOCKET" ]; then break; fi
  sleep 1
done
[ -S "$SPIRE_SOCKET" ] || die "spire-agent did not create $SPIRE_SOCKET within 30s (join token expired or SPIRE server unreachable?)"

# --- strato-agent ------------------------------------------------------------

if [ ! -f "$STRATO_CONF_DIR/config.toml" ]; then
  log "Writing $STRATO_CONF_DIR/config.toml"
  cat > "$STRATO_CONF_DIR/config.toml" << EOF
control_plane_url = "$CONTROL_PLANE_URL"

[spiffe]
enabled = true
trust_domain = "$TRUST_DOMAIN"
workload_api_socket_path = "$SPIRE_SOCKET"
source_type = "workload_api"
EOF
else
  log "$STRATO_CONF_DIR/config.toml already exists; leaving it in place (ensure control_plane_url and [spiffe] are set)"
fi

if [ "$HAVE_SYSTEMD" -eq 1 ]; then
  log "Installing strato-agent.service"
  # The service runs in plain `run` mode: after the initial join below, the
  # agent reconnects with its persisted rotated credential — never with the
  # single-use registration token, which is spent by then.
  cat > /etc/systemd/system/strato-agent.service << EOF
[Unit]
Description=Strato Agent
After=network-online.target spire-agent.service
Wants=network-online.target
Requires=spire-agent.service

[Service]
ExecStart=$STRATO_AGENT_BIN run --config-file $STRATO_CONF_DIR/config.toml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload

  STATE_FILE=/var/lib/strato/agent-state.json
  JOIN_LOG=/var/log/strato-agent-join.log
  if [ -f "$STATE_FILE" ]; then
    log "Join state already present at $STATE_FILE; skipping registration"
  else
    # `join` registers and then keeps running as the agent. Run it just long
    # enough to see registration confirmed, then hand off to the systemd
    # unit. The confirmation signal is the agent's "Registration complete"
    # log line, which fires on both auth paths — over mTLS the control plane
    # deliberately mints no reconnect token, so no state file appears (the
    # SVID is the reconnect credential).
    log "Joining the control plane"
    : > "$JOIN_LOG"
    "$STRATO_AGENT_BIN" join --config-file "$STRATO_CONF_DIR/config.toml" "$REGISTRATION_URL" \
      >> "$JOIN_LOG" 2>&1 &
    JOIN_PID=$!
    for _ in $(seq 1 60); do
      if grep -q "Registration complete" "$JOIN_LOG" 2>/dev/null; then break; fi
      if ! kill -0 "$JOIN_PID" 2>/dev/null; then
        die "strato-agent join exited before registering; see $JOIN_LOG"
      fi
      sleep 1
    done
    if ! grep -q "Registration complete" "$JOIN_LOG" 2>/dev/null; then
      kill "$JOIN_PID" 2>/dev/null || true
      die "registration did not complete within 60s; see $JOIN_LOG"
    fi
    kill "$JOIN_PID" 2>/dev/null || true
    wait "$JOIN_PID" 2>/dev/null || true
  fi

  systemctl enable --now strato-agent.service
  log "Done. Follow along with: journalctl -fu strato-agent"
else
  log "Joining the control plane (foreground; Ctrl-C stops the agent)"
  exec "$STRATO_AGENT_BIN" join --config-file "$STRATO_CONF_DIR/config.toml" "$REGISTRATION_URL"
fi
