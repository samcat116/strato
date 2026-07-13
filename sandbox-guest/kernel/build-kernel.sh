#!/usr/bin/env bash
#
# Build the Strato sandbox guest kernel for one target architecture.
#
#   build-kernel.sh <x86_64|aarch64> <output-file> [build-dir]
#
# Downloads the pinned upstream kernel (verifying its sha256), applies the
# arch config fragment on top of `defconfig`, builds, and copies the resulting
# uncompressed kernel image to <output-file>. Cross-compiles automatically when
# the target arch differs from the build host.
set -euo pipefail

ARCH_INPUT="${1:?usage: build-kernel.sh <x86_64|aarch64> <output-file> [build-dir]}"
OUT_FILE="${2:?usage: build-kernel.sh <x86_64|aarch64> <output-file> [build-dir]}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${3:-${SCRIPT_DIR}/../build/kernel}"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/LINUX_VERSION"

case "${ARCH_INPUT}" in
  x86_64)
    KARCH=x86_64
    FRAGMENT="${SCRIPT_DIR}/config-x86_64.fragment"
    IMAGE_REL="vmlinux"                        # Firecracker x86_64 boots the uncompressed ELF vmlinux
    CROSS_PREFIX="x86_64-linux-gnu-"
    ;;
  aarch64|arm64)
    KARCH=arm64
    FRAGMENT="${SCRIPT_DIR}/config-aarch64.fragment"
    IMAGE_REL="arch/arm64/boot/Image"          # Firecracker aarch64 boots the decompressed Image
    CROSS_PREFIX="aarch64-linux-gnu-"
    ;;
  *)
    echo "unsupported arch: ${ARCH_INPUT} (want x86_64 or aarch64)" >&2
    exit 2
    ;;
esac

HOST_ARCH="$(uname -m)"
CROSS=()
if [[ "${HOST_ARCH}" != "${ARCH_INPUT}" && ! ( "${HOST_ARCH}" == "arm64" && "${ARCH_INPUT}" == "aarch64" ) ]]; then
  CROSS=(CROSS_COMPILE="${CROSS_PREFIX}")
  echo ">> cross-compiling ${ARCH_INPUT} on ${HOST_ARCH} (CROSS_COMPILE=${CROSS_PREFIX})"
fi

TARBALL="linux-${LINUX_VERSION}.tar.xz"
SRC_DIR="${BUILD_DIR}/linux-${LINUX_VERSION}"
CACHE_DIR="${BUILD_DIR}/cache"
mkdir -p "${CACHE_DIR}"

if [[ ! -f "${CACHE_DIR}/${TARBALL}" ]]; then
  echo ">> downloading ${TARBALL}"
  curl -fSL --retry 3 -o "${CACHE_DIR}/${TARBALL}" \
    "https://cdn.kernel.org/pub/linux/kernel/v6.x/${TARBALL}"
fi

echo ">> verifying sha256"
echo "${LINUX_SHA256}  ${CACHE_DIR}/${TARBALL}" | sha256sum -c -

if [[ ! -d "${SRC_DIR}" ]]; then
  echo ">> extracting"
  tar -C "${BUILD_DIR}" -xf "${CACHE_DIR}/${TARBALL}"
fi

NPROC="$(nproc 2>/dev/null || echo 4)"

echo ">> configuring (${KARCH})"
make -C "${SRC_DIR}" ARCH="${KARCH}" "${CROSS[@]}" defconfig
"${SRC_DIR}/scripts/kconfig/merge_config.sh" -m -O "${SRC_DIR}" \
  "${SRC_DIR}/.config" "${FRAGMENT}"
make -C "${SRC_DIR}" ARCH="${KARCH}" "${CROSS[@]}" olddefconfig

echo ">> building (-j${NPROC})"
make -C "${SRC_DIR}" ARCH="${KARCH}" "${CROSS[@]}" -j"${NPROC}"

mkdir -p "$(dirname "${OUT_FILE}")"
cp "${SRC_DIR}/${IMAGE_REL}" "${OUT_FILE}"
echo ">> wrote ${OUT_FILE} ($(du -h "${OUT_FILE}" | cut -f1))"
