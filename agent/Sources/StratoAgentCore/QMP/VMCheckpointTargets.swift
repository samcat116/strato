import Foundation

/// Which block nodes a full-VM checkpoint writes to, and which it reads back
/// from (issue #564).
///
/// This is the whole decision procedure for a checkpoint, expressed as a pure
/// function of the VM's block topology: no QMP, no process, no filesystem. It
/// lives here rather than in `QEMUService` because the rules it encodes — what
/// disqualifies a VM, where machine state lands, how an existing checkpoint is
/// found again — are the part most worth testing, and `QEMUService` cannot be
/// exercised without a live QEMU.
public enum VMCheckpointTargets {

    /// The nodes one checkpoint spans.
    public struct Selection: Equatable, Sendable {
        /// The node the guest's RAM and device state are written into. Always
        /// also a member of `devices`.
        public let vmstate: String
        /// Every node snapshotted together, `vmstate` included.
        public let devices: [String]

        public init(vmstate: String, devices: [String]) {
            self.vmstate = vmstate
            self.devices = devices
        }
    }

    /// Why a VM cannot be checkpointed, or a checkpoint cannot be found.
    ///
    /// Deliberately says nothing about host paths: these strings reach the
    /// control plane and are stored on the snapshot row, readable by anyone
    /// with `read` on the VM. A node name identifies the disk just as well for
    /// whoever has to act on it, without publishing the agent's storage layout.
    public enum SelectionError: Error, LocalizedError, Equatable {
        /// One or more writable disks are in a format that cannot hold an
        /// internal snapshot.
        case unsupportedDiskFormats([String])
        /// Nothing writable to store machine state in.
        case noWritableSnapshotTarget
        /// No disk carries the requested checkpoint.
        case checkpointNotFound(tag: String)
        /// The checkpoint exists, but no disk holds its machine state — so
        /// there is nothing to restore, only disk contents.
        case checkpointHasNoMachineState(tag: String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedDiskFormats(let described):
                return
                    "every writable disk must be qcow2 to hold machine state, but these are not: "
                    + described.joined(separator: ", ")
            case .noWritableSnapshotTarget:
                return "no writable qcow2 disk is available to store machine state in"
            case .checkpointNotFound(let tag):
                return "no checkpoint '\(tag)' exists on any of this VM's disks"
            case .checkpointHasNoMachineState(let tag):
                return "checkpoint '\(tag)' carries no machine state; it cannot be restored"
            }
        }
    }

    /// The nodes a *new* checkpoint writes to.
    ///
    /// `nvramPath` — the VM's UEFI variable store — is excluded before anything
    /// else is decided. It is a raw pflash image, so it could not hold an
    /// internal snapshot in any case, but the exclusion is a decision and not a
    /// workaround: boot order and enrolled Secure Boot keys are firmware
    /// configuration, not guest run state, and a checkpoint that refused to
    /// exist because of them would rule out every UEFI VM — which is nearly all
    /// of them.
    ///
    /// Any *other* writable node that cannot hold an internal snapshot fails
    /// the whole checkpoint. Capturing the qcow2 disks and silently letting a
    /// raw volume run on would produce a restore whose memory and disks
    /// disagree, which is worse than no checkpoint at all.
    ///
    /// `bootDiskPath` decides where the machine state lands, and is the reason
    /// this takes an argument the block topology cannot supply. Any qcow2 disk
    /// *could* hold it, but a hot-plugged volume is the wrong one: its QMP
    /// backend is anonymous, so a positional rule picks it over the VM's own
    /// root disk, and then detaching the volume silently makes a `ready`
    /// checkpoint unrestorable while a volume clone quietly carries a copy of
    /// the guest's RAM. Machine state belongs on the disk that cannot outlive
    /// the VM. When the boot disk is unknown — a VM re-adopted from a previous
    /// agent incarnation, whose spawn configuration this process never saw —
    /// the lowest-sorting candidate is used so the choice is at least
    /// deterministic.
    public static func forCapture(
        nodes: [QMPBlockNode],
        nvramPath: String?,
        bootDiskPath: String?
    ) throws -> Selection {
        let candidates = nodes.filter { !$0.readonly && ($0.filename == nil || $0.filename != nvramPath) }

        let unsupported = candidates.filter { !$0.supportsInternalSnapshots }
        guard unsupported.isEmpty else {
            let described =
                unsupported
                .map {
                    "\($0.device.flatMap { $0.isEmpty ? nil : $0 } ?? $0.nodeName) (\($0.format ?? "unknown format"))"
                }
                .sorted()
            throw SelectionError.unsupportedDiskFormats(described)
        }
        guard !candidates.isEmpty else {
            throw SelectionError.noWritableSnapshotTarget
        }

        // Deterministic fallback order, used only when the boot disk is
        // unknown; `devices` is reported in it either way so a checkpoint's
        // node list reads the same across attempts.
        let ordered = candidates.sorted {
            ($0.device ?? "", $0.nodeName) < ($1.device ?? "", $1.nodeName)
        }
        let vmstate =
            bootDiskPath.flatMap { path in ordered.first { $0.filename == path } } ?? ordered[0]
        return Selection(vmstate: vmstate.nodeName, devices: ordered.map(\.nodeName))
    }

    /// The nodes an *existing* checkpoint lives on, found by the tag itself
    /// rather than re-derived.
    ///
    /// Restore cannot reuse `forCapture`'s choice: a disk hot-plugged since the
    /// checkpoint would change which candidates exist, and loading machine
    /// state from a node that does not carry it fails obscurely. The tag is the
    /// authority — the vmstate node is the one whose copy of the tag has
    /// machine state attached, and the disk-only participants carry the same
    /// tag with a zero size.
    public static func forTag(nodes: [QMPBlockNode], tag: String) throws -> Selection {
        let carrying = nodes.filter { $0.hasSnapshot(named: tag) }
        guard !carrying.isEmpty else {
            throw SelectionError.checkpointNotFound(tag: tag)
        }
        guard let vmstate = carrying.first(where: { ($0.snapshotVMStateSize(named: tag) ?? 0) > 0 }) else {
            throw SelectionError.checkpointHasNoMachineState(tag: tag)
        }
        return Selection(vmstate: vmstate.nodeName, devices: carrying.map(\.nodeName))
    }
}
