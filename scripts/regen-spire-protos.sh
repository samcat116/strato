#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR_PACKAGE="$ROOT/control-plane/.build/checkouts/swift-protobuf"

swift build -c release --product protoc-gen-swift --package-path "$GENERATOR_PACKAGE"
GENERATOR="$GENERATOR_PACKAGE/.build/release/protoc-gen-swift"

generate() {
  local directory="$1"
  shift
  local -a protos
  while IFS= read -r proto; do
    protos+=("$proto")
  done < <(cd "$directory/proto" && find . -name '*.proto' -print | sort)
  (
    cd "$directory"
    protoc -I proto "$@" \
      --plugin="protoc-gen-swift=$GENERATOR" \
      --swift_out=. \
      --swift_opt=Visibility=Public \
      --swift_opt=FileNaming=PathToUnderscores \
      "${protos[@]}"
  )
}

SHARED_PROTO="$ROOT/shared/Sources/SPIFFEKit/Generated/proto"

generate "$ROOT/shared/Sources/SPIFFEKit/Generated"
generate "$ROOT/control-plane/Sources/SPIREServerAPI/Generated" -I "$SHARED_PROTO"
generate "$ROOT/agent/Sources/StratoAgentSPIFFE/Generated" -I "$SHARED_PROTO"
