import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

/// STR-181: the control plane exposes a volume snapshot's live footprint, so the
/// agent reports the overlay's size *now* rather than only the empty file it was
/// at capture.
@Suite("Snapshot footprint (STR-181)")
struct SnapshotFootprintTests {

    private func facts(
        sizeBytes: Int64? = 197_120, storagePath: String? = "/volumes/snap.qcow2"
    ) -> ObservedSnapshotFacts {
        ObservedSnapshotFacts(
            sizeBytes: sizeBytes, storagePath: storagePath, architecture: .x86_64,
            qemuVersion: "9.1.0")
    }

    @Test("A volume snapshot reports a freshly measured footprint beside the captured one")
    func volumeSnapshotIsRemeasured() {
        let reported = SnapshotFootprint.reported(
            facts(), kind: .volumeSnapshot,
            measure: { path in
                #expect(path == "/volumes/snap.qcow2")
                return 512 << 20
            })

        #expect(reported?.currentSizeBytes == 512 << 20)
        // The capture-time figure is left exactly as recorded — the two answer
        // different questions.
        #expect(reported?.sizeBytes == 197_120)
        #expect(reported?.storagePath == "/volumes/snap.qcow2")
        #expect(reported?.qemuVersion == "9.1.0")
        #expect(reported?.architecture == .x86_64)
    }

    @Test("Artifacts that are finished when captured are reported verbatim")
    func otherFamiliesAreNotRemeasured() {
        for kind in [SnapshotArtifactKind.vmCheckpoint, .sandboxSnapshot] {
            let reported = SnapshotFootprint.reported(
                facts(), kind: kind,
                measure: { _ in
                    Issue.record("\(kind) must not be re-measured")
                    return 1
                })
            #expect(reported?.currentSizeBytes == nil, "\(kind)")
            #expect(reported?.sizeBytes == 197_120, "\(kind)")
        }
    }

    @Test("A snapshot with no path, or no facts yet, is left alone")
    func nothingToMeasureIsLeftAlone() {
        #expect(
            SnapshotFootprint.reported(
                facts(storagePath: nil), kind: .volumeSnapshot, measure: { _ in 1 }
            )?.currentSizeBytes == nil)
        #expect(SnapshotFootprint.reported(nil, kind: .volumeSnapshot, measure: { _ in 1 }) == nil)
    }

    @Test("A measurement that fails reports nil, never zero")
    func unmeasurableFootprintIsNil() {
        let reported = SnapshotFootprint.reported(
            facts(), kind: .volumeSnapshot, measure: { _ in nil })
        #expect(reported?.currentSizeBytes == nil)
    }

    @Test("allocatedBytes measures a real file and refuses a missing one")
    func allocatedBytesReadsTheFilesystem() throws {
        let directory = NSTemporaryDirectory() + "footprint-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let path = (directory as NSString).appendingPathComponent("overlay.qcow2")
        try Data(repeating: 0xAB, count: 128 * 1024).write(to: URL(fileURLWithPath: path))

        let measured = try #require(SnapshotFootprint.allocatedBytes(at: path))
        #expect(measured > 0)

        // Nil is "unknown", never "empty" — a file the agent cannot read must
        // not make the artifact free in the control plane's accounting.
        #expect(
            SnapshotFootprint.allocatedBytes(
                at: (directory as NSString).appendingPathComponent("absent.qcow2")) == nil)
    }
}
