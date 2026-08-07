#!/usr/bin/env bash
#
# e2e-agent.sh — run a natively-built Strato agent against a local stack.
#
#   sudo RUN_DIR=... bash deploy/compose/e2e-agent.sh start
#   sudo RUN_DIR=... bash deploy/compose/e2e-agent.sh stop
#   sudo RUN_DIR=... bash deploy/compose/e2e-agent.sh reset   # DESTRUCTIVE, see below
#   sudo RUN_DIR=... bash deploy/compose/e2e-agent.sh status
#
# e2e-up.sh prints the exact invocation with RUN_DIR filled in; sudo does not
# forward the environment, so it has to be passed on the command line.
#
# Root is required: the SPIRE workload entry that e2e-up.sh provisions carries
# the default selector `unix:uid:0` (SPIRERegistrationService), so a non-root
# agent gets no SVID and the control plane refuses the connection.
#
# This is a DEVELOPMENT launcher — no systemd, logs to files under RUN_DIR. For
# real hypervisor nodes use deploy/agent/install.sh, which installs host deps,
# writes systemd units, and manages upgrades. That script also writes an
# equivalent spire-agent.conf; if you change the socket path, data dir, or
# attestor plugins here, change them there too.
#
# `reset` is what you want after `e2e-up.sh --fresh`. Tearing the stack down with
# `down -v` gives the SPIRE server a new CA, which invalidates two things on this
# host: the cached node SVID in /var/lib/spire/agent (spire-agent would try to
# re-attest with it and silently ignore the fresh join token), and every VM under
# /var/lib/strato/vms (the new control plane has never heard of them, so the
# reconciler reports each as an orphan). `reset` deletes both.
#
# Those are the same paths deploy/agent/install.sh manages on a real node, not
# e2e-scoped ones, so `reset` refuses outright when systemd is actually running
# the strato-agent unit (or would at the next boot) and otherwise asks before
# deleting anything.
#
# Environment overrides:
#   RUN_DIR     launch files + logs        (default $XDG_STATE_HOME/strato-e2e)
#   AGENT_BIN   agent binary               (default <repo>/agent/.build/debug/StratoAgent)
#   AGENT_CFG   agent TOML config          (default /etc/strato/config.toml)
#   SPIRE_BIN   spire-agent binary         (default /usr/local/bin/spire-agent)
set -uo pipefail

say() { printf '  %s\n' "$*"; }
die() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

ACTION="${1:-}"
ASSUME_YES=0
[[ "${2:-}" == "--yes" || "${2:-}" == "-y" ]] && ASSUME_YES=1

case "$ACTION" in
  start|stop|reset|status) ;;
  # Derived, not a fixed line range: a hardcoded range silently drifts into the
  # code below whenever the header grows, printing `set -uo pipefail` as usage.
  *) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 1 ;;
esac

[[ $EUID -eq 0 ]] || die "must run as root (the SPIRE workload entry's default selector is unix:uid:0)"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)" || die "cannot resolve repo root"
RUN_DIR="${RUN_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/strato-e2e}"
AGENT_BIN="${AGENT_BIN:-$REPO_ROOT/agent/.build/debug/StratoAgent}"
AGENT_CFG="${AGENT_CFG:-/etc/strato/config.toml}"
SPIRE_BIN="${SPIRE_BIN:-/usr/local/bin/spire-agent}"
SPIRE_CFG="$RUN_DIR/spire-agent.conf"
WORKLOAD_SOCK="/var/run/spire/sockets/workload.sock"

spire_pattern=(-f "spire-agent run -config $SPIRE_CFG")

# await_exit <label> <pgrep-args...> — signal, then WAIT. pkill only delivers the
# signal; the Strato agent takes about a second to shut down, which is long
# enough that a start running straight after would see the dying process, decide
# an agent was already up, and skip launching the new one.
await_exit() {
  local label="$1"; shift
  if ! pgrep "$@" >/dev/null; then say "$label not running"; return 0; fi
  pkill "$@"
  for _ in $(seq 1 30); do
    pgrep "$@" >/dev/null || { say "stopped $label"; return 0; }
    sleep 1
  done
  say "$label ignored SIGTERM; sending SIGKILL"
  pkill -9 "$@"; sleep 1
  pgrep "$@" >/dev/null && die "could not stop $label"
  say "killed $label"
}

do_stop() {
  await_exit StratoAgent -x StratoAgent
  await_exit "node spire-agent" "${spire_pattern[@]}"
}

do_start() {
  [[ -x "$AGENT_BIN" ]] || die "no agent binary at $AGENT_BIN
       build it: swiftly run +6.3.2 swift build --package-path agent"
  [[ -f "$AGENT_CFG" ]] || die "no agent config at $AGENT_CFG
       it needs at least control_plane_url and network_mode — see
       docs/development/e2e-testing.md"
  [[ -f "$SPIRE_CFG" ]] || die "no $SPIRE_CFG
       Either e2e-up.sh has not enrolled this node yet, or RUN_DIR does not
       match the one it used (sudo does not forward the environment — pass
       RUN_DIR= explicitly, as e2e-up.sh prints it)."
  [[ -x "$SPIRE_BIN" ]] || die "no spire-agent at $SPIRE_BIN"

  mkdir -p /var/run/spire/sockets /var/lib/spire/agent \
           /var/lib/strato/vms /var/lib/strato/volumes

  if pgrep "${spire_pattern[@]}" >/dev/null; then
    say "spire-agent already running"
  else
    say "starting spire-agent"
    nohup "$SPIRE_BIN" run -config "$SPIRE_CFG" > "$RUN_DIR/spire-agent.log" 2>&1 &
    echo $! > "$RUN_DIR/spire-agent.pid"
  fi

  # The Strato agent dials the Workload API immediately on boot, so it must
  # exist before we start it.
  for _ in $(seq 1 30); do [[ -S "$WORKLOAD_SOCK" ]] && break; sleep 1; done
  [[ -S "$WORKLOAD_SOCK" ]] || {
    tail -20 "$RUN_DIR/spire-agent.log" >&2
    die "Workload API socket never appeared — see $RUN_DIR/spire-agent.log"
  }
  say "Workload API socket up"

  # A process mid-SIGTERM is on its way out, not a live agent; wait it out.
  for _ in $(seq 1 30); do pgrep -x StratoAgent >/dev/null || break; sleep 1; done
  pgrep -x StratoAgent >/dev/null && die "StratoAgent still running; run 'stop' first"

  say "starting StratoAgent"
  nohup "$AGENT_BIN" --config-file "$AGENT_CFG" > "$RUN_DIR/strato-agent.log" 2>&1 &
  echo $! > "$RUN_DIR/strato-agent.pid"

  sleep 5
  echo; say "--- spire-agent (last 5) ---"; tail -5 "$RUN_DIR/spire-agent.log" 2>/dev/null
  echo; say "--- strato-agent (last 15) ---"
  grep -vE 'SwiftOVN\] (Created|Deleted|Updated)' "$RUN_DIR/strato-agent.log" 2>/dev/null | tail -15
}

do_status() {
  if pgrep -x StratoAgent >/dev/null; then say "StratoAgent: running"; else say "StratoAgent: stopped"; fi
  if pgrep "${spire_pattern[@]}" >/dev/null; then say "spire-agent: running"; else say "spire-agent: stopped"; fi
  if [[ -S "$WORKLOAD_SOCK" ]]; then say "workload socket: present"; else say "workload socket: absent"; fi
  say "RUN_DIR: $RUN_DIR"
}

# strato_unit_state — how systemd relates to a strato-agent unit on this host.
#
#   in-use   systemd is running it now, or would start it at the next boot
#   stale    a unit file exists, but it is disabled and inactive
#   absent   no unit file, or no systemd at all
#
# The mere existence of the unit file is too weak a signal to refuse on. An
# install.sh run months ago leaves a disabled, inactive unit whose ExecStart may
# no longer even resolve; it manages nothing, and refusing on it strands a dev
# host mid-run with no recourse but deleting the unit by hand.
strato_unit_state() {
  command -v systemctl >/dev/null 2>&1 || { echo absent; return; }
  # Matched at line start: `list-unit-files` prints the unit name in column one,
  # and a bare grep would also match it inside a path or a status word.
  systemctl list-unit-files strato-agent.service 2>/dev/null \
    | grep -q '^strato-agent\.service' || { echo absent; return; }

  # `activating`/`deactivating` are mid-transition, not idle, so they count as
  # in use. `is-enabled` covers the other half: a unit that happens to be
  # stopped right now but comes back on the next boot still belongs to systemd.
  case "$(systemctl is-active strato-agent.service 2>/dev/null)" in
    active|activating|reloading|deactivating) echo in-use; return ;;
  esac
  case "$(systemctl is-enabled strato-agent.service 2>/dev/null)" in
    enabled|enabled-runtime|linked|linked-runtime) echo in-use; return ;;
  esac
  echo stale
}

do_reset() {
  # A unit systemd actually runs means deploy/agent/install.sh provisioned this
  # host as a real hypervisor node. Wiping /var/lib/strato/vms there destroys
  # live VM state, so that stays a refusal rather than a prompt. A leftover unit
  # nobody runs only warrants a warning — the confirmation below is already the
  # gate on everything destructive.
  case "$(strato_unit_state)" in
    in-use)
      die "the strato-agent systemd unit is active or enabled — this looks like a
       managed hypervisor node, not a dev host. Refusing to delete
       /var/lib/strato/vms.
       If you really mean it: systemctl disable --now strato-agent"
      ;;
    stale)
      say "WARNING: a strato-agent systemd unit exists but is disabled and inactive."
      say "         Treating it as a leftover from deploy/agent/install.sh rather"
      say "         than a managed node. If it is dead weight, delete it:"
      say "           rm /etc/systemd/system/strato-agent.service && systemctl daemon-reload"
      ;;
  esac

  if [[ "$ASSUME_YES" != 1 ]]; then
    say "reset will DELETE, as root:"
    say "  /var/lib/spire/agent   (this node's SPIRE identity)"
    say "  /var/lib/strato/vms    (every VM disk and manifest on this host)"
    [[ -t 0 ]] || die "refusing to reset without a terminal to ask. Pass --yes if you mean it."
    local reply
    read -r -p "  Continue? [y/N] " reply
    [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]] || die "aborted"
  fi

  do_stop
  say "clearing stale SPIRE identity (issued by the previous CA)"
  rm -rf /var/lib/spire/agent && mkdir -p /var/lib/spire/agent
  say "clearing VM state from previous deployments"
  rm -rf /var/lib/strato/vms && mkdir -p /var/lib/strato/vms
  do_start
}

case "$ACTION" in
  start)  do_start ;;
  stop)   do_stop ;;
  status) do_status ;;
  reset)  do_reset ;;
esac
