import Foundation
import Testing
import StratoShared

/// The one imperative volume frame that survives ADR 0001 stages 5 and 8
/// (STR-148, STR-150): the read. Create, delete, attach, detach, resize, clone
/// and both snapshot verbs are desired state now and have no messages left to
/// round-trip — `ReconciliationProtocolTests` and `SnapshotReconciliationTests`
/// pin their wire shape.
@Suite("Volume operation messages")
struct VolumeMessageTests {
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
}
