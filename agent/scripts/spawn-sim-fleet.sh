#!/usr/bin/env bash
#
# spawn-sim-fleet.sh — launch a fleet of simulated ("dummy") Strato agents for
# scale-testing a control plane. Each agent speaks the full agent protocol
# (register, heartbeat, desired-state reconciliation) but drives a no-op mock
# hypervisor and reports configurable fake host capacity, so hundreds can run on
# one machine that could never host that many real VMs.
#
# For each agent the script mints a single-use registration token via the
# control-plane API, then launches `strato-agent run --simulate` with a distinct
# name, state file, storage dir, and a host size drawn from a spread of profiles
# (so the scheduler faces a realistic mix of small/medium/large hosts).
#
# Usage:
#   spawn-sim-fleet.sh --org-id <UUID> [options]        # start a fleet
#   spawn-sim-fleet.sh --stop                            # stop this fleet
#   spawn-sim-fleet.sh --status                          # list running agents
#
# Options:
#   --count N            Number of agents to launch (default: 10)
#   --org-id UUID        Organization the agents join (required to start).
#                        In `task dev`, list orgs with:
#                          curl -s localhost:8080/api/organizations | jq .
#   --control-plane URL  Control-plane HTTP base URL (default: http://localhost:8080)
#   --name-prefix STR    Agent name prefix (default: sim)
#   --agent-bin PATH     Path to the built agent binary
#                        (default: <repo>/agent/.build/debug/StratoAgent)
#   --base-dir DIR       Where per-agent state/storage/logs live
#                        (default: /tmp/strato-sim-fleet)
#   --api-key KEY        Bearer token for the token API (or set STRATO_API_KEY).
#                        Not needed when the control plane runs with
#                        DEV_AUTH_BYPASS (the default in `task dev`).
#   --profiles LIST      Comma-separated host profiles "cpus:memMB:diskGB"
#                        cycled across the fleet
#                        (default: 8:16384:256,16:65536:512,32:131072:1024)
#   --stop               Stop all agents recorded for this base-dir
#   --status             Show running/stopped state for this base-dir
#   -h, --help           Show this help
#
# The fleet's PIDs are tracked in <base-dir>/fleet.pids so --stop/--status work
# across invocations. Re-running --start appends to an existing fleet.

set -euo pipefail

# --- defaults -----------------------------------------------------------------
COUNT=10
ORG_ID=""
CONTROL_PLANE="http://localhost:8080"
NAME_PREFIX="sim"
AGENT_BIN=""
BASE_DIR="/tmp/strato-sim-fleet"
API_KEY="${STRATO_API_KEY:-}"
PROFILES="8:16384:256,16:65536:512,32:131072:1024"
ACTION="start"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- arg parsing --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --count) COUNT="$2"; shift 2 ;;
    --org-id) ORG_ID="$2"; shift 2 ;;
    --control-plane) CONTROL_PLANE="$2"; shift 2 ;;
    --name-prefix) NAME_PREFIX="$2"; shift 2 ;;
    --agent-bin) AGENT_BIN="$2"; shift 2 ;;
    --base-dir) BASE_DIR="$2"; shift 2 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --profiles) PROFILES="$2"; shift 2 ;;
    --stop) ACTION="stop"; shift ;;
    --status) ACTION="status"; shift ;;
    -h|--help) sed -n '2,48p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

PID_FILE="$BASE_DIR/fleet.pids"

# --- stop / status ------------------------------------------------------------
stop_fleet() {
  if [[ ! -f "$PID_FILE" ]]; then
    echo "No fleet PID file at $PID_FILE — nothing to stop."
    return 0
  fi
  local stopped=0
  while IFS=$'\t' read -r pid name _; do
    [[ -z "${pid:-}" ]] && continue
    if kill -0 "$pid" 2>/dev/null; then
      # SIGTERM triggers the agent's graceful unregister from the control plane.
      kill -TERM "$pid" 2>/dev/null && stopped=$((stopped + 1))
    fi
  done < "$PID_FILE"
  echo "Sent SIGTERM to $stopped agent(s). They unregister on shutdown."
  rm -f "$PID_FILE"
}

status_fleet() {
  if [[ ! -f "$PID_FILE" ]]; then
    echo "No fleet PID file at $PID_FILE."
    return 0
  fi
  local running=0 dead=0
  printf '%-24s %-8s %s\n' "NAME" "PID" "STATE"
  while IFS=$'\t' read -r pid name profile; do
    [[ -z "${pid:-}" ]] && continue
    if kill -0 "$pid" 2>/dev/null; then
      printf '%-24s %-8s %s\n' "$name" "$pid" "running ($profile)"
      running=$((running + 1))
    else
      printf '%-24s %-8s %s\n' "$name" "$pid" "exited"
      dead=$((dead + 1))
    fi
  done < "$PID_FILE"
  echo "---"
  echo "$running running, $dead exited"
}

if [[ "$ACTION" == "stop" ]]; then stop_fleet; exit 0; fi
if [[ "$ACTION" == "status" ]]; then status_fleet; exit 0; fi

# --- start: preconditions -----------------------------------------------------
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v jq   >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }

if [[ -z "$ORG_ID" ]]; then
  echo "error: --org-id is required to start a fleet." >&2
  echo "In task dev, find one with: curl -s $CONTROL_PLANE/api/organizations | jq ." >&2
  exit 2
fi

if [[ -z "$AGENT_BIN" ]]; then
  AGENT_BIN="$REPO_ROOT/agent/.build/debug/StratoAgent"
fi
if [[ ! -x "$AGENT_BIN" ]]; then
  echo "error: agent binary not found/executable at $AGENT_BIN" >&2
  echo "Build it first: swift build --package-path $REPO_ROOT/agent" >&2
  exit 1
fi

mkdir -p "$BASE_DIR"

# Parse the profile spread into arrays.
IFS=',' read -r -a PROFILE_ARR <<< "$PROFILES"
NUM_PROFILES=${#PROFILE_ARR[@]}
if [[ "$NUM_PROFILES" -eq 0 ]]; then
  echo "error: no profiles parsed from --profiles" >&2; exit 1
fi

AUTH_ARGS=()
if [[ -n "$API_KEY" ]]; then
  AUTH_ARGS=(-H "Authorization: Bearer $API_KEY")
fi

echo "Launching $COUNT simulated agents against $CONTROL_PLANE (org $ORG_ID)"
echo "Profiles (cpus:memMB:diskGB): $PROFILES"
echo "Binary: $AGENT_BIN"
echo "Base dir: $BASE_DIR"
echo

# Derive the WebSocket-side base once for logging; the registration URL itself
# comes back from the API per token.
launched=0
for i in $(seq 1 "$COUNT"); do
  name="${NAME_PREFIX}-$(printf '%03d' "$i")"
  profile="${PROFILE_ARR[$(( (i - 1) % NUM_PROFILES ))]}"
  IFS=':' read -r cpus mem_mb disk_gb <<< "$profile"

  # 1) Mint a single-use registration token for this agent.
  resp="$(curl -sS -X POST "$CONTROL_PLANE/api/agents/registration-tokens" \
    -H "Content-Type: application/json" \
    "${AUTH_ARGS[@]}" \
    -d "{\"agentName\":\"$name\",\"organizationId\":\"$ORG_ID\"}")" || {
      echo "  [$name] token request failed" >&2; continue; }

  reg_url="$(echo "$resp" | jq -r '.registrationURL // empty')"
  if [[ -z "$reg_url" ]]; then
    echo "  [$name] could not get registrationURL. Response:" >&2
    echo "    $resp" >&2
    continue
  fi

  # 2) Launch the simulated agent with a private state file + storage dir.
  agent_dir="$BASE_DIR/$name"
  mkdir -p "$agent_dir"
  log_file="$agent_dir/agent.log"

  "$AGENT_BIN" run \
    --simulate \
    --agent-id "$name" \
    --registration-url "$reg_url" \
    --state-file "$agent_dir/state.json" \
    --vm-storage-dir "$agent_dir/vms" \
    --sim-cpus "$cpus" \
    --sim-memory-mb "$mem_mb" \
    --sim-disk-gb "$disk_gb" \
    > "$log_file" 2>&1 &

  pid=$!
  printf '%s\t%s\t%s\n' "$pid" "$name" "$profile" >> "$PID_FILE"
  echo "  [$name] pid $pid — ${cpus} vCPU / ${mem_mb} MB / ${disk_gb} GB — log: $log_file"
  launched=$((launched + 1))
done

echo
echo "Launched $launched/$COUNT agents. Tracked in $PID_FILE"
echo "  Status: $0 --status --base-dir $BASE_DIR"
echo "  Stop:   $0 --stop   --base-dir $BASE_DIR"
