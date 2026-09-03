# Generated SPIRE Server API code

The `*.pb.swift` files are generated from the service-specific protos under
`proto/`, vendored unmodified from [spiffe/spire-api-sdk](https://github.com/spiffe/spire-api-sdk)
(commit `b47aae818391451b49e329e05a8888276b493150`): the `Agent`, `Entry`,
`TrustDomain`, `Bundle`, and `SVID` server services plus the `spire/api/types`
messages they reference (including `federationrelationship` and `bundle`).
Common SPIRE value types and the Workload API live once in
`shared/Sources/SPIFFEKit/Generated`; public aliases preserve this module's
existing API.

`svid.proto` is vendored whole rather than trimmed to `MintJWTSVID`, so
`jwtsvid` and `witsvid` come with it. `witsvid.pb.swift` has no caller — it
exists because `MintWITSVIDResponse` names the type, and dropping it would mean
editing a vendored proto and having to re-edit it on every bump.

Only the protobuf *messages* are generated; `SPIREServerAPIClient` invokes the
RPCs it needs (`CreateJoinToken`, `BatchCreateEntry`, `BatchUpdateEntry`,
`ListEntries`, `BatchDeleteEntry`, `ListAgents`, `GetBundle`,
`ListFederationRelationships`, `BatchCreate/Update/DeleteFederationRelationship`,
`MintJWTSVID`, and the Workload API's `FetchX509SVID`) with manual
`MethodDescriptor`s, so no
gRPC codegen plugin is required and CI needs no protoc.

After updating the vendored protos, run
`scripts/regen-spire-protos.sh` from anywhere in the repository. It regenerates
the shared and consumer targets together.
