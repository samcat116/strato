import Foundation
import StratoShared
import Testing

@Suite("Storage device inventory wire contract")
struct StorageDeviceInventoryTests {
    @Test("WWN identity is normalized and preferred over serial")
    func preferredIdentityUsesNormalizedWWNBeforeSerial() {
        #expect(
            StorageDeviceIdentity.preferred(
                wwn: " 0x5000CCA123ABCDEF ", serial: " SERIAL-1 ")
                == StorageDeviceIdentity(kind: .wwn, value: "5000cca123abcdef")
        )
    }

    @Test("serial identity preserves case after trimming")
    func preferredIdentityFallsBackToTrimmedSerial() {
        #expect(
            StorageDeviceIdentity.preferred(wwn: "  ", serial: " SERIAL-1 ")
                == StorageDeviceIdentity(kind: .serial, value: "SERIAL-1")
        )
    }

    @Test("blank hardware identifiers leave a device anonymous")
    func preferredIdentityRejectsBlankInputs() {
        #expect(StorageDeviceIdentity.preferred(wwn: nil, serial: "   ") == nil)
    }

    @Test("observed state carries identified and anonymous disks")
    func observedStateRoundTripsStorageDevices() throws {
        let identified = ObservedStorageDevice(
            identity: StorageDeviceIdentity(kind: .wwn, value: "5000cca123abcdef"),
            devicePath: "/dev/sdb",
            sizeBytes: 1_000_204_886_016,
            model: "FastDisk 1TB",
            serial: "SERIAL-1",
            wwn: "0x5000CCA123ABCDEF",
            rotational: false,
            state: .available,
            uses: []
        )
        let anonymous = ObservedStorageDevice(
            identity: nil,
            devicePath: "/dev/sdc",
            sizeBytes: 500_107_862_016,
            rotational: true,
            state: .inUse,
            uses: [.childDevice, .filesystem, .mounted]
        )
        let report = ObservedStateReport(
            agentId: "agent-1",
            vms: [],
            resources: Fixtures.resources,
            storageDevices: [identified, anonymous]
        )

        let decoded = try throughEnvelope(report)

        #expect(decoded.storageDevices == [identified, anonymous])
    }

    @Test("an omitted storage inventory is no opinion")
    func omittedStorageDevicesDecodeAsNil() throws {
        let report = ObservedStateReport(
            agentId: "agent-1",
            vms: [],
            resources: Fixtures.resources
        )

        let encoded = try WireProtocol.makeEncoder().encode(report)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["storageDevices"] == nil)
        #expect(
            try WireProtocol.makeDecoder().decode(ObservedStateReport.self, from: encoded)
                .storageDevices == nil)
    }
}
