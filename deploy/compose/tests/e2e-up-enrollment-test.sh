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

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All $CASES checks passed."
else
  echo "$FAILURES of $CASES checks failed." >&2
fi
exit "$((FAILURES > 0))"
