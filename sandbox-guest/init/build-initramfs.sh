#!/usr/bin/env bash
#
# Build the static guest init and pack it into a gzipped cpio initramfs.
#
#   build-initramfs.sh <x86_64|aarch64> <output-file> [build-dir]
#
# The init is built fully static against musl so it has no runtime library
# dependencies inside the microVM, then placed at /init in a newc cpio archive
# the kernel unpacks as its initial root filesystem.
set -euo pipefail

ARCH_INPUT="${1:?usage: build-initramfs.sh <x86_64|aarch64> <output-file> [build-dir]}"
OUT_FILE="${2:?usage: build-initramfs.sh <x86_64|aarch64> <output-file> [build-dir]}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${3:-${SCRIPT_DIR}/../build/initramfs-${ARCH_INPUT}}"

case "${ARCH_INPUT}" in
  x86_64) RUST_TARGET="x86_64-unknown-linux-musl" ;;
  aarch64|arm64) RUST_TARGET="aarch64-unknown-linux-musl" ;;
  *) echo "unsupported arch: ${ARCH_INPUT}" >&2; exit 2 ;;
esac

echo ">> building init (${RUST_TARGET})"
rustup target add "${RUST_TARGET}" >/dev/null 2>&1 || true
cargo build --release --locked --manifest-path "${SCRIPT_DIR}/Cargo.toml" --target "${RUST_TARGET}"

BIN="${SCRIPT_DIR}/target/${RUST_TARGET}/release/strato-sandbox-init"
[[ -f "${BIN}" ]] || { echo "init binary not found at ${BIN}" >&2; exit 1; }

echo ">> assembling initramfs tree"
ROOT="${BUILD_DIR}/root"
rm -rf "${ROOT}"
mkdir -p "${ROOT}"/{dev,proc,sys,newroot}
install -m 0755 "${BIN}" "${ROOT}/init"

echo ">> packing cpio.gz"
mkdir -p "$(dirname "${OUT_FILE}")"
( cd "${ROOT}" && find . -print0 | cpio --null -o --format=newc --quiet ) | gzip -9 > "${OUT_FILE}"
echo ">> wrote ${OUT_FILE} ($(du -h "${OUT_FILE}" | cut -f1))"
