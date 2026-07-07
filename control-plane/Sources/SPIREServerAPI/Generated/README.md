# Generated SPIRE Server API code

The `*.pb.swift` files are generated from the protos under `proto/`, vendored
unmodified from [spiffe/spire-api-sdk](https://github.com/spiffe/spire-api-sdk)
(commit `b47aae818391451b49e329e05a8888276b493150`): the `Agent` and `Entry`
server services plus the `spire/api/types` messages they reference.

Only the protobuf *messages* are generated; `SPIREServerAPIClient` invokes the
RPCs it needs (`CreateJoinToken`, `BatchCreateEntry`, `ListEntries`,
`BatchDeleteEntry`) with manual `MethodDescriptor`s, so no gRPC codegen plugin
is required and CI needs no protoc.

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
