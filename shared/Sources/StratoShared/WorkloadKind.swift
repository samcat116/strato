import Foundation

/// Which kind of workload a reconcile work item, manifest entry, or wire-level
/// teardown record refers to (issue #417). The reconciler engine — diff,
/// per-key serial lanes, generation guard, attempt cap, failure classification
/// — is shared across kinds; only the actuation differs: VM items route to
/// hypervisor drivers, sandbox items to the sandbox runtime.
///
/// Lives in the shared package because it is also a wire discriminator
/// (STR-98): `DesiredWorkloadTombstone` and `UnrecognizedWorkload` are
/// kind-tagged, so the control plane names the same kinds the agent does
/// rather than mapping between two vocabularies.
///
/// `Codable` because the on-disk workload manifest tags each entry with its
/// kind; manifests written before sandboxes existed have no kind and decode
/// as `.vm`.
public enum WorkloadKind: String, Codable, Hashable, CaseIterable, Sendable {
    case vm
    case sandbox
    /// A managed volume (STR-148). Unlike the other two kinds, nothing is ever
    /// written to `VMManifestStore` under this kind: a volume's durable record
    /// on the agent is its directory in the storage backend, which is also what
    /// the reconciler enumerates as its presence set. Attachment, the one piece
    /// of volume state the filesystem cannot answer, rides the *VM's* manifest
    /// entry (`VMSpec.volumes`), because that is what the spawn path reads.
    case volume
}
