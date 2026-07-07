# Generated SPIFFE Workload API code

`workload.pb.swift` is generated from `workload.proto` (vendored from
[spiffe/go-spiffe](https://github.com/spiffe/go-spiffe/blob/main/proto/spiffe/workload/workload.proto),
with a local `swift_prefix` option added so generated types don't collide with
the hand-written SPIFFE types in this module).

Only the protobuf *messages* are generated; the client invokes the RPCs with
manual `MethodDescriptor`s (see `WorkloadAPIClient.swift`), so no gRPC codegen
plugin is required.

To regenerate after updating `workload.proto`:

```sh
# Build the generator once from the resolved SwiftPM checkout
swift build -c release --product protoc-gen-swift \
  --package-path agent/.build/checkouts/swift-protobuf

cd agent/Sources/StratoAgentSPIFFE/Generated
protoc \
  --plugin=protoc-gen-swift=../../../../.build/checkouts/swift-protobuf/.build/release/protoc-gen-swift \
  --swift_out=. --swift_opt=Visibility=Public workload.proto
```
