#!/usr/bin/env bash
# Reproducible generation and schema checks. No hosted registry is required.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
buf_bin="${STRATO_BUF:-buf}"
generator="${STRATO_PROTOC_GEN_SWIFT:-protoc-gen-swift}"
mode="${1:-check}"
case "$mode" in generate|check) ;; *) echo "Usage: $0 [generate|check] [baseline]" >&2; exit 2 ;; esac
[[ "$("$buf_bin" --version)" == "1.73.0" ]] || { echo 'Buf 1.73.0 is required' >&2; exit 1; }
[[ "$("$generator" --version)" == "protoc-gen-swift 1.38.1" ]] || {
    echo 'protoc-gen-swift 1.38.1 is required' >&2; exit 1;
}
python3 - <<'PY'
import json
for package in ("shared", "agent", "control-plane"):
    pins = json.load(open(package + "/Package.resolved"))["pins"]
    version = next(p["state"]["version"] for p in pins if p["identity"] == "swift-protobuf")
    if version != "1.38.1":
        raise SystemExit(package + ": SwiftProtobuf runtime must match generator 1.38.1")
PY
"$buf_bin" format --diff --exit-code
"$buf_bin" lint
if [[ "$mode" == check ]]; then
    "$buf_bin" breaking --against shared/proto/baseline.binpb
fi
if [[ $# -ge 2 ]]; then
    "$buf_bin" breaking --against "$2"
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/strato-protocol.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
# Use buf.gen.yaml as the generation policy; override only executable and output.
# The template is deliberately validated so a new option cannot silently drift
# between the documented configuration and local/CI generation.
python3 - "$generator" "$scratch/template.json" <<'PY'
import json, sys
from pathlib import Path
expected = '''version: v2
plugins:
  - local: protoc-gen-swift
    out: shared/Sources/StratoShared/Generated
    opt:
      - Visibility=Public
      - FileNaming=PathToUnderscores
'''
if Path("buf.gen.yaml").read_text() != expected:
    raise SystemExit("Update agent-protocol.sh when changing buf.gen.yaml generation policy")
with open(sys.argv[2], "w") as output:
    json.dump({"version": "v2", "plugins": [{"local": sys.argv[1], "out": ".",
        "opt": ["Visibility=Public", "FileNaming=PathToUnderscores"]}]}, output)
PY

generate() {
    local input="$1" destination="$2" output="$scratch/output-$3"
    "$buf_bin" generate "$input" --template "$scratch/template.json" --output "$output"
    if [[ "$3" == workload ]]; then
        python3 scripts/generate-agent-protocol-validation.py "$output"
    fi
    if [[ "$mode" == generate ]]; then
        mkdir -p "$destination"
        cp "$output/"*.swift "$destination/"
    else
        diff -ru "$destination" "$output"
    fi
}
generate . shared/Sources/StratoShared/Generated workload
for peer in baseline next; do
    input="tests/agent-protocol-peers/$peer"
    "$buf_bin" format "$input" --diff --exit-code
    "$buf_bin" lint "$input"
    case "$peer" in baseline) target=BaselinePeer ;; next) target=NextPeer ;; esac
    generate "$input" "tests/agent-protocol-peers/Sources/$target" "$peer"
done
"$buf_bin" breaking tests/agent-protocol-peers/next --against tests/agent-protocol-peers/baseline
