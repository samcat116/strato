#!/usr/bin/env bash
#
# e2e-up.sh — stand up a full Strato stack ready for end-to-end testing.
#
# Brings the deploy/compose stack up (optionally built from source), seeds an
# admin API key, enrolls this host as a hypervisor node, stages the node-side
# SPIRE config, and — once you have started the agent — wires the site's network
# controller and seeds a network + guest image. Idempotent: re-running it
# re-uses what already exists rather than duplicating it.
#
# The one thing it cannot do is start the agent. That needs root (the SPIRE
# workload entry's selector is `unix:uid:0`), and on a host where sudo prompts
# for a password an unattended script cannot get it. So the script stops, prints
# the exact command, and waits for the agent to appear.
#
# Usage:
#   ./e2e-up.sh                      # build from source, full setup
#   ./e2e-up.sh --no-build           # use whatever images are present
#   ./e2e-up.sh --fresh              # DESTRUCTIVE: down -v first, then set up
#   ./e2e-up.sh --api-key sk_...     # use an existing key (DB already seeded)
#   ./e2e-up.sh --stage stack        # stop after the stack is healthy
#   ./e2e-up.sh --down               # stop the stack, keep volumes
#
# Stages, in order: stack -> key -> enroll -> agent -> fixtures -> smoke.
# --stage <name> stops after that stage.
#
# Environment overrides:
#   ORIGIN            control-plane origin           (default http://localhost)
#   AGENT_NAME        node name to enroll            (default $(hostname -s))
#   RUN_DIR           node-side launch files         (default /home/sam/strato-agent-run)
#   GUEST_IMAGE       qcow2 seeded as a guest image  (default cirros if present)
#   SUBNET            seeded network subnet          (default 10.42.0.0/24)
set -uo pipefail

cd "$(dirname "$0")"
REPO_ROOT="$(cd ../.. && pwd)"

ORIGIN="${ORIGIN:-http://localhost}"
AGENT_NAME="${AGENT_NAME:-$(hostname -s)}"
RUN_DIR="${RUN_DIR:-/home/sam/strato-agent-run}"
SUBNET="${SUBNET:-10.42.0.0/24}"
GUEST_IMAGE="${GUEST_IMAGE:-}"
STATE_DIR="${STATE_DIR:-$RUN_DIR}"
KEY_FILE="$STATE_DIR/e2e-api-key"

BUILD=1
FRESH=0
STOP_AFTER="smoke"
API_KEY="${STRATO_API_KEY:-}"
DOWN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) BUILD=0; shift ;;
    --fresh) FRESH=1; shift ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --stage) STOP_AFTER="$2"; shift 2 ;;
    --down) DOWN=1; shift ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1 (see --help)" >&2; exit 1 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
say()  { printf '  %s\n' "$*"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

api() { # api <method> <path> [json-body]
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS -X "$method" -H "Authorization: Bearer $API_KEY" \
      -H 'Content-Type: application/json' -d "$body" "${ORIGIN}${path}"
  else
    curl -sS -X "$method" -H "Authorization: Bearer $API_KEY" "${ORIGIN}${path}"
  fi
}

jget() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

should_stop() { [[ "$STOP_AFTER" == "$1" ]]; }

# --- --down --------------------------------------------------------------------
if [[ "$DOWN" == 1 ]]; then
  bold "Stopping the stack (volumes preserved)"
  docker compose down
  say "Agent (if running) is untouched: sudo bash $RUN_DIR/stop.sh"
  exit 0
fi

# --- 0. Preflight --------------------------------------------------------------
bold "Preflight"
command -v docker >/dev/null || die "docker not found"
docker compose version >/dev/null 2>&1 || die "docker compose plugin not found"
[[ -f .env ]] || die ".env missing — run ./setup.sh first to generate secrets"
say "docker + .env present"

if [[ "$BUILD" == 1 ]]; then
  # The compose file pins `image:` to GHCR tags; a build only happens when an
  # override supplies `build:`. Without this, --no-build and a build are the
  # same thing and you silently test the published image instead of your tree.
  if [[ ! -f docker-compose.override.yml ]] || ! grep -q 'build:' docker-compose.override.yml; then
    die "--build needs a docker-compose.override.yml with build: stanzas.
       Create one (untracked) containing:

  services:
    control-plane:
      build: {context: ../.., dockerfile: control-plane/Dockerfile}
      pull_policy: never
    frontend:
      build: {context: ../../control-plane/web, dockerfile: Dockerfile}
      pull_policy: never
    bootstrap:
      pull_policy: never"
  fi
  grep -q 'bootstrap:' docker-compose.override.yml \
    || say "WARNING: override has no 'bootstrap: {pull_policy: never}' — bootstrap may pull GHCR :main and seed with a different build than the one under test"
  say "source-build override present"
fi

# --- 1. Stack ------------------------------------------------------------------
if [[ "$FRESH" == 1 ]]; then
  bold "Tearing down (--fresh): this deletes ALL compose volumes"
  say "Note: volumes are named compose_* (the project dir), NOT strato_*"
  docker compose down -v --remove-orphans
fi

bold "Bringing up the stack"
if [[ "$BUILD" == 1 ]]; then
  say "building control-plane + frontend from source (cold build ~35 min)"
  docker compose build control-plane frontend || die "image build failed"
fi
docker compose up -d || die "compose up failed"

say "waiting for /health/ready"
for _ in $(seq 1 120); do
  if curl -sS "${ORIGIN}/health/ready" 2>/dev/null | grep -q '"status":"healthy"'; then
    say "control plane healthy (database, migrations, coordination, session-store)"
    break
  fi
  sleep 5
done
curl -sS "${ORIGIN}/health/ready" 2>/dev/null | grep -q '"status":"healthy"' \
  || die "control plane never became healthy — docker compose logs control-plane"

should_stop stack && { bold "Stopped after: stack"; exit 0; }

# --- 2. Admin API key ----------------------------------------------------------
bold "Admin API key"
if [[ -z "$API_KEY" && -r "$KEY_FILE" ]]; then
  API_KEY="$(cat "$KEY_FILE")"
  say "reusing key from $KEY_FILE"
fi

key_works() {
  [[ -n "$API_KEY" ]] || return 1
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $API_KEY" "${ORIGIN}/api/projects" 2>/dev/null)"
  [[ "$code" == "200" ]]
}

if key_works; then
  say "existing key works"
else
  # `bootstrap` refuses once ANY user exists, so this only works on an empty DB.
  say "no working key — trying bootstrap (only succeeds on an empty database)"
  out="$(docker compose run --rm bootstrap 2>&1)"
  API_KEY="$(grep -oE 'sk_[A-Za-z0-9_]+' <<<"$out" | head -1)"
  if [[ -z "$API_KEY" ]]; then
    echo "$out" | grep -iE 'refus|already exist' | head -3
    die "bootstrap did not yield a key. The database already has users.
       Either pass --api-key sk_... (mint one in the UI under Access -> API Keys),
       or re-run with --fresh to wipe the deployment and start clean."
  fi
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  umask 077; printf '%s' "$API_KEY" > "$KEY_FILE" 2>/dev/null && say "saved to $KEY_FILE (mode 600)"
  say "NOTE: bootstrap consumed the first-user-becomes-admin slot. A passkey"
  say "      registered in the browser afterwards gets NO privileges (STR-178)."
fi

ORG_ID="$(api GET /api/organizations | jget "(d['items'] if isinstance(d,dict) else d)[0]['id']")"
PROJECT_ID="$(api GET /api/projects | jget "(d['items'] if isinstance(d,dict) else d)[0]['id']")"
SITE_ID="$(api GET /api/sites | jget "d['items'][0]['id']")"
[[ -n "$ORG_ID" && -n "$PROJECT_ID" && -n "$SITE_ID" ]] || die "could not resolve org/project/site with this key"
say "org=$ORG_ID"
say "project=$PROJECT_ID"
say "site=$SITE_ID"

should_stop key && { bold "Stopped after: key"; exit 0; }

# --- 3. Enroll this node -------------------------------------------------------
bold "Enrolling node '$AGENT_NAME'"
existing="$(api GET /api/agents | jget "[a['name'] for a in d['items']]")"
if [[ "$existing" == *"'$AGENT_NAME'"* ]]; then
  say "agent already registered — skipping enrollment"
else
  enroll="$(api POST /api/agent-enrollments \
    "{\"agentName\":\"$AGENT_NAME\",\"siteId\":\"$SITE_ID\",\"organizationId\":\"$ORG_ID\",\"expirationHours\":24}")"
  JOIN_TOKEN="$(jget "d['spire']['joinToken']" <<<"$enroll")"
  [[ -n "$JOIN_TOKEN" ]] || { echo "$enroll" | head -c 400; die "enrollment failed"; }
  say "join token: $JOIN_TOKEN"

  mkdir -p "$RUN_DIR" || die "cannot write $RUN_DIR"

  # A `down -v` gives the SPIRE server a brand-new CA, so both the trust bundle
  # and any cached node SVID are stale. Refresh the bundle here; reset-and-launch
  # clears the SVID.
  docker compose exec -T spire-server spire-server bundle show \
    -socketPath /tmp/spire-server/private/api.sock > "$RUN_DIR/bundle.pem" \
    || die "could not export the SPIRE trust bundle"
  say "refreshed $RUN_DIR/bundle.pem"

  cat > "$RUN_DIR/spire-agent.conf" <<EOF
agent {
    data_dir = "/var/lib/spire/agent"
    log_level = "INFO"
    server_address = "127.0.0.1"
    server_port = "$(sed -n 's/^SPIRE_NODE_PORT=//p' .env | tr -d '\r' || echo 8085)"
    socket_path = "/var/run/spire/sockets/workload.sock"
    trust_bundle_path = "$RUN_DIR/bundle.pem"
    trust_domain = "strato.local"
    # Used only on first attestation; ignored once an SVID exists in data_dir.
    join_token = "$JOIN_TOKEN"
}

plugins {
    KeyManager "disk" { plugin_data { directory = "/var/lib/spire/agent" } }
    NodeAttestor "join_token" { plugin_data {} }
    WorkloadAttestor "unix" { plugin_data { discover_workload_path = true } }
}
EOF
  say "wrote $RUN_DIR/spire-agent.conf"
fi

should_stop enroll && { bold "Stopped after: enroll"; exit 0; }

# --- 4. Agent (needs root — the human runs this) -------------------------------
bold "Agent"
if api GET /api/agents | grep -q '"status":"online"'; then
  say "an agent is already online"
else
  [[ -x "$REPO_ROOT/agent/.build/debug/StratoAgent" ]] \
    || say "WARNING: no agent binary at agent/.build/debug/StratoAgent —
       build it first: swiftly run +6.3.2 swift build --package-path agent"
  echo
  say "The agent must run as root (SPIRE selector unix:uid:0). Run this now:"
  echo
  if [[ "$FRESH" == 1 ]]; then
    # A fresh stack means a new SPIRE CA, so the cached SVID and the VM state
    # from the previous deployment are both stale.
    printf '      sudo bash %s/deploy/compose/e2e-agent.sh reset\n' "$REPO_ROOT"
  else
    printf '      sudo bash %s/deploy/compose/e2e-agent.sh start\n' "$REPO_ROOT"
  fi
  echo
  say "waiting for the agent to come online (Ctrl-C to stop waiting)..."
  for _ in $(seq 1 240); do
    api GET /api/agents | grep -q '"status":"online"' && break
    sleep 5
  done
  api GET /api/agents | grep -q '"status":"online"' \
    || die "agent never came online — check $RUN_DIR/strato-agent.log"
fi
AGENT_ID="$(api GET /api/agents | jget "[a['id'] for a in d['items'] if a['status']=='online'][0]")"
say "agent online: $AGENT_ID"

should_stop agent && { bold "Stopped after: agent"; exit 0; }

# --- 5. Fixtures: site controller, network, guest image ------------------------
bold "Fixtures"

# Without a network controller the site has no OVN authority and every VM hangs
# in create "waiting for the site's network controller".
current_nc="$(api GET "/api/sites/$SITE_ID" | jget "d.get('networkControllerAgentId')")"
if [[ "$current_nc" == "$AGENT_ID" ]]; then
  say "site network controller already set"
else
  api PUT "/api/sites/$SITE_ID" "{\"networkControllerAgentId\":\"$AGENT_ID\"}" >/dev/null
  say "set site network controller -> $AGENT_ID"
fi

NET_ID="$(api GET /api/networks | jget "[n['id'] for n in d['items'] if n['name']=='e2e-net'][0]")"
if [[ -n "$NET_ID" ]]; then
  say "network e2e-net exists: $NET_ID"
else
  NET_ID="$(api POST /api/networks \
    "{\"name\":\"e2e-net\",\"subnet\":\"$SUBNET\",\"projectId\":\"$PROJECT_ID\",\"siteId\":\"$SITE_ID\",\"ipv6Enabled\":false}" \
    | jget "d['id']")"
  [[ -n "$NET_ID" ]] || die "network creation failed"
  say "created network e2e-net ($SUBNET): $NET_ID"
fi

if [[ -z "$GUEST_IMAGE" ]]; then
  for candidate in \
    /home/sam/strato-images/cirros-test/disk.qcow2 \
    /home/sam/strato-e2e/images/noble.img; do
    [[ -r "$candidate" ]] && { GUEST_IMAGE="$candidate"; break; }
  done
fi

IMAGE_ID=""
if [[ -z "$GUEST_IMAGE" ]]; then
  say "no guest image found — set GUEST_IMAGE=/path/to.qcow2 to seed one"
else
  # Many cloud images are named generically (cirros-test/disk.qcow2), which would
  # produce a useless "e2e-disk". Fall back to the parent directory in that case.
  img_base="$(basename "${GUEST_IMAGE%.*}")"
  case "$img_base" in
    disk|image|rootfs|root) img_base="$(basename "$(dirname "$GUEST_IMAGE")")" ;;
  esac
  img_name="e2e-$img_base"
  IMAGE_ID="$(api GET "/api/projects/$PROJECT_ID/images" | jget "[i['id'] for i in (d['items'] if isinstance(d,dict) else d) if i['name']=='$img_name'][0]")"
  if [[ -n "$IMAGE_ID" ]]; then
    say "image $img_name exists: $IMAGE_ID"
  else
    IMAGE_ID="$(api POST "/api/projects/$PROJECT_ID/images" \
      "{\"name\":\"$img_name\",\"description\":\"seeded by e2e-up.sh\",\"architecture\":\"x86_64\"}" \
      | jget "d['id']")"
    [[ -n "$IMAGE_ID" ]] || die "image shell creation failed"
    curl -sS -X POST -H "Authorization: Bearer $API_KEY" \
      -F "kind=disk-image" -F "file=@${GUEST_IMAGE};filename=$(basename "$GUEST_IMAGE")" \
      "${ORIGIN}/api/projects/$PROJECT_ID/images/$IMAGE_ID/artifacts" >/dev/null \
      || die "artifact upload failed"
    say "uploaded $GUEST_IMAGE as $img_name: $IMAGE_ID"
  fi
fi

should_stop fixtures && { bold "Stopped after: fixtures"; exit 0; }

# --- 6. Smoke ------------------------------------------------------------------
bold "Smoke test"
./smoke-test.sh --origin "$ORIGIN" --api-key "$API_KEY" || die "smoke test failed"

# --- Summary -------------------------------------------------------------------
echo
bold "Ready for E2E"
cat <<EOF
  ORIGIN      $ORIGIN
  API key     $KEY_FILE
  org         $ORG_ID
  project     $PROJECT_ID
  site        $SITE_ID
  agent       $AGENT_ID
  network     $NET_ID
  image       ${IMAGE_ID:-<none seeded>}

  Create a VM (202 + {resource, targetGeneration, mutationId}; VMs start
  Created and need an explicit start):

    KEY=\$(cat $KEY_FILE)
    curl -sS -X POST -H "Authorization: Bearer \$KEY" -H 'Content-Type: application/json' \\
      -d '{"name":"e2e-1","imageId":"${IMAGE_ID:-<image>}","projectId":"$PROJECT_ID",
           "networkId":"$NET_ID","cpu":1,"memory":268435456,"disk":1073741824,
           "environment":"development"}' $ORIGIN/api/vms

  Then POST /api/vms/<id>/start. Lifecycle mutations are level-triggered, so
  wait by refetching GET /api/vms/<id> until conditions.converged is at or past
  the targetGeneration you were handed (delete is the exception — poll
  GET /api/operations/<mutationId>). Tear down with ./e2e-up.sh --down.
EOF
