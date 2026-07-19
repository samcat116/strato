#!/usr/bin/env bash
#
# spawn-sim-fleet.sh — launch a fleet of simulated ("dummy") Strato agents for
# scale-testing a control plane. Each agent speaks the full agent protocol
# (register, heartbeat, desired-state reconciliation) but drives a no-op mock
# hypervisor and a no-op mock sandbox runtime, and reports configurable fake
# host capacity, so hundreds can run on one machine that could never host that
# many real VMs or sandboxes.
#
# For each agent the script creates an enrollment via the control-plane API,
# writes a per-agent config.toml, and launches `strato-agent run --simulate`
# with a distinct name, state file, storage dir, and a host size drawn from a
# spread of profiles (so the scheduler faces a realistic mix of small/medium/
# large hosts).
#
# Agent identity is SPIFFE-only
#   Agents authenticate to the control plane exclusively with an X.509 SVID over
#   mTLS. A simulated fleet cannot attest itself: SPIRE workload attestation
#   keys off unix uid/binary path, which cannot distinguish N copies of the same
#   binary run by the same user, so one spire-agent would hand every dummy the
#   same identity. The fleet therefore uses file-based SVIDs — one per agent,
#   minted out of band against your SPIRE server — and the agent config points
#   at them with `[spiffe] source_type = "files"`.
#
#   Pass --svid-dir DIR containing one subdirectory per agent name:
#
#     DIR/<name>/svid.pem  svid_key.pem  bundle.pem
#
#   Mint them on the SPIRE server, e.g. for each agent name:
#
#     spire-server x509 mint -spiffeID spiffe://<trust-domain>/agent/<name> \
#       -write DIR/<name>
#
#   This needs SPIRE server access, so a simulated fleet is only practical
#   against a control plane whose SPIRE server you administer.
#
# Usage:
#   spawn-sim-fleet.sh --org-id <UUID> --svid-dir <DIR> [options]  # start
#   spawn-sim-fleet.sh --stop                            # stop this fleet
#   spawn-sim-fleet.sh --status                          # list running agents
#
# Options:
#   --count N            Number of agents to launch (default: 10)
#   --org-id UUID        Organization the agents join (required to start).
#                        List orgs with:
#                          curl -s -H "Authorization: Bearer $STRATO_API_KEY" \
#                            localhost:8080/api/organizations | jq .
#   --svid-dir DIR       Per-agent SVID material (required to start); see
#                        "Agent identity is SPIFFE-only" above
#   --agent-ws-url URL   Agent WebSocket endpoint the dummies dial
#                        (default: derived from --control-plane, /agent/ws)
#   --trust-domain TD    SPIFFE trust domain (default: strato.local)
#   --control-plane URL  Control-plane HTTP base URL (default: http://localhost:8080)
#   --name-prefix STR    Agent name prefix (default: sim)
#   --agent-bin PATH     Path to the built agent binary
#                        (default: <repo>/agent/.build/debug/StratoAgent)
#   --base-dir DIR       Where per-agent state/storage/logs live
#                        (default: /tmp/strato-sim-fleet)
#   --api-key KEY        Bearer token for the control-plane API, required since
#                        authentication is always enforced (or set
#                        STRATO_API_KEY). Create one under your user's API keys.
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
#   Enrollment happens once per agent, not once per start: the API refuses a
#   second enrollment for a name that already has an agent row (unregister only
#   marks it offline, it does not remove it) or an open enrollment. Agents keep
#   no local credential state — identity is the SVID and the --agent-id name —
#   so each agent's directory holds only a generated config.toml (the
#   control-plane URL and the [spiffe] block pointing at its SVID files),
#   rewritten on every start so --svid-dir changes take effect.
#
#   --stop leaves both files in place and waits for the processes to actually
#   exit before dropping their PID records, so a straggler's late unregister
#   can never land on a freshly started agent of the same name.
#
#   fleet.pids records outlive the processes they name, and PIDs get recycled,
#   so a recorded PID is never trusted on liveness alone: a process counts as a
#   fleet member only if its command line still carries this fleet's
#   --vm-storage-dir for that name. Stale records are reported and pruned, never
#   signalled — the number may belong to someone else's process by then.
#
#   For a genuinely fresh fleet, deregister the agents in the UI (or via
#   DELETE /api/agents/:id), delete their enrollments (DELETE
#   /api/agents/enrollments/:id) and remove the base dir, or just pick a new
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
SVID_DIR=""
AGENT_WS_URL=""
TRUST_DOMAIN="strato.local"
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
    --svid-dir) SVID_DIR="$2"; shift 2 ;;
    --agent-ws-url) AGENT_WS_URL="$2"; shift 2 ;;
    --trust-domain) TRUST_DOMAIN="$2"; shift 2 ;;
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
# it. Each agent's identity check below matches the --vm-storage-dir string
# recorded in its command line, so that string has to come out identical whether the
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
# agent's own --vm-storage-dir argument is unique to (base dir, name), so match
# on that. Uses `ps -ww` for the untruncated command line, and a case glob
# rather than grep so path metacharacters cannot be reinterpreted as a pattern.
pid_is_fleet_agent() {
  local pid="$1" name="$2" cmd
  cmd="$(ps -ww -o command= -p "$pid" 2>/dev/null)" || return 1
  [[ -n "$cmd" ]] || return 1
  case "$cmd" in
    *"--vm-storage-dir $BASE_DIR/$name/vms"*) return 0 ;;
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
  echo "Find one with: curl -s -H \"Authorization: Bearer \$STRATO_API_KEY\" \\" >&2
  echo "  $CONTROL_PLANE/api/organizations | jq ." >&2
  exit 2
fi

if [[ -z "$API_KEY" ]]; then
  echo "error: --api-key (or STRATO_API_KEY) is required — the control-plane API" >&2
  echo "always enforces authentication. Create a key under your user's API keys." >&2
  exit 2
fi

# Agents authenticate only by SVID, and a simulated fleet cannot attest itself
# (see the header). One SVID per agent, minted out of band, is the only way in.
if [[ -z "$SVID_DIR" ]]; then
  echo "error: --svid-dir is required to start a fleet." >&2
  echo "Agents authenticate only with a SPIFFE X.509 SVID over mTLS, and simulated" >&2
  echo "agents cannot attest themselves: SPIRE workload attestation keys off unix" >&2
  echo "uid/binary path, so every dummy on this host would get one shared identity." >&2
  echo "Mint one SVID per agent on your SPIRE server instead:" >&2
  echo "  spire-server x509 mint -spiffeID spiffe://$TRUST_DOMAIN/agent/<name> \\" >&2
  echo "    -write <svid-dir>/<name>" >&2
  exit 2
fi
if [[ ! -d "$SVID_DIR" ]]; then
  echo "error: --svid-dir '$SVID_DIR' is not a directory" >&2; exit 2
fi
SVID_DIR="$(cd "$SVID_DIR" && pwd -P)"

# The dummies dial this with ?name=<agent>; in a SPIRE deployment it is the
# Envoy mTLS listener, not the plain HTTP origin.
if [[ -z "$AGENT_WS_URL" ]]; then
  case "$CONTROL_PLANE" in
    https://*) AGENT_WS_URL="wss://${CONTROL_PLANE#https://}/agent/ws" ;;
    http://*)  AGENT_WS_URL="ws://${CONTROL_PLANE#http://}/agent/ws" ;;
    *) echo "error: --control-plane must start with http:// or https://" >&2; exit 2 ;;
  esac
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

# Enrollments currently known to the control plane, fetched once so an agent
# that is already enrolled is not enrolled again. Empty when the list is
# unavailable (auth, or an older control plane).
ENROLLMENTS_JSON="$(curl -sS "$CONTROL_PLANE/api/agents/enrollments" \
  ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} 2>/dev/null || true)"
if ! echo "$ENROLLMENTS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
  ENROLLMENTS_JSON=""
fi

# Whether the control plane already has an enrollment for this name. When the
# list is unavailable, assume it does not and let the POST below be the
# authority — a duplicate is rejected server-side, which is a clear error,
# whereas skipping a needed enrollment strands the agent silently.
has_enrollment() {
  local want="$1"
  [[ -z "$ENROLLMENTS_JSON" ]] && return 1
  echo "$ENROLLMENTS_JSON" | jq -e --arg n "$want" \
    'any(.[]; .agentName == $n)' >/dev/null 2>&1
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

launched=0 reused=0
for i in $(seq 1 "$COUNT"); do
  name="${NAME_PREFIX}-$(printf '%03d' "$i")"
  profile="${PROFILE_ARR[$(( (i - 1) % NUM_PROFILES ))]}"
  IFS=':' read -r cpus mem_mb disk_gb <<< "$profile"

  agent_dir="$BASE_DIR/$name"
  config_file="$agent_dir/config.toml"
  mkdir -p "$agent_dir"
  log_file="$agent_dir/agent.log"

  # Starting is additive, so never double-launch a name that's already up:
  # two processes sharing one agent identity fight over the same socket.
  if agent_running "$name"; then
    echo "  [$name] already running; skipping"
    continue
  fi

  # This agent's SVID, minted out of band against the SPIRE server (see the
  # header). Without it the mTLS handshake fails at the proxy with an opaque
  # TLS error, so check up front and say why.
  svid_dir="$SVID_DIR/$name"
  missing=""
  for f in svid.pem svid_key.pem bundle.pem; do
    [[ -s "$svid_dir/$f" ]] || missing="$missing $f"
  done
  if [[ -n "$missing" ]]; then
    echo "  [$name] missing SVID material in $svid_dir:$missing" >&2
    echo "    Mint it with: spire-server x509 mint \\" >&2
    echo "      -spiffeID spiffe://$TRUST_DOMAIN/agent/$name -write $svid_dir" >&2
    continue
  fi

  # Enrollment happens once per agent, not once per start. An agent that is
  # already enrolled just starts; enrolling again would 409 ("agent name is
  # already registered") because unregister-on-shutdown only marks the row
  # offline rather than removing it. A new enrollment's SPIRE join token is
  # ignored: the dummy uses the file-based SVID above rather than attesting.
  if has_enrollment "$name"; then
    mode="enrolled"
    reused=$((reused + 1))
  else
    mode="new"
    resp="$(curl -sS -X POST "$CONTROL_PLANE/api/agents/enrollments" \
      -H "Content-Type: application/json" \
      ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
      -d "{\"agentName\":\"$name\",\"organizationId\":\"$ORG_ID\"}")" || {
        echo "  [$name] enrollment request failed" >&2; continue; }

    if ! echo "$resp" | jq -e '.id // empty' >/dev/null 2>&1; then
      echo "  [$name] enrollment failed. Response:" >&2
      echo "    $resp" >&2
      if echo "$resp" | grep -q 'already registered'; then
        echo "    Hint: this name exists in the control plane but has no local state file." >&2
        echo "    Deregister it in the UI, use --name-prefix, or restore the state file." >&2
      elif echo "$resp" | grep -qi 'spire'; then
        echo "    Hint: enrollment requires the control plane to be configured for SPIRE" >&2
        echo "    (SPIRE_ENABLED=true plus SPIRE_SERVER_API_ADDRESS)." >&2
      fi
      continue
    fi
  fi

  # Rewritten on every start so a changed --svid-dir or --agent-ws-url takes
  # effect without hand-editing per-agent files.
  ( umask 077; cat > "$config_file" << EOF
# Generated by spawn-sim-fleet.sh — regenerated on every start.
# The agent's name is not a config field: it comes from --agent-id below.
control_plane_url = "$AGENT_WS_URL"
network_mode = "user"

[spiffe]
enabled = true
trust_domain = "$TRUST_DOMAIN"
source_type = "files"
certificate_path = "$svid_dir/svid.pem"
private_key_path = "$svid_dir/svid_key.pem"
trust_bundle_path = "$svid_dir/bundle.pem"
EOF
  )

  "$AGENT_BIN" run \
    --simulate \
    --config-file "$config_file" \
    --agent-id "$name" \
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
echo "Launched $launched/$COUNT agents ($reused already enrolled). Tracked in $PID_FILE"
echo "  Status: $0 --status --base-dir $BASE_DIR"
echo "  Stop:   $0 --stop   --base-dir $BASE_DIR"
