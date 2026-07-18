#!/usr/bin/env bash
#
# spawn-sim-fleet.sh — launch a fleet of simulated ("dummy") Strato agents for
# scale-testing a control plane. Each agent speaks the full agent protocol
# (register, heartbeat, desired-state reconciliation) but drives a no-op mock
# hypervisor and a no-op mock sandbox runtime, and reports configurable fake
# host capacity, so hundreds can run on one machine that could never host that
# many real VMs or sandboxes.
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
#   --allow-existing-agents
#                        Skip the pre-launch check that refuses to start when
#                        the target org already has agents outside this fleet
#                        (see "Never mix" below). Use only when those are also
#                        simulated agents.
#   --stop               Stop all agents recorded for this base-dir
#   --status             Show running/stopped state for this base-dir
#   -h, --help           Show this help
#
# Never mix simulated and real agents in one control plane / org
#   A simulated agent advertises QEMU, sandbox support, and full capacity, so
#   the scheduler and the volume selector treat it as a real host. In a control
#   plane that also has real agents, a real VM or sandbox can be scheduled onto
#   a dummy (and "run" on the mock backend while nothing actually runs), and a
#   real volume can be created on a dummy with a path that does not exist and
#   then fail when a real workload attaches it. The control plane cannot currently tell simulated
#   agents from real ones, so the only safe arrangement is a dedicated control
#   plane or a dedicated org for simulation. As a safeguard the script refuses
#   to launch into an org that already holds agents outside this fleet; override
#   with --allow-existing-agents when those are also simulated.
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
#   fleet.pids records outlive the processes they name, and PIDs get recycled,
#   so a recorded PID is never trusted on liveness alone: a process counts as a
#   fleet member only if its command line still carries this fleet's
#   --state-file for that name. Stale records are reported and pruned, never
#   signalled — the number may belong to someone else's process by then.
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
# Refuse to launch into an org that already has agents which are not part of
# this fleet, since a simulated agent must never share a placement pool with a
# real one (see the "Never mix" note in the header). Override with the flag.
ALLOW_EXISTING_AGENTS=0
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
    --allow-existing-agents) ALLOW_EXISTING_AGENTS=1; shift ;;
    --stop) ACTION="stop"; shift ;;
    --status) ACTION="status"; shift ;;
    # Print the header comment block (everything after the shebang up to the
    # first non-comment line), so help can never drift from a line range.
    -h|--help) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# Normalize the base dir to a real absolute path before anything derives from
# it. Each agent's identity check below matches the --state-file string recorded
# in its command line, so that string has to come out identical whether the
# caller passed a relative path, a trailing slash, or /tmp (a symlink to
# /private/tmp on macOS).
mkdir -p "$BASE_DIR" 2>/dev/null || true
BASE_DIR="$(cd "$BASE_DIR" 2>/dev/null && pwd -P)" || {
  echo "error: cannot resolve --base-dir '$BASE_DIR'" >&2; exit 1; }

PID_FILE="$BASE_DIR/fleet.pids"

# --- pid identity -------------------------------------------------------------

# Whether $pid really is this fleet's agent for $name, as opposed to an
# unrelated process that inherited a recycled PID.
#
# fleet.pids lives under the base dir (/tmp by default) and outlives the
# processes it records, so `kill -0` alone proves only that *something* answers
# to that number — not that it is ours. Trusting it would let --stop SIGTERM a
# stranger's process, and let --status/start misjudge which agents are up. The
# agent's own --state-file argument is unique to (base dir, name), so match on
# that. Uses `ps -ww` for the untruncated command line, and a case glob rather
# than grep so path metacharacters cannot be reinterpreted as a pattern.
pid_is_fleet_agent() {
  local pid="$1" name="$2" cmd
  cmd="$(ps -ww -o command= -p "$pid" 2>/dev/null)" || return 1
  [[ -n "$cmd" ]] || return 1
  case "$cmd" in
    *"--state-file $BASE_DIR/$name/state.json"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Drop records whose process is gone (or was never ours), so the file cannot
# grow without bound or accumulate PIDs that a later process may inherit.
prune_pid_file() {
  [[ -f "$PID_FILE" ]] || return 0
  local tmp pid name profile
  tmp="$(mktemp "$PID_FILE.XXXXXX")"
  while IFS=$'\t' read -r pid name profile; do
    [[ -z "${pid:-}" ]] && continue
    if pid_is_fleet_agent "$pid" "$name"; then
      printf '%s\t%s\t%s\n' "$pid" "$name" "$profile" >> "$tmp"
    fi
  done < "$PID_FILE"
  mv "$tmp" "$PID_FILE"
}

# --- stop / status ------------------------------------------------------------
stop_fleet() {
  if [[ ! -f "$PID_FILE" ]]; then
    echo "No fleet PID file at $PID_FILE — nothing to stop."
    return 0
  fi

  # Only ever signal PIDs that are still verifiably our agents. A stale record
  # whose PID has been recycled belongs to someone else, and SIGTERMing it would
  # kill an unrelated process.
  local pids=() names=() pid name _rest stale=0
  while IFS=$'\t' read -r pid name _rest; do
    [[ -z "${pid:-}" ]] && continue
    if pid_is_fleet_agent "$pid" "$name"; then
      pids+=("$pid"); names+=("$name")
    else
      stale=$((stale + 1))
    fi
  done < "$PID_FILE"

  if (( stale > 0 )); then
    echo "Ignoring $stale stale record(s): the process is gone or the PID is no longer ours."
  fi

  local stopped=0
  for pid in ${pids[@]+"${pids[@]}"}; do
    # SIGTERM triggers the agent's graceful unregister from the control plane.
    kill -TERM "$pid" 2>/dev/null && stopped=$((stopped + 1))
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
  # Re-check identity on every poll, not just liveness: a PID that exits here can
  # in principle be reissued to an unrelated process, and the SIGKILL below must
  # never land on it.
  local waited=0 alive=1 i
  while (( waited < STOP_TIMEOUT )); do
    alive=0
    for (( i = 0; i < ${#pids[@]}; i++ )); do
      pid_is_fleet_agent "${pids[$i]}" "${names[$i]}" && alive=$((alive + 1))
    done
    (( alive == 0 )) && break
    sleep 1
    waited=$((waited + 1))
  done

  local killed=0
  for (( i = 0; i < ${#pids[@]}; i++ )); do
    if pid_is_fleet_agent "${pids[$i]}" "${names[$i]}"; then
      kill -9 "${pids[$i]}" 2>/dev/null && killed=$((killed + 1))
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
  local running=0 dead=0 stale=0
  printf '%-24s %-8s %s\n' "NAME" "PID" "STATE"
  while IFS=$'\t' read -r pid name profile; do
    [[ -z "${pid:-}" ]] && continue
    if pid_is_fleet_agent "$pid" "$name"; then
      printf '%-24s %-8s %s\n' "$name" "$pid" "running ($profile)"
      running=$((running + 1))
    elif kill -0 "$pid" 2>/dev/null; then
      # Something answers to this PID, but it is not our agent — the record is
      # stale and the number has been reused. Never touch that process.
      printf '%-24s %-8s %s\n' "$name" "$pid" "stale (pid reused by another process)"
      stale=$((stale + 1))
    else
      printf '%-24s %-8s %s\n' "$name" "$pid" "exited"
      dead=$((dead + 1))
    fi
  done < "$PID_FILE"
  echo "---"
  echo "$running running, $dead exited, $stale stale"
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

# Safety guard: never let a simulated fleet share a control plane with real
# agents. A simulated agent advertises QEMU and full capacity, so the scheduler
# and the volume selector treat it as a real host — a real VM can be placed on
# one (and "run" on the mock), or a real volume can be created on one with a
# path that does not exist. The control plane has no way to tell simulated from
# real (that fix is tracked separately), so the only protection is not to mix
# them. Refuse if the target org already has agents that are not part of THIS
# fleet (name not prefixed with "$NAME_PREFIX-"); --allow-existing-agents
# overrides (e.g. two simulated fleets sharing an org on purpose).
#
# Best effort: if the list cannot be read (auth, older control plane), warn and
# proceed rather than block, since the guard is a convenience, not a gate.
if [[ "$ALLOW_EXISTING_AGENTS" -eq 0 ]]; then
  agents_json="$(curl -sS "$CONTROL_PLANE/api/agents" \
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} 2>/dev/null || true)"
  if echo "$agents_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    foreign="$(echo "$agents_json" | jq -r --arg org "$ORG_ID" --arg pre "$NAME_PREFIX-" \
      '[.[] | select(.organizationId == $org) | select(.name | startswith($pre) | not) | .name] | .[]' \
      2>/dev/null || true)"
    if [[ -n "$foreign" ]]; then
      echo "error: the target org already has agent(s) that are not part of this fleet:" >&2
      while IFS= read -r a; do [[ -n "$a" ]] && echo "    $a" >&2; done <<< "$foreign"
      echo "  A simulated fleet must not share a control plane/org with real agents:" >&2
      echo "  real workloads could be scheduled onto a dummy, or get volumes with" >&2
      echo "  paths that do not exist. Use a dedicated org or control plane for" >&2
      echo "  simulation. If these are also simulated agents, re-run with" >&2
      echo "  --allow-existing-agents." >&2
      exit 3
    fi
  else
    echo "warning: could not list existing agents to check for a mixed fleet; proceeding." >&2
    echo "  Make sure this org has no real agents (see --allow-existing-agents)." >&2
  fi
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

# Whether a live process for this agent name is already recorded. Identity, not
# just liveness: a stale record whose PID was recycled must not make us skip an
# agent that is actually down.
agent_running() {
  local want="$1" pid name _rest
  [[ -f "$PID_FILE" ]] || return 1
  while IFS=$'\t' read -r pid name _rest; do
    [[ "$name" == "$want" ]] || continue
    pid_is_fleet_agent "$pid" "$name" && return 0
  done < "$PID_FILE"
  return 1
}

echo "Launching $COUNT simulated agents against $CONTROL_PLANE (org $ORG_ID)"
echo "Profiles (cpus:memMB:diskGB): $PROFILES"
echo "Binary: $AGENT_BIN"
echo "Base dir: $BASE_DIR"
echo

# Drop records for processes that are gone before appending new ones, so the
# file tracks only live agents and cannot accumulate PIDs that the OS may
# later hand to unrelated processes.
prune_pid_file

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
