#!/usr/bin/env bash
#
# e2e-agent.sh — run a natively-built Strato agent against a local stack.
#
#   sudo bash deploy/compose/e2e-agent.sh start     # spire-agent + strato-agent
#   sudo bash deploy/compose/e2e-agent.sh stop
#   sudo bash deploy/compose/e2e-agent.sh reset     # clear stale state, then start
#   sudo bash deploy/compose/e2e-agent.sh status
#
# Root is required and not negotiable: the SPIRE workload entry that e2e-up.sh
# provisions has selector `unix:uid:0`, so a non-root agent gets no SVID and the
# control plane refuses the connection.
#
# This is a DEVELOPMENT launcher — no systemd, logs to files under RUN_DIR. For
# real hypervisor nodes use deploy/agent/install.sh, which installs host deps,
# writes systemd units, and manages upgrades.
#
# `reset` is what you want after `e2e-up.sh --fresh`. Tearing the stack down with
# `down -v` gives the SPIRE server a new CA, which invalidates two things on this
# host: the cached node SVID in /var/lib/spire/agent (spire-agent would try to
# re-attest with it and silently ignore the fresh join token), and every VM under
# /var/lib/strato/vms (the new control plane has never heard of them, so the
# reconciler reports each as an orphan). `reset` clears both.
#
# Environment overrides:
#   RUN_DIR     launch files + logs        (default /home/sam/strato-agent-run)
#   AGENT_BIN   agent binary               (default <repo>/agent/.build/debug/StratoAgent)
#   AGENT_CFG   agent TOML config          (default /etc/strato/config.toml)
#   SPIRE_BIN   spire-agent binary         (default /usr/local/bin/spire-agent)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_DIR="${RUN_DIR:-/home/sam/strato-agent-run}"
AGENT_BIN="${AGENT_BIN:-$REPO_ROOT/agent/.build/debug/StratoAgent}"
AGENT_CFG="${AGENT_CFG:-/etc/strato/config.toml}"
SPIRE_BIN="${SPIRE_BIN:-/usr/local/bin/spire-agent}"
SPIRE_CFG="$RUN_DIR/spire-agent.conf"
WORKLOAD_SOCK="/var/run/spire/sockets/workload.sock"

say() { printf '  %s\n' "$*"; }
die() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  start|stop|reset|status) ;;
  *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

[[ $EUID -eq 0 ]] || die "must run as root (SPIRE workload selector is unix:uid:0)"

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
  [[ -f "$AGENT_CFG" ]] || die "no agent config at $AGENT_CFG"
  [[ -f "$SPIRE_CFG" ]] || die "no $SPIRE_CFG — run deploy/compose/e2e-up.sh first
       (it enrolls this node and writes the join token here)"
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
  pgrep -x StratoAgent >/dev/null && say "StratoAgent: running" || say "StratoAgent: stopped"
  pgrep "${spire_pattern[@]}" >/dev/null && say "spire-agent: running" || say "spire-agent: stopped"
  [[ -S "$WORKLOAD_SOCK" ]] && say "workload socket: present" || say "workload socket: absent"
}

case "$1" in
  start)  do_start ;;
  stop)   do_stop ;;
  status) do_status ;;
  reset)
    do_stop
    say "clearing stale SPIRE identity (issued by the previous CA)"
    rm -rf /var/lib/spire/agent && mkdir -p /var/lib/spire/agent
    say "clearing VM state from previous deployments"
    rm -rf /var/lib/strato/vms && mkdir -p /var/lib/strato/vms
    do_start
    ;;
esac
