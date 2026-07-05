import Testing
import Vapor
@testable import App

@Suite("VolumeNaming Tests")
struct VolumeNamingTests {

    // MARK: - Device naming

    @Test("nextDeviceName starts at disk0 when nothing is attached")
    func testNextDeviceNameEmpty() {
        #expect(VolumeNaming.nextDeviceName(existingDeviceNames: []) == "disk0")
        #expect(VolumeNaming.nextDeviceName(existingDeviceNames: [nil, nil]) == "disk0")
    }

    @Test("nextDeviceName picks one past the highest existing disk number")
    func testNextDeviceNameIncrements() {
        #expect(VolumeNaming.nextDeviceName(existingDeviceNames: ["disk0"]) == "disk1")
        #expect(VolumeNaming.nextDeviceName(existingDeviceNames: ["disk0", "disk2", "disk1"]) == "disk3")
    }

    @Test("nextDeviceName ignores names that don't match the disk<N> shape")
    func testNextDeviceNameIgnoresNonMatching() {
        #expect(VolumeNaming.nextDeviceName(existingDeviceNames: ["cdrom", "vda", nil]) == "disk0")
        #expect(VolumeNaming.nextDeviceName(existingDeviceNames: ["disk5", "sda", "cdrom"]) == "disk6")
    }

    // MARK: - Format parsing

    @Test("parseFormat defaults to qcow2 and parses valid values")
    func testParseFormat() throws {
        #expect(try VolumeNaming.parseFormat(nil) == .qcow2)
        #expect(try VolumeNaming.parseFormat("qcow2") == .qcow2)
        #expect(try VolumeNaming.parseFormat("raw") == .raw)
    }

    @Test("parseFormat rejects invalid values")
    func testParseFormatInvalid() {
        #expect(throws: Abort.self) {
            try VolumeNaming.parseFormat("vmdk")
        }
    }

    // MARK: - Volume-type parsing

    @Test("parseVolumeType defaults to data and parses valid values")
    func testParseVolumeType() throws {
        #expect(try VolumeNaming.parseVolumeType(nil) == .data)
        #expect(try VolumeNaming.parseVolumeType("boot") == .boot)
        #expect(try VolumeNaming.parseVolumeType("data") == .data)
    }

    @Test("parseVolumeType rejects invalid values")
    func testParseVolumeTypeInvalid() {
        #expect(throws: Abort.self) {
            try VolumeNaming.parseVolumeType("swap")
        }
    }
}
