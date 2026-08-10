import Foundation
import Testing

@testable import StratoShared

/// STR-129: a volume's device name reaches a hypervisor as an object id, so an
/// id QEMU or Firecracker would refuse must not be representable — not in a
/// request body, and not in a `VolumeSpec` decoded from the wire or from the
/// agent's manifest.
@Suite("Volume Device Name")
struct VolumeDeviceNameTests {

    @Test("Accepts the names the platform generates and the ones operators use")
    func acceptsLegalNames() throws {
        for name in ["disk0", "disk10", "vda", "vol-1", "boot.disk", "a_b", "A0", "0disk"] {
            #expect(VolumeDeviceName(name)?.rawValue == name, "expected '\(name)' to be accepted")
        }
    }

    @Test("Rejects names a hypervisor id cannot be")
    func rejectsIllegalNames() {
        let illegal = [
            "",  // an empty device_id is silently accepted by nothing
            " ",
            "disk 1",  // a space splits the id
            "/var/lib/strato/disk",  // a path from a request body
            "disk/1",
            "-disk",  // leading separator
            ".disk",
            "_disk",
            "disk;rm",
            "diskü",
            String(repeating: "d", count: VolumeDeviceName.maxLength + 1),
        ]
        for name in illegal {
            #expect(VolumeDeviceName(name) == nil, "expected '\(name)' to be rejected")
        }
    }

    @Test("A name exactly at the length bound is accepted")
    func acceptsMaximumLength() {
        let atBound = String(repeating: "d", count: VolumeDeviceName.maxLength)
        #expect(VolumeDeviceName(atBound) != nil)
    }

    @Test("The throwing initializer names the value it refused")
    func throwingInitializerCarriesTheValue() {
        #expect(throws: InvalidVolumeDeviceName.self) {
            try VolumeDeviceName(validating: "disk 1")
        }
    }

    @Test("disk(_:) generates a legal name for any slot")
    func generatedNamesAreLegal() {
        #expect(VolumeDeviceName.disk(0).rawValue == "disk0")
        #expect(VolumeDeviceName.disk(42).rawValue == "disk42")
        // Non-failable, so a negative index must still produce something legal
        // rather than `disk-1`, which the leading-separator rule would refuse.
        #expect(VolumeDeviceName.isValid(VolumeDeviceName.disk(-1).rawValue))
    }

    // MARK: - Wire format

    @Test("Encodes as the bare string the field always was")
    func encodesAsAString() throws {
        let spec = VolumeSpec(
            volumeId: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            deviceName: VolumeDeviceName("disk1")!,
            storagePath: "/var/lib/strato/volumes/a.qcow2",
            readonly: false,
            bootOrder: 1)

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any]
        #expect(json?["deviceName"] as? String == "disk1")
    }

    @Test("Decoding validates, so a spec cannot carry an illegal name")
    func decodingValidates() throws {
        let legal = #"{"volumeId":"00000000-0000-0000-0000-0000000000AA","deviceName":"disk1","readonly":false}"#
        let decoded = try JSONDecoder().decode(VolumeSpec.self, from: Data(legal.utf8))
        #expect(decoded.deviceName.rawValue == "disk1")

        let illegal = #"{"volumeId":"00000000-0000-0000-0000-0000000000AA","deviceName":"disk 1","readonly":false}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(VolumeSpec.self, from: Data(illegal.utf8))
        }
    }

    @Test("Ordering is by name, so specs sorted on it are deterministic")
    func ordersByName() {
        let names = ["disk10", "disk2", "vda"].compactMap(VolumeDeviceName.init)
        #expect(names.sorted().map(\.rawValue) == ["disk10", "disk2", "vda"])
    }
}
