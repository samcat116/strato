#!/usr/bin/env bash
# End-to-end contract test for STR-301 against a real libvirt agent.
#
# Creates a VM with a 512 MiB grant and a 1 GiB virtio-mem ceiling, starts it,
# grows it online to the ceiling, and proves that both libvirt's live device and
# the control plane's observed generation reached the accepted target.
set -euo pipefail

ORIGIN="${ORIGIN:-}"
API_KEY="${STRATO_API_KEY:-}"
PROJECT_ID=""
NETWORK_ID=""
IMAGE_ID=""
LIBVIRT_URI="qemu:///system"
TIMEOUT_SECONDS=300

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Usage: memory-growth-test.sh --origin URL --api-key KEY --project UUID \
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
INITIAL_MEMORY=536870912
MAX_MEMORY=1073741824
REGION_MEMORY=$((MAX_MEMORY - INITIAL_MEMORY))

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

# Prints "maximum requested" in bytes from the live libvirt domain XML.
live_memory_layout() {
  virsh -q -c "$LIBVIRT_URI" dumpxml "$VM_ID" | python3 -c '
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.stdin).getroot()

def bytes_for(element):
    unit = element.get("unit", "KiB")
    scale = {"B": 1, "bytes": 1, "KiB": 1024, "MiB": 1024**2, "GiB": 1024**3}[unit]
    return int(element.text) * scale

maximum = bytes_for(root.find("maxMemory"))
devices = [m for m in root.findall("./devices/memory") if m.get("model") == "virtio-mem"]
assert len(devices) == 1, f"expected one virtio-mem device, found {len(devices)}"
requested = bytes_for(devices[0].find("./target/requested"))
print(maximum, requested)
'
}

wait_live_requested() {
  local expected="$1" label="$2" started=$SECONDS layout maximum requested
  while (( SECONDS - started < TIMEOUT_SECONDS )); do
    layout="$(live_memory_layout)"
    read -r maximum requested <<< "$layout"
    if [[ "$maximum" == "$MAX_MEMORY" && "$requested" == "$expected" ]]; then
      echo "  ok: $label (maximum=$maximum requested=$requested)"
      return
    fi
    sleep 1
  done
  echo "FAIL: $label did not reach maximum=$MAX_MEMORY requested=$expected" >&2
  echo "last live layout: maximum=$maximum requested=$requested" >&2
  exit 1
}

echo "STR-301 live QEMU memory growth contract"
create_body="$(printf \
  '{"name":"str-301-%s","imageId":"%s","projectId":"%s","networkId":"%s","environment":"development","cpu":1,"maxCpu":1,"memory":%s,"maxMemory":%s,"disk":10737418240}' \
  "$$" "$IMAGE_ID" "$PROJECT_ID" "$NETWORK_ID" "$INITIAL_MEMORY" "$MAX_MEMORY")"
code="$(request POST /api/vms "$TMP_DIR/create.json" "$create_body")"
expect_code "create VM with memory headroom" "$code" 202 "$TMP_DIR/create.json"
VM_ID="$(json_get "d['resource']['id']" "$TMP_DIR/create.json")"
target="$(json_get "d['targetGeneration']" "$TMP_DIR/create.json")"
wait_converged "$VM_ID" "$target" "create"

code="$(request POST "/api/vms/${VM_ID}/start" "$TMP_DIR/start.json")"
expect_code "start VM" "$code" 202 "$TMP_DIR/start.json"
target="$(json_get "d['targetGeneration']" "$TMP_DIR/start.json")"
wait_converged "$VM_ID" "$target" "start"
wait_live_requested 0 "libvirt starts at 512 MiB within the 1 GiB ceiling"

code="$(request PUT "/api/vms/${VM_ID}" "$TMP_DIR/grow.json" "{\"memory\":${MAX_MEMORY}}")"
expect_code "grow running VM to 1 GiB" "$code" 202 "$TMP_DIR/grow.json"
target="$(json_get "d['targetGeneration']" "$TMP_DIR/grow.json")"
wait_converged "$VM_ID" "$target" "live memory growth"
wait_live_requested "$REGION_MEMORY" "libvirt plugged the complete virtio-mem region"

request GET "/api/vms/${VM_ID}" "$TMP_DIR/final.json" >/dev/null
python3 - "$target" "$MAX_MEMORY" "$TMP_DIR/final.json" <<'PY'
import json, sys
target, memory = int(sys.argv[1]), int(sys.argv[2])
d = json.load(open(sys.argv[3]))
c = d["conditions"]
assert d["memory"] == memory, d
assert c["converged"] is True, c
assert c["targetGeneration"] == target, c
assert c["observedGeneration"] >= target, c
PY
echo "  ok: API observed generation $target at the 1 GiB grant"
echo "PASS: STR-301"
