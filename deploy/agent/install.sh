#!/usr/bin/env bash
# strato-agent install.sh — one-command hypervisor node install.
#
# Downloads the strato-agent and spire-agent binaries, installs the host
# dependencies the agent needs (QEMU and libvirtd, and OVN/OVS for SDN
# networking), attests this node to SPIRE, writes the agent config, and starts
# everything under systemd. Designed to be curled and piped:
#
#   curl -fsSL https://raw.githubusercontent.com/samcat116/strato/main/deploy/agent/install.sh \
#     | sudo bash -s -- \
#     --control-plane-url 'wss://cp.example.com/agent/ws' \
#     --agent-name 'hv-01' \
#     --spire-join-token '...' \
#     --spire-server-address 'cp.example.com:8085' \
#     --trust-domain 'strato.local'
#
# That invocation is exactly what the Strato UI emits when you enroll a node
# (Agents -> Enroll node, or POST /api/agent-enrollments): enrollment
# provisions the node in SPIRE and hands back this command with the join token
# filled in. Agents authenticate to the control plane ONLY by SPIFFE X.509 SVID
# over mTLS, so all five flags above are required — there is no token join and
# no unauthenticated path.
#
# Unless --no-telemetry, the script also installs Grafana Alloy +
# spiffe-helper, which push node metrics and journal logs to the control
# plane's telemetry ingest using the same SVID.
#
# Re-running this with a *fresh* bootstrap command re-enrolls the node: a
# changed --trust-domain or a join token this host has not already redeemed
# clears the spire-agent data dir so the node attests again under its new
# identity. Re-running the *same* command (to upgrade binaries, say) leaves the
# attested identity alone.
#
# Linux only: spire-agent, systemd, and KVM all are.
#
# Flags (all five below are required):
#   --control-plane-url URL  Agent WebSocket endpoint (ws:// or wss://; always
#                            wss:// in a SPIRE deployment, since Envoy
#                            terminates mTLS in front of the control plane)
#   --agent-name NAME        The name this node was enrolled under. Must match
#                            the enrollment exactly — the control plane resolves
#                            the enrollment row by name. ASCII letters, digits,
#                            '-', '_' and '.' only.
#   --spire-join-token TOK   One-time SPIRE join token from the enrollment
#   --spire-server-address H:P  SPIRE server this node attests to
#   --trust-domain TD        SPIFFE trust domain (default: strato.local)
#
# Optional flags:
#   --version VERSION        Release tag to install (default: latest)
#   --repo OWNER/NAME        GitHub repository to fetch from (default: samcat116/strato)
#   --bin-dir DIR            Where to install binaries (default: /usr/local/bin)
#   --network-mode MODE      ovn | user — which deps to install/require (default: ovn)
#   --strato-agent-bin PATH  Use an existing binary instead of downloading one
#   --no-deps                Do not install host packages (still checks them)
#   --no-libvirt-config      Install libvirt but leave /etc/libvirt/qemu.conf
#                            alone (for hosts whose config is managed by
#                            configuration management)
#   --no-systemd             Do not install/enable systemd units
#   --skip-preflight         Skip the host dependency summary
#   --sandbox-guest          Also install the sandbox guest base image (kernel +
#                            init) so this host can run sandboxes (Linux only)
#   -h, --help               Show this help
#
# SPIRE / telemetry tuning:
#   --trust-bundle PATH           SPIRE trust bundle PEM. Without it the agent
#                                 uses insecure_bootstrap (TOFU) — fine for labs,
#                                 not for hostile networks.
#   --control-plane-spiffe-id ID  SPIFFE ID the control plane's TLS certificate
#                                 must present; the agent refuses any other
#                                 identity, even bundle-signed ones (issue #552).
#                                 Default: spiffe://<trust-domain>/control-plane,
#                                 which both supported deployments provision.
#   --no-telemetry                Skip Alloy/spiffe-helper (host metrics + logs)
#   --ingest-url URL              Telemetry ingest origin (default: derived from
#                                 the control-plane URL, e.g. https://cp:8443)
#   --spire-version V             spire-agent release (default: pinned below)
#   --alloy-version V             Grafana Alloy release (default: pinned below)
#   --spiffe-helper-version V     spiffe-helper release (default: pinned below)

set -euo pipefail

CONTROL_PLANE_URL=""
AGENT_NAME=""
VERSION="latest"
REPO="samcat116/strato"
BIN_DIR="/usr/local/bin"
NETWORK_MODE="ovn"
STRATO_AGENT_BIN=""
INSTALL_DEPS=1
USE_SYSTEMD=1
RUN_PREFLIGHT=1
INSTALL_SANDBOX_GUEST=0
CONFIGURE_LIBVIRT=1

# The account strato-agent.service runs as, and therefore the uid libvirt must
# hand VM disks and sockets to (see configure_libvirt_conf below). Root: the default
# storage/config/SPIRE paths are root-owned, the SPIRE workload selector the
# control plane provisions is `unix:uid:0`, and the agent manages TAP devices,
# netlink and ovs-vsctl. Running unprivileged is a supported but manual
# configuration (docs/deployment/agents.md#privileges); this variable is the one
# place that assumption is written down.
AGENT_USER="root"

# Hypervisor nodes need libvirt >= 11.5: internal snapshots of UEFI VMs (how
# checkpoint/restore works) arrived in 10.9, and 11.2-11.3 carry a revert
# regression fixed in 11.5. Ubuntu 24.04 ships 10.0.0 and is therefore not a
# supported hypervisor host; 26.04 ships 12.0.0.
LIBVIRT_MIN_VERSION="11.5.0"
LIBVIRT_QEMU_CONF=/etc/libvirt/qemu.conf

# SPIRE / telemetry. Versions are pinned for reproducible installs: SPIRE
# matches the compose spire-server image (deploy/compose/spiffe/Dockerfile);
# bump Alloy/spiffe-helper deliberately, checking their release notes.
JOIN_TOKEN=""
SPIRE_SERVER_ADDRESS=""
TRUST_DOMAIN="strato.local"
TRUST_BUNDLE=""
CONTROL_PLANE_SPIFFE_ID=""
INSTALL_TELEMETRY=1
INGEST_URL=""
SPIRE_VERSION="1.9.6"
ALLOY_VERSION="v1.17.1"
SPIFFE_HELPER_VERSION="v0.11.0"
COREDNS_VERSION="1.12.0"

STRATO_CONF_DIR=/etc/strato
STRATO_STATE_DIR=/var/lib/strato
CONFIG_FILE="$STRATO_CONF_DIR/config.toml"
UNIT_FILE=/etc/systemd/system/strato-agent.service

SPIRE_CONF_DIR=/etc/spire
SPIRE_DATA_DIR=/var/lib/spire/agent
SPIRE_SOCKET_DIR=/var/run/spire/sockets
SPIRE_SOCKET="$SPIRE_SOCKET_DIR/workload.sock"
ALLOY_CONF_DIR=/etc/alloy
ALLOY_DATA_DIR=/var/lib/alloy
ALLOY_CERT_DIR="$ALLOY_DATA_DIR/certs"
HELPER_CONF_DIR=/etc/spiffe-helper

log() { echo "==> $*"; }
warn() { echo "warning: $*" >&2; }
die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --control-plane-url) CONTROL_PLANE_URL="$2"; shift 2 ;;
    --agent-name)       AGENT_NAME="$2"; shift 2 ;;
    --version)          VERSION="$2"; shift 2 ;;
    --repo)             REPO="$2"; shift 2 ;;
    --bin-dir)          BIN_DIR="$2"; shift 2 ;;
    --network-mode)     NETWORK_MODE="$2"; shift 2 ;;
    --strato-agent-bin) STRATO_AGENT_BIN="$2"; shift 2 ;;
    --no-deps)          INSTALL_DEPS=0; shift ;;
    --no-libvirt-config) CONFIGURE_LIBVIRT=0; shift ;;
    --no-systemd)       USE_SYSTEMD=0; shift ;;
    --skip-preflight)   RUN_PREFLIGHT=0; shift ;;
    --sandbox-guest)    INSTALL_SANDBOX_GUEST=1; shift ;;
    --spire-join-token)      JOIN_TOKEN="$2"; shift 2 ;;
    --spire-server-address)  SPIRE_SERVER_ADDRESS="$2"; shift 2 ;;
    --trust-domain)          TRUST_DOMAIN="$2"; shift 2 ;;
    --trust-bundle)          TRUST_BUNDLE="$2"; shift 2 ;;
    --control-plane-spiffe-id) CONTROL_PLANE_SPIFFE_ID="$2"; shift 2 ;;
    --no-telemetry)          INSTALL_TELEMETRY=0; shift ;;
    --ingest-url)            INGEST_URL="$2"; shift 2 ;;
    --spire-version)         SPIRE_VERSION="${2#v}"; shift 2 ;;
    --alloy-version)         ALLOY_VERSION="$2"; shift 2 ;;
    --spiffe-helper-version) SPIFFE_HELPER_VERSION="$2"; shift 2 ;;
    -h|--help)          grep '^#' "$0" | cut -c 3-; exit 0 ;;
    *)                  die "unknown option: $1 (see --help)" ;;
  esac
done

case "$NETWORK_MODE" in
  ovn|user) ;;
  *) die "--network-mode must be 'ovn' or 'user' (got '$NETWORK_MODE')" ;;
esac

# Every install is a SPIFFE install: the node attests to the SPIRE server and
# the agent authenticates to the control plane with its SVID (mTLS). There is
# no other agent auth path, so all of these are required rather than optional.
[ -n "$CONTROL_PLANE_URL" ] || die "--control-plane-url is required (from the enrollment's bootstrap command)"
[ -n "$AGENT_NAME" ]        || die "--agent-name is required (must match the name the node was enrolled under)"
[ -n "$JOIN_TOKEN" ]        || die "--spire-join-token is required (from the enrollment's bootstrap command)"
[ -n "$SPIRE_SERVER_ADDRESS" ] || die "--spire-server-address is required (the SPIRE server this node attests to)"
[ -n "$TRUST_DOMAIN" ]      || die "--trust-domain must not be empty"

case "$CONTROL_PLANE_URL" in
  ws://*|wss://*) ;;
  *) die "--control-plane-url must start with ws:// or wss:// (got '$CONTROL_PLANE_URL')" ;;
esac
case "$CONTROL_PLANE_URL" in
  ws://*) warn "--control-plane-url is ws:// (no TLS); mTLS agent auth needs wss://" ;;
esac

# Mirrors the control plane's own validation, so a bad name fails here rather
# than after the whole install with an opaque registration rejection.
case "$AGENT_NAME" in
  *[!A-Za-z0-9._-]*|"") die "--agent-name must be ASCII letters, digits, '-', '_' or '.' (got '$AGENT_NAME')" ;;
esac

# --- platform detection ------------------------------------------------------

uname_s="$(uname -s)"
uname_m="$(uname -m)"
case "$uname_s" in
  Linux)  OS=linux ;;
  Darwin)
    die "macOS is not a supported agent platform: agents authenticate only by SPIFFE SVID, and spire-agent, systemd, and KVM are all Linux-only. Run agents on a Linux hypervisor host."
    ;;
  *)      die "unsupported OS: $uname_s (Linux only)" ;;
esac
case "$uname_m" in
  x86_64|amd64)  ARCH=x86_64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *)             die "unsupported architecture: $uname_m" ;;
esac
ASSET="strato-${OS}-${ARCH}.tar.gz"
# spire/alloy release assets use Go arch names; spiffe-helper uses uname-style.
GOARCH=$([ "$ARCH" = "x86_64" ] && echo amd64 || echo arm64)
log "Detected host: ${OS}/${ARCH}"

# Telemetry runs as systemd units and reads journald, so it is the one piece
# that --no-systemd cannot carry. The SVID it authenticates with is always
# present now that every install is a SPIFFE install.
if [ "$INSTALL_TELEMETRY" -eq 1 ] && [ "$USE_SYSTEMD" -eq 0 ]; then
  warn "telemetry (Alloy) requires systemd; skipping — re-run without --no-systemd to enable it"
  INSTALL_TELEMETRY=0
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
need_root "configuring spire-agent"

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

# --- sandbox guest base image (optional, Linux only) -------------------------
# The kernel + init/guest-agent (issue #419) a host needs to boot sandboxes.
# Off by default: without it the agent simply never advertises the
# sandbox_runtime capability (SandboxRuntimeProbe), so the control plane won't
# place sandboxes here. The tarball is the on-disk layout the agent expects at
# sandbox_guest_image_path (default /var/lib/strato/sandbox/guest).
SANDBOX_GUEST_DIR="${STRATO_STATE_DIR}/sandbox/guest"

install_sandbox_guest() {
  if [ "$OS" != "linux" ]; then
    warn "sandboxes are Linux/Firecracker only; skipping --sandbox-guest on ${OS}"
    return 0
  fi
  command -v curl >/dev/null 2>&1 || die "curl is required to download the sandbox guest image"
  # The guest artifacts use the toolchain arch name (aarch64), not uname's arm64.
  local garch; garch=$([ "$ARCH" = "arm64" ] && echo aarch64 || echo "$ARCH")
  local asset="sandbox-guest-${garch}.tar.gz"

  local base
  if [ "$VERSION" = "latest" ]; then
    base="https://github.com/${REPO}/releases/latest/download"
  else
    base="https://github.com/${REPO}/releases/download/${VERSION}"
  fi

  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  log "Downloading sandbox guest image (${asset})"
  curl -fSL "${base}/${asset}" -o "${tmp}/${asset}" \
    || die "download failed: ${base}/${asset} — no published sandbox guest image for ${garch}? Build it with sandbox-guest/build.sh."
  if curl -fsSL "${base}/${asset}.sha256" -o "${tmp}/${asset}.sha256" 2>/dev/null; then
    (cd "$tmp" && sha256sum -c "${asset}.sha256") || die "checksum verification failed for ${asset}"
  else
    warn "no checksum sidecar for ${asset}; skipping verification"
  fi

  install -d "$SANDBOX_GUEST_DIR"
  tar xzf "${tmp}/${asset}" -C "$SANDBOX_GUEST_DIR" \
    || die "failed to extract ${asset} into ${SANDBOX_GUEST_DIR}"
  log "Installed sandbox guest image to ${SANDBOX_GUEST_DIR}"
}

if [ "$INSTALL_SANDBOX_GUEST" -eq 1 ]; then
  install_sandbox_guest
fi

# --- SPIRE / telemetry binaries ------------------------------------------------
# Official GitHub release artifacts, pinned versions. Each install is skipped
# when a binary of the requested version is already present, so re-runs are
# cheap and an operator-managed binary at the same version is left alone.

# fetch <url> <dest> <what>
fetch() {
  curl -fsSL "$1" -o "$2" || die "download failed: $1 ($3)"
}

install_spire_agent() {
  if command -v spire-agent >/dev/null 2>&1 \
    && spire-agent --version 2>&1 | grep -q "$SPIRE_VERSION"; then
    log "spire-agent $SPIRE_VERSION already installed; skipping download"
    return 0
  fi
  local tarball="spire-${SPIRE_VERSION}-linux-${GOARCH}-musl.tar.gz"
  local base="https://github.com/spiffe/spire/releases/download/v${SPIRE_VERSION}"
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  log "Downloading spire-agent ${SPIRE_VERSION} (${GOARCH})"
  fetch "${base}/${tarball}" "${tmp}/${tarball}" "spire-agent"
  if fetch "${base}/${tarball%.tar.gz}_sha256sum.txt" "${tmp}/sums.txt" "spire checksum" 2>/dev/null; then
    (cd "$tmp" && sha256sum -c sums.txt >/dev/null) || die "checksum verification failed for ${tarball}"
  fi
  tar -xzf "${tmp}/${tarball}" -C "$tmp" "spire-${SPIRE_VERSION}/bin/spire-agent" \
    || die "SPIRE tarball did not contain bin/spire-agent"
  install -m 0755 "${tmp}/spire-${SPIRE_VERSION}/bin/spire-agent" "${BIN_DIR}/spire-agent"
  log "Installed spire-agent to ${BIN_DIR}/spire-agent"
}

install_alloy() {
  if command -v alloy >/dev/null 2>&1 \
    && alloy --version 2>&1 | grep -q "${ALLOY_VERSION#v}"; then
    log "alloy ${ALLOY_VERSION} already installed; skipping download"
    return 0
  fi
  command -v unzip >/dev/null 2>&1 \
    || die "unzip is required to install Alloy (apt-get install unzip, or pass --no-telemetry)"
  local zip="alloy-linux-${GOARCH}.zip"
  local base="https://github.com/grafana/alloy/releases/download/${ALLOY_VERSION}"
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  log "Downloading Grafana Alloy ${ALLOY_VERSION} (${GOARCH})"
  fetch "${base}/${zip}" "${tmp}/${zip}" "alloy"
  if fetch "${base}/SHA256SUMS" "${tmp}/SHA256SUMS" "alloy checksums" 2>/dev/null; then
    (cd "$tmp" && grep " ${zip}\$" SHA256SUMS | sha256sum -c - >/dev/null) \
      || die "checksum verification failed for ${zip}"
  fi
  unzip -o -q "${tmp}/${zip}" -d "$tmp"
  install -m 0755 "${tmp}/alloy-linux-${GOARCH}" "${BIN_DIR}/alloy"
  log "Installed alloy to ${BIN_DIR}/alloy"
}

install_spiffe_helper() {
  if command -v spiffe-helper >/dev/null 2>&1 \
    && spiffe-helper -version 2>&1 | grep -q "${SPIFFE_HELPER_VERSION#v}"; then
    log "spiffe-helper ${SPIFFE_HELPER_VERSION} already installed; skipping download"
    return 0
  fi
  # spiffe-helper release assets use uname-style arch (x86_64/arm64) — matches
  # $ARCH, not $GOARCH. No checksum file is published for it.
  local tarball="spiffe-helper_${SPIFFE_HELPER_VERSION}_Linux-${ARCH}.tar.gz"
  local base="https://github.com/spiffe/spiffe-helper/releases/download/${SPIFFE_HELPER_VERSION}"
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  log "Downloading spiffe-helper ${SPIFFE_HELPER_VERSION} (${ARCH})"
  fetch "${base}/${tarball}" "${tmp}/${tarball}" "spiffe-helper"
  tar -xzf "${tmp}/${tarball}" -C "$tmp" spiffe-helper \
    || die "spiffe-helper tarball did not contain a 'spiffe-helper' binary"
  install -m 0755 "${tmp}/spiffe-helper" "${BIN_DIR}/spiffe-helper"
  log "Installed spiffe-helper to ${BIN_DIR}/spiffe-helper"
}

install_coredns() {
  # The per-network DNS resolver (STR-40). Not packaged by Debian/Ubuntu in a
  # version worth pinning to, and the agent invokes it by absolute path, so it
  # is downloaded like spire-agent and alloy rather than apt-installed.
  #
  # Only relevant in OVN mode: the resolver terminates on a localport inside a
  # per-network namespace, neither of which exists under user-mode networking.
  if [ "$NETWORK_MODE" != "ovn" ]; then
    return 0
  fi
  # Probed at the path the *agent* looks in, not through PATH. The agent
  # resolves CoreDNS from an absolute candidate list, so a binary on PATH but
  # outside that list (say /usr/sbin/coredns) would make this skip the install
  # and then leave the agent registering `resolverCapable: false` — which, per
  # the site-wide fold, withholds the resolver from every network in the site.
  if [ -x "${BIN_DIR}/coredns" ] \
    && "${BIN_DIR}/coredns" -version 2>&1 | grep -q "CoreDNS-${COREDNS_VERSION}"; then
    log "coredns ${COREDNS_VERSION} already installed; skipping download"
    return 0
  fi
  local tarball="coredns_${COREDNS_VERSION}_linux_${GOARCH}.tgz"
  local base="https://github.com/coredns/coredns/releases/download/v${COREDNS_VERSION}"
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  log "Downloading CoreDNS ${COREDNS_VERSION} (${GOARCH})"
  fetch "${base}/${tarball}" "${tmp}/${tarball}" "coredns"
  # Verified like every other artifact here. CoreDNS publishes a per-asset
  # sha256 beside the tarball, so unlike spiffe-helper there is nothing to opt
  # out of — and what lands is a root-owned binary the agent execs inside every
  # tenant network namespace to parse packets a guest chose, which makes it the
  # last thing on this host that should arrive unverified.
  if fetch "${base}/${tarball}.sha256" "${tmp}/${tarball}.sha256" "coredns checksum" 2>/dev/null; then
    (cd "$tmp" && sha256sum -c "${tarball}.sha256" >/dev/null) \
      || die "checksum verification failed for ${tarball}"
  else
    warn "no published checksum for ${tarball}; installing unverified"
  fi
  tar -xzf "${tmp}/${tarball}" -C "$tmp" coredns \
    || die "coredns tarball did not contain a 'coredns' binary"
  install -m 0755 "${tmp}/coredns" "${BIN_DIR}/coredns"
  log "Installed coredns to ${BIN_DIR}/coredns"
}

# (Invoked after install_deps below: install_alloy needs the unzip package.)

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
  # libvirtd is the second daemon the agent drives VMs through: the daemon
  # itself plus virsh, which both this script's preflight and the agent's use
  # to prove qemu:///system is reachable and new enough. swtpm backs guest
  # TPM 2.0 devices — libvirt starts and supervises it per domain, so it must
  # be on the host even though the agent never launches it itself.
  pkgs+=(libvirt-daemon-system libvirt-clients swtpm swtpm-tools)
  if [ "$NETWORK_MODE" = "ovn" ]; then
    pkgs+=(ovn-host ovn-common openvswitch-switch openvswitch-common)
  fi
  if [ "$INSTALL_TELEMETRY" -eq 1 ]; then
    # Grafana Alloy releases ship as zip archives.
    pkgs+=(unzip)
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

# --- libvirt configuration ---------------------------------------------------
# The agent drives VMs through libvirtd at qemu:///system, and the architecture
# invariant is that the *agent* owns every path under /var/lib/strato. libvirt's
# qemu driver disagrees by default: it runs QEMU as libvirt-qemu:kvm and chowns
# each domain's disks to that uid on start.
#
# The fix is not to switch labeling off. `security_driver = "none"`,
# `dynamic_ownership = 0` and `<seclabel type='none'/>` are global off-switches
# that also stop libvirt preparing its *own* runtime artifacts — the swtpm
# control socket under /run/libvirt — for the QEMU uid, which fails the domain
# start outright (validated in issue #899). Instead leave the DAC driver running
# and point it at the agent's own account: relabeling is then a no-op on files
# the agent already owns, and libvirt still manages swtpm and NVRAM correctly.
#
# AppArmor stays enabled for the same reason it does everywhere else — a denial
# is a profile to fix, not a driver to disable.

LIBVIRT_SOCKET_UNIT=""
LIBVIRT_SERVICE_UNIT=""

# Modular libvirt (virtqemud) vs monolithic (libvirtd): which one answers
# qemu:///system varies by distro release, and both sets of units can be
# installed at once. An enabled unit is the authoritative answer; failing that
# prefer the modular daemon, which is what upstream ships going forward.
detect_libvirt_units() {
  command -v systemctl >/dev/null 2>&1 || return 0
  local unit
  for unit in virtqemud.socket libvirtd.socket; do
    if systemctl is-enabled "$unit" >/dev/null 2>&1; then
      LIBVIRT_SOCKET_UNIT="$unit"
      LIBVIRT_SERVICE_UNIT="${unit%.socket}.service"
      return 0
    fi
  done
  for unit in virtqemud.socket libvirtd.socket; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      LIBVIRT_SOCKET_UNIT="$unit"
      LIBVIRT_SERVICE_UNIT="${unit%.socket}.service"
      return 0
    fi
  done
}

# set_qemu_conf_key <key> <literal value> — rewrite or append one qemu.conf
# assignment, touching nothing else. Returns 0 if the file changed, 1 if the key
# already held this value (so callers can skip the daemon restart).
#
# Only uncommented assignments are matched: libvirt ships the whole file as
# commented-out keys documenting their defaults, and those lines are reference
# material an operator reads — they must survive re-runs untouched.
#
# Duplicate assignments are collapsed to one, and the *last* occurrence decides
# whether the file already agrees with us. libvirt's parser lets the last
# assignment win, so a file carrying two `user =` lines would otherwise be read
# as already-correct from the first while libvirt ran with the second — a silent
# no-op in exactly the hand-edited case this function exists to fix. Collapsing
# rather than rewriting each in place is what makes a second run a no-op.
#
# awk with the value passed through ENVIRON rather than sed, for the same reason
# set_spiffe_key does it below: the value is data, never a replacement pattern.
set_qemu_conf_key() {
  local key="$1" value="$2"
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$LIBVIRT_QEMU_CONF"; then
    local current occurrences
    current="$(sed -n \
      "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*\$/\1/p" \
      "$LIBVIRT_QEMU_CONF" | tail -1)"
    occurrences="$(grep -cE "^[[:space:]]*${key}[[:space:]]*=" "$LIBVIRT_QEMU_CONF")"
    # Already right *and* stated once: nothing to do. Collapsing duplicates is
    # worth a rewrite even when the effective value matches.
    if [ "$current" = "$value" ] && [ "$occurrences" -eq 1 ]; then
      return 1
    fi
    log "Setting ${key} = ${value} in $LIBVIRT_QEMU_CONF (was ${current})"
    # cp -p first so the redirect below truncates a file that already carries the
    # original's mode and ownership: qemu.conf is 0600 root on Debian/Ubuntu and
    # can hold VNC/SPICE passwords and TLS material, and a bare `> tmp` would
    # create it 0644 under the ambient umask — both exposing it in /etc/libvirt
    # while it exists and widening the real file once moved into place.
    cp -p "$LIBVIRT_QEMU_CONF" "$LIBVIRT_QEMU_CONF.tmp"
    # Our assignment lands at the first match's position; any further ones are
    # dropped, leaving exactly one so the next run sees nothing to do.
    QEMU_CONF_KEY="$key" QEMU_CONF_VALUE="$value" awk '
      BEGIN { key = ENVIRON["QEMU_CONF_KEY"]; value = ENVIRON["QEMU_CONF_VALUE"] }
      $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
        if (!written) { print key " = " value; written = 1 }
        next
      }
      { print }
    ' "$LIBVIRT_QEMU_CONF" > "$LIBVIRT_QEMU_CONF.tmp" \
      && mv "$LIBVIRT_QEMU_CONF.tmp" "$LIBVIRT_QEMU_CONF"
    return 0
  fi
  if ! grep -q '^# --- strato-agent (managed' "$LIBVIRT_QEMU_CONF"; then
    cat >> "$LIBVIRT_QEMU_CONF" << 'EOF'

# --- strato-agent (managed by deploy/agent/install.sh) -----------------------
# Run QEMU as the account strato-agent runs as, so libvirt's dynamic ownership
# is a no-op on the VM tree the agent owns (/var/lib/strato/vms/<uuid>/) while
# libvirt keeps preparing its own swtpm/NVRAM artifacts for that same uid.
# dynamic_ownership stays 1 (the default): switching it off breaks the latter.
# Do not add security_driver = "none" — AppArmor is expected to stay enabled.
EOF
  fi
  log "Adding ${key} = ${value} to $LIBVIRT_QEMU_CONF"
  printf '%s = %s\n' "$key" "$value" >> "$LIBVIRT_QEMU_CONF"
}

# Writes the three qemu.conf keys we own. Sets LIBVIRT_CONF_CHANGED=1 when the
# file was modified, so only a real change restarts the daemon. This is the one
# piece --no-libvirt-config skips; everything else below runs regardless, because
# a host whose qemu.conf is managed elsewhere still needs its socket enabled and
# its agent account able to reach it.
LIBVIRT_CONF_CHANGED=0

configure_libvirt_conf() {
  if [ "$CONFIGURE_LIBVIRT" -eq 0 ]; then
    log "Leaving $LIBVIRT_QEMU_CONF alone (--no-libvirt-config); ensure it sets user/group = \"$AGENT_USER\" and dynamic_ownership = 1"
    return 0
  fi
  if [ ! -f "$LIBVIRT_QEMU_CONF" ]; then
    warn "$LIBVIRT_QEMU_CONF not found; is libvirt installed? Install libvirt-daemon-system and re-run, or configure it yourself (user/group = \"$AGENT_USER\")"
    return 0
  fi

  if set_qemu_conf_key user "\"$AGENT_USER\""; then LIBVIRT_CONF_CHANGED=1; fi
  if set_qemu_conf_key group "\"$AGENT_USER\""; then LIBVIRT_CONF_CHANGED=1; fi
  # Explicit rather than left to the default, so a host where someone disabled
  # it (the natural-looking fix for the ownership problem, and the wrong one)
  # is corrected on the next run.
  if set_qemu_conf_key dynamic_ownership 1; then LIBVIRT_CONF_CHANGED=1; fi

  # swtpm_user/swtpm_group are deliberately left at the distro default (tss):
  # libvirt creates the vTPM state under its own /var/lib/libvirt/swtpm, not the
  # agent-owned tree, and the spike confirmed the agent only ever needs to reach
  # the control socket. If the domain XML ends up placing TPM state under
  # /var/lib/strato (issue #902), these two keys have to follow user/group.
}

# The agent connects to qemu:///system as itself. root needs no help; any other
# account needs the libvirt group for the socket and kvm for acceleration. Not
# governed by --no-libvirt-config: group membership is host state, not this
# file's content, and an agent that cannot open the socket never starts a VM.
grant_libvirt_access() {
  [ "$AGENT_USER" != "root" ] || return 0
  local group
  for group in libvirt kvm; do
    if getent group "$group" >/dev/null 2>&1; then
      usermod -aG "$group" "$AGENT_USER" \
        || warn "could not add $AGENT_USER to the $group group; the agent may not be able to reach qemu:///system"
    fi
  done
}

# libvirt's own `default` NAT network is not something Strato uses — the agent
# does its own IPAM and TAP management — and on a hypervisor node it is an
# unrequested virbr0, a dnsmasq bound to :53 on it, and a set of NAT rules
# sitting next to OVS. Turn off its autostart, and tear it down now when doing so
# cannot disturb a guest.
disable_libvirt_default_network() {
  command -v virsh >/dev/null 2>&1 || return 0
  LC_ALL=C virsh -c qemu:///system net-info default >/dev/null 2>&1 || return 0

  if LC_ALL=C virsh -c qemu:///system net-info default 2>/dev/null | grep -q '^Autostart:.*yes'; then
    log "Disabling autostart of libvirt's 'default' NAT network (Strato does not use libvirt networking)"
    LC_ALL=C virsh -c qemu:///system net-autostart --disable default >/dev/null 2>&1 \
      || warn "could not disable autostart of libvirt's 'default' network; do it by hand with 'virsh net-autostart --disable default'"
  fi

  # Only destroy it when no domain is running: on a fresh node there are none,
  # and on a host that predates this script a running guest may be using virbr0.
  # Being wrong here disconnects someone's VM, so leave it to the operator.
  local running
  running="$(LC_ALL=C virsh -c qemu:///system list --state-running --name 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$running" ]; then
    warn "libvirt's 'default' network is still active and this host has running domains; leaving it up. Once they are gone: virsh net-destroy default"
    return 0
  fi
  if LC_ALL=C virsh -c qemu:///system net-info default 2>/dev/null | grep -q '^Active:.*yes'; then
    log "Tearing down libvirt's 'default' NAT network (virbr0 + dnsmasq)"
    LC_ALL=C virsh -c qemu:///system net-destroy default >/dev/null 2>&1 \
      || warn "could not destroy libvirt's 'default' network; do it by hand with 'virsh net-destroy default'"
  fi
}

enable_libvirt_socket() {
  command -v systemctl >/dev/null 2>&1 || return 0
  detect_libvirt_units
  if [ -z "$LIBVIRT_SOCKET_UNIT" ]; then
    warn "no virtqemud.socket or libvirtd.socket unit found; start libvirtd yourself so qemu:///system is reachable"
    return 0
  fi
  log "Enabling $LIBVIRT_SOCKET_UNIT"
  systemctl enable --now "$LIBVIRT_SOCKET_UNIT" \
    || warn "could not enable $LIBVIRT_SOCKET_UNIT; qemu:///system may be unreachable"
  if [ "$LIBVIRT_CONF_CHANGED" -eq 1 ]; then
    # try-restart, not restart: a socket-activated daemon that hasn't been
    # triggered yet will pick the new config up when it starts, and there is no
    # reason to start it early. Restarting a running libvirtd does not disturb
    # VMs — it reconnects to the QEMU processes it left running.
    log "Restarting $LIBVIRT_SERVICE_UNIT to apply $LIBVIRT_QEMU_CONF"
    systemctl try-restart "$LIBVIRT_SERVICE_UNIT" \
      || warn "could not restart $LIBVIRT_SERVICE_UNIT; restart it by hand so the new $LIBVIRT_QEMU_CONF takes effect"
  fi
}

configure_libvirt_conf
grant_libvirt_access
enable_libvirt_socket
disable_libvirt_default_network

install_spire_agent
install_coredns
if [ "$INSTALL_TELEMETRY" -eq 1 ]; then
  install_alloy
  install_spiffe_helper
fi

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

# version_ge <have> <want> — dotted numeric comparison (11.5 >= 11.5.0).
version_ge() {
  case "$1$2" in
    *[!0-9.]*|"") return 1 ;;
  esac
  local i have want h w
  IFS=. read -r -a have <<< "$1"
  IFS=. read -r -a want <<< "$2"
  for i in 0 1 2; do
    h="${have[i]:-0}"
    w="${want[i]:-0}"
    [ "$h" -gt "$w" ] && return 0
    [ "$h" -lt "$w" ] && return 1
  done
  return 0
}

# The version qemu:///system reports, which doubles as the reachability probe:
# virsh has to connect to the daemon to answer. Empty when virsh is missing or
# the connection failed.
#
# LC_ALL=C is load-bearing: virsh prints "Running against daemon:" through
# gettext, so on a host whose locale has a libvirt catalog installed the marker
# comes back translated and this reports a healthy daemon as unreachable. sudo
# keeps LANG/LC_* via env_keep, so the installer inherits the operator's locale.
LIBVIRT_VERSION=""
check_libvirtd() {
  command -v virsh >/dev/null 2>&1 || return 1
  LIBVIRT_VERSION="$(LC_ALL=C virsh -c qemu:///system version --daemon 2>/dev/null \
    | sed -n 's/^Running against daemon:[[:space:]]*\([0-9.]*\).*/\1/p' | head -1)"
  [ -n "$LIBVIRT_VERSION" ]
}

# Firmware descriptors are what make <os firmware='efi'> autoselection work; the
# agent falls back to explicit firmware paths without them.
check_firmware_descriptors() { compgen -G "/usr/share/qemu/firmware/*.json"; }

preflight() {
  [ "$RUN_PREFLIGHT" -eq 1 ] || return 0
  PREFLIGHT_OK=1
  log "Host preflight:"
  check_present "qemu-img" "install qemu-utils" command -v qemu-img
  if [ "$OS" = "linux" ]; then
    check_present "/dev/kvm (hardware acceleration)" \
      "no KVM — hardware acceleration off; VMs fall back to slow emulation" check_kvm
    check_present "swtpm" \
      "install swtpm swtpm-tools; without it this host cannot run VMs with a TPM 2.0 (Windows 11/Server 2025)" \
      command -v swtpm
    check_present "libvirtd (qemu:///system)" \
      "install libvirt-daemon-system libvirt-clients and start ${LIBVIRT_SOCKET_UNIT:-libvirtd.socket}; the agent manages VMs through libvirtd" \
      check_libvirtd
    # Reported separately from presence: the message has to name the version
    # found, and an old-but-running libvirt is a different problem from a
    # missing one — it needs a newer distro, not a package install.
    if [ -n "$LIBVIRT_VERSION" ] && ! version_ge "$LIBVIRT_VERSION" "$LIBVIRT_MIN_VERSION"; then
      echo "    [MISS] libvirt >= ${LIBVIRT_MIN_VERSION} (found ${LIBVIRT_VERSION}) — VM checkpoints need internal"
      echo "           snapshots of UEFI guests, which libvirt only supports from 10.9 and only"
      echo "           reliably from ${LIBVIRT_MIN_VERSION}. Ubuntu 24.04 ships 10.0.0 and is not a supported"
      echo "           hypervisor host; use Ubuntu 26.04 (libvirt 12.0.0) or another distro at ${LIBVIRT_MIN_VERSION}+."
      PREFLIGHT_OK=0
    fi
    check_present "QEMU firmware descriptors (/usr/share/qemu/firmware)" \
      "install ovmf/qemu-efi-aarch64; without the JSON descriptors libvirt cannot autoselect UEFI firmware" \
      check_firmware_descriptors
  fi
  if [ "$NETWORK_MODE" = "ovn" ] && [ "$OS" = "linux" ]; then
    check_present "ip (iproute2)"    "install iproute2"           command -v ip
    check_present "ovs-vsctl (OVS)"  "install openvswitch-switch" command -v ovs-vsctl
    check_present "ovn-appctl (OVN)" "install ovn-host"           command -v ovn-appctl
    # Advisory here as in the agent's own preflight, but worth naming the reach:
    # the control plane withholds a network's resolver unless every agent in the
    # site can serve one, so this host missing CoreDNS holds the whole site back.
    check_present "coredns (per-network DNS resolver)" \
      "rerun this installer, or install CoreDNS to ${BIN_DIR}/coredns" test -x "${BIN_DIR}/coredns"
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
  # The agent's mTLS credential comes from spire-agent's Workload API, so it
  # must not start without it.
  local unit_deps="network-online.target spire-agent.service"
  local unit_requires="Requires=spire-agent.service"
  local unit_wants="network-online.target"
  # libvirtd is ordered but not required: a node reboot must not race the agent
  # ahead of the daemon it manages VMs through, while a libvirt that fails to
  # start should leave the agent up and complaining (its preflight names the
  # problem) rather than dead with it.
  [ -n "$LIBVIRT_SOCKET_UNIT" ] || detect_libvirt_units
  if [ -n "$LIBVIRT_SOCKET_UNIT" ]; then
    unit_deps="$unit_deps $LIBVIRT_SOCKET_UNIT"
    unit_wants="$unit_wants $LIBVIRT_SOCKET_UNIT"
  fi
  cat > "$UNIT_FILE" << EOF
[Unit]
Description=Strato Agent
Documentation=https://github.com/${REPO}/blob/main/docs/deployment/agents.md
After=${unit_deps}
Wants=${unit_wants}
${unit_requires}

[Service]
ExecStart=${STRATO_AGENT_BIN} run --config-file ${CONFIG_FILE} --agent-id ${AGENT_NAME}
Restart=on-failure
RestartSec=10
# The agent manages VMs, TAP devices, and KVM, so it needs broad host access;
# avoid the aggressive sandbox directives that would break those.
#
# KillMode=process is load-bearing, not a tuning knob. Hypervisor processes
# (QEMU, Firecracker) are spawned as children of the agent and therefore live
# in this unit's cgroup; the default KillMode=control-group signals the whole
# cgroup on stop, so every restart — including the automatic one from
# Restart=on-failure — would SIGKILL every VM on the host. VMs are meant to
# outlive the agent: the persisted VM manifest exists precisely so a restarted
# agent re-adopts the hypervisor processes it left running. Signal only the
# agent itself.
KillMode=process
# Graceful shutdown takes seconds. Don't sit in final-sigterm for the 90s
# default if something in the process ever fails to exit.
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

install_unit

# --- SPIRE node identity (SPIRE mode only) ------------------------------------
# Ported from the former strato-node-bootstrap.sh: attest this node to the
# SPIRE server with the one-time join token, then serve the Workload API that
# the strato-agent (and spiffe-helper) draw SVIDs from.

# A spire-agent that has already attested keeps its SVID and private key in
# data_dir and ignores the join token from then on. That is right for an
# ordinary re-run (upgrading binaries must not force re-attestation), and wrong
# for a re-enrollment: the operator has revoked the old grant and been handed a
# fresh bootstrap command, so the stored identity is dead. Worse, with per-org
# trust domains (issue #600) re-enrollment can move the node into a *different*
# trust domain, where the old SVID is not merely revoked but meaningless.
#
# Distinguish the two by what the new bootstrap command carries: a changed trust
# domain, or a join token this node has not already redeemed. A plain re-run
# replays the same command, so both compare equal and the data dir survives.
reset_spire_data_dir_if_reenrolling() {
  local conf="$SPIRE_CONF_DIR/agent.conf"
  [ -f "$conf" ] || return 0
  [ -d "$SPIRE_DATA_DIR" ] || return 0

  local prev_td prev_token reason=""
  prev_td="$(sed -n 's/^[[:space:]]*trust_domain[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$conf" | head -1)"
  prev_token="$(sed -n 's/^[[:space:]]*join_token[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$conf" | head -1)"

  if [ -n "$prev_td" ] && [ "$prev_td" != "$TRUST_DOMAIN" ]; then
    reason="trust domain changed ($prev_td -> $TRUST_DOMAIN)"
  elif [ -n "$prev_token" ] && [ "$prev_token" != "$JOIN_TOKEN" ]; then
    reason="a new join token was issued (re-enrollment)"
  fi

  [ -n "$reason" ] || return 0

  log "Resetting $SPIRE_DATA_DIR: $reason"
  # Stop first: a running spire-agent would keep serving the old SVID from
  # memory and rewrite its key material on shutdown.
  if [ "$USE_SYSTEMD" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
    systemctl stop spire-agent.service 2>/dev/null || true
  else
    pkill -f "spire-agent run" 2>/dev/null || true
  fi
  # Contents, not the directory: it may be a mount point, and the KeyManager
  # "disk" plugin is configured to write into this exact path. `find -delete`
  # rather than a glob so dotfiles go too and an empty directory is not an
  # error.
  find "${SPIRE_DATA_DIR:?}" -mindepth 1 -delete \
    || die "could not clear $SPIRE_DATA_DIR; remove it by hand and re-run"
}

setup_spire() {
  # Fail fast on a stale agent config. write_config below only writes
  # config.toml when it is absent, so a leftover file without a [spiffe]
  # section (e.g. from an install that predates SPIFFE-only auth) would
  # silently leave the agent connecting with no client certificate — the
  # mTLS handshake then
  # fails at the proxy with an opaque TLS error.
  if [ -f "$CONFIG_FILE" ] && ! grep -q '^\[spiffe\]' "$CONFIG_FILE"; then
    die "$CONFIG_FILE exists but has no [spiffe] section (it predates SPIFFE onboarding). Remove it (sudo rm $CONFIG_FILE) and re-run, or add a [spiffe] block manually."
  fi

  local host="${SPIRE_SERVER_ADDRESS%:*}" port="${SPIRE_SERVER_ADDRESS##*:}"
  [ "$host" != "$port" ] || die "--spire-server-address must be host:port"

  reset_spire_data_dir_if_reenrolling

  mkdir -p "$SPIRE_CONF_DIR" "$SPIRE_DATA_DIR" "$SPIRE_SOCKET_DIR"

  local bootstrap_line
  if [ -n "$TRUST_BUNDLE" ]; then
    [ -f "$TRUST_BUNDLE" ] || die "trust bundle not found: $TRUST_BUNDLE"
    cp "$TRUST_BUNDLE" "$SPIRE_CONF_DIR/bundle.pem"
    bootstrap_line='trust_bundle_path = "'"$SPIRE_CONF_DIR"'/bundle.pem"'
  else
    log "No --trust-bundle given; using insecure_bootstrap (trust-on-first-use)"
    bootstrap_line='insecure_bootstrap = true'
  fi

  log "Writing $SPIRE_CONF_DIR/agent.conf"
  cat > "$SPIRE_CONF_DIR/agent.conf" << EOF
agent {
    data_dir = "$SPIRE_DATA_DIR"
    # A healthy spire-agent has nothing to say between SVID rotations, and one
    # of these ships alongside every node — keep the steady state silent and
    # raise this by hand when debugging attestation.
    log_level = "WARN"
    server_address = "$host"
    server_port = "$port"
    socket_path = "$SPIRE_SOCKET"
    trust_domain = "$TRUST_DOMAIN"
    # Single-use: redeemed on first attestation, ignored once this node has
    # its SVID. Re-provision with a fresh token if the node is wiped.
    join_token = "$JOIN_TOKEN"
    $bootstrap_line
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

  if [ "$USE_SYSTEMD" -eq 1 ]; then
    log "Installing spire-agent.service"
    cat > /etc/systemd/system/spire-agent.service << EOF
[Unit]
Description=SPIRE Agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${BIN_DIR}/spire-agent run -config ${SPIRE_CONF_DIR}/agent.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    # Restart, not `enable --now`: this function has just rewritten agent.conf
    # with a new join token, server address, and trust domain, and an already
    # running spire-agent would keep serving the previous SVID from its Workload
    # API. strato-agent would then restart into the new control-plane URL while
    # still presenting the old identity — re-enrollment would fail.
    systemctl enable spire-agent.service
    systemctl restart spire-agent.service
  else
    log "Starting spire-agent in the background (no systemd)"
    nohup "${BIN_DIR}/spire-agent" run -config "$SPIRE_CONF_DIR/agent.conf" \
      >> /var/log/spire-agent.log 2>&1 &
  fi

  log "Waiting for the Workload API socket at $SPIRE_SOCKET"
  for _ in $(seq 1 30); do
    [ -S "$SPIRE_SOCKET" ] && break
    sleep 1
  done
  [ -S "$SPIRE_SOCKET" ] || die "spire-agent did not create $SPIRE_SOCKET within 30s (join token expired or SPIRE server unreachable?)"
}

# --- telemetry: Alloy + spiffe-helper (SPIRE mode, systemd only) ---------------
# Alloy collects node metrics (node_exporter set) and the strato/spire journal
# units, and pushes them to the control plane's Envoy mTLS listener
# (/ingest/metrics -> Prometheus, /ingest/logs -> Loki). Its client credential
# is this node's SVID; Alloy cannot speak the Workload API, so spiffe-helper
# materializes the SVID as rotating PEM files that Alloy re-reads on each TLS
# handshake.

write_telemetry_config() {
  [ "$INSTALL_TELEMETRY" -eq 1 ] || return 0

  # Basic identity label on every pushed series/stream.
  local agent_name="$AGENT_NAME"

  # Ingest origin: the same Envoy mTLS listener the agent WebSocket uses, over
  # HTTPS. Derived from the control-plane URL unless --ingest-url overrides.
  local ingest="$INGEST_URL"
  if [ -z "$ingest" ]; then
    local cp_url="${CONTROL_PLANE_URL%%\?*}"
    ingest="${cp_url%/agent/ws}"
    case "$ingest" in
      wss://*) ingest="https://${ingest#wss://}" ;;
      ws://*)
        ingest="http://${ingest#ws://}"
        warn "control-plane URL is ws:// (no TLS); telemetry pushes will fail mTLS — pass --ingest-url if the ingest endpoint differs"
        ;;
    esac
  fi

  mkdir -p "$ALLOY_CONF_DIR" "$ALLOY_DATA_DIR" "$HELPER_CONF_DIR"
  # Root-only: spiffe-helper writes the node's private key here.
  install -d -m 0700 "$ALLOY_CERT_DIR"

  log "Writing $HELPER_CONF_DIR/helper.conf"
  cat > "$HELPER_CONF_DIR/helper.conf" << EOF
# Written by install.sh: materializes this node's SVID as PEM files for Alloy.
agent_address = "$SPIRE_SOCKET"
cert_dir = "$ALLOY_CERT_DIR"
svid_file_name = "svid.pem"
svid_key_file_name = "svid_key.pem"
svid_bundle_file_name = "bundle.pem"
# Write the federated domains' roots into bundle.pem alongside our own.
# Alloy pushes to the control plane's Envoy listener, which presents a
# platform-trust-domain SVID — and with per-org trust domains (issue #600)
# this node is issued in its organization's domain, so our own roots cannot
# verify that peer. Without this, telemetry mTLS fails with an unknown-CA
# error while the agent's own WebSocket keeps working.
include_federated_domains = true
daemon_mode = true
EOF
  chmod 600 "$HELPER_CONF_DIR/helper.conf"

  if [ -f "$ALLOY_CONF_DIR/config.alloy" ]; then
    log "$ALLOY_CONF_DIR/config.alloy already exists; leaving it in place"
  else
    log "Writing $ALLOY_CONF_DIR/config.alloy (ingest: $ingest, agent: $agent_name)"
    cat > "$ALLOY_CONF_DIR/config.alloy" << EOF
// Written by install.sh; edit freely — re-runs leave this file in place.
//
// Host telemetry for the Strato control plane. Authentication is SPIFFE mTLS:
// the cert files below are this node's SVID, kept fresh by spiffe-helper and
// re-read by Alloy on every TLS handshake, so SVID rotation needs no reload.

prometheus.exporter.unix "host" { }

prometheus.scrape "host" {
  targets         = prometheus.exporter.unix.host.targets
  forward_to      = [prometheus.remote_write.strato.receiver]
  scrape_interval = "15s"
}

prometheus.remote_write "strato" {
  endpoint {
    url = "${ingest}/ingest/metrics"

    tls_config {
      cert_file = "${ALLOY_CERT_DIR}/svid.pem"
      key_file  = "${ALLOY_CERT_DIR}/svid_key.pem"
      ca_file   = "${ALLOY_CERT_DIR}/bundle.pem"
    }
  }

  external_labels = {
    agent = "${agent_name}",
  }
}

loki.source.journal "strato_agent" {
  matches    = "_SYSTEMD_UNIT=strato-agent.service"
  labels     = { job = "node-journal", unit = "strato-agent" }
  forward_to = [loki.write.strato.receiver]
}

loki.source.journal "spire_agent" {
  matches    = "_SYSTEMD_UNIT=spire-agent.service"
  labels     = { job = "node-journal", unit = "spire-agent" }
  forward_to = [loki.write.strato.receiver]
}

loki.write "strato" {
  endpoint {
    url = "${ingest}/ingest/logs"

    tls_config {
      cert_file = "${ALLOY_CERT_DIR}/svid.pem"
      key_file  = "${ALLOY_CERT_DIR}/svid_key.pem"
      ca_file   = "${ALLOY_CERT_DIR}/bundle.pem"
    }
  }

  external_labels = {
    agent = "${agent_name}",
  }
}
EOF
  fi

  log "Installing spiffe-helper.service and alloy.service"
  cat > /etc/systemd/system/spiffe-helper.service << EOF
[Unit]
Description=SPIFFE Helper (SVID files for Alloy)
After=spire-agent.service
Wants=spire-agent.service

[Service]
ExecStart=${BIN_DIR}/spiffe-helper -config ${HELPER_CONF_DIR}/helper.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/alloy.service << EOF
[Unit]
Description=Grafana Alloy (Strato host telemetry)
After=network-online.target spiffe-helper.service
Wants=network-online.target spiffe-helper.service

[Service]
ExecStart=${BIN_DIR}/alloy run ${ALLOY_CONF_DIR}/config.alloy --storage.path=${ALLOY_DATA_DIR}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

enable_telemetry() {
  [ "$INSTALL_TELEMETRY" -eq 1 ] || return 0
  # Restart rather than `enable --now`, for the same reason as strato-agent
  # below: write_telemetry_config may have just rewritten these units' config
  # (trust domain, SPIRE socket, ingest endpoint), and an already-running
  # spiffe-helper or alloy would otherwise keep the superseded values.
  log "Starting spiffe-helper and alloy"
  systemctl enable spiffe-helper.service alloy.service
  systemctl restart spiffe-helper.service alloy.service
}

setup_spire
write_telemetry_config

# --- agent config + start ----------------------------------------------------

# Write the agent config before starting. The systemd unit passes an explicit
# --config-file, and the agent treats an explicit path as authoritative, so on
# a fresh host the file must exist first. This is also the only place the
# selected network mode is persisted — without it the agent defaults to OVN
# even when installed with --network-mode user.
# Replace `key = "..."` inside config.toml, or insert it directly under the
# [spiffe] header when absent. Used for the handful of values a re-enrollment
# must refresh — everything else in an existing config is left to the operator.
#
# awk rather than sed throughout: this only ever runs against a config the
# operator may have hand-edited, and awk lets the value be passed as data
# instead of interpolated into a sed replacement, where a `|` or `&` in the
# value would corrupt the result. Both branches also stop after the first
# match, so a key that appears twice is not rewritten twice.
#
# The value arrives through ENVIRON rather than `awk -v`, which expands
# backslash escapes in its assignment (`a\db` would lose the `\d`). Neither a
# trust domain nor a SPIFFE ID can contain a backslash, so this is belt and
# braces — but it costs nothing and keeps the function honest about being a
# verbatim writer.
set_spiffe_key() {
  local key="$1" value="$2"
  if grep -q "^[[:space:]]*${key}[[:space:]]*=" "$CONFIG_FILE"; then
    local current
    current="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"\(.*\)\".*/\1/p" "$CONFIG_FILE" | head -1)"
    [ "$current" != "$value" ] || return 0
    log "Updating ${key} in $CONFIG_FILE ($current -> $value)"
    # Write through a temp file: in-place editing spelling differs GNU vs BSD.
    SPIFFE_KEY="$key" SPIFFE_VALUE="$value" awk '
      BEGIN { key = ENVIRON["SPIFFE_KEY"]; value = ENVIRON["SPIFFE_VALUE"] }
      !done && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { print key " = \"" value "\""; done = 1; next }
      { print }
    ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  else
    log "Adding ${key} to $CONFIG_FILE"
    # Directly under the [spiffe] header rather than at EOF: this branch only
    # runs for a config that already existed, so a table the operator added
    # after [spiffe] would otherwise silently capture the key.
    SPIFFE_KEY="$key" SPIFFE_VALUE="$value" awk '
      BEGIN { key = ENVIRON["SPIFFE_KEY"]; value = ENVIRON["SPIFFE_VALUE"] }
      { print }
      !done && $0 ~ /^[[:space:]]*\[spiffe\][[:space:]]*$/ { print key " = \"" value "\""; done = 1 }
    ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    # setup_spire already refuses a config with no [spiffe] section, so the
    # insert above finds its anchor. Fall back to appending rather than
    # silently dropping the key if that ever stops being true.
    grep -q "^[[:space:]]*${key}[[:space:]]*=" "$CONFIG_FILE" \
      || printf '%s = "%s"\n' "$key" "$value" >> "$CONFIG_FILE"
  fi
}

write_config() {
  install -d "$STRATO_CONF_DIR"
  local cp_url="${CONTROL_PLANE_URL%%\?*}"
  if [ -f "$CONFIG_FILE" ]; then
    # Reinstall. Re-running the bootstrap command is exactly how an operator
    # re-enrolls against a new control plane or a changed mTLS endpoint, and the
    # command carries that URL — but the systemd unit passes no URL override, so
    # leaving the old value here would silently keep the agent dialing the
    # previous host. Update that one key and leave any hand-edits alone.
    if grep -q '^[[:space:]]*control_plane_url[[:space:]]*=' "$CONFIG_FILE"; then
      local current
      current="$(sed -n 's/^[[:space:]]*control_plane_url[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$CONFIG_FILE" | head -1)"
      if [ "$current" != "$cp_url" ]; then
        log "Updating control_plane_url in $CONFIG_FILE ($current -> $cp_url)"
        # Write through a temp file: in-place sed spelling differs GNU vs BSD.
        sed "s|^[[:space:]]*control_plane_url[[:space:]]*=.*|control_plane_url = \"$cp_url\"|" \
          "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
      fi
    else
      # Bare keys must precede the first table, so prepend rather than append.
      log "Adding control_plane_url to $CONFIG_FILE"
      printf 'control_plane_url = "%s"\n' "$cp_url" | cat - "$CONFIG_FILE" > "$CONFIG_FILE.tmp" \
        && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    fi
    # The trust domain and the pinned control-plane identity must track the
    # bootstrap command for the same reason control_plane_url does — and more
    # urgently, because re-enrolling into a different organization's trust
    # domain (issue #600) changes both. A stale trust_domain leaves the agent
    # pinning spiffe://<old-domain>/control-plane and refusing every handshake.
    set_spiffe_key trust_domain "$TRUST_DOMAIN"
    if [ -n "$CONTROL_PLANE_SPIFFE_ID" ]; then
      set_spiffe_key control_plane_spiffe_id "$CONTROL_PLANE_SPIFFE_ID"
    fi

    log "$CONFIG_FILE already existed; other settings left as-is (ensure the [spiffe] block is correct)"
    return 0
  fi
  log "Writing $CONFIG_FILE (network_mode = ${NETWORK_MODE})"
  # The agent's name is not a config-file field: it comes from --agent-id on
  # the command line (defaulting to the hostname), which the systemd unit above
  # pins to the enrolled name. The agent dials control_plane_url with it as the
  # ?name= query parameter and the control plane resolves the enrollment by it.
  #
  # control_plane_spiffe_id is only written when the operator overrode it:
  # unset, the agent pins the conventional spiffe://<trust-domain>/control-plane.
  local cp_spiffe_id_line=""
  if [ -n "$CONTROL_PLANE_SPIFFE_ID" ]; then
    cp_spiffe_id_line='control_plane_spiffe_id = "'"$CONTROL_PLANE_SPIFFE_ID"'"'
  fi
  cat > "$CONFIG_FILE" << EOF
control_plane_url = "$cp_url"
network_mode = "$NETWORK_MODE"

# The agent presents its SVID from the Workload API as the mTLS client
# certificate; the control plane maps it back to this node's identity. The
# agent in turn pins the control plane's SPIFFE ID on every connection
# (control_plane_spiffe_id; defaults to spiffe://<trust_domain>/control-plane).
[spiffe]
enabled = true
trust_domain = "$TRUST_DOMAIN"
workload_api_socket_path = "$SPIRE_SOCKET"
source_type = "workload_api"
$cp_spiffe_id_line
EOF
}

write_config

if [ "$USE_SYSTEMD" -eq 1 ]; then
  # `enable --now` only *starts* a unit, so on a rerun an already-active agent
  # keeps running the old binary against the previous control_plane_url — and
  # re-running this installer to move a node to a new control plane is exactly
  # when that matters. `restart` starts a stopped unit and restarts a running
  # one, covering fresh installs and reinstalls alike.
  log "Starting strato-agent"
  systemctl enable strato-agent.service
  systemctl restart strato-agent.service
  # After the agent so the node is attested before the first pushes; harmless
  # either way — Alloy buffers and retries until its SVID files appear.
  enable_telemetry
  log "Done. Follow along with: journalctl -fu strato-agent"
else
  log "Install complete (no systemd unit installed). Start the agent with:"
  log "  ${STRATO_AGENT_BIN} run --config-file ${CONFIG_FILE} --agent-id ${AGENT_NAME}"
  log "spire-agent must be running first — it supplies the agent's SVID."
fi
