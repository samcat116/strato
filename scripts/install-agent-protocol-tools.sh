#!/usr/bin/env bash
# Installs only into the selected task-local directory; never changes global PATH.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${1:-$root/.build/agent-protocol-tools}"
mkdir -p "$destination/bin"
destination="$(cd "$destination" && pwd)"
platform="$(uname -s)-$(uname -m)"
case "$platform" in
    Darwin-arm64) asset=buf-Darwin-arm64; digest=6e6df0fef4522e4e43dfe7c341873c3f2c29ceb45a9dfa5e0bad5580b8b2022f ;;
    Darwin-x86_64) asset=buf-Darwin-x86_64; digest=ff78d0ebf34180ebfa81d370275851ec630fcb088bf33e213fd723d0fd7444a6 ;;
    Linux-aarch64|Linux-arm64) asset=buf-Linux-aarch64; digest=902b75267db7f4391e99b7fa0756050e5354234cc0437ef50eee9c788950c7a3 ;;
    Linux-x86_64) asset=buf-Linux-x86_64; digest=8f2986298ad08f0cc1bf999b9797b7c383adf32d7edf0f73d6f1e1a701baeac1 ;;
    *) echo "Unsupported protocol-tool platform: $platform" >&2; exit 1 ;;
esac
if [[ ! -f "$destination/bin/buf" ]]; then
    curl --fail --location --retry 3 --output "$destination/bin/buf.download" \
        "https://github.com/bufbuild/buf/releases/download/v1.73.0/$asset"
    mv "$destination/bin/buf.download" "$destination/bin/buf"
fi
python3 - "$destination/bin/buf" "$digest" <<'PY'
import hashlib, pathlib, sys
if hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() != sys.argv[2]:
    raise SystemExit("Pinned Buf binary checksum mismatch")
PY
chmod +x "$destination/bin/buf"
revision=55d7a1cc5666b85c13464aea1c4b4a90feccb4c8
if [[ ! -d "$destination/swift-protobuf/.git" ]]; then
    git clone --branch 1.38.1 --depth 1 https://github.com/apple/swift-protobuf.git "$destination/swift-protobuf"
fi
[[ "$(git -C "$destination/swift-protobuf" rev-parse HEAD)" == "$revision" ]] || {
    echo 'Pinned SwiftProtobuf source revision mismatch' >&2; exit 1;
}
[[ -z "$(git -C "$destination/swift-protobuf" status --porcelain)" ]] || {
    echo 'Pinned SwiftProtobuf source has local changes' >&2; exit 1;
}
swift build --package-path "$destination/swift-protobuf" --scratch-path "$destination/build" \
    -j 4 -c release --product protoc-gen-swift
bin_path="$(swift build --package-path "$destination/swift-protobuf" --scratch-path "$destination/build" -c release --show-bin-path)"
printf 'export STRATO_BUF=%q\nexport STRATO_PROTOC_GEN_SWIFT=%q\n' \
    "$destination/bin/buf" "$bin_path/protoc-gen-swift" > "$destination/env.sh"
echo "Protocol tools ready; source $destination/env.sh"
