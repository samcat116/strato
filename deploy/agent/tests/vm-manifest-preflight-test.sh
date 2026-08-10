#!/usr/bin/env bash
# Fixture tests for the read-only STR-225 manifest cutover inventory.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT="$SCRIPT_DIR/../../../agent/scripts/vm-manifest-preflight.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

FAILURES=0
CASES=0

check_case() {
  local description="$1" expected_status="$2" expected_text="$3" root="$4"
  local output status
  CASES=$((CASES + 1))
  output="$("$PREFLIGHT" "$root" 2>&1)"
  status=$?
  if [[ "$status" -eq "$expected_status" && "$output" == *"$expected_text"* ]]; then
    echo "  ok: $description"
  else
    echo "  FAIL: $description" >&2
    printf '    expected status %s and text: %s\n' "$expected_status" "$expected_text" >&2
    printf '    got status %s and output:\n%s\n' "$status" "$output" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

fresh="$WORK_DIR/fresh"
mkdir -p "$fresh"
check_case 'a fresh host passes' 0 'manifest state: fresh host' "$fresh"

current="$WORK_DIR/current"
mkdir -p "$current"
printf '%s\n' '{"vm-a":{"kind":"vm","hypervisorType":"qemu","spec":{}}}' \
  > "$current/vm-manifest.json"
check_case 'a kind-complete unified manifest passes' 0 'kind-complete (1 entries)' "$current"

legacy="$WORK_DIR/legacy"
mkdir -p "$legacy"
printf '%s\n' '{"vm-a":{"cpus":2,"memoryBytes":1024}}' > "$legacy/qemu-manifest.json"
check_case 'a VMSpec legacy-only manifest blocks cutover' 1 'legacy format: VMSpec map (1 entries)' "$legacy"

pre_vmspec="$WORK_DIR/pre-vmspec"
mkdir -p "$pre_vmspec"
printf '%s\n' \
  '{"vm-old":{"cpus":{"boot_vcpus":6,"max_vcpus":8},"memory":{"size":4096}}}' \
  > "$pre_vmspec/qemu-manifest.json"
check_case 'a pre-VMSpec legacy-only manifest names its workload' 1 'pre-VMSpec legacy entries:' "$pre_vmspec"
check_case 'the pre-VMSpec workload ID is reported' 1 'vm-old' "$pre_vmspec"

kindless="$WORK_DIR/kindless"
mkdir -p "$kindless"
printf '%s\n' '{"vm-old":{"hypervisorType":"firecracker","spec":{"cpus":5}}}' \
  > "$kindless/vm-manifest.json"
check_case 'a kindless unified entry blocks cutover' 1 'unified entries without a workload kind:' "$kindless"
check_case 'the kindless workload ID is reported' 1 'vm-old' "$kindless"

shadow="$WORK_DIR/shadow"
mkdir -p "$shadow"
printf '%s\n' '{"vm-a":{"kind":"vm","hypervisorType":"qemu","spec":{}}}' \
  > "$shadow/vm-manifest.json"
printf '%s\n' 'not-json' > "$shadow/qemu-manifest.json"
check_case 'a shadow legacy file is non-authoritative and is not opened' 0 \
  'legacy manifest: shadowed by the unified manifest' "$shadow"

if [[ "$FAILURES" -eq 0 ]]; then
  echo "vm-manifest-preflight.sh: $CASES checks passed"
else
  echo "vm-manifest-preflight.sh: $FAILURES of $CASES checks FAILED" >&2
fi
exit $((FAILURES > 0))
