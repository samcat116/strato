#!/usr/bin/env bash
#
# Build the static Strato VM guest agent for one architecture and lay out the
# two files its installer consumes. The output directory is the root of the
# release tarball: no host paths or architecture directory are baked into it.
#
#   build-guest-agent.sh [--arch x86_64|aarch64] [--out DIR]
#
# Defaults: build for the host architecture into ./build/guest-agent/<arch>.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH="$(uname -m)"
OUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "${ARCH}" in
  x86_64)
    RUST_TARGET="x86_64-unknown-linux-musl"
    ;;
  aarch64|arm64)
    ARCH="aarch64"
    RUST_TARGET="aarch64-unknown-linux-musl"
    ;;
  *)
    echo "unsupported arch: ${ARCH}" >&2
    exit 2
    ;;
esac

OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/build/guest-agent/${ARCH}}"

echo "== building VM guest agent for ${ARCH} (${RUST_TARGET}) =="
rustup target add "${RUST_TARGET}" >/dev/null 2>&1 || true
cargo build --release --locked \
  --manifest-path "${SCRIPT_DIR}/init/Cargo.toml" \
  --target "${RUST_TARGET}" \
  --bin strato-guest-agent

BIN="${SCRIPT_DIR}/init/target/${RUST_TARGET}/release/strato-guest-agent"
[[ -f "${BIN}" ]] || { echo "guest-agent binary not found at ${BIN}" >&2; exit 1; }

mkdir -p "${OUT_DIR}"
install -m 0755 "${BIN}" "${OUT_DIR}/strato-guest-agent"
install -m 0644 "${SCRIPT_DIR}/strato-guest-agent.service" \
  "${OUT_DIR}/strato-guest-agent.service"

echo "== wrote VM guest-agent layout to ${OUT_DIR} =="
ls -la "${OUT_DIR}"
