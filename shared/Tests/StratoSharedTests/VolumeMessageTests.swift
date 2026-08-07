import Foundation
import Testing
import StratoShared

/// The imperative volume frames that survive ADR 0001 stage 5 (STR-148):
/// the two artifact verbs (stage 8) and the read (stage 7). Create, delete,
/// attach, detach, resize and clone are desired state now and have no messages
/// left to round-trip — `ReconciliationProtocolTests` pins their wire shape.
@Suite("Volume operation messages")
struct VolumeMessageTests {
    @Test func volumeSnapshotRoundTrip() throws {
        let decoded = try throughEnvelope(
            VolumeSnapshotMessage(
                requestId: Fixtures.requestId,
                timestamp: Fixtures.timestamp,
                volumeId: "vol-1",
                snapshotId: "snap-1",
                volumePath: "/var/lib/strato/vol-1.qcow2"
            )
        )
        #expect(decoded.type == .volumeSnapshot)
        #expect(decoded.snapshotId == "snap-1")
        // A detached volume (or older control plane) carries no VM to freeze.
        #expect(decoded.attachedVMId == nil)
    }

    /// A new control plane names the attached VM so the agent can fs-freeze its
    /// guest around the snapshot (issue #563).
    @Test func volumeSnapshotCarriesAttachedVMId() throws {
        let decoded = try throughEnvelope(
            VolumeSnapshotMessage(
                requestId: Fixtures.requestId,
                timestamp: Fixtures.timestamp,
                volumeId: "vol-1",
                snapshotId: "snap-1",
                volumePath: "/var/lib/strato/vol-1.qcow2",
                attachedVMId: "vm-42"
            )
        )
        #expect(decoded.attachedVMId == "vm-42")
    }

    @Test func volumeInfoRoundTrip() throws {
        let decoded = try throughEnvelope(
            VolumeInfoMessage(
                requestId: Fixtures.requestId, timestamp: Fixtures.timestamp, volumeId: "vol-1",
                volumePath: "/var/lib/strato/vol-1.qcow2")
        )
        #expect(decoded.type == .volumeInfo)
        #expect(decoded.volumeId == "vol-1")
    }

    @Test func volumeInfoResponseRoundTrip() throws {
        let decoded = try roundTrip(
            VolumeInfoResponse(
                volumeId: "vol-1", actualSize: 1_234_567, virtualSize: 10_737_418_240, format: "qcow2", dirty: true,
                encrypted: true)
        )
        #expect(decoded.volumeId == "vol-1")
        #expect(decoded.actualSize == 1_234_567)
        #expect(decoded.virtualSize == 10_737_418_240)
        #expect(decoded.format == "qcow2")
        #expect(decoded.dirty)
        #expect(decoded.encrypted)
    }

    @Test func volumeStatusResponseRoundTrip() throws {
        let decoded = try roundTrip(VolumeStatusResponse(volumeId: "vol-1", status: "creating", storagePath: nil))
        #expect(decoded.volumeId == "vol-1")
        #expect(decoded.status == "creating")
        #expect(decoded.storagePath == nil)
    }
}
