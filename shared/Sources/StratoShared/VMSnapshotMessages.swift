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
// was true of the verb and false of the result, and wire v33 acts on the
// difference (ADR 0001 stage 8, STR-150): **"checkpoint C exists for VM V" is a
// durable artifact**, so `vm_checkpoint` and `vm_snapshot_delete` are gone and
// the checkpoint rides `DesiredStateMessage.snapshots` — captured footprint,
// QEMU version and device nodes coming back on the observed report instead of
// in a one-shot RPC reply that a dropped socket could lose.
//
// `vm_restore` followed at wire v34 (stage 9, STR-151), by the other route out
// of the same false dichotomy. Loading a captured RAM image back into a live
// QEMU process really *is* an edge rather than a state — "the VM should be at
// checkpoint C" is not something an agent can re-converge on, because the guest
// starts writing the moment it resumes — so it did not become a state by being
// re-described. It became one by being **counted**: `DesiredVMState.restore`
// carries a monotonic nonce and the checkpoint it names, the agent acts only
// when the nonce outranks the one it durably recorded, and a sync that is
// dropped, replayed or re-driven converges instead of rewinding a live guest
// twice. Nothing in this file is a message any more.

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
