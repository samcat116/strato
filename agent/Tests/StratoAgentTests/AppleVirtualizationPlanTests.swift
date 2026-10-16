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

    @Test("A coalesced stopped Apple resize precedes boot", arguments: [VMStatus.created, .shutdown])
    func stoppedResizeBeforeBoot(status: VMStatus) {
        let id = UUID()
        let desired = DesiredVMState(
            vmId: id, hypervisorType: .appleVirtualization,
            spec: VMSpec(cpus: 2, memoryBytes: 1 << 30, boot: .disk(firmware: nil)),
            desiredStatus: .running, generation: 3)
        let plan = Reconciler.plan(
            desired: [desired], present: [id.uuidString: .managed(status)], lastApplied: [id.uuidString: 1],
            presentSizing: [id.uuidString: VMSizing(cpus: 1, memoryBytes: 512 << 20)])
        #expect(plan.items.map(\.steps) == [[.resize, .boot]])
    }

    @Test("Apple network drift waits for cold boot without unsupported hot-plug")
    func networkDriftDoesNotBlockLifecycle() {
        let id = UUID()
        let networkID = UUID()
        let oldNIC = NetworkSpec(network: "nat", networkId: networkID, macAddress: "02:00:00:00:00:01")
        let newNIC = NetworkSpec(
            network: "nat", networkId: networkID, macAddress: "02:00:00:00:00:01", dnsServers: ["192.0.2.53"])
        func plan(observed: VMStatus, desired: DesiredVMStatus) -> ReconcilePlan {
            Reconciler.plan(
                desired: [
                    DesiredVMState(
                        vmId: id, hypervisorType: .appleVirtualization,
                        spec: VMSpec(cpus: 1, memoryBytes: 1 << 30, boot: .disk(firmware: nil), networks: [newNIC]),
                        desiredStatus: desired, generation: 2)
                ],
                present: [id.uuidString: .managed(observed)], lastApplied: [id.uuidString: 1],
                appliedEdges: [id.uuidString: AppliedEdgeNonces()],
                presentNetworks: [id.uuidString: [oldNIC]])
        }
        #expect(plan(observed: .running, desired: .running).items.flatMap(\.steps).isEmpty)
        #expect(plan(observed: .shutdown, desired: .running).items.map(\.steps) == [[.boot]])
        #expect(plan(observed: .running, desired: .shutdown).items.map(\.steps) == [[.shutdown]])
    }

    @Test("Apple reboot rebuilds desired configuration through cold boot before acknowledging its nonce")
    func rebootRebuildsConfiguration() throws {
        let id = UUID()
        let desired = DesiredVMState(
            vmId: id, hypervisorType: .appleVirtualization,
            spec: VMSpec(
                cpus: 1, memoryBytes: 1 << 30, boot: .disk(firmware: nil),
                networks: [NetworkSpec(network: "nat", networkId: UUID(), dnsServers: ["192.0.2.53"])]),
            desiredStatus: .running, generation: 2, rebootGeneration: 2)
        let plan = Reconciler.plan(
            desired: [desired], present: [id.uuidString: .managed(.running)], lastApplied: [id.uuidString: 1],
            appliedEdges: [id.uuidString: AppliedEdgeNonces(reboot: 1)],
            presentNetworks: [id.uuidString: []])
        let item = try #require(plan.items.first)
        #expect(item.steps == [.shutdown, .boot])
        #expect(item.desired?.spec.networks == desired.spec.networks)
        #expect(item.appliedEdges == AppliedEdgeNonces(reboot: 2))
        let replay = Reconciler.plan(
            desired: [desired], present: [id.uuidString: .managed(.running)], lastApplied: [id.uuidString: 2],
            appliedEdges: [id.uuidString: AppliedEdgeNonces(reboot: 2)],
            presentNetworks: [id.uuidString: desired.spec.networks])
        #expect(replay.items.isEmpty)
    }

    @Test("A mixed fleet retains Apple cold reboot and same-generation QEMU guest convergence")
    func mixedFleetGuestConvergence() throws {
        let appleID = UUID()
        let qemuID = UUID()
        let apple = DesiredVMState(
            vmId: appleID, hypervisorType: .appleVirtualization,
            spec: VMSpec(cpus: 1, memoryBytes: 1 << 30, boot: .disk(firmware: nil)),
            desiredStatus: .running, generation: 2, rebootGeneration: 2)
        let qemu = DesiredVMState(
            vmId: qemuID, hypervisorType: .qemu,
            spec: VMSpec(cpus: 1, memoryBytes: 1 << 30, boot: .disk(firmware: nil), guestAgentEnabled: true),
            desiredStatus: .running, generation: 2,
            guestConfig: GuestConfig(packages: [GuestPackage(name: "curl", state: .present)]))
        let plan = Reconciler.plan(
            desired: [apple, qemu],
            present: [appleID.uuidString: .managed(.running), qemuID.uuidString: .managed(.running)],
            lastApplied: [appleID.uuidString: 1, qemuID.uuidString: 2],
            appliedEdges: [appleID.uuidString: AppliedEdgeNonces(reboot: 1), qemuID.uuidString: AppliedEdgeNonces()])
        let reboot = try #require(plan.items.first { $0.id == appleID.uuidString })
        #expect(reboot.steps == [.shutdown, .boot])
        #expect(reboot.appliedEdges == AppliedEdgeNonces(reboot: 2))
        let convergence = try #require(plan.items.first { $0.id == qemuID.uuidString })
        #expect(convergence.steps == [.convergeGuestConfig])
        #expect(convergence.generation == 2)
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
