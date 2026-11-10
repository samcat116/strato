#!/usr/bin/env bash
# CI and local entry point after installing the pinned tools.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
bash -n scripts/agent-protocol.sh scripts/check-agent-protocol.sh scripts/install-agent-protocol-tools.sh
swift format lint --strict --recursive tests/agent-protocol-peers/Package.swift tests/agent-protocol-peers/Sources
python3 scripts/tests/test_agent_protocol_accessors.py
bash scripts/agent-protocol.sh check
if [[ $# -gt 0 ]]; then
    base="$1"
    git rev-parse --verify "$base^{commit}" >/dev/null
    if git cat-file -e "$base:shared/proto/strato/agent/v1/workload.proto" 2>/dev/null; then
        "${STRATO_BUF:-buf}" breaking --against ".git#ref=$base"
    elif git cat-file -e "$base:shared/proto/baseline.binpb" 2>/dev/null; then
        echo 'Target branch contains a baseline but no workload schema; refusing to skip compatibility' >&2
        exit 1
    else
        echo 'Initial Protobuf cutover: target branch has no workload schema; frozen v1 baseline checked above.'
    fi
fi
swift run --package-path tests/agent-protocol-peers -j 4 CompatibilityProbe
swift test --package-path shared -j 4 --force-resolved-versions --filter 'AgentProtocolCompatibilityTests|AgentProtobuf'
