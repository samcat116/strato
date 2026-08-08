import Foundation
import StratoShared

/// Re-measuring the one artifact family whose bytes keep growing after capture
/// (STR-181).
///
/// `SnapshotRecordStore` holds what the agent measured *at* capture, and for a
/// VM checkpoint or a sandbox snapshot that is the final answer — the artifact is
/// finished when it is written. A volume snapshot is not: it is an external
/// qcow2 overlay, stat'd the instant `qemu-img create` returns, so the recorded
/// `sizeBytes` is an empty file's header and stays there however far the volume
/// diverges. The control plane's storage quota charges these now, so the number
/// it charges has to be re-read on every report.
///
/// This is deliberately not folded back into the record: that file is the
/// durable memory of the capture, and rewriting it per heartbeat would put a
/// file write on the heartbeat path.
public enum SnapshotFootprint {

    /// How much of the filesystem a file actually occupies, or nil when it
    /// cannot be read.
    ///
    /// Allocated blocks rather than `st_size`, because the number this feeds is
    /// a storage quota and what fills a hypervisor's disk is allocation — a
    /// qcow2 overlay is written sparsely, so its apparent size runs ahead of
    /// what it costs. Falls back to the apparent size on a filesystem that does
    /// not report allocation, which is still a better answer than nil.
    ///
    /// Nil is "unknown", never "empty": a footprint the agent could not measure
    /// must not silently become a free one in the control plane's accounting.
    public static func allocatedBytes(at path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
            let allocated = values.totalFileAllocatedSize
        {
            return Int64(allocated)
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }

    /// The facts to report for one artifact: the recorded ones, plus a freshly
    /// measured `currentSizeBytes` when the family is one that keeps growing.
    ///
    /// Every other kind gets nil, which the control plane reads as "this agent
    /// does not re-measure this" and answers by leaving its own figure alone.
    public static func reported(
        _ facts: ObservedSnapshotFacts?, kind: SnapshotArtifactKind,
        measure: (String) -> Int64? = allocatedBytes(at:)
    ) -> ObservedSnapshotFacts? {
        guard kind == .volumeSnapshot, let facts, let path = facts.storagePath else { return facts }
        return ObservedSnapshotFacts(
            sizeBytes: facts.sizeBytes,
            currentSizeBytes: measure(path),
            storagePath: facts.storagePath,
            architecture: facts.architecture,
            deviceNodes: facts.deviceNodes,
            qemuVersion: facts.qemuVersion,
            memorySizeBytes: facts.memorySizeBytes,
            vmstateSizeBytes: facts.vmstateSizeBytes,
            rootfsSizeBytes: facts.rootfsSizeBytes,
            firecrackerVersion: facts.firecrackerVersion,
            guestControlProtocolVersion: facts.guestControlProtocolVersion,
            forkLayoutVersion: facts.forkLayoutVersion,
            cpuTemplate: facts.cpuTemplate)
    }
}
