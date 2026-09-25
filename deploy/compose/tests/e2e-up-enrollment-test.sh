#!/usr/bin/env bash
# Verifies the compose E2E flow redeems the enrollment bearer and decodes the
# private bootstrap bundle instead of reading the removed inline SPIRE token.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_UP="$SCRIPT_DIR/../e2e-up.sh"
export FUNCTION_SOURCE="$E2E_UP"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

FAILURES=0
CASES=0
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../tests/lib.sh"

HARNESS="$WORK_DIR/harness.sh"
{
  echo 'set -uo pipefail'
  extract_function redeem_agent_enrollment
  extract_function bootstrap_value
  extract_function bundle_fingerprints
  extract_function bundles_share_certificate
  extract_function ensure_control_plane_spire_identity
} > "$HARNESS"
# shellcheck source=/dev/null
. "$HARNESS"

BOOTSTRAP_FIXTURE="$WORK_DIR/bootstrap.txt"
{
  echo STRATO_AGENT_BOOTSTRAP_V1
  printf '%s' 'ws://localhost/agent/ws' | base64
  printf '%s' 'compose-node' | base64
  printf '%s' 'compose-join-token' | base64
  printf '%s' 'spire-server:8081' | base64
  printf '%s' 'strato.local' | base64
  printf '%s' 'spiffe://strato.local/control-plane' | base64
} > "$BOOTSTRAP_FIXTURE"

STUB_DIR="$WORK_DIR/bin"
CURL_ARGS="$WORK_DIR/curl-args"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CURL_ARGS"
cat "$BOOTSTRAP_FIXTURE"
EOF
chmod +x "$STUB_DIR/curl"

export ORIGIN=http://localhost
export BOOTSTRAP_FIXTURE CURL_ARGS
bundle="$(PATH="$STUB_DIR:$PATH" redeem_agent_enrollment enroll_v1_test)"

check "redemption uses the bootstrap endpoint" \
  http://localhost/api/agent-enrollments/bootstrap "$(tail -n 1 "$CURL_ARGS")"
check "redemption sends the one-time bearer" 1 \
  "$(grep -c '^Authorization: Bearer enroll_v1_test$' "$CURL_ARGS")"
check "redemption requests the versioned bundle" 1 \
  "$(grep -c '^Accept: application/vnd.strato.agent-bootstrap.v1$' "$CURL_ARGS")"
check "agent name is decoded from the bundle" compose-node \
  "$(bootstrap_value agentName <<< "$bundle")"
check "join token is decoded from the bundle" compose-join-token \
  "$(bootstrap_value joinToken <<< "$bundle")"
check "trust domain is decoded from the bundle" strato.local \
  "$(bootstrap_value trustDomain <<< "$bundle")"

invalid_bundle="${bundle/STRATO_AGENT_BOOTSTRAP_V1/STRATO_AGENT_BOOTSTRAP_V2}"
if bootstrap_value joinToken <<< "$invalid_bundle" >/dev/null 2>&1; then
  fail "an unknown bootstrap bundle version is rejected"
else
  CASES=$((CASES + 1))
  echo "  ok: an unknown bootstrap bundle version is rejected"
fi

# A normal SPIRE CA rotation overlaps roots. Only a complete lack of shared
# certificates means the persisted node identity belongs to a replaced server.
for name in old overlap replacement; do
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$name" \
    -keyout "$WORK_DIR/$name.key" -out "$WORK_DIR/$name.pem" >/dev/null 2>&1
done
cat "$WORK_DIR/old.pem" "$WORK_DIR/overlap.pem" > "$WORK_DIR/saved-bundle.pem"
cat "$WORK_DIR/overlap.pem" "$WORK_DIR/replacement.pem" > "$WORK_DIR/rotated-bundle.pem"

check "all certificates in a bundle are fingerprinted" 2 \
  "$(bundle_fingerprints "$WORK_DIR/saved-bundle.pem" | wc -l)"
if bundles_share_certificate "$WORK_DIR/saved-bundle.pem" "$WORK_DIR/rotated-bundle.pem"; then
  CASES=$((CASES + 1))
  echo "  ok: overlapping CA rotation keeps the registration"
else
  fail "overlapping CA rotation keeps the registration"
fi
if bundles_share_certificate "$WORK_DIR/old.pem" "$WORK_DIR/replacement.pem"; then
  fail "disjoint CA bundles require re-enrollment"
else
  CASES=$((CASES + 1))
  echo "  ok: disjoint CA bundles require re-enrollment"
fi
if bundles_share_certificate "$WORK_DIR/missing.pem" "$WORK_DIR/replacement.pem"; then
  fail "a missing saved bundle requires re-enrollment"
else
  CASES=$((CASES + 1))
  echo "  ok: a missing saved bundle requires re-enrollment"
fi

check "repaired enrollments print reset, not start" 1 \
  "$(grep -c 'if \[\[ "$AGENT_RESET_REQUIRED" == 1 \]\]' "$E2E_UP")"

# The control-plane recovery must leave every persistent workload volume alone:
# only the generated CP-side SPIRE identity volume is removed and recreated.
DOCKER_ACTIONS="$WORK_DIR/docker-actions"
: > "$DOCKER_ACTIONS"
READY_CALLS=0
READY_AFTER=0
envoy_server_cert_ready() {
  READY_CALLS=$((READY_CALLS + 1))
  [[ "$READY_CALLS" -gt "$READY_AFTER" ]]
}
say() { :; }
die() { echo "unexpected die: $*" >&2; return 1; }
sleep() { :; }
docker() {
  printf '%s\n' "$*" >> "$DOCKER_ACTIONS"
  case "$*" in
    "compose ps -q spire-agent-cp") echo cp-container ;;
    "inspect cp-container --format "*) echo compose_spire_agent_cp_data ;;
  esac
}

ensure_control_plane_spire_identity
check "a healthy Envoy identity is left untouched" 0 "$(wc -l < "$DOCKER_ACTIONS")"

READY_CALLS=0
READY_AFTER=15
ensure_control_plane_spire_identity
check "stale CP sidecars are stopped" 1 \
  "$(grep -c '^compose stop envoy spire-agent-cp$' "$DOCKER_ACTIONS")"
check "only the resolved CP identity volume is removed" 1 \
  "$(grep -c '^volume rm compose_spire_agent_cp_data$' "$DOCKER_ACTIONS")"
check "CP sidecars are recreated through Compose bootstrap" 1 \
  "$(grep -c '^compose up -d spire-agent-cp envoy$' "$DOCKER_ACTIONS")"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All $CASES checks passed."
else
  echo "$FAILURES of $CASES checks failed." >&2
fi
exit "$((FAILURES > 0))"
