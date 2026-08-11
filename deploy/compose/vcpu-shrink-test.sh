#!/usr/bin/env bash
# End-to-end contract test for STR-241 against a real libvirt agent.
#
# Creates and starts a 2-vCPU VM, proves API convergence agrees with the live
# libvirt count, verifies a running 2 -> 1 update is rejected without changing
# either fact, then applies the supported stop/resize/start sequence and proves
# both surfaces report 1 vCPU.
set -euo pipefail

ORIGIN="${ORIGIN:-}"
API_KEY="${STRATO_API_KEY:-}"
PROJECT_ID=""
NETWORK_ID=""
IMAGE_ID=""
LIBVIRT_URI="qemu:///system"
TIMEOUT_SECONDS=300

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Usage: vcpu-shrink-test.sh --origin URL --api-key KEY --project UUID \
         --network UUID --image UUID [--libvirt-uri URI] [--timeout SECONDS]

Run it on the libvirt agent host as an account that can read qemu:///system.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --origin) ORIGIN="$2"; shift 2 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --project) PROJECT_ID="$2"; shift 2 ;;
    --network) NETWORK_ID="$2"; shift 2 ;;
    --image) IMAGE_ID="$2"; shift 2 ;;
    --libvirt-uri) LIBVIRT_URI="$2"; shift 2 ;;
    --timeout) TIMEOUT_SECONDS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for command in curl python3 virsh; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Error: required command not found: $command" >&2
    exit 2
  }
done
[[ -n "$ORIGIN" ]] || { echo "Error: --origin is required" >&2; exit 2; }
[[ -n "$API_KEY" ]] || { echo "Error: --api-key or STRATO_API_KEY is required" >&2; exit 2; }
[[ -n "$PROJECT_ID" ]] || { echo "Error: --project is required" >&2; exit 2; }
[[ -n "$NETWORK_ID" ]] || { echo "Error: --network is required" >&2; exit 2; }
[[ -n "$IMAGE_ID" ]] || { echo "Error: --image is required" >&2; exit 2; }
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  echo "Error: --timeout must be a positive integer" >&2
  exit 2
}

TMP_DIR="$(mktemp -d)"
VM_ID=""
AUTH=(-H "Authorization: Bearer ${API_KEY}")

cleanup() {
  if [[ -n "$VM_ID" ]]; then
    curl -sS -o /dev/null -X DELETE "${AUTH[@]}" "${ORIGIN}/api/vms/${VM_ID}" || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# request METHOD PATH OUTPUT [JSON] -- prints only the HTTP status code.
request() {
  local method="$1" path="$2" output="$3" body="${4:-}"
  if [[ -n "$body" ]]; then
    curl -sS -o "$output" -w '%{http_code}' -X "$method" "${AUTH[@]}" \
      -H 'Content-Type: application/json' -d "$body" "${ORIGIN}${path}"
  else
    curl -sS -o "$output" -w '%{http_code}' -X "$method" "${AUTH[@]}" "${ORIGIN}${path}"
  fi
}

json_get() {
  local expression="$1" file="$2"
  python3 -c "import json; d=json.load(open('$file')); print($expression)"
}

expect_code() {
  local label="$1" actual="$2" expected="$3" body_file="$4"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $label returned $actual, expected $expected" >&2
    cat "$body_file" >&2
    exit 1
  fi
  echo "  ok: $label -> $actual"
}

wait_converged() {
  local vm_id="$1" generation="$2" label="$3" started=$SECONDS state
  while (( SECONDS - started < TIMEOUT_SECONDS )); do
    request GET "/api/vms/${vm_id}" "$TMP_DIR/state.json" >/dev/null
    state="$(python3 - "$generation" "$TMP_DIR/state.json" <<'PY'
import json, sys
target = int(sys.argv[1])
d = json.load(open(sys.argv[2]))
c = d["conditions"]
degraded = c.get("degraded")
if degraded and degraded.get("sinceGeneration") == target:
    print("failed:" + degraded.get("reason", "unknown error"))
elif c.get("converged") and c.get("observedGeneration", -1) >= target:
    print("done")
else:
    print("pending")
PY
)"
    case "$state" in
      done) echo "  ok: $label converged at generation $generation"; return ;;
      failed:*) echo "FAIL: $label ${state#failed:}" >&2; exit 1 ;;
    esac
    sleep 1
  done
  echo "FAIL: timed out waiting for $label at generation $generation" >&2
  cat "$TMP_DIR/state.json" >&2
  exit 1
}

live_vcpus() {
  virsh -q -c "$LIBVIRT_URI" vcpucount "$VM_ID" --live --active | tr -d '[:space:]'
}

echo "STR-241 live vCPU shrink contract"
create_body="$(printf \
  '{"name":"str-241-%s","imageId":"%s","projectId":"%s","networkId":"%s","environment":"development","cpu":2,"maxCpu":2,"memory":536870912,"disk":2147483648}' \
  "$$" "$IMAGE_ID" "$PROJECT_ID" "$NETWORK_ID")"
code="$(request POST /api/vms "$TMP_DIR/create.json" "$create_body")"
expect_code "create 2-vCPU VM" "$code" 202 "$TMP_DIR/create.json"
VM_ID="$(json_get "d['resource']['id']" "$TMP_DIR/create.json")"
target="$(json_get "d['targetGeneration']" "$TMP_DIR/create.json")"
wait_converged "$VM_ID" "$target" "create"

code="$(request POST "/api/vms/${VM_ID}/start" "$TMP_DIR/start.json")"
expect_code "start VM" "$code" 202 "$TMP_DIR/start.json"
target="$(json_get "d['targetGeneration']" "$TMP_DIR/start.json")"
wait_converged "$VM_ID" "$target" "start"
[[ "$(live_vcpus)" == 2 ]] || { echo "FAIL: live domain did not start with 2 vCPUs" >&2; exit 1; }
echo "  ok: converged API state agrees with libvirt live count 2"

code="$(request PUT "/api/vms/${VM_ID}" "$TMP_DIR/rejected.json" '{"cpu":1}')"
expect_code "reject running 2 -> 1 vCPU resize" "$code" 422 "$TMP_DIR/rejected.json"
python3 - "$TMP_DIR/rejected.json" <<'PY'
import json, sys
reason = json.load(open(sys.argv[1])).get("reason", "")
assert "live vCPU unplug is not supported" in reason, reason
assert "no resize was recorded" in reason, reason
PY
request GET "/api/vms/${VM_ID}" "$TMP_DIR/after-reject.json" >/dev/null
python3 - "$TMP_DIR/after-reject.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["cpu"] == 2, d
assert d["conditions"]["converged"] is True, d["conditions"]
assert d["conditions"]["observedGeneration"] >= d["conditions"]["targetGeneration"], d["conditions"]
PY
[[ "$(live_vcpus)" == 2 ]] || { echo "FAIL: rejected shrink changed the live count" >&2; exit 1; }
echo "  ok: rejected shrink leaves ordinary convergence truthful at 2 live vCPUs"

code="$(request POST "/api/vms/${VM_ID}/stop" "$TMP_DIR/stop.json")"
expect_code "stop VM" "$code" 202 "$TMP_DIR/stop.json"
target="$(json_get "d['targetGeneration']" "$TMP_DIR/stop.json")"
wait_converged "$VM_ID" "$target" "stop"

code="$(request PUT "/api/vms/${VM_ID}" "$TMP_DIR/stopped-resize.json" '{"cpu":1}')"
expect_code "resize stopped VM to 1 vCPU" "$code" 200 "$TMP_DIR/stopped-resize.json"
[[ "$(json_get "d['cpu']" "$TMP_DIR/stopped-resize.json")" == 1 ]] || {
  echo "FAIL: stopped resize response did not record 1 vCPU" >&2
  exit 1
}

code="$(request POST "/api/vms/${VM_ID}/start" "$TMP_DIR/restart.json")"
expect_code "start resized VM" "$code" 202 "$TMP_DIR/restart.json"
target="$(json_get "d['targetGeneration']" "$TMP_DIR/restart.json")"
wait_converged "$VM_ID" "$target" "start after stopped resize"
[[ "$(live_vcpus)" == 1 ]] || { echo "FAIL: live domain did not restart with 1 vCPU" >&2; exit 1; }
request GET "/api/vms/${VM_ID}" "$TMP_DIR/final.json" >/dev/null
python3 - "$TMP_DIR/final.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["cpu"] == 1, d
assert d["conditions"]["converged"] is True, d["conditions"]
PY
echo "  ok: after stop/resize/start, converged API state agrees with libvirt live count 1"
echo "PASS: STR-241"
