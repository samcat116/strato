import Foundation

// MARK: - Full-VM checkpoint / restore messages (protocol version >= 22, issue #564)
//
// A checkpoint is RAM + device state + disk captured at one consistent point,
// which is a different primitive from the disk-only volume snapshot the
// storage layer already has. Like volume operations, the sandbox snapshot
// trio, and `vmReboot`, a checkpoint is an *action* rather than a state, so it
// cannot ride the level-triggered desired-state sync: each message below is a
// request/response pair over the agent WebSocket, correlated by `requestId`
// and answered with `success`/`error`, and forwarded across replicas by the
// same RPC channel the volume operations use.
//
// The mechanism is QEMU's `snapshot-save` / `snapshot-load` / `snapshot-delete`
// job trio, which writes the machine state into an *internal* snapshot of the
// VM's qcow2 disks. Nothing here names a file, therefore: the state lives
// inside disks the agent already owns, and the agent re-derives everything it
// needs from `vmId` + `snapshotId`.

/// Ask an agent to checkpoint a VM: capture guest RAM and device state into an
/// internal snapshot of its qcow2 disks, consistent with the disk contents at
/// that instant. The VM keeps running (QEMU pauses it only for the duration of
/// the save job) and the agent reports the captured footprint back in
/// `VMCheckpointStatusResponse`.
public struct VMCheckpointMessage: WebSocketMessage {
    public var type: MessageType { .vmCheckpoint }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let snapshotId: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        snapshotId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.snapshotId = snapshotId
    }
}

/// Ask an agent to restore a VM in place from one of its checkpoints: load the
/// captured RAM and device state back into the VM's QEMU process and resume.
/// Same VM, same identity — it keeps its ID, disks, NICs, and addresses.
///
/// The VM must exist on the agent (created, running, or stopped); a VM whose
/// QEMU process is gone is re-created by the desired-state sync first, which
/// is what makes "restore after an agent restart" work without any extra
/// message.
public struct VMRestoreMessage: WebSocketMessage {
    public var type: MessageType { .vmRestore }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let snapshotId: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        snapshotId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.snapshotId = snapshotId
    }
}

/// Ask an agent to delete a VM checkpoint from its disks. Carries only IDs:
/// the agent derives the snapshot tag from `snapshotId` exactly as it did at
/// creation, so deletion also cleans up a checkpoint whose create succeeded
/// agent-side but whose response was lost. Agent-side deletion is idempotent —
/// a tag that is already gone is a success, not an error.
public struct VMSnapshotDeleteMessage: WebSocketMessage {
    public var type: MessageType { .vmSnapshotDelete }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let snapshotId: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        snapshotId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.snapshotId = snapshotId
    }
}

/// The agent's report on a completed VM checkpoint, carried in the `success`
/// response payload.
///
/// `vmStateSizeBytes` is the machine state QEMU wrote (RAM + device state) —
/// the only footprint a checkpoint *adds*, since the disks it lives inside are
/// already charged as volume storage. The compatibility fields record what a
/// later restore must match: a QEMU internal snapshot is tied to the machine
/// shape and the QEMU build that captured it.
public struct VMCheckpointStatusResponse: Codable, Sendable {
    public let snapshotId: String
    /// Bytes of guest RAM + device state written into the vmstate disk, as
    /// QEMU reports it for the snapshot tag. Nil when the QEMU build did not
    /// report a size for the tag it just wrote — the checkpoint is still
    /// valid, so this is "unknown", never "empty".
    public let vmStateSizeBytes: Int64?
    /// The qcow2 block-node names the checkpoint spans, in the order they were
    /// snapshotted. Recorded for diagnostics: a restore re-derives the node
    /// list from the VM as it is *then*, since disks may have been hot-plugged
    /// since.
    public let deviceNodes: [String]
    /// `query-version` of the QEMU that took the checkpoint. A restore needs a
    /// compatible (in practice: identical) QEMU build and machine type.
    public let qemuVersion: String?
    /// Host CPU architecture the checkpoint was taken on.
    public let architecture: CPUArchitecture?

    public init(
        snapshotId: String,
        vmStateSizeBytes: Int64?,
        deviceNodes: [String],
        qemuVersion: String?,
        architecture: CPUArchitecture?
    ) {
        self.snapshotId = snapshotId
        self.vmStateSizeBytes = vmStateSizeBytes
        self.deviceNodes = deviceNodes
        self.qemuVersion = qemuVersion
        self.architecture = architecture
    }
}

// MARK: - Snapshot tags

/// How a control-plane snapshot id becomes a QEMU snapshot tag.
///
/// QEMU identifiers must start with a letter and contain only alphanumerics,
/// `-`, `.` and `_`; a bare UUID can start with a digit, so every tag and job
/// id carries a fixed prefix. The mapping is pure and total in both codebases
/// so a delete can re-derive the tag of a create whose response was lost.
public enum VMSnapshotTag {
    public static let prefix = "strato-"

    /// The qcow2 internal snapshot tag for a control-plane snapshot id.
    public static func tag(for snapshotId: String) -> String {
        prefix + snapshotId.lowercased()
    }
}
