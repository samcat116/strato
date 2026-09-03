#!/usr/bin/env bash
# End-to-end contract test for STR-241, STR-247, and STR-248 against a real
# libvirt agent using an image whose native size can exceed the 2 GiB request.
#
# Creates and starts a 2-vCPU VM, proves API convergence agrees with the live
# libvirt count, verifies a running 2 -> 1 update is rejected without changing
# either fact, then applies the supported stop/resize/start sequence and proves
# the persistent definition changes before boot and both final surfaces report
# 1 vCPU.
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
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/api.sh"

cleanup() {
  if [[ -n "$VM_ID" ]]; then
    curl -sS -o /dev/null -X DELETE "${AUTH[@]}" "${ORIGIN}/api/vms/${VM_ID}" || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

live_vcpus() {
  virsh -q -c "$LIBVIRT_URI" vcpucount "$VM_ID" --live --active | tr -d '[:space:]'
}

persistent_vcpus() {
  virsh -q -c "$LIBVIRT_URI" vcpucount "$VM_ID" --config --active | tr -d '[:space:]'
}

echo "STR-241/STR-247/STR-248 VM convergence contract"
create_body="$(printf \
  '{"name":"str-248-%s","imageId":"%s","projectId":"%s","networkId":"%s","environment":"development","cpu":2,"maxCpu":2,"memory":536870912,"disk":2147483648}' \
  "$$" "$IMAGE_ID" "$PROJECT_ID" "$NETWORK_ID")"
code="$(request POST /api/vms "$TMP_DIR/create.json" "$create_body")"
expect_code "create 2-vCPU VM" "$code" 202 "$TMP_DIR/create.json"
VM_ID="$(json_get "d['resource']['id']" "$TMP_DIR/create.json")"
target="$(json_get "d['targetGeneration']" "$TMP_DIR/create.json")"
wait_converged "$VM_ID" "$target" "create"

# This workflow is STR-247 coverage only when the chosen image materializes
# above the 2 GiB request. Also require the control plane to have admitted that
# measured size into desired state before it reports VM creation converged.
request GET "/api/volumes?project_id=${PROJECT_ID}&type=boot" "$TMP_DIR/boot-volumes.json" >/dev/null
python3 - "$VM_ID" "$TMP_DIR/boot-volumes.json" <<'PY'
import json, sys
vm_id = sys.argv[1]
volumes = json.load(open(sys.argv[2]))["items"]
boot = next((v for v in volumes if v.get("vmId") == vm_id), None)
assert boot is not None, f"managed boot volume for VM {vm_id} was not returned"
requested = 2 * 1024 * 1024 * 1024
observed = boot.get("observedSize")
desired = boot.get("size")
assert observed is not None and observed > requested, (
    f"image does not exercise STR-247: boot volume observed size {observed!r} "
    f"must exceed the {requested}-byte request"
)
assert desired == observed, (
    f"boot volume converged without normalizing admitted size: desired={desired}, "
    f"observed={observed}"
)
PY
echo "  ok: image exceeds 2 GiB and boot-volume size was normalized before convergence"

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
target="$(json_get "d['conditions']['targetGeneration']" "$TMP_DIR/stopped-resize.json")"
wait_converged "$VM_ID" "$target" "stopped vCPU resize"
[[ "$(persistent_vcpus)" == 1 ]] || {
  echo "FAIL: stopped resize converged without changing the persistent vCPU count" >&2
  exit 1
}
echo "  ok: stopped resize persisted 1 vCPU before boot"

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
echo "PASS: STR-241, STR-247, and STR-248"
