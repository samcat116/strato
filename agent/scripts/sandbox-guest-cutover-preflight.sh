#!/usr/bin/env bash
# Read-only host artifact inventory for the STR-223 sandbox guest cutover.
set -euo pipefail

guest_image_dir=/var/lib/strato/sandbox/guest
vm_storage_dir=/var/lib/strato/vms
jailer_chroot_dir=
firecracker_name=firecracker

usage() {
  cat <<'EOF'
Usage: sandbox-guest-cutover-preflight.sh [options]

Options:
  --guest-image-dir DIR   Installed sandbox guest directory.
  --vm-storage-dir DIR    Agent vm_storage_dir; contains snapshot-records.json.
  --jailer-chroot-dir DIR Agent sandbox_jailer_chroot_dir.
  --firecracker-name NAME Firecracker executable basename used by the jailer.
  -h, --help              Show this help.

The command is read-only. It exits 1 when an installed guest manifest, active
config drive, or recorded sandbox checkpoint uses a retired schema/protocol.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --guest-image-dir) guest_image_dir=$2; shift 2 ;;
    --vm-storage-dir) vm_storage_dir=$2; shift 2 ;;
    --jailer-chroot-dir) jailer_chroot_dir=$2; shift 2 ;;
    --firecracker-name) firecracker_name=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$jailer_chroot_dir" ]]; then
  jailer_chroot_dir="${vm_storage_dir}/jailer"
fi

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

blockers=0
config_count=0
snapshot_count=0

report_config() {
  local kind=$1
  local id=$2
  local path=$3
  local document
  local identity=present
  local schema
  config_count=$((config_count + 1))
  if [[ ! -r "$path" ]]; then
    printf '%s\n' "$kind $id: config unreadable at $path"
    blockers=$((blockers + 1))
    return
  fi
  document=$(LC_ALL=C tr -d '\000' < "$path")
  if ! schema=$(jq -er '.schema_version | numbers' <<< "$document" 2>/dev/null); then
    printf '%s\n' "$kind $id: config has no readable schema_version at $path"
    blockers=$((blockers + 1))
    return
  fi
  if ! jq -e '[.sandbox_id, .identity_nonce] | all(type == "string" and length > 0)' \
    <<< "$document" >/dev/null 2>&1; then
    identity=missing
    blockers=$((blockers + 1))
  fi
  printf '%s\n' "$kind $id: config_schema=$schema identity=$identity path=$path"
  if [[ "$schema" != 2 ]]; then
    blockers=$((blockers + 1))
  fi
}

manifest_path="${guest_image_dir}/guest.json"
if [[ ! -e "$guest_image_dir" ]]; then
  printf '%s\n' "Installed guest: none at $guest_image_dir"
elif [[ ! -r "$manifest_path" ]]; then
  printf '%s\n' "Installed guest: manifest unreadable at $manifest_path"
  blockers=$((blockers + 1))
else
  manifest_schema=$(jq -er '.schemaVersion | numbers' "$manifest_path" 2>/dev/null || true)
  manifest_version=$(jq -er '.version | strings' "$manifest_path" 2>/dev/null || true)
  capabilities_type=$(jq -er '.capabilities | type' "$manifest_path" 2>/dev/null || true)
  artifacts_type=$(jq -er '.artifacts | type' "$manifest_path" 2>/dev/null || true)
  manifest_valid=$(jq -er '
    .schemaVersion == 2
      and (.version | type == "string")
      and ((.gitSHA == null) or (.gitSHA | type == "string"))
      and (.capabilities | type == "array")
      and all(.capabilities[]; type == "string")
      and (.artifacts | type == "array")
      and all(.artifacts[];
        type == "object"
          and (.arch | type == "string")
          and (.kernel | type == "string")
          and (.initramfs | type == "string")
          and (.bootArgs | type == "string"))
  ' "$manifest_path" 2>/dev/null || true)
  printf '%s\n' \
    "Installed guest: manifest_schema=${manifest_schema:-missing} version=${manifest_version:-missing} capabilities=${capabilities_type:-missing} artifacts=${artifacts_type:-missing} shape=${manifest_valid:-invalid} path=$manifest_path"
  if [[ "$manifest_valid" != true ]]; then
    blockers=$((blockers + 1))
  fi
fi

# Active flat and jailed config drives. Missing roots mean this host has no
# sandboxes in that layout; find errors are suppressed only for that case.
flat_root="${vm_storage_dir}"
if [[ -d "$flat_root" ]]; then
  while IFS= read -r -d '' config; do
    sandbox_id=${config#"${flat_root}/"}
    sandbox_id=${sandbox_id%/config.img}
    report_config "Active sandbox" "$sandbox_id" "$config"
  done < <(find "$flat_root" -mindepth 2 -maxdepth 2 -type f -name config.img -print0)
fi

jailed_root="${jailer_chroot_dir}/${firecracker_name}"
if [[ -d "$jailed_root" ]]; then
  while IFS= read -r -d '' config; do
    sandbox_id=${config#"${jailed_root}/"}
    sandbox_id=${sandbox_id%/root/config.img}
    report_config "Active jailed sandbox" "$sandbox_id" "$config"
  done < <(find "$jailed_root" -mindepth 3 -maxdepth 3 -type f -path '*/root/config.img' -print0)
fi

records_path="${vm_storage_dir}/snapshot-records.json"
if [[ ! -e "$records_path" ]]; then
  printf '%s\n' "Recorded checkpoints: none at $records_path"
elif ! jq -e 'type == "object"' "$records_path" >/dev/null 2>&1; then
  printf '%s\n' "Recorded checkpoints: unreadable snapshot record object at $records_path"
  blockers=$((blockers + 1))
else
  while IFS= read -r record; do
    snapshot_count=$((snapshot_count + 1))
    snapshot_id=$(jq -r '.key' <<< "$record")
    protocol=$(jq -r '.value.facts.guestControlProtocolVersion // "missing"' <<< "$record")
    layout=$(jq -r '.value.facts.forkLayoutVersion // "missing"' <<< "$record")
    storage_path=$(jq -r '.value.facts.storagePath // ""' <<< "$record")
    printf '%s\n' \
      "Checkpoint $snapshot_id: guest_protocol=$protocol fork_layout=$layout storage_path=${storage_path:-missing}"
    if [[ "$protocol" != 4 ]]; then
      blockers=$((blockers + 1))
    fi
    if [[ -z "$storage_path" ]]; then
      printf '%s\n' "Checkpoint $snapshot_id: cannot verify config schema without facts.storagePath"
      blockers=$((blockers + 1))
    else
      report_config "Checkpoint" "$snapshot_id" "${storage_path}/config.img"
    fi
  done < <(jq -c 'to_entries[] | select(.value.kind == "SandboxSnapshot")' "$records_path")
fi

printf '%s\n' \
  "Inventory summary: installed_manifest=$([[ -e "$manifest_path" ]] && echo 1 || echo 0) configs=$config_count checkpoints=$snapshot_count blockers=$blockers"
if [[ "$blockers" -ne 0 ]]; then
  echo "preflight failed: upgrade/recreate active artifacts and delete or recapture legacy checkpoints before deploying STR-223" >&2
  exit 1
fi

echo "preflight passed: every installed sandbox guest artifact uses manifest/config schema 2 and guest control protocol 4"
