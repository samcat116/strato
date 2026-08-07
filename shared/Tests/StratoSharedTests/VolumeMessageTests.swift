import Foundation
import Testing
import StratoShared

/// The imperative volume frames that survive ADR 0001 stage 5 (STR-148): the
/// two artifact verbs (stage 8). Create, delete, attach, detach, resize and
/// clone are desired state now and have no messages left to round-trip —
/// `ReconciliationProtocolTests` pins their wire shape — and the `volume_info`
/// read left the protocol in stage 7 (STR-149) without a replacement frame.
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

    // `volume_info` no longer has a message to round-trip (wire v32, STR-149).
    // Its wire string is pinned as retired alongside every other removed one in
    // `MessageTypeTests.retiredWireStrings`, rather than here.

    @Test func volumeStatusResponseRoundTrip() throws {
        let decoded = try roundTrip(VolumeStatusResponse(volumeId: "vol-1", status: "creating", storagePath: nil))
        #expect(decoded.volumeId == "vol-1")
        #expect(decoded.status == "creating")
        #expect(decoded.storagePath == nil)
    }
}
