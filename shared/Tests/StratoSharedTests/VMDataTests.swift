import Foundation
import Testing
import StratoShared

@Suite("VMData wire format")
struct VMDataTests {
    @Test func fullyPopulatedRoundTrip() throws {
        let vm = VMData(
            id: Fixtures.uuidA,
            name: "db-1",
            description: "primary database",
            image: "ubuntu-24.04",
            status: .paused,
            hypervisorId: "agent-2",
            hypervisorType: .firecracker,
            cpu: 8,
            maxCpu: 16,
            memory: 34_359_738_368,
            hugepages: true,
            sharedMemory: true,
            disk: 107_374_182_400,
            diskPath: "/var/lib/strato/db-1.qcow2",
            readonlyDisk: true,
            kernelPath: "/boot/vmlinux",
            initramfsPath: "/boot/initrd",
            cmdline: "console=ttyS0",
            firmwarePath: "/fw/OVMF.fd",
            macAddress: "52:54:00:11:22:33",
            ipAddress: "10.0.0.20",
            networkMask: "255.255.255.0",
            consoleMode: .socket,
            serialMode: .file,
            consoleSocket: "/run/strato/console.sock",
            serialSocket: "/run/strato/serial.sock",
            createdAt: Fixtures.timestamp,
            updatedAt: Fixtures.laterDate
        )
        let decoded = try roundTrip(vm)
        #expect(decoded.id == Fixtures.uuidA)
        #expect(decoded.name == "db-1")
        #expect(decoded.description == "primary database")
        #expect(decoded.image == "ubuntu-24.04")
        #expect(decoded.status == .paused)
        #expect(decoded.hypervisorId == "agent-2")
        #expect(decoded.hypervisorType == .firecracker)
        #expect(decoded.cpu == 8)
        #expect(decoded.maxCpu == 16)
        #expect(decoded.memory == 34_359_738_368)
        #expect(decoded.hugepages)
        #expect(decoded.sharedMemory)
        #expect(decoded.disk == 107_374_182_400)
        #expect(decoded.diskPath == "/var/lib/strato/db-1.qcow2")
        #expect(decoded.readonlyDisk)
        #expect(decoded.kernelPath == "/boot/vmlinux")
        #expect(decoded.initramfsPath == "/boot/initrd")
        #expect(decoded.cmdline == "console=ttyS0")
        #expect(decoded.firmwarePath == "/fw/OVMF.fd")
        #expect(decoded.macAddress == "52:54:00:11:22:33")
        #expect(decoded.ipAddress == "10.0.0.20")
        #expect(decoded.networkMask == "255.255.255.0")
        #expect(decoded.consoleMode == .socket)
        #expect(decoded.serialMode == .file)
        #expect(decoded.consoleSocket == "/run/strato/console.sock")
        #expect(decoded.serialSocket == "/run/strato/serial.sock")
        #expect(decoded.createdAt == Fixtures.timestamp)
        #expect(decoded.updatedAt == Fixtures.laterDate)
    }

    @Test func minimalRoundTripKeepsNils() throws {
        let vm = VMData(
            id: Fixtures.uuidB,
            name: "tiny",
            description: "",
            image: "alpine",
            status: .created,
            cpu: 1,
            maxCpu: 1,
            memory: 268_435_456,
            disk: 1_073_741_824
        )
        let decoded = try roundTrip(vm)
        #expect(decoded.hypervisorId == nil)
        #expect(decoded.hypervisorType == .qemu)
        #expect(decoded.diskPath == nil)
        #expect(decoded.kernelPath == nil)
        #expect(decoded.macAddress == nil)
        #expect(decoded.consoleSocket == nil)
        #expect(decoded.createdAt == nil)
        #expect(decoded.updatedAt == nil)
        // Defaults from the initializer, preserved through the wire.
        #expect(decoded.consoleMode == .pty)
        #expect(decoded.serialMode == .pty)
        #expect(!decoded.hugepages)
        #expect(!decoded.readonlyDisk)
    }

    /// Every field must actually reach the wire — a field silently dropped by
    /// encoding would still pass a round trip.
    @Test func allFieldsAreEncoded() throws {
        let vm = VMData(
            id: Fixtures.uuidA, name: "n", description: "d", image: "i",
            status: .running, hypervisorId: "h", cpu: 1, maxCpu: 2,
            memory: 1, disk: 1, diskPath: "p", kernelPath: "k",
            initramfsPath: "ir", cmdline: "c", firmwarePath: "f",
            macAddress: "m", ipAddress: "ip", networkMask: "nm",
            consoleSocket: "cs", serialSocket: "ss",
            createdAt: Fixtures.timestamp, updatedAt: Fixtures.timestamp
        )
        let keys = try encodedKeys(vm)
        let expected: Set<String> = [
            "id", "name", "description", "image", "status",
            "hypervisorId", "hypervisorType",
            "cpu", "maxCpu", "memory", "hugepages", "sharedMemory",
            "disk", "diskPath", "readonlyDisk",
            "kernelPath", "initramfsPath", "cmdline", "firmwarePath",
            "macAddress", "ipAddress", "networkMask",
            "consoleMode", "serialMode", "consoleSocket", "serialSocket",
            "createdAt", "updatedAt",
        ]
        #expect(keys == expected)
    }
}
