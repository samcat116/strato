# Generated SPIFFE / SPIRE agent API code

The generated file and proto in this directory are the SPIRE agent's
**Delegated Identity API**, vendored unmodified from
[spiffe/spire-api-sdk](https://github.com/spiffe/spire-api-sdk) at commit
`b47aae818391451b49e329e05a8888276b493150`. It backs
`DelegatedIdentityClient.swift`, which fetches SVIDs minted for *other*
workloads (guest VMs and sandboxes) that the local SPIRE agent cannot attest
directly.

Common SPIRE value types and the Workload API live once in
`shared/Sources/SPIFFEKit/Generated`. `SPIFFEGeneratedAliases.swift` preserves
this module's public names for callers.

Only the protobuf *messages* are generated; the clients invoke the RPCs they
need (`FetchX509SVID`, `SubscribeToX509SVIDs`, `SubscribeToX509Bundles`) with
manual `MethodDescriptor`s, so no gRPC codegen plugin is required and CI needs
no protoc.

After updating the vendored protos, run
`scripts/regen-spire-protos.sh` from anywhere in the repository. It regenerates
the shared and consumer targets together.
