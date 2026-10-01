import Foundation
import Logging
import StratoAgentCore
import StratoShared
import Testing

@testable import StratoAgentRuntime

@Suite("Missing inventory quarantine")
struct MissingInventoryTests {
    private func withAgent(_ body: (Agent, String) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let agent = Agent(
            agentID: "missing-inventory", webSocketURL: "ws://127.0.0.1:8080/agent",
            configuration: runtimeTestConfiguration(
                path: root + "/vms", volumeStoragePath: root + "/volumes",
                simulation: SimulationConfig(enabled: true, diskGB: 100)),
            logger: Logger(label: "missing-inventory-test"))
        await agent.prepareMissingInventoryTest()
        do {
            try await body(agent, root)
        } catch {
            try await agent.closeMissingInventoryTest()
            throw error
        }
        try await agent.closeMissingInventoryTest()
    }

    @Test("A lost manifest makes the initial report blind and refuses persistence")
    func initialQuarantine() async throws {
        try await withAgent { agent, root in
            #expect(await agent.manifestStatus()?.inventoryComplete == false)
            #expect(await agent.presenceIsComplete() == false)
            #expect(await agent.persistManifest() == false)
            #expect(await agent.missingSnapshotInventoryIsUnknown())
            #expect(await agent.observedSnapshotPresence() == nil)
            let resources = await agent.getAgentResources()
            #expect(resources.availableCPU == 0)
            #expect(resources.availableMemory == 0)
            #expect(resources.availableDisk == 0)
            #expect(!FileManager.default.fileExists(atPath: root + "/vms/vm-manifest.json"))
        }
    }

    @Test("An independently empty host becomes writable after its first desired sync")
    func freshHost() async throws {
        try await withAgent { agent, root in
            await agent.verifyMissingInventories(using: DesiredStateMessage(vms: []))
            #expect(await agent.presenceIsComplete())
            #expect(await agent.manifestStatus() == nil)
            #expect(await agent.missingSnapshotInventoryIsUnknown() == false)
            // Persist proof before accepting a first placement: otherwise a
            // restart with a queued create would look like inventory loss.
            let store = VMManifestStore(path: root + "/vms/vm-manifest.json", logger: Logger(label: "test"))
            guard case .loaded(let entries, let quarantined) = store.load() else {
                Issue.record("verified empty workload inventory was not persisted")
                return
            }
            #expect(entries.isEmpty && quarantined.isEmpty)
            let snapshots = SnapshotRecordStore(
                path: root + "/vms/snapshot-records.json", logger: Logger(label: "test"))
            guard case .loaded(let records) = snapshots.load() else {
                Issue.record("verified empty snapshot inventory was not persisted")
                return
            }
            #expect(records.isEmpty)
        }
    }

    @Test("Surviving hypervisor guests keep a missing manifest quarantined", arguments: HypervisorType.allCases)
    func survivingGuest(type: HypervisorType) async throws {
        try await withAgent { agent, root in
            try await agent.seedSurvivingGuest(type: type)
            await agent.verifyMissingInventories(using: DesiredStateMessage(vms: []))
            #expect(await agent.manifestStatus()?.inventoryComplete == false)
            #expect(await agent.manifestStatus()?.reason.contains("survivor") == true)
            #expect(await agent.persistManifest() == false)
            #expect(!FileManager.default.fileExists(atPath: root + "/vms/vm-manifest.json"))
        }
    }

    @Test("Control-plane placement prevents a repointed storage root from asserting emptiness")
    func controlPlaneStillHasWorkloads() async throws {
        try await withAgent { agent, _ in
            let desired = DesiredStateMessage(
                vms: [],
                volumes: [
                    DesiredVolumeState(
                        volumeId: UUID(), desiredStatus: .absent, generation: 2,
                        sizeBytes: 1024, format: "qcow2")
                ])
            await agent.verifyMissingInventories(using: desired)
            #expect(await agent.presenceIsComplete() == false)
            #expect(await agent.manifestStatus()?.reason.contains("control plane") == true)
            #expect(await agent.missingSnapshotInventoryIsUnknown())
        }
    }

    @Test(
        "Placed VMs prevent bootstrap even when the local root is empty", arguments: [DesiredVMStatus.running, .absent])
    func controlPlaneStillHasVMs(status: DesiredVMStatus) async throws {
        try await withAgent { agent, _ in
            let desired = DesiredStateMessage(vms: [
                DesiredVMState(
                    vmId: UUID(), hypervisorType: .qemu,
                    spec: VMSpec(cpus: 2, memoryBytes: 1024, boot: .disk(firmware: nil)),
                    desiredStatus: status, generation: 2)
            ])
            await agent.verifyMissingInventories(using: desired)
            #expect(await agent.presenceIsComplete() == false)
            #expect(await agent.persistManifest() == false)
            #expect(await agent.manifestStatus()?.reason.contains("control plane") == true)
        }
    }

    @Test("A missing backend is unknown, not a fresh host")
    func unavailableProbe() async throws {
        try await withAgent { agent, _ in
            await agent.removeBootstrapHypervisor()
            await agent.verifyMissingInventories(using: DesiredStateMessage(vms: []))
            #expect(await agent.presenceIsComplete() == false)
            #expect(await agent.persistManifest() == false)
        }
    }

    @Test("A surviving storage volume prevents bootstrap even with no control-plane placement")
    func survivingVolume() async throws {
        try await withAgent { agent, _ in
            try await agent.seedSurvivingVolume()
            await agent.verifyMissingInventories(using: DesiredStateMessage(vms: []))
            #expect(await agent.presenceIsComplete() == false)
            #expect(await agent.manifestStatus()?.reason.contains("volume(s)") == true)
        }
    }

    @Test("A restored manifest is recovered without overwriting its entries")
    func lateMount() async throws {
        try await withAgent { agent, root in
            let store = VMManifestStore(path: root + "/vms/vm-manifest.json", logger: Logger(label: "test"))
            let entry = VMManifestEntry(
                hypervisorType: .qemu,
                spec: VMSpec(cpus: 2, memoryBytes: 1024, boot: .disk(firmware: nil)))
            #expect(store.save(["restored": entry]))
            await agent.verifyMissingInventories(using: DesiredStateMessage(vms: []))
            #expect(await agent.presenceIsComplete())
            #expect(await agent.observedPresence()["restored"] == .orphaned)
        }
    }

    @Test("Missing snapshot records cannot confirm a pending checkpoint deletion")
    func missingSnapshots() async throws {
        try await withAgent { agent, _ in
            await agent.applyManifestLoad(.loaded(entries: [:], quarantined: [:]))
            let desired = DesiredStateMessage(
                vms: [],
                snapshots: [
                    DesiredSnapshotState(
                        snapshotId: UUID(), kind: .vmCheckpoint, parentId: UUID(),
                        desiredStatus: .absent, generation: 2)
                ])
            await agent.verifyMissingInventories(using: desired)
            #expect(await agent.missingSnapshotInventoryIsUnknown())
            await #expect(throws: (any Error).self) { try await agent.requireWritableSnapshotInventory() }
        }
    }

    @Test("Existing workloads without any snapshot history can initialize snapshot records")
    func noSnapshotHistory() async throws {
        try await withAgent { agent, _ in
            let entry = VMManifestEntry(
                hypervisorType: .qemu,
                spec: VMSpec(cpus: 2, memoryBytes: 1024, boot: .disk(firmware: nil)))
            await agent.applyManifestLoad(.loaded(entries: ["existing-guest": entry], quarantined: [:]))
            await agent.verifyMissingInventories(using: DesiredStateMessage(vms: []))
            #expect(await agent.missingSnapshotInventoryIsUnknown() == false)
            try await agent.requireWritableSnapshotInventory()
        }
    }
}

extension Agent {
    fileprivate func prepareMissingInventoryTest() async {
        for type in HypervisorType.allCases {
            hypervisorServices[type] = MockHypervisorService(logger: logger, hypervisorType: type)
        }
        let local = MockStorageBackend(logger: logger, volumeStoragePath: configuration.volumeStoragePath)
        storageBackend = local
        storageBackends = StorageBackendRegistry(local: local, makeCeph: { _ in fatalError("No Ceph in this test") })
        await applyManifestLoad(manifestStore.load())
        applySnapshotInventory(snapshotRecordStore.load())
    }

    fileprivate func missingSnapshotInventoryIsUnknown() -> Bool { snapshotInventoryUnreadable }
    fileprivate func removeBootstrapHypervisor() { hypervisorServices.removeValue(forKey: .qemu) }
    fileprivate func seedSurvivingGuest(type: HypervisorType) async throws {
        _ = try await hypervisorServices[type]?.adoptVM(
            vmId: "survivor", spec: VMSpec(cpus: 2, memoryBytes: 1024, boot: .disk(firmware: nil)))
    }
    fileprivate func seedSurvivingVolume() async throws {
        _ = try await storageBackend?.createVolume(volumeId: UUID().uuidString, sizeBytes: 1024, format: .qcow2)
    }
    fileprivate func closeMissingInventoryTest() async throws { try await eventLoopGroup.shutdownGracefully() }
}

@Suite("Missing inventory host probes")
struct MissingInventoryHostProbeTests {
    @Test(
        "Surviving hypervisor processes are found even when state and sockets vanished",
        arguments: ["/usr/bin/firecracker", "/usr/bin/qemu-system-x86_64"])
    func survivingProcess(binary: String) throws {
        #if os(Linux)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/proc/42", withIntermediateDirectories: true)
        try Data("\(binary)\0".utf8)
            .write(to: URL(fileURLWithPath: root + "/proc/42/cmdline"))
        #expect(throws: MissingInventoryEvidence.self) {
            try MissingInventoryHostProbe.verify(
                vmStoragePath: root + "/new-root", socketDirectory: root + "/sockets",
                jailDirectory: root + "/jails", firecrackerBinaryPath: "/usr/bin/firecracker",
                procDirectory: root + "/proc")
        }
        #endif
    }

    @Test("Empty directories and an empty process inventory corroborate a new host")
    func emptyHost() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/proc", withIntermediateDirectories: true)
        try MissingInventoryHostProbe.verify(
            vmStoragePath: root + "/vms", socketDirectory: root + "/sockets",
            jailDirectory: root + "/jails", firecrackerBinaryPath: "/usr/bin/firecracker",
            procDirectory: root + "/proc")
    }

    @Test("A Firecracker-only host can prove freshness without a libvirt daemon")
    func noLibvirtDaemon() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/proc", withIntermediateDirectories: true)
        try MissingInventoryHostProbe.verify(
            vmStoragePath: root + "/vms", socketDirectory: root + "/sockets",
            jailDirectory: root + "/jails", firecrackerBinaryPath: "/usr/bin/firecracker",
            procDirectory: root + "/proc", needsLibvirtFilesystemProof: true,
            libvirtConfigurationDirectory: root + "/libvirt-config", libvirtStateDirectory: root + "/libvirt-state")
    }

    @Test(
        "An unavailable daemon cannot hide inactive domain configuration or saved state",
        arguments: ["libvirt-config/strato-guest.xml", "libvirt-state/save/strato-guest.save"])
    func offlineLibvirtArtifacts(path: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let artifact = root + "/" + path
        try FileManager.default.createDirectory(
            atPath: (artifact as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("surviving domain".utf8).write(to: URL(fileURLWithPath: artifact))
        #expect(throws: MissingInventoryEvidence.self) {
            try MissingInventoryHostProbe.verify(
                vmStoragePath: root + "/vms", socketDirectory: root + "/sockets",
                jailDirectory: root + "/jails", firecrackerBinaryPath: "/usr/bin/firecracker",
                procDirectory: root + "/proc", needsLibvirtFilesystemProof: true,
                libvirtConfigurationDirectory: root + "/libvirt-config", libvirtStateDirectory: root + "/libvirt-state")
        }
    }

    @Test(
        "Surviving workload artifacts block bootstrap", arguments: ["vms/guest", "sockets/guest.sock", "jails/guest"])
    func survivingArtifacts(path: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/" + path, withIntermediateDirectories: true)
        #expect(throws: MissingInventoryEvidence.self) {
            try MissingInventoryHostProbe.verify(
                vmStoragePath: root + "/vms", socketDirectory: root + "/sockets",
                jailDirectory: root + "/jails", firecrackerBinaryPath: "/usr/bin/firecracker",
                procDirectory: root + "/proc")
        }
    }

    @Test("An unavailable process inventory cannot prove an empty host")
    func missingProcessInventory() throws {
        #if os(Linux)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        #expect(throws: (any Error).self) {
            try MissingInventoryHostProbe.verify(
                vmStoragePath: root + "/vms", socketDirectory: root + "/sockets",
                jailDirectory: root + "/jails", firecrackerBinaryPath: "/usr/bin/firecracker",
                procDirectory: root + "/proc")
        }
        #endif
    }
}
