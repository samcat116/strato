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
# Lifecycle
#   The fleet's PIDs are tracked in <base-dir>/fleet.pids so --stop/--status
#   work across invocations. Starting is additive: agents already running are
#   skipped, so raising --count grows an existing fleet.
#
#   Registration happens once per agent, not once per start, because the token
#   API refuses to mint a second token for a name in two different ways: the
#   name already has an agent row (unregister only marks it offline, it does not
#   remove it), or the name already has an unused, still-valid token. So each
#   agent keeps two files in its own directory:
#
#     state.json                 written once the agent registers; holds the
#                                rotated reconnect token. Restarts resume from
#                                it, exactly as a real agent does after a reboot.
#     pending-registration.url   the minted registration URL, saved BEFORE the
#                                agent launches. If the process dies before it
#                                opens the socket, the token is never consumed —
#                                and cannot be re-minted — so this file is the
#                                only copy. Reused until state.json appears.
#
#   --stop leaves both files in place and waits for the processes to actually
#   exit before dropping their PID records, so a straggler's late unregister
#   can never land on a freshly started agent of the same name.
#
#   For a genuinely fresh fleet, deregister the agents in the UI (or via
#   DELETE /api/agents/:id) and remove the base dir, or just pick a new
#   --name-prefix.

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
# How long --stop waits for agents to exit before SIGKILLing. Names stay
# reserved (PID records kept) until then, so a late unregister from a
# straggler can never hit a freshly started agent of the same name.
STOP_TIMEOUT=15

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
    # Print the header comment block (everything after the shebang up to the
    # first non-comment line), so help can never drift from a line range.
    -h|--help) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
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

  local pids=() pid name _rest
  while IFS=$'\t' read -r pid name _rest; do
    [[ -z "${pid:-}" ]] && continue
    pids+=("$pid")
  done < "$PID_FILE"

  local stopped=0
  for pid in ${pids[@]+"${pids[@]}"}; do
    if kill -0 "$pid" 2>/dev/null; then
      # SIGTERM triggers the agent's graceful unregister from the control plane.
      kill -TERM "$pid" 2>/dev/null && stopped=$((stopped + 1))
    fi
  done
  echo "Sent SIGTERM to $stopped agent(s); waiting for them to exit..."

  # Wait for the processes to actually exit before releasing their names.
  #
  # A shutting-down agent sends its unregister late, and the control plane
  # resolves that unregister by agent NAME. Two processes started from the same
  # state file share a name and an assigned agent id, so the ownership guard
  # cannot tell them apart: if the PID file were dropped immediately and a
  # replacement started, the straggler's unregister would mark the FRESH agent
  # offline, clear its socket route, and close its console/exec sessions. So the
  # PID records — which is what blocks a name from being reused — must outlive
  # the processes.
  local waited=0 alive=1
  while (( waited < STOP_TIMEOUT )); do
    alive=0
    for pid in ${pids[@]+"${pids[@]}"}; do
      kill -0 "$pid" 2>/dev/null && alive=$((alive + 1))
    done
    (( alive == 0 )) && break
    sleep 1
    waited=$((waited + 1))
  done

  local killed=0
  for pid in ${pids[@]+"${pids[@]}"}; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null && killed=$((killed + 1))
    fi
  done
  if (( killed > 0 )); then
    echo "warning: $killed agent(s) did not exit within ${STOP_TIMEOUT}s and were SIGKILLed." >&2
    echo "  A killed agent never unregisters, so the control plane keeps it online until" >&2
    echo "  its presence TTL lapses. Wait for that before starting these names again." >&2
    sleep 1
  fi

  rm -f "$PID_FILE"
  echo "All agents exited; their names are free to reuse."
  echo "State files kept in $BASE_DIR — starting again resumes these same agents."
  echo "For a clean slate, deregister the agents in the UI and: rm -rf $BASE_DIR"
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

# NOTE: macOS ships bash 3.2, where `set -u` makes "${arr[@]}" on an EMPTY
# array abort with "unbound variable". Every optional-array expansion below
# therefore uses the ${arr[@]+"${arr[@]}"} idiom.
AUTH_ARGS=()
if [[ -n "$API_KEY" ]]; then
  AUTH_ARGS=(-H "Authorization: Bearer $API_KEY")
fi

# Registration tokens currently known to the control plane, fetched once so a
# saved pending URL can be told from a dead one. Empty when the list is
# unavailable (auth, or an older control plane).
TOKENS_JSON="$(curl -sS "$CONTROL_PLANE/api/agents/registration-tokens" \
  ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} 2>/dev/null || true)"
if ! echo "$TOKENS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
  TOKENS_JSON=""
fi

# Whether the control plane still lists a valid, unused token for this name —
# i.e. whether a saved pending URL is still redeemable. When the list is
# unavailable, assume it is: wrongly discarding the URL strands the agent (the
# API refuses to mint a second token while the first is unused and valid),
# whereas wrongly keeping it just fails one launch that a retry fixes.
has_valid_unused_token() {
  local want="$1"
  [[ -z "$TOKENS_JSON" ]] && return 0
  echo "$TOKENS_JSON" | jq -e --arg n "$want" \
    'any(.[]; .agentName == $n and .isUsed == false and .isValid == true)' >/dev/null 2>&1
}

# Whether a live process for this agent name is already recorded.
agent_running() {
  local want="$1" pid name _rest
  [[ -f "$PID_FILE" ]] || return 1
  while IFS=$'\t' read -r pid name _rest; do
    [[ "$name" == "$want" ]] || continue
    kill -0 "$pid" 2>/dev/null && return 0
  done < "$PID_FILE"
  return 1
}

echo "Launching $COUNT simulated agents against $CONTROL_PLANE (org $ORG_ID)"
echo "Profiles (cpus:memMB:diskGB): $PROFILES"
echo "Binary: $AGENT_BIN"
echo "Base dir: $BASE_DIR"
echo

launched=0 resumed=0 reused=0
for i in $(seq 1 "$COUNT"); do
  name="${NAME_PREFIX}-$(printf '%03d' "$i")"
  profile="${PROFILE_ARR[$(( (i - 1) % NUM_PROFILES ))]}"
  IFS=':' read -r cpus mem_mb disk_gb <<< "$profile"

  agent_dir="$BASE_DIR/$name"
  state_file="$agent_dir/state.json"
  pending_file="$agent_dir/pending-registration.url"
  mkdir -p "$agent_dir"
  log_file="$agent_dir/agent.log"

  # Starting is additive, so never double-launch a name that's already up:
  # two processes sharing one agent identity fight over the same socket.
  if agent_running "$name"; then
    echo "  [$name] already running; skipping"
    continue
  fi

  # Registration happens once per agent, not once per start:
  #
  #  - state.json  => already joined. Resume from the rotated reconnect token,
  #    exactly as a real agent does across a reboot. Minting again would 409
  #    ("agent name is already registered") because unregister-on-shutdown only
  #    marks the row offline rather than removing it.
  #  - pending URL => a token was minted but never consumed (the agent died
  #    before it opened the socket). The token is single-use but still UNUSED,
  #    and the API also 409s on "a valid registration token already exists", so
  #    re-minting is impossible until it expires. The minted URL is therefore
  #    saved to disk before launch and reused until state.json appears.
  #  - neither     => mint a fresh token.
  REG_ARGS=()
  if [[ -s "$state_file" ]]; then
    mode="resumed"
    resumed=$((resumed + 1))
    rm -f "$pending_file"  # token was consumed; the record is spent
  elif [[ -s "$pending_file" ]] && has_valid_unused_token "$name"; then
    mode="pending"
    reg_url="$(cat "$pending_file")"
    REG_ARGS=(--registration-url "$reg_url")
    reused=$((reused + 1))
  else
    mode="joined"
    # A saved URL whose token is gone (expired or somehow consumed) is dead
    # weight; drop it so the mint below is the one source of truth.
    rm -f "$pending_file"
    resp="$(curl -sS -X POST "$CONTROL_PLANE/api/agents/registration-tokens" \
      -H "Content-Type: application/json" \
      ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
      -d "{\"agentName\":\"$name\",\"organizationId\":\"$ORG_ID\"}")" || {
        echo "  [$name] token request failed" >&2; continue; }

    reg_url="$(echo "$resp" | jq -r '.registrationURL // empty')"
    if [[ -z "$reg_url" ]]; then
      echo "  [$name] could not get registrationURL. Response:" >&2
      echo "    $resp" >&2
      if echo "$resp" | grep -q 'already registered'; then
        echo "    Hint: this name exists in the control plane but has no local state file." >&2
        echo "    Deregister it in the UI, use --name-prefix, or restore the state file." >&2
      elif echo "$resp" | grep -q 'token already exists'; then
        echo "    Hint: an unused token for this name exists but its URL was not saved" >&2
        echo "    locally. Wait for it to expire (1h by default), delete it with" >&2
        echo "    DELETE $CONTROL_PLANE/api/agents/registration-tokens/<id>, or use --name-prefix." >&2
      fi
      continue
    fi
    # Persist BEFORE launching: the token is spent the moment the agent opens
    # the socket, but if the process dies first this file is the only copy of a
    # credential the API will not re-issue.
    ( umask 077; printf '%s\n' "$reg_url" > "$pending_file" )
    REG_ARGS=(--registration-url "$reg_url")
  fi

  "$AGENT_BIN" run \
    --simulate \
    --agent-id "$name" \
    ${REG_ARGS[@]+"${REG_ARGS[@]}"} \
    --state-file "$state_file" \
    --vm-storage-dir "$agent_dir/vms" \
    --sim-cpus "$cpus" \
    --sim-memory-mb "$mem_mb" \
    --sim-disk-gb "$disk_gb" \
    > "$log_file" 2>&1 &

  pid=$!
  printf '%s\t%s\t%s\n' "$pid" "$name" "$profile" >> "$PID_FILE"
  echo "  [$name] pid $pid ($mode) — ${cpus} vCPU / ${mem_mb} MB / ${disk_gb} GB — log: $log_file"
  launched=$((launched + 1))
done

echo
echo "Launched $launched/$COUNT agents ($resumed resumed from state, $reused reusing a pending token). Tracked in $PID_FILE"
echo "  Status: $0 --status --base-dir $BASE_DIR"
echo "  Stop:   $0 --stop   --base-dir $BASE_DIR"
