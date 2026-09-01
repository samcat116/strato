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
# workload entry's default selector is `unix:uid:0`), and on a host where sudo
# prompts for a password an unattended script cannot get it. So the script
# stops, prints the exact command, and waits for the agent to appear.
#
# This deliberately does NOT use the `bootstrapCommand` the enrollment endpoint
# returns, which is the documented path for real nodes (see CLAUDE.md and
# deploy/agent/install.sh). That command downloads a released binary and
# installs systemd units; for development you want the agent you just built in
# `agent/.build/debug`, running in the foreground of a log file you can tail.
#
# Usage:
#   ./e2e-up.sh                      # build from source, full setup
#   ./e2e-up.sh --no-build           # use whatever images are present
#   ./e2e-up.sh --fresh              # DESTRUCTIVE: down -v first, then set up
#   ./e2e-up.sh --api-key sk_...     # use an existing key (DB already seeded)
#   ./e2e-up.sh --stage stack        # stop after the stack is healthy
#   ./e2e-up.sh --down               # stop the stack, keep volumes
#   ./e2e-up.sh --yes                # skip the prompt --fresh would otherwise ask
#   ./e2e-up.sh --admin-email you@x  # also seed YOU as admin, with a claim link
#
# Stages, in order: stack -> key -> enroll -> agent -> fixtures -> smoke.
# --stage <name> stops after that stage.
#
# Prefer STRATO_API_KEY over --api-key: an argv key is visible in `ps` output
# and lands in shell history.
#
# Environment overrides:
#   ORIGIN            control-plane origin           (default http://localhost)
#   AGENT_NAME        node name to enroll            (default $(hostname -s))
#   RUN_DIR           node-side launch files         (default $XDG_STATE_HOME/strato-e2e)
#   STATE_DIR         where the API key is cached    (default $RUN_DIR)
#   GUEST_IMAGE       qcow2 seeded as a guest image  (default: none)
#   SUBNET            seeded network subnet          (default 10.42.0.0/24)
#   TRUST_DOMAIN      SPIFFE trust domain            (default strato.local)
#   ADMIN_EMAIL       same as --admin-email
set -uo pipefail

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
say()  { printf '  %s\n' "$*"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Resolve $0 before the cd: --help reads this file back with sed, and a relative
# invocation ("./deploy/compose/e2e-up.sh") stops resolving once we have moved.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" || die "cannot resolve $0"
cd "$(dirname "$0")" || die "cannot cd to $(dirname "$0")"
REPO_ROOT="$(cd ../.. && pwd)" || die "cannot resolve repo root"

ORIGIN="${ORIGIN:-http://localhost}"
AGENT_NAME="${AGENT_NAME:-$(hostname -s)}"
RUN_DIR="${RUN_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/strato-e2e}"
SUBNET="${SUBNET:-10.42.0.0/24}"
GUEST_IMAGE="${GUEST_IMAGE:-}"
STATE_DIR="${STATE_DIR:-$RUN_DIR}"
# deploy/compose/spiffe/spire-server.conf pins this; deploy/agent/install.sh
# takes it as a flag. Override together if you change one.
TRUST_DOMAIN="${TRUST_DOMAIN:-strato.local}"
KEY_FILE="$STATE_DIR/e2e-api-key"

BUILD=1
FRESH=0
STOP_AFTER="smoke"
API_KEY="${STRATO_API_KEY:-}"
DOWN=0
ASSUME_YES=0
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
STAGES="stack key enroll agent fixtures smoke"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) BUILD=0; shift ;;
    --fresh) FRESH=1; shift ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --stage) STOP_AFTER="$2"; shift 2 ;;
    --down) DOWN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
    # Derived, not a fixed line range — see the note in e2e-agent.sh.
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$SELF"; exit 0 ;;
    *) echo "Unknown argument: $1 (see --help)" >&2; exit 1 ;;
  esac
done

# An unrecognized stage would otherwise fall through every `should_stop` test
# and run the WHOLE script — including the destructive and blocking parts —
# which is the opposite of what someone passing --stage wants.
[[ " $STAGES " == *" $STOP_AFTER "* ]] \
  || die "unknown stage '$STOP_AFTER'. Valid: $STAGES"

# confirm <prompt> — gated on --yes, refuses outright when not interactive.
confirm() {
  [[ "$ASSUME_YES" == 1 ]] && return 0
  [[ -t 0 ]] || die "$1
       Refusing to continue without a terminal to ask. Pass --yes if you mean it."
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

# --fail-with-body: curl exits 0 on 4xx/5xx by default, which would silently
# defeat every `|| die` below. This makes the exit code honest while still
# printing the error body so the caller can show it.
api() { # api <method> <path> [json-body]
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS --fail-with-body -X "$method" -H "Authorization: Bearer $API_KEY" \
      -H 'Content-Type: application/json' -d "$body" "${ORIGIN}${path}"
  else
    curl -sS --fail-with-body -X "$method" -H "Authorization: Bearer $API_KEY" \
      "${ORIGIN}${path}"
  fi
}

jget() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

redeem_agent_enrollment() { # redeem_agent_enrollment <enroll_v1 token>
  local token="$1"
  curl -sS --fail-with-body -X POST \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.strato.agent-bootstrap.v1' \
    "${ORIGIN}/api/agent-enrollments/bootstrap"
}

bootstrap_value() { # bootstrap_value <agentName|joinToken|trustDomain>
  local field="$1"
  python3 -c '
import base64
import binascii
import sys

indexes = {"agentName": 2, "joinToken": 3, "trustDomain": 5}
lines = sys.stdin.read().splitlines()
if len(lines) != 7 or lines[0] != "STRATO_AGENT_BOOTSTRAP_V1":
    raise SystemExit("invalid Strato agent bootstrap bundle")
try:
    index = indexes[sys.argv[1]]
    value = base64.b64decode(lines[index], validate=True).decode("utf-8")
except (KeyError, ValueError, UnicodeDecodeError, binascii.Error) as error:
    raise SystemExit(f"invalid Strato agent bootstrap value: {error}")
print(value)
' "$field"
}

should_stop() { [[ "$STOP_AFTER" == "$1" ]]; }

# --- --down --------------------------------------------------------------------
if [[ "$DOWN" == 1 ]]; then
  bold "Stopping the stack (volumes preserved)"
  docker compose down
  say "Agent (if running) is untouched:"
  say "  sudo RUN_DIR=$RUN_DIR bash $REPO_ROOT/deploy/compose/e2e-agent.sh stop"
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
  bold "Tearing down (--fresh)"
  say "This DELETES every compose volume: the database (organizations,"
  say "projects, VMs, and any registered passkey credential), the image"
  say "store, and the SPIRE server's CA."
  say "Note: volumes are named compose_* (the project dir), NOT strato_*"
  confirm "  Destroy the current deployment?" || die "aborted"
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
  # Without --admin-email the seeded admin is a headless account with no passkey,
  # and the first-user-becomes-admin slot is spent — so a passkey registered in
  # the browser afterwards gets nothing (STR-178). Passing it mints a claim link
  # so the operator administers the deployment as themselves.
  if [[ -n "$ADMIN_EMAIL" ]]; then
    out="$(docker compose run --rm bootstrap bootstrap --env production --admin-email "$ADMIN_EMAIL" 2>&1)"
  else
    out="$(docker compose run --rm bootstrap 2>&1)"
  fi
  API_KEY="$(grep -oE 'sk_[A-Za-z0-9_]+' <<<"$out" | head -1)"
  # UserController.claimURL builds "<WEBAUTHN_RELYING_PARTY_ORIGIN>/claim?token=..."
  CLAIM_URL="$(grep -oE 'https?://[^ ]*/claim\?token=[^ ]+' <<<"$out" | head -1)"
  if [[ -z "$API_KEY" ]]; then
    echo "$out" | grep -iE 'refus|already exist' | head -3
    die "bootstrap did not yield a key. The database already has users.
       Either export STRATO_API_KEY=sk_... (mint one in the UI under
       Access -> API Keys), or re-run with --fresh to wipe the deployment."
  fi
  mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
  (umask 077; printf '%s' "$API_KEY" > "$KEY_FILE") && say "saved to $KEY_FILE (mode 600)"
  if [[ -n "$CLAIM_URL" ]]; then
    echo
    say "Claim link for $ADMIN_EMAIL — open it in a browser to enroll a passkey."
    say "Single use, and it is not shown again:"
    say "  $CLAIM_URL"
    echo
  elif [[ -z "$ADMIN_EMAIL" ]]; then
    say "NOTE: the seeded admin is headless and cannot log in to the UI. A passkey"
    say "      registered in the browser gets no privileges. Re-run with"
    say "      --admin-email you@example.com on a fresh deployment, or promote an"
    say "      existing account: docker compose run --rm bootstrap grant-platform-admin --email you@example.com --claim"
  fi
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

# Everything written below carries a credential: spire-agent.conf embeds a live
# single-use join token. Set the umask for the whole stage rather than relying
# on one inherited from an earlier branch.
umask 077

agent_count() { # agent_count — how many agents carry $AGENT_NAME
  api GET /api/agents | jget "sum(1 for a in d['items'] if a['name']=='$AGENT_NAME')"
}

if [[ "$(agent_count)" == "0" ]]; then
  enroll="$(api POST /api/agent-enrollments \
    "{\"agentName\":\"$AGENT_NAME\",\"siteId\":\"$SITE_ID\",\"organizationId\":\"$ORG_ID\",\"expirationHours\":24}")" \
    || die "enrollment request failed: $enroll"
  bootstrap_token="$(jget "d['bootstrapToken']" <<<"$enroll")" \
    || die "enrollment response did not contain a bootstrap token"
  [[ -n "$bootstrap_token" ]] || die "enrollment returned an empty bootstrap token"
  bootstrap="$(redeem_agent_enrollment "$bootstrap_token")" \
    || die "bootstrap-token redemption failed"
  bootstrap_agent_name="$(bootstrap_value agentName <<<"$bootstrap")" \
    || die "bootstrap response did not contain a valid agent name"
  [[ "$bootstrap_agent_name" == "$AGENT_NAME" ]] \
    || die "bootstrap response named '$bootstrap_agent_name', expected '$AGENT_NAME'"
  JOIN_TOKEN="$(bootstrap_value joinToken <<<"$bootstrap")" \
    || die "bootstrap response did not contain a valid join token"
  TRUST_DOMAIN="$(bootstrap_value trustDomain <<<"$bootstrap")" \
    || die "bootstrap response did not contain a valid trust domain"

  mkdir -p "$RUN_DIR" || die "cannot write $RUN_DIR"

  # A `down -v` gives the SPIRE server a brand-new CA, so both the trust bundle
  # and any cached node SVID are stale. Refresh the bundle here; e2e-agent.sh
  # reset clears the SVID.
  docker compose exec -T spire-server spire-server bundle show \
    -socketPath /tmp/spire-server/private/api.sock > "$RUN_DIR/bundle.pem" \
    || die "could not export the SPIRE trust bundle"
  say "refreshed $RUN_DIR/bundle.pem"

  # `sed` exits 0 when it matches nothing, so a `|| echo` fallback here would be
  # dead code and an older .env (setup.sh never rewrites an existing one) would
  # silently produce an empty port and an opaque spire-agent config error.
  node_port="$(sed -n 's/^SPIRE_NODE_PORT=//p' .env | tr -d '\r')"
  node_port="${node_port:-8085}"

  cat > "$RUN_DIR/spire-agent.conf" <<EOF
agent {
    data_dir = "/var/lib/spire/agent"
    log_level = "INFO"
    server_address = "127.0.0.1"
    server_port = "$node_port"
    socket_path = "/var/run/spire/sockets/workload.sock"
    trust_bundle_path = "$RUN_DIR/bundle.pem"
    trust_domain = "$TRUST_DOMAIN"
    # Used only on first attestation; ignored once an SVID exists in data_dir.
    join_token = "$JOIN_TOKEN"
}

plugins {
    KeyManager "disk" { plugin_data { directory = "/var/lib/spire/agent" } }
    NodeAttestor "join_token" { plugin_data {} }
    WorkloadAttestor "unix" { plugin_data { discover_workload_path = true } }
}
EOF
  say "wrote $RUN_DIR/spire-agent.conf (join token embedded; mode 600)"
else
  say "agent '$AGENT_NAME' already registered — skipping enrollment"
fi

umask 022

should_stop enroll && { bold "Stopped after: enroll"; exit 0; }

# --- 4. Agent (needs root — the human runs this) -------------------------------
bold "Agent"

# Scoped to THIS node. Matching any online agent would skip the wait on a site
# that already has one, and then hand the site's network controller to an
# unrelated host below.
agent_id_if_online() {
  api GET /api/agents \
    | jget "next((a['id'] for a in d['items'] if a['name']=='$AGENT_NAME' and a['status']=='online'), '')"
}

AGENT_ID="$(agent_id_if_online)"
if [[ -n "$AGENT_ID" ]]; then
  say "agent '$AGENT_NAME' is already online"
else
  [[ -x "$REPO_ROOT/agent/.build/debug/StratoAgent" ]] \
    || say "WARNING: no agent binary at agent/.build/debug/StratoAgent —
       build it first: swiftly run +6.3.2 swift build --package-path agent"
  echo
  say "The agent must run as root (the SPIRE workload entry's default selector"
  say "is unix:uid:0). sudo does not forward the environment, so RUN_DIR is"
  say "passed explicitly — run this now:"
  echo
  if [[ "$FRESH" == 1 ]]; then
    # A fresh stack means a new SPIRE CA, so the cached SVID and the VM state
    # from the previous deployment are both stale.
    printf '      sudo RUN_DIR=%s bash %s/deploy/compose/e2e-agent.sh reset\n' \
      "$RUN_DIR" "$REPO_ROOT"
  else
    printf '      sudo RUN_DIR=%s bash %s/deploy/compose/e2e-agent.sh start\n' \
      "$RUN_DIR" "$REPO_ROOT"
  fi
  echo
  say "waiting for '$AGENT_NAME' to come online (Ctrl-C to stop waiting)..."
  for _ in $(seq 1 240); do
    AGENT_ID="$(agent_id_if_online)"
    [[ -n "$AGENT_ID" ]] && break
    sleep 5
  done
  [[ -n "$AGENT_ID" ]] || die "agent '$AGENT_NAME' never came online — check $RUN_DIR/strato-agent.log"
fi
say "agent online: $AGENT_ID"

should_stop agent && { bold "Stopped after: agent"; exit 0; }

# --- 5. Fixtures: site controller, network, guest image ------------------------
bold "Fixtures"

# Without a network controller the site has no OVN authority and every VM hangs
# in create "waiting for the site's network controller".
current_nc="$(api GET "/api/sites/$SITE_ID" | jget "d.get('networkControllerAgentId') or ''")"
if [[ "$current_nc" == "$AGENT_ID" ]]; then
  say "site network controller already set"
else
  api PUT "/api/sites/$SITE_ID" "{\"networkControllerAgentId\":\"$AGENT_ID\"}" >/dev/null \
    || die "could not set the site network controller"
  say "set site network controller -> $AGENT_ID"
fi

NET_ID="$(api GET /api/networks | jget "next((n['id'] for n in d['items'] if n['name']=='e2e-net'), '')")"
if [[ -n "$NET_ID" ]]; then
  say "network e2e-net exists: $NET_ID"
else
  NET_ID="$(api POST /api/networks \
    "{\"name\":\"e2e-net\",\"subnet\":\"$SUBNET\",\"projectId\":\"$PROJECT_ID\",\"siteId\":\"$SITE_ID\",\"ipv6Enabled\":false}" \
    | jget "d['id']")"
  [[ -n "$NET_ID" ]] || die "network creation failed"
  say "created network e2e-net ($SUBNET): $NET_ID"
fi

IMAGE_ID=""
if [[ -z "$GUEST_IMAGE" ]]; then
  say "no GUEST_IMAGE set — skipping image seeding"
  say "  (set GUEST_IMAGE=/path/to/guest.qcow2 to seed one)"
else
  [[ -r "$GUEST_IMAGE" ]] || die "GUEST_IMAGE not readable: $GUEST_IMAGE"
  # Many cloud images are named generically (cirros-test/disk.qcow2), which would
  # produce a useless "e2e-disk". Fall back to the parent directory in that case.
  img_base="$(basename "${GUEST_IMAGE%.*}")"
  case "$img_base" in
    disk|image|rootfs|root) img_base="$(basename "$(dirname "$GUEST_IMAGE")")" ;;
  esac
  img_name="e2e-$img_base"

  images_json="$(api GET "/api/projects/$PROJECT_ID/images")"
  IMAGE_ID="$(jget "next((i['id'] for i in (d['items'] if isinstance(d,dict) else d) if i['name']=='$img_name'), '')" <<<"$images_json")"
  # An image row with no artifact is a half-finished previous run (the shell is
  # created before the upload). Checking only the row would make that state
  # permanent: every rerun would report "exists" and skip the upload, and the
  # break would not surface until VM create failed for an unrelated-looking
  # reason.
  artifact_count=0
  [[ -n "$IMAGE_ID" ]] && artifact_count="$(jget "next((len(i.get('artifacts') or []) for i in (d['items'] if isinstance(d,dict) else d) if i['id']=='$IMAGE_ID'), 0)" <<<"$images_json")"

  if [[ -n "$IMAGE_ID" && "${artifact_count:-0}" -gt 0 ]]; then
    say "image $img_name exists: $IMAGE_ID"
  else
    if [[ -n "$IMAGE_ID" ]]; then
      say "image $img_name exists but has no artifact — re-uploading"
    else
      IMAGE_ID="$(api POST "/api/projects/$PROJECT_ID/images" \
        "{\"name\":\"$img_name\",\"description\":\"seeded by e2e-up.sh\",\"architecture\":\"x86_64\"}" \
        | jget "d['id']")"
      [[ -n "$IMAGE_ID" ]] || die "image shell creation failed"
    fi
    curl -sS --fail-with-body -X POST -H "Authorization: Bearer $API_KEY" \
      -F "kind=disk-image" -F "file=@${GUEST_IMAGE};filename=$(basename "$GUEST_IMAGE")" \
      "${ORIGIN}/api/projects/$PROJECT_ID/images/$IMAGE_ID/artifacts" >/dev/null \
      || die "artifact upload failed (image $IMAGE_ID now has no artifact; rerun to retry)"
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
  the targetGeneration you were handed, or conditions.degraded names it — the
  two are mutually exclusive, so exactly one answers (delete is the exception —
  poll GET /api/operations/<mutationId>). Tear down with ./e2e-up.sh --down.
EOF
