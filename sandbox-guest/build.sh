#!/usr/bin/env bash
#
# Build the Strato sandbox guest image — a kernel + initramfs pair per arch —
# and lay them out with a `guest.json` manifest the agent reads
# (StratoAgentCore/SandboxGuestImage). The output directory is exactly the
# on-disk layout an agent expects at `sandbox_guest_image_path`
# (default /var/lib/strato/sandbox/guest).
#
#   build.sh [--arch x86_64[,aarch64]] [--out DIR] [--version VER] [--git-sha SHA]
#
# Defaults: build for the host arch into ./build/out, version derived from the
# pinned kernel + init crate versions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/kernel/LINUX_VERSION"
INIT_VERSION="$(grep -m1 '^version' "${SCRIPT_DIR}/init/Cargo.toml" | cut -d'"' -f2)"

ARCHES="$(uname -m)"
OUT_DIR="${SCRIPT_DIR}/build/out"
VERSION="${LINUX_VERSION}+init${INIT_VERSION}"
GIT_SHA="$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCHES="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --git-sha) GIT_SHA="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "${OUT_DIR}"
IFS=',' read -r -a ARCH_LIST <<< "${ARCHES}"

boot_args_for() {
  case "$1" in
    x86_64) echo "console=ttyS0 reboot=k panic=1 pci=off" ;;
    aarch64|arm64) echo "console=ttyAMA0 reboot=k panic=1 pci=off" ;;
  esac
}

entries=()
for arch in "${ARCH_LIST[@]}"; do
  arch="$(echo "${arch}" | xargs)"  # trim
  echo "== building guest image for ${arch} =="
  kernel_name="vmlinux-${arch}"
  initramfs_name="initramfs-${arch}.cpio.gz"

  "${SCRIPT_DIR}/kernel/build-kernel.sh" "${arch}" "${OUT_DIR}/${kernel_name}"
  "${SCRIPT_DIR}/init/build-initramfs.sh" "${arch}" "${OUT_DIR}/${initramfs_name}"

  ksha="$(sha256sum "${OUT_DIR}/${kernel_name}" | cut -d' ' -f1)"
  isha="$(sha256sum "${OUT_DIR}/${initramfs_name}" | cut -d' ' -f1)"
  ksize="$(stat -c%s "${OUT_DIR}/${kernel_name}")"
  isize="$(stat -c%s "${OUT_DIR}/${initramfs_name}")"
  echo "${ksha}  ${kernel_name}" > "${OUT_DIR}/${kernel_name}.sha256"
  echo "${isha}  ${initramfs_name}" > "${OUT_DIR}/${initramfs_name}.sha256"

  entries+=("$(cat <<JSON
    {
      "arch": "${arch}",
      "kernel": "${kernel_name}",
      "initramfs": "${initramfs_name}",
      "kernelSha256": "${ksha}",
      "initramfsSha256": "${isha}",
      "kernelSize": ${ksize},
      "initramfsSize": ${isize},
      "bootArgs": "$(boot_args_for "${arch}")"
    }
JSON
)")
done

# Join entries with commas into the guest.json manifest. Command substitution
# strips the trailing newline, so the accumulated string ends with a bare ",".
joined="$(printf '%s,\n' "${entries[@]}")"
joined="${joined%,}"
cat > "${OUT_DIR}/guest.json" <<JSON
{
  "schemaVersion": 1,
  "version": "${VERSION}",
  "gitSHA": "${GIT_SHA}",
  "artifacts": [
${joined}
  ]
}
JSON

echo "== wrote guest image to ${OUT_DIR} =="
ls -la "${OUT_DIR}"
