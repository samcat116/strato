# Generated SPIFFE API messages

The `*.pb.swift` files are generated from the protos under `proto/`. This
target owns the common SPIFFE Workload API and SPIRE API value types used by
both the control plane and agent. Consumer targets keep only their own
service-specific messages.

The SPIRE protos are vendored from `spiffe/spire-api-sdk` at commit
`b47aae818391451b49e329e05a8888276b493150`. `workload.proto` is vendored from
`spiffe/go-spiffe` with the local `swift_prefix` option retained.

Run `scripts/regen-spire-protos.sh` from anywhere in the repository after
updating a vendored proto. The script regenerates this shared target first,
then each service-specific consumer target using the shared proto directory
as an import path.
