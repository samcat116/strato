#!/usr/bin/env bash
# End-to-end contract test for STR-270 against a real QEMU/libvirt agent and
# a VM image that contains the Strato guest agent and fio.
#
# Proves cold-boot enforcement, live raises and lowers, persistent libvirt
# configuration, agent restart/adoption, VM reboot, and hot detach/reattach.
set -euo pipefail

ORIGIN="${ORIGIN:-}"
API_KEY="${STRATO_API_KEY:-}"
PROJECT_ID=""
NETWORK_ID=""
IMAGE_ID=""
LIBVIRT_URI="qemu:///system"
RESTART_AGENT_COMMAND=""
TIMEOUT_SECONDS=300
FIO_RUNTIME_SECONDS=60
FIO_RAMP_SECONDS=10

INITIAL_IOPS=200
RAISED_IOPS=500
LOWERED_IOPS=100
INITIAL_BPS=$((4 * 1024 * 1024))
RAISED_BPS=$((12 * 1024 * 1024))
LOWERED_BPS=$((2 * 1024 * 1024))

usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Usage: volume-io-limits-test.sh --origin URL --api-key KEY --project UUID \
         --network UUID --image UUID --restart-agent-command COMMAND \
         [--libvirt-uri URI] [--timeout SECONDS]

Run this on the libvirt agent host as an account that can read qemu:///system
and restart the agent. The image must contain the Strato guest agent and fio.
COMMAND is typically "sudo systemctl restart strato-agent".
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
    --restart-agent-command) RESTART_AGENT_COMMAND="$2"; shift 2 ;;
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
[[ -n "$RESTART_AGENT_COMMAND" ]] || {
  echo "Error: --restart-agent-command is required for the adoption check" >&2
  exit 2
}
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  echo "Error: --timeout must be a positive integer" >&2
  exit 2
}

TMP_DIR="$(mktemp -d)"
VM_ID=""
VOLUME_ID=""
VOLUME_TARGET=""
AUTH=(-H "Authorization: Bearer ${API_KEY}")
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/api.sh"

cleanup() {
  if [[ -n "$VOLUME_ID" ]]; then
    curl -sS -o /dev/null -X POST "${AUTH[@]}" \
      "${ORIGIN}/api/volumes/${VOLUME_ID}/detach" || true
  fi
  if [[ -n "$VM_ID" ]]; then
    curl -sS -o /dev/null -X DELETE "${AUTH[@]}" \
      "${ORIGIN}/api/vms/${VM_ID}" || true
  fi
  if [[ -n "$VOLUME_ID" ]]; then
    curl -sS -o /dev/null -X DELETE "${AUTH[@]}" \
      "${ORIGIN}/api/volumes/${VOLUME_ID}" || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

wait_volume_converged() {
  local generation="$1" label="$2" started=$SECONDS state
  while (( SECONDS - started < TIMEOUT_SECONDS )); do
    request GET "/api/volumes/${VOLUME_ID}" "$TMP_DIR/volume-state.json" >/dev/null
    state="$(python3 - "$generation" "$TMP_DIR/volume-state.json" <<'PY'
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
      done) echo "  ok: $label converged at volume generation $generation"; return ;;
      failed:*) echo "FAIL: $label ${state#failed:}" >&2; exit 1 ;;
    esac
    sleep 1
  done
  echo "FAIL: timed out waiting for $label at volume generation $generation" >&2
  cat "$TMP_DIR/volume-state.json" >&2
  exit 1
}

wait_vm_converged() {
  local generation="$1" label="$2"
  wait_converged "$VM_ID" "$generation" "$label"
}

set_limits() {
  local label="$1" body="$2" code target
  code="$(request POST "/api/volumes/${VOLUME_ID}/io-limits" "$TMP_DIR/set-limits.json" "$body")"
  expect_code "$label" "$code" 202 "$TMP_DIR/set-limits.json"
  target="$(json_get "d['targetGeneration']" "$TMP_DIR/set-limits.json")"
  wait_volume_converged "$target" "$label"
}

assert_applied_limits() {
  local expected_iops="$1" expected_bps="$2" label="$3"
  request GET "/api/volumes/${VOLUME_ID}" "$TMP_DIR/applied-limits.json" >/dev/null
  python3 - "$expected_iops" "$expected_bps" "$TMP_DIR/applied-limits.json" <<'PY'
import json, sys

def value(raw):
    return None if raw == "-" else int(raw)

expected = {"iopsTotal": value(sys.argv[1]), "bpsTotal": value(sys.argv[2])}
expected = {key: item for key, item in expected.items() if item is not None}
d = json.load(open(sys.argv[3]))
assert d.get("ioLimits") == expected, (d.get("ioLimits"), expected)
assert d.get("appliedIOLimits") == expected, (d.get("appliedIOLimits"), expected)
assert d["conditions"]["converged"] is True, d["conditions"]
PY
  echo "  ok: $label API desired/applied echo agrees"
}

volume_target() {
  virsh -q -c "$LIBVIRT_URI" dumpxml "$VM_ID" > "$TMP_DIR/volume-target.xml"
  python3 - "$VOLUME_ID" "$TMP_DIR/volume-target.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
volume_id = sys.argv[1]
root = ET.parse(sys.argv[2]).getroot()
for disk in root.findall("./devices/disk"):
    serial = disk.findtext("serial")
    if serial == f"vol-{volume_id}":
        target = disk.find("target")
        assert target is not None and target.get("dev"), "volume disk has no target"
        print(target.get("dev"))
        break
else:
    raise AssertionError(f"volume {volume_id} is not present in domain XML")
PY
}

assert_libvirt_limits() {
  local expected_iops="$1" expected_bps="$2" label="$3" mode output
  for mode in live persistent; do
    if [[ "$mode" == live ]]; then
      output="$TMP_DIR/domain-live.xml"
      virsh -q -c "$LIBVIRT_URI" dumpxml "$VM_ID" > "$output"
    else
      output="$TMP_DIR/domain-persistent.xml"
      virsh -q -c "$LIBVIRT_URI" dumpxml "$VM_ID" --inactive > "$output"
    fi
    python3 - "$VOLUME_ID" "$expected_iops" "$expected_bps" "$output" <<'PY'
import sys, xml.etree.ElementTree as ET
volume_id, expected_iops, expected_bps, path = sys.argv[1:]
expected_iops, expected_bps = int(expected_iops), int(expected_bps)
root = ET.parse(path).getroot()
disk = next(
    (item for item in root.findall("./devices/disk")
     if item.findtext("serial") == f"vol-{volume_id}"),
    None,
)
assert disk is not None, f"volume {volume_id} is absent"
iotune = disk.find("iotune")
actual_iops = int(iotune.findtext("total_iops_sec", "0")) if iotune is not None else 0
actual_bps = int(iotune.findtext("total_bytes_sec", "0")) if iotune is not None else 0
assert (actual_iops, actual_bps) == (expected_iops, expected_bps), (
    (actual_iops, actual_bps), (expected_iops, expected_bps)
)
PY
  done
  echo "  ok: $label libvirt live and persistent definitions agree"
}

run_guest() {
  local label="$1" stdout_file="$2"
  shift 2
  local body code operation_id started=$SECONDS status
  body="$(python3 - "$@" <<'PY'
import json, sys
print(json.dumps({"command": sys.argv[1:]}))
PY
)"

  while true; do
    code="$(request POST "/api/vms/${VM_ID}/actions/run" "$TMP_DIR/command-accepted.json" "$body")"
    if [[ "$code" == 202 ]]; then
      break
    fi
    if [[ "$code" != 503 || $((SECONDS - started)) -ge $TIMEOUT_SECONDS ]]; then
      echo "FAIL: $label could not start guest command (HTTP $code)" >&2
      cat "$TMP_DIR/command-accepted.json" >&2
      exit 1
    fi
    sleep 1
  done

  operation_id="$(json_get "d['id']" "$TMP_DIR/command-accepted.json")"
  while (( SECONDS - started < TIMEOUT_SECONDS )); do
    request GET "/api/operations/${operation_id}" "$TMP_DIR/command-operation.json" >/dev/null
    status="$(json_get "d['status']" "$TMP_DIR/command-operation.json")"
    case "$status" in
      succeeded)
        python3 - "$TMP_DIR/command-operation.json" "$stdout_file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
result = d.get("result") or {}
assert result.get("exitCode") == 0, result
assert result.get("truncated") is False, result
with open(sys.argv[2], "w") as output:
    output.write(result.get("stdout", ""))
PY
        return
        ;;
      failed)
        echo "FAIL: $label guest command failed" >&2
        cat "$TMP_DIR/command-operation.json" >&2
        exit 1
        ;;
    esac
    sleep 1
  done
  echo "FAIL: timed out waiting for $label guest command" >&2
  exit 1
}

measure_fio() {
  local dimension="$1" ceiling="$2" minimum="$3" label="$4"
  local rw block_size observed
  if [[ "$dimension" == iops ]]; then
    rw="randread"
    block_size="4k"
  else
    rw="read"
    block_size="1m"
  fi

  run_guest "$label" "$TMP_DIR/fio.json" \
    fio --name=strato-volume-limit --filename="/dev/${VOLUME_TARGET}" \
    --direct=1 --ioengine=sync --numjobs=1 --time_based=1 \
    --runtime="$FIO_RUNTIME_SECONDS" --ramp_time="$FIO_RAMP_SECONDS" \
    --group_reporting=1 --rw="$rw" --bs="$block_size" --output-format=json

  observed="$(python3 - "$dimension" "$ceiling" "$minimum" "$TMP_DIR/fio.json" <<'PY'
import json, sys
dimension, ceiling, minimum, path = sys.argv[1:]
ceiling = float(ceiling)
minimum = None if minimum == "-" else float(minimum)
d = json.load(open(path))
job = d["jobs"][0]
if dimension == "iops":
    observed = float(job["read"]["iops"]) + float(job["write"]["iops"])
else:
    observed = float(job["read"]["bw_bytes"]) + float(job["write"]["bw_bytes"])
assert observed <= ceiling * 1.10, (
    f"observed {observed:.2f} exceeds ceiling {ceiling:.0f} by more than 10%"
)
if minimum is not None:
    assert observed > minimum, (
        f"observed {observed:.2f} did not rise above prior tolerated ceiling {minimum:.2f}"
    )
print(f"{observed:.2f}")
PY
)"
  echo "  ok: $label observed $observed $dimension (ceiling $ceiling)"
}

echo "STR-270 QEMU volume I/O-limit contract"

create_volume_body="$(python3 - "$PROJECT_ID" "$INITIAL_IOPS" "$$" <<'PY'
import json, sys
print(json.dumps({
    "name": f"str-270-{sys.argv[3]}",
    "projectId": sys.argv[1],
    "sizeGB": 10,
    "iopsTotal": int(sys.argv[2]),
}))
PY
)"
code="$(request POST /api/volumes "$TMP_DIR/create-volume.json" "$create_volume_body")"
expect_code "create capped volume" "$code" 202 "$TMP_DIR/create-volume.json"
VOLUME_ID="$(json_get "d['resource']['id']" "$TMP_DIR/create-volume.json")"
target="$(json_get "d['targetGeneration']" "$TMP_DIR/create-volume.json")"
wait_volume_converged "$target" "create capped volume"

create_vm_body="$(python3 - "$IMAGE_ID" "$PROJECT_ID" "$NETWORK_ID" "$$" <<'PY'
import json, sys
print(json.dumps({
    "name": f"str-270-{sys.argv[4]}",
    "imageId": sys.argv[1],
    "projectId": sys.argv[2],
    "networkId": sys.argv[3],
    "environment": "development",
    "cpu": 1,
    "memory": 536870912,
    "disk": 10737418240,
    "hypervisorType": "qemu",
    "guestAgentEnabled": True,
}))
PY
)"
code="$(request POST /api/vms "$TMP_DIR/create-vm.json" "$create_vm_body")"
expect_code "create QEMU VM" "$code" 202 "$TMP_DIR/create-vm.json"
VM_ID="$(json_get "d['resource']['id']" "$TMP_DIR/create-vm.json")"
target="$(json_get "d['targetGeneration']" "$TMP_DIR/create-vm.json")"
wait_vm_converged "$target" "create VM"

code="$(request POST "/api/volumes/${VOLUME_ID}/attach" "$TMP_DIR/attach.json" \
  "{\"vmId\":\"${VM_ID}\",\"deviceName\":\"disk1\"}")"
expect_code "attach capped volume before boot" "$code" 202 "$TMP_DIR/attach.json"
target="$(json_get "d['targetGeneration']" "$TMP_DIR/attach.json")"
wait_volume_converged "$target" "cold attachment"
assert_applied_limits "$INITIAL_IOPS" - "cold attachment"

code="$(request POST "/api/vms/${VM_ID}/start" "$TMP_DIR/start.json")"
expect_code "start VM" "$code" 202 "$TMP_DIR/start.json"
target="$(json_get "d['targetGeneration']" "$TMP_DIR/start.json")"
wait_vm_converged "$target" "start VM"
VOLUME_TARGET="$(volume_target)"
assert_libvirt_limits "$INITIAL_IOPS" 0 "cold boot"
measure_fio iops "$INITIAL_IOPS" - "cold-boot IOPS ceiling"

set_limits "raise live IOPS ceiling" "{\"iopsTotal\":${RAISED_IOPS}}"
assert_applied_limits "$RAISED_IOPS" - "raised IOPS"
assert_libvirt_limits "$RAISED_IOPS" 0 "raised IOPS"
measure_fio iops "$RAISED_IOPS" "$((INITIAL_IOPS * 110 / 100))" "raised live IOPS ceiling"

set_limits "lower live IOPS ceiling" "{\"iopsTotal\":${LOWERED_IOPS}}"
assert_applied_limits "$LOWERED_IOPS" - "lowered IOPS"
assert_libvirt_limits "$LOWERED_IOPS" 0 "lowered IOPS"
measure_fio iops "$LOWERED_IOPS" - "lowered live IOPS ceiling"

set_limits "set bandwidth ceiling" "{\"bpsTotal\":${INITIAL_BPS}}"
assert_applied_limits - "$INITIAL_BPS" "initial bandwidth"
assert_libvirt_limits 0 "$INITIAL_BPS" "initial bandwidth"
measure_fio bps "$INITIAL_BPS" - "initial bandwidth ceiling"

set_limits "raise live bandwidth ceiling" "{\"bpsTotal\":${RAISED_BPS}}"
assert_applied_limits - "$RAISED_BPS" "raised bandwidth"
assert_libvirt_limits 0 "$RAISED_BPS" "raised bandwidth"
measure_fio bps "$RAISED_BPS" "$((INITIAL_BPS * 110 / 100))" "raised live bandwidth ceiling"

set_limits "lower live bandwidth ceiling" "{\"bpsTotal\":${LOWERED_BPS}}"
assert_applied_limits - "$LOWERED_BPS" "lowered bandwidth"
assert_libvirt_limits 0 "$LOWERED_BPS" "lowered bandwidth"
measure_fio bps "$LOWERED_BPS" - "lowered live bandwidth ceiling"

echo "  restarting agent: $RESTART_AGENT_COMMAND"
bash -lc "$RESTART_AGENT_COMMAND"
measure_fio bps "$LOWERED_BPS" - "bandwidth ceiling after agent restart/adoption"
assert_libvirt_limits 0 "$LOWERED_BPS" "agent restart/adoption"

code="$(request POST "/api/vms/${VM_ID}/restart" "$TMP_DIR/reboot.json")"
expect_code "reboot VM" "$code" 202 "$TMP_DIR/reboot.json"
target="$(json_get "d['targetGeneration']" "$TMP_DIR/reboot.json")"
wait_vm_converged "$target" "VM reboot"
measure_fio bps "$LOWERED_BPS" - "bandwidth ceiling after VM reboot"
assert_libvirt_limits 0 "$LOWERED_BPS" "VM reboot"

code="$(request POST "/api/volumes/${VOLUME_ID}/detach" "$TMP_DIR/detach.json")"
expect_code "hot detach volume" "$code" 202 "$TMP_DIR/detach.json"
target="$(json_get "d['targetGeneration']" "$TMP_DIR/detach.json")"
wait_volume_converged "$target" "hot detach"

code="$(request POST "/api/volumes/${VOLUME_ID}/attach" "$TMP_DIR/reattach.json" \
  "{\"vmId\":\"${VM_ID}\",\"deviceName\":\"disk1\"}")"
expect_code "hot reattach volume" "$code" 202 "$TMP_DIR/reattach.json"
target="$(json_get "d['targetGeneration']" "$TMP_DIR/reattach.json")"
wait_volume_converged "$target" "hot reattach"
VOLUME_TARGET="$(volume_target)"
assert_applied_limits - "$LOWERED_BPS" "hot reattach"
assert_libvirt_limits 0 "$LOWERED_BPS" "hot reattach"
measure_fio bps "$LOWERED_BPS" - "bandwidth ceiling after hot reattach"

echo "PASS: STR-270"
