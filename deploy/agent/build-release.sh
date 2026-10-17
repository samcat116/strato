#!/usr/bin/env bash
# Shared by main publication and the nonpublishing manual artifact validation.
set -euo pipefail
arch="${1:?usage: build-release.sh <x86_64|arm64> <output-dir>}"
output="${2:?}"
: "${GITHUB_SHA:?}" "${SWIFTPM_CACHE_PATH:?}"
[[ "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]] || exit 1
[ "$(git rev-parse HEAD)" = "$GITHUB_SHA" ] || { echo "checkout identity mismatch" >&2; exit 1; }
case "$(uname -m):$arch" in
  x86_64:x86_64|aarch64:arm64) ;;
  *) echo "native architecture does not match $arch" >&2; exit 1 ;;
esac
cat > agent/Sources/StratoAgentRuntime/CompiledBuildInfo.swift <<EOF
enum CompiledBuildInfo {
    static let version: String? = "main-${GITHUB_SHA::12}"
    static let gitSHA: String? = "${GITHUB_SHA}"
}
EOF
swift build --package-path agent -c release --product StratoAgent --static-swift-stdlib -j 4 --cache-path "$SWIFTPM_CACHE_PATH"
bin="$(swift build --package-path agent -c release --show-bin-path)"
strip "$bin/StratoAgent"
# Static Swift does not mean static glibc. Refuse accidental image binaries.
libraries=$(ldd "$bin/StratoAgent")
printf '%s\n' "$libraries"
if grep -E 'libswift|libjemalloc|not found' <<< "$libraries"; then exit 1; fi
wire=$(sed -n 's/.*public static let currentVersion = \([0-9]*\).*/\1/p' shared/Sources/StratoShared/WireProtocol.swift)
python3 deploy/agent/package-release.py package --binary "$bin/StratoAgent" \
  --arch "$arch" --sha "$GITHUB_SHA" --wire-version "$wire" \
  --epoch "$(git show -s --format=%ct HEAD)" --output "$output"
