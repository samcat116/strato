import Foundation

/// The lifecycle mutations that run asynchronously against an agent (issue #259).
/// Each API mutation records exactly one operation of one of these kinds; the raw
/// values are the wire vocabulary shared with the frontend's operation polling.
public enum VMOperationKind: String, Codable, CaseIterable, Sendable {
    case create
    case boot
    case shutdown
    case reboot
    case pause
    case resume
    case delete
    /// Online vCPU/memory resize of a running VM (issue #568). Completed by
    /// the agent's observed-state report, like the other desired-state
    /// mutations; resizing a stopped VM records no operation at all.
    case resize
    // Sandbox checkpoint/restore (issue #426). Snapshot deletion gets its own
    // kind so a failed cleanup is distinguishable from a failed delete of the
    // sandbox itself.
    case snapshot
    case snapshotDelete = "snapshot_delete"
    case restore
    /// Off-node export of a sandbox snapshot's artifacts to control-plane
    /// object storage (issue #428).
    case snapshotExport = "snapshot_export"
}

/// Terminal-or-not state of an asynchronous VM operation. `pending` is the only
/// non-terminal state: clients poll until they see anything else.
public enum VMOperationStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case succeeded
    case failed

    public var isTerminal: Bool {
        self != .pending
    }
}
