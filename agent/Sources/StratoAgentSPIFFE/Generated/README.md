# Generated SPIFFE / SPIRE agent API code

The `*.pb.swift` files are generated from the protos under `proto/`.

`proto/workload.proto` is the SPIFFE Workload API, vendored from
[spiffe/go-spiffe](https://github.com/spiffe/go-spiffe/blob/main/proto/spiffe/workload/workload.proto)
with a local `swift_prefix` option added so generated types don't collide with
the hand-written SPIFFE types in this module. It backs
`WorkloadAPIClient.swift`, which fetches *this process's own* SVID.

`proto/spire/**` is the SPIRE agent's **Delegated Identity API** plus the
`spire.api.types` messages it references, vendored unmodified from
[spiffe/spire-api-sdk](https://github.com/spiffe/spire-api-sdk) at commit
`b47aae818391451b49e329e05a8888276b493150` — the same commit recorded in
`control-plane/Sources/SPIREServerAPI/Generated/README.md`. It backs
`DelegatedIdentityClient.swift`, which fetches SVIDs minted for *other*
workloads (guest VMs and sandboxes) that the local SPIRE agent cannot attest
directly.

`spire/api/types/{selector,spiffeid,x509svid}.proto` are byte-identical copies
of the control plane's vendored versions. **Keep the two trees in lockstep**:
if one is re-vendored at a newer SDK commit, the other must move with it, or
the two packages will disagree about the wire format of the same SPIRE API.

Only the protobuf *messages* are generated; the clients invoke the RPCs they
need (`FetchX509SVID`, `SubscribeToX509SVIDs`, `SubscribeToX509Bundles`) with
manual `MethodDescriptor`s, so no gRPC codegen plugin is required and CI needs
no protoc.

To regenerate after updating the vendored protos:

```sh
# Build the generator once from the resolved SwiftPM checkout
swift build -c release --product protoc-gen-swift \
  --package-path agent/.build/checkouts/swift-protobuf

cd agent/Sources/StratoAgentSPIFFE/Generated
protoc -I proto \
  --plugin=protoc-gen-swift=../../../.build/checkouts/swift-protobuf/.build/release/protoc-gen-swift \
  --swift_out=. --swift_opt=Visibility=Public --swift_opt=FileNaming=PathToUnderscores \
  $(cd proto && find . -name '*.proto' | sed 's|^\./||')
```

`workload.proto` imports `google/protobuf/struct.proto`, so protoc must be able
to resolve the well-known types. Most protoc distributions ship them next to the
binary; on distros that split them out (Amazon Linux, Debian) install the
matching `protobuf-devel` / `libprotobuf-dev` package first.
