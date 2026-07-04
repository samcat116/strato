import Foundation
import Testing
import StratoShared

@Suite("VM lifecycle and query messages")
struct VMMessageTests {
    @Test func vmCreateRoundTrip() throws {
        let spec = VMSpec(
            cpus: 2,
            maxCpus: 4,
            memoryBytes: 2_147_483_648,
            sharedMemory: true,
            hugepages: true,
            boot: .disk(firmware: "/usr/share/OVMF/OVMF_CODE.fd"),
            volumes: [VolumeSpec(volumeId: Fixtures.uuidA, deviceName: "disk0", storagePath: "/var/lib/strato/disk0.qcow2", readonly: false, bootOrder: 0)],
            networks: [NetworkSpec(network: "default", macAddress: "52:54:00:00:00:01", ipAddress: "10.0.0.5", netmask: "255.255.255.0", mtu: 1500)],
            console: ConsoleSpec(console: .pty, serial: .socket)
        )
        let vmData = VMData(
            id: Fixtures.uuidB,
            name: "web-1",
            description: "web server",
            image: "debian-12",
            status: .created,
            hypervisorId: "agent-1",
            hypervisorType: .qemu,
            cpu: 2,
            maxCpu: 4,
            memory: 2_147_483_648,
            disk: 21_474_836_480,
            consoleMode: .pty,
            serialMode: .socket,
            createdAt: Fixtures.timestamp,
            updatedAt: Fixtures.laterDate
        )
        let message = VMCreateMessage(
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            vmData: vmData,
            vmSpec: spec,
            imageInfo: Fixtures.imageInfo
        )

        let decoded = try throughEnvelope(message)
        #expect(decoded.type == .vmCreate)
        #expect(decoded.vmData.id == Fixtures.uuidB)
        #expect(decoded.vmData.name == "web-1")
        #expect(decoded.vmData.status == .created)
        #expect(decoded.vmData.hypervisorType == .qemu)
        #expect(decoded.vmData.consoleMode == .pty)
        #expect(decoded.vmData.serialMode == .socket)
        #expect(decoded.vmData.createdAt == Fixtures.timestamp)
        #expect(decoded.vmSpec.cpus == 2)
        #expect(decoded.vmSpec.maxCpus == 4)
        #expect(decoded.vmSpec.memoryBytes == 2_147_483_648)
        #expect(decoded.vmSpec.sharedMemory)
        #expect(decoded.vmSpec.hugepages)
        #expect(decoded.vmSpec.volumes.count == 1)
        #expect(decoded.vmSpec.volumes.first?.volumeId == Fixtures.uuidA)
        #expect(decoded.vmSpec.networks.first?.macAddress == "52:54:00:00:00:01")
        #expect(decoded.imageInfo?.imageId == Fixtures.imageInfo.imageId)
        #expect(decoded.imageInfo?.downloadURL == Fixtures.imageInfo.downloadURL)
    }

    /// `imageInfo` is optional on the wire: VMs whose boot volume already
    /// exists agent-side are created without one.
    @Test func vmCreateWithoutImageInfoRoundTrip() throws {
        let message = VMCreateMessage(
            vmData: VMData(
                id: Fixtures.uuidA, name: "v", description: "", image: "img",
                status: .created, cpu: 1, maxCpu: 1, memory: 1_073_741_824, disk: 1_073_741_824
            ),
            vmSpec: VMSpec(cpus: 1, memoryBytes: 1_073_741_824, boot: .disk(firmware: nil))
        )
        let decoded = try throughEnvelope(message)
        #expect(decoded.imageInfo == nil)
        // maxCpus defaults to cpus when not given.
        #expect(decoded.vmSpec.maxCpus == 1)
    }

    /// All plain lifecycle operations share VMOperationMessage; the carried
    /// type must survive so the agent dispatches the right operation.
    @Test(arguments: [MessageType.vmBoot, .vmShutdown, .vmReboot, .vmPause, .vmResume, .vmDelete, .vmStatus])
    func vmOperationRoundTrip(type: MessageType) throws {
        let message = VMOperationMessage(
            type: type,
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            vmId: "vm-9"
        )
        let decoded = try throughEnvelope(message)
        #expect(decoded.type == type)
        #expect(decoded.vmId == "vm-9")
        #expect(decoded.requestId == Fixtures.requestId)
    }

    @Test func vmInfoRequestRoundTrip() throws {
        let decoded = try throughEnvelope(
            VMInfoRequestMessage(requestId: Fixtures.requestId, timestamp: Fixtures.timestamp, vmId: "vm-3")
        )
        #expect(decoded.type == .vmInfo)
        #expect(decoded.vmId == "vm-3")
    }
}
