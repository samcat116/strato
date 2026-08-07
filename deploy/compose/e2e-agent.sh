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
# Warnings go to stderr, matching deploy/agent/install.sh's warn().
warn() { printf '  %s\n' "$*" >&2; }
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
# Echoes three fields: `<state> <is-active> <is-enabled>`, where state is
#
#   in-use   systemd is running it now, or owns it for the next boot
#   stale    a unit file exists, but systemd is not running it
#   absent   no unit file, or no systemd at all
#
# The raw values ride along so the caller can report what it actually saw
# rather than restating the branch it landed in.
#
# The mere existence of the unit file is too weak a signal to refuse on. An
# install.sh run months ago leaves a disabled, inactive unit whose ExecStart may
# no longer even resolve; it manages nothing, and refusing on it strands a dev
# host mid-run with no recourse but deleting the unit by hand.
strato_unit_state() {
  local units active enabled
  command -v systemctl >/dev/null 2>&1 || { echo "absent - -"; return; }

  # Deliberately not a pipeline. `grep -q` exits at its first match, so under
  # `pipefail` a SIGPIPE'd `systemctl` would fail the test and report `absent` —
  # the guard vanishing in the unsafe direction.
  units="$(systemctl list-unit-files strato-agent.service 2>/dev/null)"
  # Anchored at line start: a bare `strato-agent` would also match the name
  # inside a path or a status word.
  grep -q '^strato-agent\.service' <<<"$units" || { echo "absent - -"; return; }

  active="$(systemctl is-active strato-agent.service 2>/dev/null)"
  enabled="$(systemctl is-enabled strato-agent.service 2>/dev/null)"

  # A denylist, not an allowlist: everything that falls through here reaches
  # `rm -rf /var/lib/strato/vms`, so the unknown case has to land on the safe
  # side. Only these two mean "genuinely not running"; transitional states,
  # states systemd adds later (`refreshing`, v254+), and the empty string from a
  # systemctl that failed after the unit-file check all read as in use. A false
  # refusal costs the one command the error message prints; a false `stale`
  # deletes VM disks.
  case "$active" in
    inactive|failed) ;;
    *) echo "in-use ${active:-unknown} ${enabled:-unknown}"; return ;;
  esac

  # `is-enabled` stays an allowlist: the values it can return that are missing
  # here (`static`, `indirect`, `generated`, `transient`) all describe units
  # whose live instances `is-active` has already caught above. What these five
  # share is that systemd owns the unit file — `enabled`/`enabled-runtime` start
  # it at the next boot, while `linked`/`linked-runtime`/`alias` make a file
  # outside the search path known to systemd under another path or name. None of
  # them is a file this script gets to call abandoned.
  case "$enabled" in
    enabled|enabled-runtime|linked|linked-runtime|alias)
      echo "in-use ${active:-unknown} ${enabled:-unknown}"; return ;;
  esac
  echo "stale ${active:-unknown} ${enabled:-unknown}"
}

# strato_guests_running — pids of hypervisor processes backed by the VM state
# directory `reset` deletes. Empty output means none.
#
# Scoped to /var/lib/strato/vms rather than matching qemu/firecracker outright:
# a dev host may legitimately run unrelated guests, and refusing on those would
# recreate the very false positive this guard exists to remove. Matching the
# path matches the disks that are about to disappear, which is the thing worth
# protecting. It also covers the Firecracker jailer (its chroot lives under the
# same tree, see Agent.swift's sandboxJailerChrootDir), and it is the only half
# of this guard that works at all on the non-systemd hosts install.sh supports.
strato_guests_running() {
  pgrep -f '/var/lib/strato/vms' 2>/dev/null | grep -vx "$$" || true
}

do_reset() {
  # A unit systemd actually runs means deploy/agent/install.sh provisioned this
  # host as a real hypervisor node. Wiping /var/lib/strato/vms there destroys
  # live VM state, so that stays a refusal rather than a prompt. A leftover unit
  # nobody runs only warrants a warning — the confirmation below is already the
  # gate on everything destructive.
  local state active enabled guests
  read -r state active enabled <<<"$(strato_unit_state)"

  case "$state" in
    in-use)
      die "the strato-agent systemd unit is in use (is-active=$active,
       is-enabled=$enabled) — this looks like a managed hypervisor node, not a
       dev host. Refusing to delete /var/lib/strato/vms.
       If you really mean it: systemctl disable --now strato-agent"
      ;;
    stale)
      warn "WARNING: strato-agent.service exists but systemd is not running it"
      warn "         (is-active=$active, is-enabled=$enabled). Treating it as a"
      warn "         leftover from deploy/agent/install.sh, not a managed node."
      if [[ "$enabled" == masked ]]; then
        warn "         To clear it: systemctl unmask strato-agent"
      else
        warn "         To clear it: rm /etc/systemd/system/strato-agent.service &&"
        warn "                      systemctl daemon-reload"
      fi
      ;;
  esac

  # Checked independently of systemd's opinion. Live guests are what
  # /var/lib/strato/vms actually protects, and reaching `stale` only takes a
  # deliberate `systemctl disable --now` — which is exactly what someone does
  # for maintenance while the guests it started keep running, since they outlive
  # the agent by design. On a non-systemd host this is the only check there is.
  guests="$(strato_guests_running)"
  if [[ -n "$guests" ]]; then
    die "hypervisor processes are still backed by /var/lib/strato/vms
       (pids: $(tr '\n' ' ' <<<"$guests"))
       Deleting it would pull the disks out from under live guests. Stop them
       first, or remove the paths by hand if you know they are already dead."
  fi

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
