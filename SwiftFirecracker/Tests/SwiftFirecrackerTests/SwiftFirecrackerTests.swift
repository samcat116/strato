import Foundation
import Testing
@testable import SwiftFirecracker

@Suite("SwiftFirecracker Tests")
struct SwiftFirecrackerTests {
    @Test("MachineConfig encodes correctly")
    func testMachineConfigEncoding() throws {
        let config = MachineConfig(vcpuCount: 2, memSizeMib: 512)
        let encoder = JSONEncoder()
        let data = try encoder.encode(config)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"vcpu_count\":2"))
        #expect(json.contains("\"mem_size_mib\":512"))
    }

    @Test("BootSource encodes correctly")
    func testBootSourceEncoding() throws {
        let bootSource = BootSource(
            kernelImagePath: "/path/to/vmlinux",
            initrdPath: "/path/to/initrd",
            bootArgs: "console=ttyS0"
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(bootSource)
        let json = String(data: data, encoding: .utf8)!

        // JSONEncoder escapes forward slashes as \/
        #expect(json.contains("kernel_image_path"))
        #expect(json.contains("vmlinux"))
        #expect(json.contains("\"boot_args\":\"console=ttyS0\""))
    }

    @Test("Drive encodes correctly")
    func testDriveEncoding() throws {
        let drive = Drive.rootDrive(id: "rootfs", path: "/path/to/rootfs.ext4")
        let encoder = JSONEncoder()
        let data = try encoder.encode(drive)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"drive_id\":\"rootfs\""))
        #expect(json.contains("path_on_host"))
        #expect(json.contains("rootfs.ext4"))
        #expect(json.contains("\"is_root_device\":true"))
    }

    @Test("NetworkInterface encodes correctly")
    func testNetworkInterfaceEncoding() throws {
        let networkInterface = NetworkInterface.tap(
            id: "eth0",
            tapName: "tap0",
            macAddress: "AA:BB:CC:DD:EE:FF"
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(networkInterface)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"iface_id\":\"eth0\""))
        #expect(json.contains("\"host_dev_name\":\"tap0\""))
        #expect(json.contains("\"guest_mac\":\"AA:BB:CC:DD:EE:FF\""))
    }

    @Test("BootSource.withRootFS creates correct boot args")
    func testBootSourceWithRootFS() {
        let bootSource = BootSource.withRootFS(
            kernelImagePath: "/vmlinux",
            rootDevice: "/dev/vda",
            consoleDevice: "ttyS0"
        )

        #expect(bootSource.bootArgs?.contains("console=ttyS0") == true)
        #expect(bootSource.bootArgs?.contains("root=/dev/vda") == true)
        #expect(bootSource.bootArgs?.contains("panic=1") == true)
    }

    @Test("VMAction encodes correctly")
    func testVMActionEncoding() throws {
        let action = VMAction(actionType: .instanceStart)
        let encoder = JSONEncoder()
        let data = try encoder.encode(action)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"action_type\":\"InstanceStart\""))
    }

    @Test("FirecrackerError provides descriptions")
    func testErrorDescriptions() {
        let error1 = FirecrackerError.vmNotFound("test-vm")
        #expect(error1.localizedDescription.contains("test-vm"))

        let error2 = FirecrackerError.httpError(statusCode: 400, message: "Bad request")
        #expect(error2.localizedDescription.contains("400"))

        let error3 = FirecrackerError.invalidState(current: "Running", expected: "Paused")
        #expect(error3.localizedDescription.contains("Running"))
        #expect(error3.localizedDescription.contains("Paused"))
    }
}
