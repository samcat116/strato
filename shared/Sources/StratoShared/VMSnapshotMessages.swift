import Foundation

// MARK: - Full-VM checkpoint / restore (protocol version >= 22, issue #564)
//
// A checkpoint is RAM + device state + disk captured at one consistent point,
// which is a different primitive from the disk-only volume snapshot the storage
// layer already has. The mechanism is QEMU's `snapshot-save` / `snapshot-load` /
// `snapshot-delete` job trio, which writes the machine state into an *internal*
// snapshot of the VM's qcow2 disks. Nothing here names a file, therefore: the
// state lives inside disks the agent already owns, and the agent re-derives
// everything it needs from `vmId` + `snapshotId`.
//
// This file used to open by asserting that a checkpoint "is an *action* rather
// than a state, so it cannot ride the level-triggered desired-state sync". That
// was true of the verb and false of the result, and wire v32 acts on the
// difference (ADR 0001 stage 8, STR-150): **"checkpoint C exists for VM V" is a
// durable artifact**, so `vm_checkpoint` and `vm_snapshot_delete` are gone and
// the checkpoint rides `DesiredStateMessage.snapshots` — captured footprint,
// QEMU version and device nodes coming back on the observed report instead of
// in a one-shot RPC reply that a dropped socket could lose.
//
// `vm_restore` stays imperative for now. Loading a captured RAM image back into
// a live QEMU process really is an edge rather than a state — "the VM should be
// at checkpoint C" is not something an agent can re-converge on, because the
// guest starts writing the moment it resumes. STR-151 converts it to a
// monotonic nonce on the desired entry, which is the shape edges take.

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

// MARK: - Snapshot tags

/// How a control-plane snapshot id becomes a QEMU snapshot tag.
///
/// QEMU identifiers must start with a letter and contain only alphanumerics,
/// `-`, `.` and `_`; a bare UUID can start with a digit, so every tag and job
/// id carries a fixed prefix. The mapping is pure and total in both codebases,
/// which is what lets the agent *enumerate* its checkpoints — read the tags off
/// a VM's disks, map each back to a snapshot id — and so answer the observed
/// report without a side manifest. It is also why a delete needs no path: the
/// tag of a capture whose report was lost is re-derivable from the id alone.
public enum VMSnapshotTag {
    public static let prefix = "strato-"

    /// The qcow2 internal snapshot tag for a control-plane snapshot id.
    public static func tag(for snapshotId: String) -> String {
        prefix + snapshotId.lowercased()
    }

    /// The control-plane snapshot id a tag was minted from, or nil for a tag
    /// this platform did not write. The inverse of `tag(for:)`, so the agent
    /// can turn a disk's tag list into desired-state identities and leave
    /// anyone else's internal snapshots alone.
    public static func snapshotId(fromTag tag: String) -> UUID? {
        guard tag.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(tag.dropFirst(prefix.count)))
    }
}
