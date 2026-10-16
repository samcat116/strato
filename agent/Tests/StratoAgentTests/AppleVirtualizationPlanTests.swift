import Foundation
import StratoShared
import Testing
@testable import StratoAgentCore

@Suite("Apple Virtualization configuration")
struct AppleVirtualizationPlanTests {
    private func disk(format: DiskFormat = .raw, limits: VolumeIOLimits? = nil) -> VolumeSpec {
        VolumeSpec(
            volumeId: UUID(), deviceName: .disk(0),
            attachment: .file(path: "/tmp/managed.raw", format: format), ioLimits: limits)
    }

    @Test(
        "Invalid guest memory fails before filesystem or framework work",
        arguments: [Int64(511 << 20), Int64((512 << 20) + 1), Int64(2049 << 20)])
    func memoryLimits(bytes: Int64) {
        #expect(throws: HypervisorServiceError.self) {
            try AppleVirtualizationPlan(
                spec: VMSpec(cpus: 1, memoryBytes: bytes, boot: .disk(firmware: nil), volumes: [disk()]),
                networks: [], memoryBounds: (512 << 20)...(2048 << 20))
        }
    }

    @Test("EFI and direct-kernel boot retain raw volume ordering")
    func supportedBoots() throws {
        for boot in [BootSource.disk(firmware: nil), .directKernel(kernel: "/kernel", initramfs: nil, cmdline: nil)] {
            let plan = try AppleVirtualizationPlan(
                spec: VMSpec(cpus: 2, memoryBytes: 512 * 1024 * 1024, boot: boot, volumes: [disk()]),
                networks: [])
            #expect(plan.disks.map(\.path) == ["/tmp/managed.raw"])
            #expect(plan.disks[0].readonly == false)
        }
    }

    @Test("qcow2 and capped disks are rejected rather than misinterpreted")
    func unsupportedDisks() {
        for volume in [disk(format: .qcow2), disk(limits: VolumeIOLimits(iopsTotal: 100))] {
            #expect(throws: HypervisorServiceError.self) {
                try AppleVirtualizationPlan(
                    spec: VMSpec(
                        cpus: 2, memoryBytes: 512 * 1024 * 1024, boot: .disk(firmware: nil), volumes: [volume]),
                    networks: [])
            }
        }
    }

    @Test("Unsupported guest features fail before realization")
    func unsupportedFeatures() {
        let volume = disk()
        let specs = [
            VMSpec(
                cpus: 2, memoryBytes: 512 * 1024 * 1024, boot: .disk(firmware: nil), machine: MachineProfile(tpm: true),
                volumes: [volume]),
            VMSpec(
                cpus: 2, memoryBytes: 512 * 1024 * 1024, boot: .disk(firmware: nil), guestAgentEnabled: true,
                volumes: [volume]),
            VMSpec(
                cpus: 2, memoryBytes: 512 * 1024 * 1024, boot: .disk(firmware: nil), volumes: [volume],
                metadataSource: .imds),
            VMSpec(cpus: 2, memoryBytes: 512 * 1024 * 1024, boot: .disk(firmware: "/custom.fd"), volumes: [volume]),
        ]
        for spec in specs {
            #expect(throws: HypervisorServiceError.self) { try AppleVirtualizationPlan(spec: spec, networks: []) }
        }
    }

    @Test("NAT attachments are supported and TAP attachments fail explicitly")
    func networkAttachments() throws {
        let spec = VMSpec(
            cpus: 2, memoryBytes: 512 * 1024 * 1024, boot: .disk(firmware: nil), volumes: [disk()],
            networks: [NetworkSpec(network: "dev", networkId: UUID(), macAddress: "02:00:00:00:00:01")])
        let nat = ResolvedNetworkAttachment(network: "dev", attachment: .userMode, macAddress: "02:00:00:00:00:01")
        #expect(try AppleVirtualizationPlan(spec: spec, networks: [nat]).networks.count == 1)
        #expect(throws: HypervisorServiceError.self) {
            try AppleVirtualizationPlan(
                spec: spec,
                networks: [
                    ResolvedNetworkAttachment(
                        network: "dev", attachment: .tap(interface: "tap0"))
                ])
        }
        #expect(throws: HypervisorServiceError.self) { try AppleVirtualizationPlan(spec: spec, networks: []) }
    }

    @Test("A stopped native VM must realize a resize before its generation converges")
    func stoppedResize() {
        let id = UUID()
        let desired = DesiredVMState(
            vmId: id, hypervisorType: .appleVirtualization,
            spec: VMSpec(cpus: 2, memoryBytes: 1 << 30, boot: .disk(firmware: nil)),
            desiredStatus: .shutdown, generation: 2)
        let plan = Reconciler.plan(
            desired: [desired], present: [id.uuidString: .managed(.shutdown)], lastApplied: [id.uuidString: 1],
            presentSizing: [id.uuidString: VMSizing(cpus: 1, memoryBytes: 512 << 20)])
        #expect(plan.items.map(\.steps) == [[.resize]])
    }

    @Test("Duplicate disk sources cannot be attached twice")
    func duplicateDisks() {
        #expect(throws: HypervisorServiceError.self) {
            try AppleVirtualizationPlan(
                spec: VMSpec(
                    cpus: 2, memoryBytes: 512 * 1024 * 1024, boot: .disk(firmware: nil), volumes: [disk(), disk()]),
                networks: [])
        }
    }
}
