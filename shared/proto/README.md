# Agent workload protocol

The schemas in `strato/agent/v1` define the agent/control-plane workload contract.
Generated Swift messages are checked in under `shared/Sources/StratoShared/Generated`.
Ordinary Swift builds require neither Buf nor a code-generation step.

## Reproduce the contract checks

```sh
bash scripts/install-agent-protocol-tools.sh
source .build/agent-protocol-tools/env.sh
bash scripts/agent-protocol.sh generate
bash scripts/check-agent-protocol.sh origin/main
```

The installer uses task-local storage, pinned checksums for Buf 1.73.0, and the
pinned SwiftProtobuf 1.38.1 source revision. `STRATO_BUF` and
`STRATO_PROTOC_GEN_SWIFT` can select existing exact-version tools. Generation
happens in a temporary directory; check mode compares without modifying sources.

`baseline.binpb` is the frozen initial v1 descriptor, not generated output to
refresh on each feature PR. The check compares against it and, when requested,
the target Git revision. Adding fields does not require bumping the major.
Reserved names/numbers cannot be reused. New required behavior needs a capability
and runtime tests even if Buf reports no structural break.

The independent `tests/agent-protocol-peers` modules demonstrate additive evolution,
unknown-field preservation, exact binary stream data, UInt64 precision, and
absence-versus-empty collections. They do not replace the agent/control-plane
integration and lifecycle tests.

Preserve existing public, guest, browser, and stored JSON formats through explicit
codecs. Do not substitute ProtoJSON for those formats or hash arbitrary binary
serialization as a canonical ETag.
