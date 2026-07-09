#!/usr/bin/env bash
# strato-agent install.sh — one-command hypervisor node install.
#
# Downloads the strato-agent release binary for this host, installs the host
# dependencies it needs (QEMU, and OVN/OVS for SDN networking), installs a
# systemd unit, and — when given a registration URL — joins a control plane.
# Designed to be curled and piped:
#
#   curl -fsSL https://raw.githubusercontent.com/samcat116/strato/main/deploy/agent/install.sh \
#     | sudo bash -s -- --registration-url 'wss://cp.example.com/agent/ws?token=...&name=hv-01'
#
# The registration URL comes from the Strato UI (Agents -> Create Registration
# Token). Without --registration-url the script installs the binary, deps, and
# systemd unit but does not join — run `strato-agent join <url>` yourself, or
# re-run this script with the URL, when you have a token.
#
# Flags:
#   --registration-url URL   Join the control plane after install (single-use token URL)
#   --version VERSION        Release tag to install (default: latest)
#   --repo OWNER/NAME        GitHub repository to fetch from (default: samcat116/strato)
#   --bin-dir DIR            Where to install the binary (default: /usr/local/bin)
#   --network-mode MODE      ovn | user — which deps to install/require (default: ovn)
#   --strato-agent-bin PATH  Use an existing binary instead of downloading one
#   --no-deps                Do not install host packages (still checks them)
#   --no-systemd             Do not install/enable the systemd unit
#   --skip-preflight         Skip the host dependency summary
#   -h, --help               Show this help
#
# Everything but the binary download and systemd/apt steps also works on macOS
# (dev/test only — user-mode networking, no systemd); pass --no-systemd there.

set -euo pipefail

REGISTRATION_URL=""
VERSION="latest"
REPO="samcat116/strato"
BIN_DIR="/usr/local/bin"
NETWORK_MODE="ovn"
STRATO_AGENT_BIN=""
INSTALL_DEPS=1
USE_SYSTEMD=1
RUN_PREFLIGHT=1

STRATO_CONF_DIR=/etc/strato
STRATO_STATE_DIR=/var/lib/strato
STATE_FILE="$STRATO_STATE_DIR/agent-state.json"
CONFIG_FILE="$STRATO_CONF_DIR/config.toml"
UNIT_FILE=/etc/systemd/system/strato-agent.service

log() { echo "==> $*"; }
warn() { echo "warning: $*" >&2; }
die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --registration-url) REGISTRATION_URL="$2"; shift 2 ;;
    --version)          VERSION="$2"; shift 2 ;;
    --repo)             REPO="$2"; shift 2 ;;
    --bin-dir)          BIN_DIR="$2"; shift 2 ;;
    --network-mode)     NETWORK_MODE="$2"; shift 2 ;;
    --strato-agent-bin) STRATO_AGENT_BIN="$2"; shift 2 ;;
    --no-deps)          INSTALL_DEPS=0; shift ;;
    --no-systemd)       USE_SYSTEMD=0; shift ;;
    --skip-preflight)   RUN_PREFLIGHT=0; shift ;;
    -h|--help)          grep '^#' "$0" | cut -c 3-; exit 0 ;;
    *)                  die "unknown option: $1 (see --help)" ;;
  esac
done

case "$NETWORK_MODE" in
  ovn|user) ;;
  *) die "--network-mode must be 'ovn' or 'user' (got '$NETWORK_MODE')" ;;
esac

# --- platform detection ------------------------------------------------------

uname_s="$(uname -s)"
uname_m="$(uname -m)"
case "$uname_s" in
  Linux)  OS=linux ;;
  Darwin) OS=macos ;;
  *)      die "unsupported OS: $uname_s (Linux or macOS only)" ;;
esac
case "$uname_m" in
  x86_64|amd64)  ARCH=x86_64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *)             die "unsupported architecture: $uname_m" ;;
esac
ASSET="strato-${OS}-${ARCH}.tar.gz"
log "Detected host: ${OS}/${ARCH}"

if [ "$OS" = "macos" ]; then
  # No apt, no systemd, no KVM/OVN. Keep going so the binary and (optional)
  # foreground join still work for dev/test, but turn the Linux-only bits off.
  [ "$INSTALL_DEPS" -eq 1 ] && log "macOS host: skipping package install (use 'brew install qemu')"
  INSTALL_DEPS=0
  USE_SYSTEMD=0
fi

# --- privilege check ---------------------------------------------------------

is_root() { [ "$(id -u)" -eq 0 ]; }
need_root() {
  is_root && return 0
  die "must run as root for this step ($1). Re-run under sudo, or pass --bin-dir to a writable location with --no-deps --no-systemd."
}

if [ "$INSTALL_DEPS" -eq 1 ]; then need_root "installing host packages"; fi
if [ "$USE_SYSTEMD" -eq 1 ]; then need_root "installing the systemd unit"; fi
if [ -z "$STRATO_AGENT_BIN" ] && [ ! -w "$BIN_DIR" ]; then need_root "writing to $BIN_DIR"; fi

# --- binary install ----------------------------------------------------------

sha256_verify() {
  # $1: directory holding both the asset and <asset>.sha256
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$1" && sha256sum -c "${ASSET}.sha256")
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$1" && shasum -a 256 -c "${ASSET}.sha256")
  else
    warn "no sha256sum/shasum available; skipping checksum verification"
  fi
}

install_binary() {
  if [ -n "$STRATO_AGENT_BIN" ]; then
    [ -x "$STRATO_AGENT_BIN" ] || die "--strato-agent-bin '$STRATO_AGENT_BIN' is not an executable file"
    log "Using existing binary at $STRATO_AGENT_BIN"
    return 0
  fi

  command -v curl >/dev/null 2>&1 || die "curl is required to download the binary"
  command -v tar  >/dev/null 2>&1 || die "tar is required to unpack the binary"

  local base
  if [ "$VERSION" = "latest" ]; then
    base="https://github.com/${REPO}/releases/latest/download"
  else
    base="https://github.com/${REPO}/releases/download/${VERSION}"
  fi

  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  log "Downloading ${ASSET} (${VERSION})"
  curl -fsSL "${base}/${ASSET}" -o "${tmp}/${ASSET}" || die \
    "download failed: ${base}/${ASSET} — no published binary for ${OS}/${ARCH} at '${VERSION}'? Build from source or use the Docker image (ghcr.io/${REPO}-agent)."

  if curl -fsSL "${base}/${ASSET}.sha256" -o "${tmp}/${ASSET}.sha256" 2>/dev/null; then
    log "Verifying checksum"
    sha256_verify "$tmp" || die "checksum verification failed for ${ASSET}"
  else
    warn "no published checksum for ${ASSET}; skipping verification"
  fi

  tar -xzf "${tmp}/${ASSET}" -C "$tmp" strato-agent \
    || die "release tarball did not contain a 'strato-agent' binary"

  install -d "$BIN_DIR"
  install -m 0755 "${tmp}/strato-agent" "${BIN_DIR}/strato-agent"
  STRATO_AGENT_BIN="${BIN_DIR}/strato-agent"
  log "Installed strato-agent to ${STRATO_AGENT_BIN}"
  "$STRATO_AGENT_BIN" --version 2>/dev/null | head -n1 || true
}

install_binary

# --- host dependencies -------------------------------------------------------
# Mirrors the runtime packages in agent/Dockerfile. Hypervisor hosts run only
# the OVN/OVS chassis side; the NB/SB/northd central is a separate deployment.

apt_packages() {
  local qemu_system firmware
  if [ "$ARCH" = "arm64" ]; then
    qemu_system="qemu-system-arm"
    firmware="qemu-efi-aarch64"
  else
    qemu_system="qemu-system-x86"
    firmware="ovmf"
  fi
  # Base: disk tooling (qemu-img), the qemu-system for this arch, UEFI firmware
  # for disk-image boot, glib (QEMUKit links it), and socat.
  local pkgs=(qemu-utils "$qemu_system" "$firmware" libglib2.0-0 socat ca-certificates)
  if [ "$NETWORK_MODE" = "ovn" ]; then
    pkgs+=(ovn-host ovn-common openvswitch-switch openvswitch-common)
  fi
  printf '%s\n' "${pkgs[@]}"
}

install_deps() {
  [ "$INSTALL_DEPS" -eq 1 ] || { log "Skipping package install (--no-deps)"; return 0; }
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "apt-get not found; install these packages with your package manager: $(apt_packages | tr '\n' ' ')"
    return 0
  fi
  local pkgs
  mapfile -t pkgs < <(apt_packages)
  log "Installing host packages: ${pkgs[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get -q update
  DEBIAN_FRONTEND=noninteractive apt-get -q install -y "${pkgs[@]}"
}

install_deps

# --- preflight summary -------------------------------------------------------
# Fast, best-effort feedback. The agent itself runs the authoritative host
# preflight at startup and gates its reported capabilities accordingly.

PREFLIGHT_OK=1

# check_present <label> <hint> <test-command...> — reports a [ ok ]/[MISS] line.
check_present() {
  local label="$1" hint="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then
    echo "    [ ok ] $label"
  else
    echo "    [MISS] $label — $hint"
    PREFLIGHT_OK=0
  fi
}

# check_kvm — /dev/kvm must exist and be read/writable for hardware accel.
check_kvm() { [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; }

preflight() {
  [ "$RUN_PREFLIGHT" -eq 1 ] || return 0
  PREFLIGHT_OK=1
  log "Host preflight:"
  check_present "qemu-img" "install qemu-utils" command -v qemu-img
  if [ "$OS" = "linux" ]; then
    check_present "/dev/kvm (hardware acceleration)" \
      "no KVM — hardware acceleration off; VMs fall back to slow emulation" check_kvm
  fi
  if [ "$NETWORK_MODE" = "ovn" ] && [ "$OS" = "linux" ]; then
    check_present "ip (iproute2)"    "install iproute2"           command -v ip
    check_present "ovs-vsctl (OVS)"  "install openvswitch-switch" command -v ovs-vsctl
    check_present "ovn-appctl (OVN)" "install ovn-host"           command -v ovn-appctl
  fi
  if [ "$PREFLIGHT_OK" -eq 0 ]; then
    warn "some host dependencies are missing (see [MISS] above); the agent will run but may report reduced capacity"
  fi
}

preflight

# --- systemd unit ------------------------------------------------------------

install_unit() {
  [ "$USE_SYSTEMD" -eq 1 ] || { log "Skipping systemd unit (--no-systemd)"; return 0; }
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not found; skipping systemd unit. Run 'strato-agent' under your init/supervisor of choice."
    USE_SYSTEMD=0
    return 0
  fi
  install -d "$STRATO_CONF_DIR" "$STRATO_STATE_DIR"
  log "Installing $UNIT_FILE"
  # Runs in plain `run` mode: after the initial join the agent reconnects with
  # its persisted rotated token, never the single-use registration token.
  cat > "$UNIT_FILE" << EOF
[Unit]
Description=Strato Agent
Documentation=https://github.com/${REPO}/blob/main/docs/deployment/agents.md
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${STRATO_AGENT_BIN} run --config-file ${CONFIG_FILE}
Restart=on-failure
RestartSec=10
# The agent manages VMs, TAP devices, and KVM, so it needs broad host access;
# avoid the aggressive sandbox directives that would break those.

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

install_unit

# --- config + join (only with a registration URL) ----------------------------

# Write the agent config before joining. `strato-agent join --config-file`
# treats an explicit path as authoritative and fails if the file is missing (it
# only auto-writes when using the default config path), so on a fresh host the
# file must exist first. This is also the only place the selected network mode
# is persisted — without it a Linux agent defaults to OVN even when installed
# with --network-mode user. Linux only; macOS uses the agent's own default
# config path (and always user-mode SLIRP), so join auto-writes it there.
write_config() {
  local url="$1"
  install -d "$STRATO_CONF_DIR"
  if [ -f "$CONFIG_FILE" ]; then
    log "$CONFIG_FILE already exists; leaving it in place (ensure control_plane_url and network_mode are set)"
    return 0
  fi
  local cp_url="${url%%\?*}"
  log "Writing $CONFIG_FILE (network_mode = ${NETWORK_MODE})"
  cat > "$CONFIG_FILE" << EOF
control_plane_url = "$cp_url"
network_mode = "$NETWORK_MODE"
EOF
}

join_control_plane() {
  local url="$1"
  case "$url" in
    ws://*|wss://*) ;;
    *) die "--registration-url must start with ws:// or wss:// (got '$url')" ;;
  esac

  if [ "$OS" = "linux" ]; then write_config "$url"; fi

  if [ "$USE_SYSTEMD" -eq 1 ]; then
    # A registration URL was supplied, so always register with it — that is the
    # documented recovery path when the stored state is stale, revoked, or
    # corrupt, and `join` overwrites the old state on success. Skipping join
    # here would start the service on the dead state and it would just fail.
    if [ -f "$STATE_FILE" ]; then
      log "Existing join state at $STATE_FILE will be replaced by this registration"
    fi
    # `join` registers and then keeps running as the agent. Run it just long
    # enough to confirm registration (the "Registration complete" log line),
    # then hand off to the systemd unit which reconnects with the rotated token.
    local join_log=/var/log/strato-agent-join.log
    log "Joining the control plane"
    : > "$join_log"
    "$STRATO_AGENT_BIN" join --config-file "$CONFIG_FILE" "$url" >> "$join_log" 2>&1 &
    local join_pid=$!
    for _ in $(seq 1 60); do
      if grep -q "Registration complete" "$join_log" 2>/dev/null; then break; fi
      if ! kill -0 "$join_pid" 2>/dev/null; then
        die "strato-agent join exited before registering; see $join_log"
      fi
      sleep 1
    done
    if ! grep -q "Registration complete" "$join_log" 2>/dev/null; then
      kill "$join_pid" 2>/dev/null || true
      die "registration did not complete within 60s; see $join_log"
    fi
    kill "$join_pid" 2>/dev/null || true
    wait "$join_pid" 2>/dev/null || true
    systemctl enable --now strato-agent.service
    log "Done. Follow along with: journalctl -fu strato-agent"
  else
    log "Joining the control plane (foreground; Ctrl-C stops the agent)"
    if [ "$OS" = "linux" ]; then
      exec "$STRATO_AGENT_BIN" join --config-file "$CONFIG_FILE" "$url"
    else
      # macOS: no config was written above; let join use its platform default
      # config path and auto-write the minimal config there.
      exec "$STRATO_AGENT_BIN" join "$url"
    fi
  fi
}

if [ -n "$REGISTRATION_URL" ]; then
  join_control_plane "$REGISTRATION_URL"
else
  log "Install complete. To register this host, create a token in the Strato UI"
  log "(Agents -> Create Registration Token) and run:"
  log "  ${STRATO_AGENT_BIN} join '<registration-url>'"
  if [ "$USE_SYSTEMD" -eq 1 ]; then
    log "Then start it on boot:  sudo systemctl enable --now strato-agent"
    log "(or just re-run this installer with --registration-url to do both)."
  fi
  if [ "$OS" = "linux" ] && [ "$NETWORK_MODE" = "user" ]; then
    log "Note: network_mode is only persisted during join. Re-run with"
    log "--registration-url, or add 'network_mode = \"user\"' to $CONFIG_FILE yourself,"
    log "otherwise the agent will default to OVN networking."
  fi
fi
