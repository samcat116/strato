import Foundation
import Testing

@testable import StratoAgentCore

/// STR-129: hot-plug used to name the QMP device after the volume's *device
/// name*, so detach resolved a disk by a string the control plane had never
/// constrained. Two volumes holding one `disk1` meant `device_del` could unplug
/// the wrong one — a live disk pulled out from under a running guest.
@Suite("QEMU Disk Identity")
struct QEMUDiskIdentityTests {

    @Test("The device id is derived from the volume id, so it is unique by construction")
    func deviceIDIsDerivedFromTheVolumeID() {
        let first = UUID(uuidString: "A1B2C3D4-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "A1B2C3D4-0000-0000-0000-000000000002")!

        #expect(
            QEMUDiskIdentity.deviceID(volumeId: first.uuidString)
                != QEMUDiskIdentity.deviceID(volumeId: second.uuidString))
        // Case does not make two ids: the control plane and the agent both
        // render UUIDs uppercase today, but nothing guarantees that forever.
        #expect(
            QEMUDiskIdentity.deviceID(volumeId: first.uuidString)
                == QEMUDiskIdentity.deviceID(volumeId: first.uuidString.lowercased()))
    }

    @Test("The device id is something QEMU accepts as an id")
    func deviceIDIsAWellFormedQEMUID() throws {
        let id = QEMUDiskIdentity.deviceID(volumeId: UUID().uuidString)

        // QEMU's `id_wellformed`: a leading letter, then `[A-Za-z0-9-._]`.
        let first = try #require(id.first)
        #expect(first.isLetter)
        #expect(id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_" })
        #expect(id.hasPrefix("vol-"))
    }
}
