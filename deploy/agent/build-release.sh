#!/usr/bin/env bash
# Shared by main publication and the nonpublishing manual artifact validation.
set -euo pipefail
arch="${1:?usage: build-release.sh <x86_64|arm64> <output-dir>}"
output="${2:?}"
: "${GITHUB_SHA:?}" "${SWIFTPM_CACHE_PATH:?}"
[[ "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]] || exit 1
# Actions checkout's temporary HOME can differ from this container's HOME.
# Trust only this mounted checkout, only for these read-only commands; never
# persist a global safe.directory exception or disable ownership checks broadly.
[ "$(git -c safe.directory="$PWD" rev-parse HEAD)" = "$GITHUB_SHA" ] || { echo "checkout identity mismatch" >&2; exit 1; }
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
xml_dir="$PWD/agent/.build/static-xml"
bash deploy/agent/build-static-xml.sh "$xml_dir"
# Swift 6.4.0's default backend drops Foundation's static dependencies:
# https://github.com/swiftlang/swift-build/issues/1764
swift build --package-path agent -c release --product StratoAgent --static-swift-stdlib \
  --build-system native -j 4 --cache-path "$SWIFTPM_CACHE_PATH" \
  -Xlinker "-L$xml_dir"
bin="$(swift build --package-path agent -c release --build-system native --show-bin-path)"
probe_package=.github/fixtures/agent-runtime-probe
swift build --package-path "$probe_package" -c release --static-swift-stdlib --build-system native \
  -Xlinker "-L$xml_dir"
probe_bin="$(swift build --package-path "$probe_package" -c release --build-system native --show-bin-path)"
"$probe_bin/AgentRuntimeProbe"
mkdir -p "$output"
cp "$probe_bin/AgentRuntimeProbe" "$output/runtime-probe"
strip "$bin/StratoAgent"
# Static Swift does not mean static glibc. Refuse accidental image binaries.
libraries=$(ldd "$bin/StratoAgent")
printf '%s\n' "$libraries"
if grep -E 'libswift|libFoundation|lib_Foundation|libdispatch|libBlocksRuntime|libjemalloc|libxml2|libicu|not found' <<< "$libraries"; then exit 1; fi
wire=$(sed -n 's/.*public static let currentVersion = \([0-9]*\).*/\1/p' shared/Sources/StratoShared/WireProtocol.swift)
python3 deploy/agent/package-release.py package --binary "$bin/StratoAgent" \
  --arch "$arch" --sha "$GITHUB_SHA" --wire-version "$wire" \
  --epoch "$(git -c safe.directory="$PWD" show -s --format=%ct HEAD)" --output "$output"
