# Generated SPIRE Server API code

The `*.pb.swift` files are generated from the protos under `proto/`, vendored
unmodified from [spiffe/spire-api-sdk](https://github.com/spiffe/spire-api-sdk)
(commit `b47aae818391451b49e329e05a8888276b493150`): the `Agent`, `Entry`,
`TrustDomain`, `Bundle`, and `SVID` server services plus the `spire/api/types`
messages they reference (including `federationrelationship` and `bundle`).

`svid.proto` is vendored whole rather than trimmed to `MintJWTSVID`, so
`jwtsvid` and `witsvid` come with it. `witsvid.pb.swift` has no caller — it
exists because `MintWITSVIDResponse` names the type, and dropping it would mean
editing a vendored proto and having to re-edit it on every bump.

`proto/workload.proto` and `workload.pb.swift` are the SPIFFE Workload API,
mirrored from `agent/Sources/StratoAgentSPIFFE/Generated` (originally vendored
from [spiffe/go-spiffe](https://github.com/spiffe/go-spiffe/blob/main/proto/spiffe/workload/workload.proto)
with a local `swift_prefix` option). The control plane uses it to fetch its own
SVID for the mTLS path to the SPIRE server's admin API.

Only the protobuf *messages* are generated; `SPIREServerAPIClient` invokes the
RPCs it needs (`CreateJoinToken`, `BatchCreateEntry`, `BatchUpdateEntry`,
`ListEntries`, `BatchDeleteEntry`, `ListAgents`, `GetBundle`,
`ListFederationRelationships`, `BatchCreate/Update/DeleteFederationRelationship`,
`MintJWTSVID`, and the Workload API's `FetchX509SVID`) with manual
`MethodDescriptor`s, so no
gRPC codegen plugin is required and CI needs no protoc.

To regenerate after updating the vendored protos:

```sh
# Build the generator once from the resolved SwiftPM checkout
swift build -c release --product protoc-gen-swift \
  --package-path control-plane/.build/checkouts/swift-protobuf

cd control-plane/Sources/SPIREServerAPI/Generated
protoc -I proto \
  --plugin=protoc-gen-swift=../../../.build/checkouts/swift-protobuf/.build/release/protoc-gen-swift \
  --swift_out=. --swift_opt=Visibility=Public --swift_opt=FileNaming=PathToUnderscores \
  $(cd proto && find . -name '*.proto' | sed 's|^\./||')
```
