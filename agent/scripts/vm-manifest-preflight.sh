#!/usr/bin/env bash
# Read-only host inventory for the canonical VM manifest cutover (STR-225).
set -euo pipefail

command -v jq >/dev/null || { echo 'jq is required' >&2; exit 2; }

if [[ $# -eq 0 ]]; then
  storage_roots=(/var/lib/strato/vms)
else
  storage_roots=("$@")
fi

failures=0

for root in "${storage_roots[@]}"; do
  unified="$root/vm-manifest.json"
  legacy="$root/qemu-manifest.json"
  printf '[%s]\n' "$root"

  if [[ -e "$unified" ]]; then
    if ! jq -e 'type == "object"' "$unified" >/dev/null 2>&1; then
      echo '  unified manifest: unreadable or not a JSON object'
      failures=$((failures + 1))
    else
      kindless=$(
        jq -r '
          to_entries[]
          | select((.value | type) != "object" or (.value | has("kind") | not))
          | .key' "$unified"
      )
      if [[ -n "$kindless" ]]; then
        echo '  unified entries without a workload kind:'
        while IFS= read -r workload_id; do printf '    %s\n' "$workload_id"; done <<< "$kindless"
        failures=$((failures + 1))
      else
        count=$(jq 'length' "$unified")
        printf '  unified manifest: kind-complete (%s entries)\n' "$count"
      fi
    fi

    if [[ -e "$legacy" ]]; then
      echo '  legacy manifest: shadowed by the unified manifest (not authoritative)'
    else
      echo '  legacy manifest: absent'
    fi
    continue
  fi

  if [[ ! -e "$legacy" ]]; then
    echo '  manifest state: fresh host'
    continue
  fi

  echo '  legacy-only manifest: present'
  failures=$((failures + 1))
  if ! jq -e 'type == "object"' "$legacy" >/dev/null 2>&1; then
    echo '  legacy format: unreadable or not a JSON object'
    continue
  fi

  pre_vmspec=$(
    jq -r '
      to_entries[]
      | select(
          (.value | type) != "object"
          or (.value.cpus? | type) == "object"
          or (.value | has("memory")))
      | .key' "$legacy"
  )
  if [[ -n "$pre_vmspec" ]]; then
    echo '  pre-VMSpec legacy entries:'
    while IFS= read -r workload_id; do printf '    %s\n' "$workload_id"; done <<< "$pre_vmspec"
  else
    count=$(jq 'length' "$legacy")
    printf '  legacy format: VMSpec map (%s entries)\n' "$count"
  fi
done

if [[ $failures -ne 0 ]]; then
  echo "preflight failed: $failures storage root(s) need manifest remediation" >&2
  exit 1
fi

echo 'preflight passed: zero legacy-only manifests and zero kindless unified entries'
