import Foundation
import Logging
import StratoShared
import Testing
import StratoAgentTestSupport

@testable import StratoAgentCore

/// Test-only readers for the load result. Deliberately not on the production
/// type: an `entries`-that-defaults-to-empty accessor is exactly the collapse
/// STR-138 removed, and callers must keep being made to handle `.unreadable`.
extension ManifestLoad {
    fileprivate var loadedEntries: [String: VMManifestEntry] {
        guard case .loaded(let entries, _) = self else { return [:] }
        return entries
    }

    fileprivate var loadedQuarantined: [String: QuarantinedManifestEntry] {
        guard case .loaded(_, let quarantined) = self else { return [:] }
        return quarantined
    }

    fileprivate var readFailure: ManifestReadFailure? {
        guard case .unreadable(let failure) = self else { return nil }
        return failure
    }

    fileprivate var isFresh: Bool {
        if case .fresh = self { return true }
        return false
    }
}

@Suite("VMManifestStore Tests")
struct VMManifestStoreTests {

    private func makeStore(dir: String) -> VMManifestStore {
        VMManifestStore(
            path: dir + "/vm-manifest.json",
            logger: Logger(label: "test")
        )
    }

    private func makeSpec(cpus: Int = 2, memoryBytes: Int64 = 2_147_483_648) -> VMSpec {
        VMSpec(cpus: cpus, memoryBytes: memoryBytes, boot: .disk(firmware: nil))
    }

    @Test("Save and load round-trips entries with their hypervisor types")
    func roundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        store.save([
            "vm-a": VMManifestEntry(
                hypervisorType: .qemu,
                spec: makeSpec(cpus: 2),
                realizedMemoryReservationBytes: 8_589_934_592),
            "vm-b": VMManifestEntry(
                hypervisorType: .firecracker,
                spec: makeSpec(cpus: 4, memoryBytes: 1_073_741_824),
                firecrackerMMDSPolicyApplied: true,
                firecrackerMMDSInterfaces: ["eth0", "eth2"]),
        ])

        let loaded = store.load().loadedEntries
        #expect(loaded.count == 2)
        #expect(loaded["vm-a"]?.hypervisorType == .qemu)
        #expect(loaded["vm-a"]?.spec.cpus == 2)
        #expect(loaded["vm-a"]?.realizedMemoryReservationBytes == 8_589_934_592)
        #expect(loaded["vm-b"]?.hypervisorType == .firecracker)
        #expect(loaded["vm-b"]?.spec.cpus == 4)
        #expect(loaded["vm-b"]?.spec.memoryBytes == 1_073_741_824)
        #expect(loaded["vm-b"]?.firecrackerMMDSPolicyApplied == true)
        #expect(loaded["vm-b"]?.firecrackerMMDSInterfaces == ["eth0", "eth2"])
    }

    @Test("A legacy Firecracker entry decodes without an MMDS policy marker")
    func entryWithoutFirecrackerMMDSPolicyDecodes() throws {
        let encoded = try JSONEncoder().encode(
            VMManifestEntry(
                hypervisorType: .firecracker, spec: makeSpec(),
                firecrackerMMDSPolicyApplied: true))
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "firecrackerMMDSPolicyApplied")
        object.removeValue(forKey: "firecrackerMMDSInterfaces")

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(VMManifestEntry.self, from: legacy)

        #expect(decoded.hypervisorType == .firecracker)
        #expect(decoded.firecrackerMMDSPolicyApplied == nil)
        #expect(decoded.firecrackerMMDSInterfaces == nil)
    }

    @Test("Re-specing a Firecracker entry keeps its MMDS policy marker")
    func withSpecKeepsFirecrackerMMDSPolicy() {
        let entry = VMManifestEntry(
            hypervisorType: .firecracker, spec: makeSpec(cpus: 2),
            firecrackerMMDSPolicyApplied: true,
            firecrackerMMDSInterfaces: ["eth0"])

        let resized = entry.with(spec: makeSpec(cpus: 8))

        #expect(resized.firecrackerMMDSPolicyApplied == true)
        #expect(resized.firecrackerMMDSInterfaces == ["eth0"])
    }

    @Test("Firecracker adoption preserves the MMDS policy realized before restart")
    func firecrackerAdoptionPreservesRealizedMMDSPolicy() {
        let interfaceId = UUID()
        let networkId = UUID()
        func network(metadataEnabled: Bool) -> NetworkSpec {
            NetworkSpec(
                interfaceId: interfaceId, deviceName: "net0", orderIndex: 0,
                network: "management", networkId: networkId,
                metadataEnabled: metadataEnabled)
        }
        let realized = makeSpec().withNetworks([network(metadataEnabled: true)])
        let desired = makeSpec(cpus: 8).withNetworks([network(metadataEnabled: false)])
        let entry = VMManifestEntry(
            hypervisorType: .firecracker, spec: realized,
            firecrackerMMDSPolicyApplied: true,
            firecrackerMMDSInterfaces: ["eth0"])

        let adopted = entry.recordingAdoption(of: desired)

        #expect(adopted.spec.cpus == 8)
        #expect(adopted.spec.networks.count == 1)
        #expect(adopted.spec.networks[0].metadataEnabled == true)
        #expect(adopted.firecrackerMMDSPolicyApplied == true)
        #expect(adopted.firecrackerMMDSInterfaces == ["eth0"])
    }

    @Test("QEMU adoption preserves the block policy realized before restart")
    func qemuAdoptionPreservesRealizedBlockPolicy() throws {
        let volumeId = UUID()
        let policy = AppliedBlockDevicePolicy(
            active: true, requestedMode: .direct,
            cacheMode: BlockDeviceCacheMode.none, ioMode: .ioUring,
            discard: true, nonRotational: true, queueCount: 4)
        let realized = makeSpec().withVolumes([
            VolumeSpec(
                volumeId: volumeId, deviceName: .disk(0),
                attachment: .file(path: "/volumes/root.qcow2", format: .qcow2),
                bootOrder: 0, blockMode: .direct, appliedBlockPolicy: policy)
        ])
        let desired = makeSpec(cpus: 4).withVolumes([
            VolumeSpec(
                volumeId: volumeId, deviceName: .disk(0), bootOrder: 0,
                blockMode: .direct)
        ])
        let entry = VMManifestEntry(hypervisorType: .qemu, spec: realized)

        let adopted = entry.recordingAdoption(of: desired)

        #expect(adopted.spec.cpus == 4)
        #expect(try #require(adopted.spec.volumes.first).appliedBlockPolicy == policy)
    }

    @Test("Legacy QEMU adoption reports historical policy without claiming a new disk")
    func legacyQEMUAdoptionRecordsConservativePolicy() throws {
        let legacyVolumeId = UUID()
        let newVolumeId = UUID()
        let realized = makeSpec().withVolumes([
            VolumeSpec(
                volumeId: legacyVolumeId, deviceName: .disk(0),
                attachment: .file(path: "/volumes/root.qcow2", format: .qcow2),
                bootOrder: 0)
        ])
        let desired = makeSpec().withVolumes([
            VolumeSpec(
                volumeId: legacyVolumeId, deviceName: .disk(0), bootOrder: 0,
                blockMode: .direct),
            VolumeSpec(
                volumeId: newVolumeId, deviceName: .disk(1),
                blockMode: .direct),
        ])

        let adopted = VMManifestEntry(hypervisorType: .qemu, spec: realized)
            .recordingAdoption(of: desired)

        let legacy = try #require(adopted.spec.volumes.first { $0.volumeId == legacyVolumeId })
        let applied = try #require(legacy.appliedBlockPolicy)
        #expect(applied.active)
        #expect(applied.requestedMode == .conservative)
        #expect(applied.cacheMode == nil)
        #expect(applied.ioMode == nil)
        #expect(!applied.discard)
        #expect(applied.queueCount == nil)
        #expect(applied.fallbackReason?.contains("predates") == true)

        let notYetAttached = try #require(
            adopted.spec.volumes.first { $0.volumeId == newVolumeId })
        #expect(notYetAttached.appliedBlockPolicy == nil)
    }

    @Test("Disk reservations survive the manifest round-trip")
    func diskReservationRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        let spec = VMSpec(
            cpus: 2, memoryBytes: 1_073_741_824, diskBytes: 21_474_836_480, boot: .disk(firmware: nil))
        store.save(["vm-a": VMManifestEntry(hypervisorType: .qemu, spec: spec)])

        let loaded = store.load().loadedEntries
        #expect(loaded["vm-a"]?.spec.diskBytes == 21_474_836_480)
        #expect(loaded.values.totalReservedDiskBytes == 21_474_836_480)
    }

    @Test("Volume I/O limits survive agent restart through the VM manifest")
    func volumeIOLimitsRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)
        let volumeID = UUID()
        let spec = makeSpec().withVolumes([
            VolumeSpec(
                volumeId: volumeID,
                deviceName: .disk(1),
                attachment: .file(path: "/var/lib/strato/volumes/data/volume.qcow2", format: .qcow2),
                ioLimits: VolumeIOLimits(iopsTotal: 750, bpsTotal: 32 << 20))
        ])

        store.save(["vm-a": VMManifestEntry(hypervisorType: .qemu, spec: spec)])

        let restored = try #require(store.load().loadedEntries["vm-a"]?.spec.volumes.first)
        #expect(restored.volumeId == volumeID)
        #expect(restored.ioLimits == VolumeIOLimits(iopsTotal: 750, bpsTotal: 32 << 20))
    }

    // MARK: - vsock context IDs (STR-72)

    /// The correctness claim of STR-72: a restarted agent has to come back
    /// knowing which CIDs its running VMs hold, or it hands one of them to a
    /// new VM and the two share a control channel.
    @Test("vsock CIDs survive the manifest round-trip")
    func vsockCIDRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        store.save([
            "vm-a": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec(), vsockCID: 7),
            "vm-b": VMManifestEntry(hypervisorType: .firecracker, spec: makeSpec()),
        ])

        let loaded = store.load().loadedEntries
        #expect(loaded["vm-a"]?.vsockCID == 7)
        // Firecracker's vsock never touches the host namespace, so it takes no CID.
        #expect(loaded["vm-b"]?.vsockCID == nil)
    }

    /// Entries written before the allocator existed carry no CID and must
    /// decode rather than throw — a manifest full of pre-STR-72 VMs is the
    /// normal state of every host being upgraded.
    @Test("An entry without a vsock CID decodes with none")
    func entryWithoutVsockCIDDecodes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        store.save(["vm-a": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec(cpus: 2), vsockCID: 7)])
        var raw = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: store.path)))
                as? [String: Any])
        var entry = try #require(raw["vm-a"] as? [String: Any])
        #expect(entry["vsockCID"] != nil)
        entry.removeValue(forKey: "vsockCID")
        raw["vm-a"] = entry
        try JSONSerialization.data(withJSONObject: raw).write(to: URL(fileURLWithPath: store.path))

        let loaded = store.load().loadedEntries
        // Routable, not quarantined: a missing CID is an ordinary pre-STR-72
        // entry, not an entry this build cannot read.
        #expect(loaded.count == 1)
        #expect(loaded["vm-a"]?.vsockCID == nil)
        #expect(loaded["vm-a"]?.spec.cpus == 2)
    }

    /// A spec change must not cost the VM its CID: the entry is copied, not
    /// rebuilt from `(hypervisorType, spec)`.
    @Test("Re-specing an entry keeps its vsock CID")
    func withSpecKeepsVsockCID() {
        let entry = VMManifestEntry(
            hypervisorType: .qemu,
            spec: makeSpec(cpus: 2),
            realizedMemoryReservationBytes: 8_589_934_592,
            vsockCID: 11)
        let resized = entry.with(spec: makeSpec(cpus: 8))

        #expect(resized.vsockCID == 11)
        #expect(resized.realizedMemoryReservationBytes == 8_589_934_592)
        #expect(resized.spec.cpus == 8)
        #expect(resized.hypervisorType == .qemu)
        #expect(resized.kind == .vm)
    }

    // MARK: - Sandbox jail uids (STR-290)

    @Test("Sandbox jail uids survive the manifest round-trip")
    func sandboxJailUIDRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)
        let spec = SandboxSpec(image: "alpine:3", cpus: 2, memoryBytes: 2048)

        store.save(["sandbox-a": VMManifestEntry(sandboxSpec: spec, jailUID: 250_123)])

        let loaded = try #require(store.load().loadedEntries["sandbox-a"])
        #expect(loaded.kind == .sandbox)
        #expect(loaded.jailUID == 250_123)
        #expect(loaded.vsockCID == nil)
    }

    @Test("An explicitly unjailed sandbox stays UID-less across restart")
    func unjailedSandboxRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)
        let spec = SandboxSpec(image: "alpine:3", cpus: 2, memoryBytes: 2048)

        store.save([
            "sandbox-a": VMManifestEntry(
                sandboxSpec: spec, jailUID: nil, jailerUsed: false)
        ])

        let loaded = try #require(store.load().loadedEntries["sandbox-a"])
        #expect(loaded.kind == .sandbox)
        #expect(loaded.jailUID == nil)
        #expect(loaded.jailerUsed == false)
        #expect(!loaded.needsLegacyJailUIDAdoption)
    }

    @Test("A sandbox entry written before STR-290 decodes without a jail uid")
    func entryWithoutSandboxJailUIDDecodes() throws {
        let encoded = try JSONEncoder().encode(
            VMManifestEntry(
                sandboxSpec: SandboxSpec(image: "alpine:3", cpus: 2, memoryBytes: 2048),
                jailUID: 250_123,
                jailerUsed: true))
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["jailUID"] != nil)
        object.removeValue(forKey: "jailUID")
        object.removeValue(forKey: "jailerUsed")

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(VMManifestEntry.self, from: legacy)

        #expect(decoded.kind == .sandbox)
        #expect(decoded.jailUID == nil)
        #expect(decoded.jailerUsed == nil)
        #expect(decoded.needsLegacyJailUIDAdoption)
    }

    @Test("Recording a jail uid preserves the sandbox's durable history")
    func recordingSandboxJailUIDCopiesTheEntry() {
        let entry = VMManifestEntry(
            sandboxSpec: SandboxSpec(image: "alpine:3", cpus: 2, memoryBytes: 2048),
            appliedEdges: AppliedEdgeNonces(reboot: 3, restore: 1))

        let recorded = entry.recordingJailUID(250_123)

        #expect(recorded.kind == .sandbox)
        #expect(recorded.sandboxSpec?.image == entry.sandboxSpec?.image)
        #expect(recorded.sandboxSpec?.cpus == entry.sandboxSpec?.cpus)
        #expect(recorded.appliedEdges == entry.appliedEdges)
        #expect(recorded.jailUID == 250_123)
        #expect(recorded.jailerUsed == true)
    }

    @Test("A legacy sandbox uid adoption is durable across the next manifest load")
    func legacySandboxJailUIDAdoptionPersists() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)
        let sandboxId = "sandbox-written-before-str-290"
        let spec = SandboxSpec(image: "alpine:3", cpus: 2, memoryBytes: 2048)

        // Write a real manifest, then remove only the field an older agent did
        // not know about. This exercises the store shape rather than decoding
        // an isolated entry that is never written back.
        store.save([sandboxId: VMManifestEntry(sandboxSpec: spec, jailUID: 250_123)])
        var manifest = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: store.path)))
                as? [String: Any])
        var legacyEntry = try #require(manifest[sandboxId] as? [String: Any])
        legacyEntry.removeValue(forKey: "jailUID")
        manifest[sandboxId] = legacyEntry
        try JSONSerialization.data(withJSONObject: manifest).write(
            to: URL(fileURLWithPath: store.path))

        var entries = store.load().loadedEntries
        let loadedLegacy = try #require(entries[sandboxId])
        #expect(loadedLegacy.jailUID == nil)

        let adopted = try SandboxJailPlan.legacyUID(sandboxId: sandboxId, uidBase: 100_000)
        entries[sandboxId] = loadedLegacy.recordingJailUID(adopted)
        #expect(store.save(entries))

        let restarted = try #require(store.load().loadedEntries[sandboxId])
        #expect(restarted.jailUID == adopted)
        #expect(restarted.sandboxSpec?.image == spec.image)
        #expect(restarted.sandboxSpec?.cpus == spec.cpus)
        #expect(restarted.sandboxSpec?.memoryBytes == spec.memoryBytes)
    }

    @Test("Boot reservation records growth without crediting a mixed shrink")
    func bootReservationKeepsShrink() {
        let current = makeSpec(cpus: 4, memoryBytes: 2_147_483_648)
        let desired = VMSpec(
            cpus: 2,
            maxCpus: 8,
            memoryBytes: 4_294_967_296,
            maxMemoryBytes: 8_589_934_592,
            boot: .disk(firmware: nil))
        let reserved = VMManifestEntry(hypervisorType: .qemu, spec: current)
            .reservingPositiveSizingGrowth(toward: desired)

        #expect(reserved.spec.cpus == 4)
        #expect(reserved.spec.maxCpus == 8)
        #expect(reserved.spec.memoryBytes == 4_294_967_296)
        #expect(reserved.spec.maxMemoryBytes == 8_589_934_592)
    }

    /// The other field that made copying necessary (STR-151): the record of
    /// what this host has already *done* to the workload. Losing it to a resize
    /// or a volume attach would make the next sync read "no record" and quietly
    /// discard a reboot or restore the user had asked for.
    @Test("Re-specing an entry keeps its applied edge nonces")
    func withSpecKeepsAppliedEdges() {
        let entry = VMManifestEntry(
            hypervisorType: .qemu, spec: makeSpec(cpus: 2),
            appliedEdges: AppliedEdgeNonces(reboot: 3, restore: 1))
        let resized = entry.with(spec: makeSpec(cpus: 8))

        #expect(resized.appliedEdges == AppliedEdgeNonces(reboot: 3, restore: 1))
        #expect(resized.spec.cpus == 8)
    }

    @Test("A sandbox entry keeps its spec and allocated identities through a re-spec")
    func withSpecKeepsSandboxShape() {
        let sandboxSpec = SandboxSpec(image: "alpine:3", cpus: 2, memoryBytes: 2048)
        let entry = VMManifestEntry(sandboxSpec: sandboxSpec, jailUID: 250_123)
        let updated = entry.with(spec: makeSpec(cpus: 4))

        #expect(updated.kind == .sandbox)
        #expect(updated.sandboxSpec?.image == "alpine:3")
        #expect(updated.vsockCID == nil)
        #expect(updated.jailUID == 250_123)
        #expect(updated.hypervisorType == .firecracker)
    }

    /// A quarantined entry's workload may still be running on its CID, and the
    /// namespace is host-global, so the CID is salvaged for the same reason its
    /// CPU and memory are.
    @Test("A quarantined entry still surrenders its vsock CID")
    func quarantinedEntrySalvagesVsockCID() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        store.save(["vm-future": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec(cpus: 8), vsockCID: 42)])
        var raw = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: store.path)))
                as? [String: Any])
        var future = try #require(raw["vm-future"] as? [String: Any])
        future["hypervisorType"] = "libvirt"
        raw["vm-future"] = future
        try JSONSerialization.data(withJSONObject: raw).write(to: URL(fileURLWithPath: store.path))

        let quarantined = try #require(store.load().loadedQuarantined["vm-future"])
        #expect(quarantined.vsockCID == 42)
        #expect(quarantined.cpus == 8)
    }

    @Test("A quarantined sandbox still surrenders its jail uid")
    func quarantinedEntrySalvagesSandboxJailUID() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)
        store.save([
            "sandbox-future": VMManifestEntry(
                sandboxSpec: SandboxSpec(image: "alpine:3", cpus: 1, memoryBytes: 1024),
                jailUID: 250_123)
        ])
        var raw = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: store.path)))
                as? [String: Any])
        var future = try #require(raw["sandbox-future"] as? [String: Any])
        future["hypervisorType"] = "future-firecracker"
        raw["sandbox-future"] = future
        try JSONSerialization.data(withJSONObject: raw).write(to: URL(fileURLWithPath: store.path))

        let quarantined = try #require(store.load().loadedQuarantined["sandbox-future"])
        #expect(quarantined.jailUID == 250_123)
        #expect(quarantined.kind == .sandbox)
    }

    @Test("A quarantined unjailed sandbox preserves its explicit UID-less state")
    func quarantinedEntrySalvagesUnjailedState() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)
        store.save([
            "sandbox-future": VMManifestEntry(
                sandboxSpec: SandboxSpec(image: "alpine:3", cpus: 1, memoryBytes: 1024),
                jailerUsed: false)
        ])
        var raw = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: store.path)))
                as? [String: Any])
        var future = try #require(raw["sandbox-future"] as? [String: Any])
        future["hypervisorType"] = "future-firecracker"
        raw["sandbox-future"] = future
        try JSONSerialization.data(withJSONObject: raw).write(to: URL(fileURLWithPath: store.path))

        let quarantined = try #require(store.load().loadedQuarantined["sandbox-future"])
        #expect(quarantined.jailUID == nil)
        #expect(quarantined.jailerUsed == false)
        #expect(quarantined.kind == .sandbox)
        #expect(!quarantined.needsLegacyJailUIDAdoption)
    }

    @Test("A path-only manifest disk recovers only from a managed desired identity")
    func recoversPathOnlyVolumeIdentity() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)
        let volumeId = UUID()
        let legacyPath = "/var/lib/strato/vms/vm-a/disk.qcow2"
        let managedPath = "/var/lib/strato/vms/vm-a/rootfs.raw"
        let legacySpec = VMSpec(
            cpus: 2, memoryBytes: 1_073_741_824, boot: .disk(firmware: nil),
            volumes: [
                VolumeSpec(
                    volumeId: volumeId, deviceName: .disk(0),
                    attachment: .file(path: legacyPath, format: .qcow2),
                    bootOrder: nil)
            ])
        store.save([
            "vm-a": VMManifestEntry(
                hypervisorType: .firecracker, spec: legacySpec, vsockCID: 19)
        ])

        var raw = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: store.path)))
                as? [String: Any])
        var entry = try #require(raw["vm-a"] as? [String: Any])
        var spec = try #require(entry["spec"] as? [String: Any])
        var volumes = try #require(spec["volumes"] as? [[String: Any]])
        volumes[0].removeValue(forKey: "volumeId")
        volumes[0].removeValue(forKey: "attachment")
        volumes[0]["storagePath"] = legacyPath
        spec["volumes"] = volumes
        entry["spec"] = spec
        raw["vm-a"] = entry
        try JSONSerialization.data(withJSONObject: raw).write(to: URL(fileURLWithPath: store.path))

        let quarantined = try #require(store.load().loadedQuarantined["vm-a"])
        let desired = legacySpec.withVolumes([
            VolumeSpec(
                volumeId: volumeId, deviceName: .disk(0),
                attachment: .file(path: managedPath, format: .raw),
                bootOrder: 0)
        ])
        let recovered = try #require(
            quarantined.recoveringManagedVolumeIdentities(from: desired))
        #expect(recovered.vsockCID == 19)
        #expect(recovered.spec.volumes.count == 1)
        #expect(recovered.spec.volumes[0].volumeId == volumeId)
        #expect(recovered.spec.volumes[0].attachment == .file(path: managedPath, format: .raw))
    }

    @Test("Reserved-disk total treats missing diskBytes and sandbox entries as zero")
    func totalReservedDiskTreatsMissingAsZero() {
        let withDisk = VMSpec(
            cpus: 1, memoryBytes: 268_435_456, diskBytes: 5_368_709_120, boot: .disk(firmware: nil))
        let entries: [String: VMManifestEntry] = [
            "vm-new": VMManifestEntry(hypervisorType: .qemu, spec: withDisk),
            // A spec persisted before diskBytes existed (issue #473).
            "vm-old": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec()),
            // Sandboxes reserve no disk, matching the scheduler.
            "sb-a": VMManifestEntry(
                sandboxSpec: SandboxSpec(image: "ghcr.io/acme/worker:v3", cpus: 1, memoryBytes: 268_435_456)),
        ]
        #expect(entries.values.totalReservedDiskBytes == 5_368_709_120)
    }

    @Test("A host with no manifest at all reads as fresh, not as a failed read")
    func freshWhenMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // The first-boot path, and the one case that may be read as "nothing
        // is running here": no manifest, nothing to salvage. It must stay
        // distinguishable from an unreadable file.
        let load = makeStore(dir: dir).load()
        #expect(load.isFresh)
        #expect(load.readFailure == nil)
        #expect(load.loadedEntries.isEmpty)
    }

    @Test("An empty manifest object still reads as an empty host")
    func emptyObjectLoadsAsEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        try Data("{}".utf8).write(to: URL(fileURLWithPath: store.path))
        let load = store.load()
        #expect(load.readFailure == nil)
        #expect(load.loadedEntries.isEmpty)
        #expect(!load.isFresh)
    }

    // MARK: - Unreadable manifests (STR-138)

    @Test("A manifest that is not JSON reads as unreadable, never as an empty host")
    func corruptManifestIsUnreadable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        try Data("not json".utf8).write(to: URL(fileURLWithPath: store.path))

        let load = store.load()
        #expect(load.readFailure?.path == store.path)
        #expect(!load.isFresh)
        #expect(load.loadedEntries.isEmpty)
    }

    @Test("A truncated manifest reads as unreadable")
    func truncatedManifestIsUnreadable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        store.save([
            "vm-a": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec()),
            "vm-b": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec()),
        ])
        // What a host that lost power mid-write, or filled its filesystem,
        // leaves behind.
        let whole = try Data(contentsOf: URL(fileURLWithPath: store.path))
        try whole.prefix(whole.count / 2).write(to: URL(fileURLWithPath: store.path))

        #expect(store.load().readFailure != nil)
    }

    @Test("A zero-length manifest reads as unreadable")
    func emptyFileIsUnreadable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        try Data().write(to: URL(fileURLWithPath: store.path))
        #expect(store.load().readFailure != nil)
    }

    @Test("An unreadable manifest is preserved byte-for-byte and left in place")
    func unreadableManifestIsPreserved() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        let original = Data("{\"vm-a\": {\"hypervisorType\"".utf8)
        try original.write(to: URL(fileURLWithPath: store.path))

        let failure = try #require(store.load().readFailure)
        let preservedPath = try #require(failure.preservedCopyPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: preservedPath)) == original)
        // A copy, not a move: the original is what a build that understands
        // the file needs to find, and moving it aside would make the next
        // start read the host as fresh.
        #expect(try Data(contentsOf: URL(fileURLWithPath: store.path)) == original)
    }

    @Test("A crash-looping agent leaves one preserved copy, not one per restart")
    func preservationIsDedupedByContent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        try Data("garbage".utf8).write(to: URL(fileURLWithPath: store.path))
        let first = try #require(store.load().readFailure?.preservedCopyPath)
        let second = try #require(store.load().readFailure?.preservedCopyPath)
        #expect(first == second)

        let copies = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.contains(VMManifestStore.preservedSuffix) }
        #expect(copies.count == 1)
    }

    // MARK: - Quarantined entries (STR-138)

    @Test("One entry this build cannot route costs one entry, not the host")
    func unknownHypervisorTypeQuarantinesOneEntry() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        // The rollback scenario: an agent downgraded past a hypervisor backend
        // it once wrote here. The whole dictionary used to decode as a unit, so
        // this single entry discarded every QEMU and Firecracker VM with it.
        let futureSpec = VMSpec(
            cpus: 8, memoryBytes: 8_589_934_592, diskBytes: 10_737_418_240, boot: .disk(firmware: nil))
        store.save([
            "vm-a": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec(cpus: 2)),
            "vm-b": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec(cpus: 4)),
            "vm-c": VMManifestEntry(hypervisorType: .firecracker, spec: makeSpec(cpus: 1)),
            "vm-future": VMManifestEntry(hypervisorType: .qemu, spec: futureSpec),
        ])
        // Rewrite one entry's backend to a case this build has never heard of,
        // leaving everything else exactly as the newer agent wrote it.
        var raw = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: store.path)))
                as? [String: Any])
        var future = try #require(raw["vm-future"] as? [String: Any])
        future["hypervisorType"] = "libvirt"
        raw["vm-future"] = future
        try JSONSerialization.data(withJSONObject: raw).write(to: URL(fileURLWithPath: store.path))

        let load = store.load()
        #expect(load.readFailure == nil)
        #expect(load.loadedEntries.count == 3)
        #expect(load.loadedEntries["vm-a"]?.spec.cpus == 2)
        #expect(load.loadedEntries["vm-c"]?.hypervisorType == .firecracker)

        let quarantined = try #require(load.loadedQuarantined["vm-future"])
        #expect(load.loadedQuarantined.count == 1)
        #expect(quarantined.hypervisorTypeRawValue == "libvirt")
        #expect(quarantined.reason.contains("libvirt"))
        // The safety-critical half: the entry still reserves what it is using,
        // so the scheduler cannot hand that capacity to a new placement.
        #expect(quarantined.cpus == 8)
        #expect(quarantined.memoryBytes == 8_589_934_592)
        #expect(quarantined.diskBytes == 10_737_418_240)
        #expect(quarantined.effectiveKind == .vm)
    }

    @Test("An entry whose spec this build cannot decode is quarantined, not dropped")
    func undecodableSpecQuarantinesOneEntry() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        // A required VMSpec field that isn't there — what rolling back past a
        // spec change looks like on disk.
        let json = """
            {
              "vm-a": {"kind": "vm", "hypervisorType": "qemu", "spec": {"cpus": 3, "memoryBytes": 1024}},
              "sb-a": {"kind": "sandbox", "hypervisorType": "firecracker", "spec": "not-an-object",
                       "sandboxSpec": {"cpus": 2, "memoryBytes": 2048}}
            }
            """
        try Data(json.utf8).write(to: URL(fileURLWithPath: store.path))

        let load = store.load()
        #expect(load.readFailure == nil)
        #expect(load.loadedEntries.isEmpty)
        #expect(load.loadedQuarantined.count == 2)
        #expect(load.loadedQuarantined["vm-a"]?.cpus == 3)
        #expect(load.loadedQuarantined["vm-a"]?.memoryBytes == 1024)
        // Sandbox entries salvage their reservation from `sandboxSpec` when
        // the projected `spec` is the unreadable part.
        #expect(load.loadedQuarantined["sb-a"]?.effectiveKind == .sandbox)
        #expect(load.loadedQuarantined["sb-a"]?.cpus == 2)
        #expect(load.loadedQuarantined["sb-a"]?.memoryBytes == 2048)
    }

    @Test("An entry that is not an object at all is still quarantined")
    func nonObjectEntryIsQuarantined() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        try Data("{\"vm-a\": 7}".utf8).write(to: URL(fileURLWithPath: store.path))

        let load = store.load()
        #expect(load.readFailure == nil)
        // Nothing can be salvaged but the id — which is still enough to refuse
        // to create a second copy of whatever is running under it.
        let quarantined = try #require(load.loadedQuarantined["vm-a"])
        #expect(quarantined.cpus == 0)
        #expect(quarantined.kind == nil)
        #expect(quarantined.effectiveKind == .vm)
    }

    @Test("Saving re-emits quarantined entries verbatim, so rolling forward restores them")
    func savePreservesQuarantinedEntriesVerbatim() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        let json = """
            {"vm-future": {"kind": "vm", "hypervisorType": "libvirt",
                           "spec": {"cpus": 4, "memoryBytes": 4096}, "domainXML": "<domain/>"}}
            """
        try Data(json.utf8).write(to: URL(fileURLWithPath: store.path))

        let quarantined = store.load().loadedQuarantined
        #expect(quarantined.count == 1)

        // The agent creates a VM it *can* route; the write must not drop the
        // entry it cannot, nor rewrite it into a shape this build prefers —
        // the newer build needs the original routing field back.
        store.save(
            ["vm-b": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec())],
            preserving: quarantined)

        let written = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: store.path)))
                as? [String: Any])
        let future = try #require(written["vm-future"] as? [String: Any])
        #expect(future["hypervisorType"] as? String == "libvirt")
        #expect(future["domainXML"] as? String == "<domain/>")
        #expect(written["vm-b"] != nil)

        // And it still quarantines the same way on the next read.
        let reloaded = store.load()
        #expect(reloaded.loadedEntries.keys.sorted() == ["vm-b"])
        #expect(reloaded.loadedQuarantined["vm-future"]?.hypervisorTypeRawValue == "libvirt")
    }

    @Test("Sandbox entries round-trip with their kind, spec, and synthesized reservation")
    func sandboxEntryRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        let sandboxSpec = SandboxSpec(
            image: "ghcr.io/acme/worker:v3", imageDigest: "sha256:abc", cpus: 3, memoryBytes: 536_870_912)
        store.save([
            "vm-a": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec(cpus: 2)),
            "sb-a": VMManifestEntry(sandboxSpec: sandboxSpec),
        ])

        let loaded = store.load().loadedEntries
        #expect(loaded.count == 2)
        #expect(loaded["vm-a"]?.kind == .vm)
        #expect(loaded["vm-a"]?.sandboxSpec == nil)
        #expect(loaded["sb-a"]?.kind == .sandbox)
        #expect(loaded["sb-a"]?.hypervisorType == .firecracker)
        #expect(loaded["sb-a"]?.sandboxSpec?.image == "ghcr.io/acme/worker:v3")
        #expect(loaded["sb-a"]?.sandboxSpec?.imageDigest == "sha256:abc")
        // The reservation projection is what restart-survival capacity
        // accounting reads, for both kinds.
        #expect(loaded["sb-a"]?.spec.cpus == 3)
        #expect(loaded["sb-a"]?.spec.memoryBytes == 536_870_912)
    }

    @Test("An entry missing its required kind is quarantined instead of accepted")
    func kindlessEntryIsQuarantined() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = makeStore(dir: dir)

        struct KindlessEntry: Encodable {
            let hypervisorType: HypervisorType
            let spec: VMSpec
        }
        let kindless = ["vm-old": KindlessEntry(hypervisorType: .firecracker, spec: makeSpec(cpus: 5))]
        try JSONEncoder().encode(kindless).write(to: URL(fileURLWithPath: store.path))

        let load = store.load()
        #expect(load.loadedEntries.isEmpty)
        let quarantined = try #require(load.loadedQuarantined["vm-old"])
        #expect(quarantined.kind == nil)
        #expect(quarantined.hypervisorTypeRawValue == HypervisorType.firecracker.rawValue)
        #expect(quarantined.cpus == 5)
        #expect(quarantined.effectiveKind == .vm)
    }

    @Test("Save creates intermediate directories")
    func savesIntoMissingDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = VMManifestStore(
            path: dir + "/nested/deeper/vm-manifest.json",
            logger: Logger(label: "test")
        )

        store.save(["vm-a": VMManifestEntry(hypervisorType: .qemu, spec: makeSpec())])
        #expect(store.load().loadedEntries["vm-a"]?.spec.cpus == 2)
    }
}
