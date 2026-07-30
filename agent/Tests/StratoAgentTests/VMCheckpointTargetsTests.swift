import Foundation
import Testing

@testable import StratoAgentCore

/// The checkpoint selection rules (issue #564): which disks a checkpoint spans,
/// which VM it refuses outright, and where the machine state lands. Pure over a
/// block topology, so every case is reachable without a live QEMU.
@Suite("VM checkpoint targets")
struct VMCheckpointTargetsTests {

    private static let nvram = "/vms/vm-1/nvram.fd"

    private static func node(
        device: String?,
        nodeName: String,
        format: String? = "qcow2",
        filename: String? = nil,
        readonly: Bool = false,
        snapshots: [QMPSnapshotInfo] = []
    ) -> QMPBlockNode {
        QMPBlockNode(
            device: device, nodeName: nodeName, format: format,
            filename: filename ?? "/vms/vm-1/\(nodeName).qcow2",
            readonly: readonly, snapshots: snapshots)
    }

    /// A UEFI VM with a cloud-init seed and one hot-plugged volume — the
    /// topology every interesting rule turns on. The volume's backend is
    /// anonymous (`blockdev-add` + `device_add` name no BlockBackend), which is
    /// what makes naive ordering pick it.
    private static func realisticTopology(tag: String? = nil, vmStateOn: String? = nil) -> [QMPBlockNode] {
        func snapshots(_ nodeName: String) -> [QMPSnapshotInfo] {
            guard let tag else { return [] }
            return [
                QMPSnapshotInfo(
                    id: "1", name: tag, vmStateSize: nodeName == vmStateOn ? 2_147_483_648 : 0)
            ]
        }
        return [
            Self.node(
                device: "drive0", nodeName: "#block100", filename: "/vms/vm-1/disk.qcow2",
                snapshots: snapshots("#block100")),
            Self.node(
                device: "", nodeName: "drive-vdb", filename: "/pool/volumes/vol-7.qcow2",
                snapshots: snapshots("drive-vdb")),
            Self.node(
                device: "drive2", nodeName: "#block300", format: "raw",
                filename: "/vms/vm-1/seed.iso", readonly: true),
            Self.node(
                device: "pflash1", nodeName: "#block400", format: "raw", filename: nvram),
        ]
    }

    // MARK: - Capture

    @Test("machine state goes on the boot disk, not the hot-plugged volume")
    func machineStateLandsOnBootDisk() throws {
        let selection = try VMCheckpointTargets.forCapture(
            nodes: Self.realisticTopology(), nvramPath: Self.nvram,
            bootDiskPath: "/vms/vm-1/disk.qcow2")

        // The volume's anonymous backend sorts first, so a positional rule
        // would put the guest's RAM inside a disk that can be detached — which
        // silently makes a `ready` checkpoint unrestorable and makes a volume
        // clone carry a copy of the guest's memory.
        #expect(selection.vmstate == "#block100")
        #expect(selection.devices.sorted() == ["#block100", "drive-vdb"])
    }

    @Test("an unknown boot disk falls back to deterministic placement")
    func unknownBootDiskIsDeterministic() throws {
        // A VM re-adopted from a previous agent incarnation has no stored spawn
        // configuration. The choice is then arbitrary, but it must at least be
        // the same on every call.
        let first = try VMCheckpointTargets.forCapture(
            nodes: Self.realisticTopology(), nvramPath: Self.nvram, bootDiskPath: nil)
        let second = try VMCheckpointTargets.forCapture(
            nodes: Self.realisticTopology().reversed(), nvramPath: Self.nvram, bootDiskPath: nil)
        #expect(first == second)
    }

    @Test("the UEFI variable store is excluded, not a reason to refuse")
    func nvramIsExcluded() throws {
        let selection = try VMCheckpointTargets.forCapture(
            nodes: Self.realisticTopology(), nvramPath: Self.nvram,
            bootDiskPath: "/vms/vm-1/disk.qcow2")
        // Writable and raw, so an inclusive rule would fail every UEFI VM.
        #expect(!selection.devices.contains("#block400"))
    }

    @Test("a read-only raw disk is excluded, not a reason to refuse")
    func readOnlyRawIsExcluded() throws {
        let selection = try VMCheckpointTargets.forCapture(
            nodes: Self.realisticTopology(), nvramPath: Self.nvram,
            bootDiskPath: "/vms/vm-1/disk.qcow2")
        #expect(!selection.devices.contains("#block300"))
    }

    @Test("one writable raw disk refuses the whole checkpoint")
    func writableRawRefusesEverything() throws {
        var nodes = Self.realisticTopology()
        nodes.append(Self.node(device: "drive9", nodeName: "#block900", format: "raw"))

        // Capturing the qcow2 disks while this one ran on would restore to a
        // machine whose memory and disks disagree.
        #expect(throws: VMCheckpointTargets.SelectionError.self) {
            try VMCheckpointTargets.forCapture(
                nodes: nodes, nvramPath: Self.nvram, bootDiskPath: "/vms/vm-1/disk.qcow2")
        }
    }

    @Test("the refusal names disks by device, never by host path")
    func refusalDoesNotLeakHostPaths() {
        let nodes = [
            Self.node(
                device: "drive9", nodeName: "#block900", format: "raw",
                filename: "/srv/agent-internal/secret-layout/vol.img")
        ]
        do {
            _ = try VMCheckpointTargets.forCapture(
                nodes: nodes, nvramPath: Self.nvram, bootDiskPath: nil)
            Issue.record("expected a refusal")
        } catch {
            // The message reaches the snapshot row, readable by any project
            // member; the agent's storage layout is not theirs to see.
            let message = error.localizedDescription
            #expect(message.contains("drive9"))
            #expect(!message.contains("/srv/agent-internal"))
        }
    }

    @Test("an anonymous backend still identifies itself in a refusal")
    func refusalNamesAnonymousBackendByNode() {
        let nodes = [Self.node(device: "", nodeName: "drive-vdb", format: "raw")]
        do {
            _ = try VMCheckpointTargets.forCapture(
                nodes: nodes, nvramPath: Self.nvram, bootDiskPath: nil)
            Issue.record("expected a refusal")
        } catch {
            // An empty BlockBackend name identifies nothing, so the node name
            // has to stand in.
            #expect(error.localizedDescription.contains("drive-vdb"))
        }
    }

    @Test("a VM with nothing writable but its variable store is refused")
    func noWritableTargetIsRefused() {
        let nodes = [
            Self.node(device: "drive0", nodeName: "#block100", format: "raw", readonly: true),
            Self.node(device: "pflash1", nodeName: "#block400", format: "raw", filename: Self.nvram),
        ]
        #expect(throws: VMCheckpointTargets.SelectionError.noWritableSnapshotTarget) {
            try VMCheckpointTargets.forCapture(
                nodes: nodes, nvramPath: Self.nvram, bootDiskPath: nil)
        }
    }

    @Test("a VM with no variable store is unaffected by the exclusion")
    func absentNvramPathExcludesNothing() throws {
        let nodes = [Self.node(device: "drive0", nodeName: "#block100")]
        let selection = try VMCheckpointTargets.forCapture(
            nodes: nodes, nvramPath: nil, bootDiskPath: nil)
        #expect(selection.devices == ["#block100"])
    }

    // MARK: - Restore

    @Test("an existing checkpoint is found by its tag, wherever the state sits")
    func tagLookupFindsMachineState() throws {
        // Deliberately the disk the *capture* rule would not have chosen: a
        // checkpoint taken before the boot-disk rule, or on a re-adopted VM,
        // must still restore.
        let selection = try VMCheckpointTargets.forTag(
            nodes: Self.realisticTopology(tag: "strato-abc", vmStateOn: "drive-vdb"),
            tag: "strato-abc")
        #expect(selection.vmstate == "drive-vdb")
        #expect(selection.devices.sorted() == ["#block100", "drive-vdb"])
    }

    @Test("a tag no disk carries is not found")
    func missingTagIsNotFound() {
        #expect(
            throws: VMCheckpointTargets.SelectionError.checkpointNotFound(tag: "strato-nope")
        ) {
            try VMCheckpointTargets.forTag(
                nodes: Self.realisticTopology(tag: "strato-abc", vmStateOn: "#block100"),
                tag: "strato-nope")
        }
    }

    @Test("a tag present on the disks but holding no machine state cannot restore")
    func tagWithoutMachineStateCannotRestore() {
        // Every participant reports a zero size — the disk half of a checkpoint
        // whose machine state is gone. Loading it would fail obscurely inside
        // QEMU; refusing says what is actually wrong.
        #expect(
            throws: VMCheckpointTargets.SelectionError.checkpointHasNoMachineState(tag: "strato-abc")
        ) {
            try VMCheckpointTargets.forTag(
                nodes: Self.realisticTopology(tag: "strato-abc", vmStateOn: nil),
                tag: "strato-abc")
        }
    }
}
