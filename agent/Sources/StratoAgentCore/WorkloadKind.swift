import Foundation

/// Which kind of workload a reconcile work item or manifest entry refers to
/// (issue #417). The reconciler engine — diff, per-key serial lanes, generation
/// guard, attempt cap, failure classification — is shared across kinds; only
/// the actuation differs: VM items route to hypervisor drivers, sandbox items
/// to the sandbox runtime.
///
/// `Codable` because the on-disk workload manifest tags each entry with its
/// kind; manifests written before sandboxes existed have no kind and decode
/// as `.vm`.
public enum WorkloadKind: String, Codable, Hashable, Sendable {
    case vm
    case sandbox
}
