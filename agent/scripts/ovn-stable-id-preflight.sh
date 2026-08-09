#!/usr/bin/env bash
# Read-only inventory for the OVN stable-network-ID cutover (STR-226).
set -euo pipefail

OVN_NBCTL=${OVN_NBCTL:-ovn-nbctl}
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

switches=$(
  "$OVN_NBCTL" --format=json --data=json \
    --columns=_uuid,name,external_ids list Logical_Switch |
    jq -c '
      .headings as $h
      | .data[] | [[$h, .] | transpose[] | {(.[0]): .[1]}] | add
      | .external_ids = (.external_ids[1] | map({key: .[0], value: .[1]}) | from_entries)
      | select(.external_ids.description == "Auto-created network for VM")
      | select(.name | test("^net-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") | not)
      | {uuid: ._uuid[1], name, subnet: .external_ids.subnet}'
)

dhcp=$(
  "$OVN_NBCTL" --format=json --data=json \
    --columns=_uuid,cidr,external_ids list DHCP_Options |
    jq -c '
      .headings as $h
      | .data[] | [[$h, .] | transpose[] | {(.[0]): .[1]}] | add
      | .external_ids = (.external_ids[1] | map({key: .[0], value: .[1]}) | from_entries)
      | select(.external_ids["strato-managed"] == "true")
      | select(.external_ids["network-id"] == null)
      | {uuid: ._uuid[1], cidr, network_name: .external_ids["network-name"]}'
)

printf '%s\n' 'Legacy name-based logical switches:'
printf '%s\n' "${switches:-none}"
printf '%s\n' 'Managed DHCP rows without a stable network-id:'
printf '%s\n' "${dhcp:-none}"

if [[ -n "$switches" || -n "$dhcp" ]]; then
  echo 'preflight failed: converge these rows with the migration-capable agent before upgrading' >&2
  exit 1
fi

echo 'preflight passed: zero adoptable legacy OVN objects'
