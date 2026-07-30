import Foundation
import Testing

@testable import StratoShared

@Suite("VM checkpoint messages (issue #564)")
struct VMSnapshotMessageTests {
    @Test("checkpoint request survives the envelope")
    func checkpointRoundTrips() throws {
        let message = VMCheckpointMessage(
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            vmId: Fixtures.uuidA.uuidString,
            snapshotId: Fixtures.uuidB.uuidString)

        let decoded = try throughEnvelope(message)
        #expect(decoded.type == .vmCheckpoint)
        #expect(decoded.vmId == Fixtures.uuidA.uuidString)
        #expect(decoded.snapshotId == Fixtures.uuidB.uuidString)
        #expect(decoded.timestamp == Fixtures.timestamp)
    }

    @Test("restore request survives the envelope")
    func restoreRoundTrips() throws {
        let message = VMRestoreMessage(
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            vmId: Fixtures.uuidA.uuidString,
            snapshotId: Fixtures.uuidB.uuidString)

        let decoded = try throughEnvelope(message)
        #expect(decoded.type == .vmRestore)
        #expect(decoded.snapshotId == Fixtures.uuidB.uuidString)
    }

    @Test("delete request carries only ids")
    func deleteCarriesOnlyIDs() throws {
        let message = VMSnapshotDeleteMessage(
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            vmId: Fixtures.uuidA.uuidString,
            snapshotId: Fixtures.uuidB.uuidString)

        // No path on the wire: the agent re-derives the tag, so a delete works
        // even when the create's success response was lost.
        let keys = try encodedKeys(message)
        #expect(keys == ["requestId", "timestamp", "vmId", "snapshotId"])
        #expect(try throughEnvelope(message).type == .vmSnapshotDelete)
    }

    @Test("status report round-trips, including an unknown vmstate size")
    func statusReportRoundTrips() throws {
        let report = VMCheckpointStatusResponse(
            snapshotId: Fixtures.uuidB.uuidString,
            vmStateSizeBytes: 2_147_483_648,
            deviceNodes: ["strato-disk0", "strato-disk1"],
            qemuVersion: "9.1.0",
            architecture: .x86_64)

        let decoded = try roundTrip(report)
        #expect(decoded.vmStateSizeBytes == 2_147_483_648)
        #expect(decoded.deviceNodes == ["strato-disk0", "strato-disk1"])
        #expect(decoded.qemuVersion == "9.1.0")
        #expect(decoded.architecture == .x86_64)

        // A QEMU build that reported no size for the tag it just wrote leaves
        // the field nil — "unknown", never "empty".
        let sizeless = VMCheckpointStatusResponse(
            snapshotId: Fixtures.uuidB.uuidString,
            vmStateSizeBytes: nil,
            deviceNodes: ["strato-disk0"],
            qemuVersion: nil,
            architecture: nil)
        let decodedSizeless = try roundTrip(sizeless)
        #expect(decodedSizeless.vmStateSizeBytes == nil)
        #expect(decodedSizeless.qemuVersion == nil)
        #expect(decodedSizeless.architecture == nil)
    }

    @Test("snapshot tags are valid QEMU identifiers derived from the id")
    func tagDerivation() {
        let tag = VMSnapshotTag.tag(for: "AAAAAAAA-1111-2222-3333-444444444444")
        // A bare UUID may start with a digit, which QEMU rejects as an
        // identifier; the fixed prefix makes every tag legal.
        #expect(tag == "strato-aaaaaaaa-1111-2222-3333-444444444444")
        #expect(tag.first?.isLetter == true)
        #expect(tag.allSatisfy { $0.isLetter || $0.isNumber || "-._".contains($0) })
        // Total and pure: a delete re-derives exactly what the create wrote.
        #expect(VMSnapshotTag.tag(for: "aaaaaaaa-1111-2222-3333-444444444444") == tag)
    }
}
