import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("Metadata Persistence Tests")
struct MetadataPersistenceTests {

    private static func temporaryPath() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("metadata-\(UUID().uuidString).json")
    }

    private static func store(_ path: String) -> MetadataSnapshotStore {
        MetadataSnapshotStore(path: path, logger: Logger(label: "test"))
    }

    private static func metadata(_ vmId: UUID, hostname: String? = nil) -> InstanceMetadata {
        InstanceMetadata(
            instanceId: vmId, hostname: hostname, projectId: UUID(), sshAuthorizedKeys: ["ssh-ed25519 AAA"])
    }

    // MARK: - The durable copy

    @Test("Records survive a round trip, withdrawals and generations included")
    func roundTrip() throws {
        let path = Self.temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = Self.store(path)

        let served = UUID()
        let withdrawn = UUID()
        let records: [UUID: PersistedMetadataRecord] = [
            served: PersistedMetadataRecord(
                generation: 7, metadata: Self.metadata(served, hostname: "web-01"), withdrawn: false),
            // Carries no payload, but it carries the generation that refuses a
            // late replay of the sync which still listed the VM. Dropping it at
            // the file boundary would resurrect that VM once per agent restart.
            withdrawn: PersistedMetadataRecord(generation: 9, metadata: nil, withdrawn: true),
        ]

        #expect(store.save(records))
        guard case .records(let loaded) = store.load() else {
            Issue.record("a file just written must be readable")
            return
        }
        #expect(loaded == records)
        #expect(loaded[withdrawn]?.withdrawn == true)
        #expect(loaded[withdrawn]?.generation == 9)
    }

    @Test("The record file is not world-readable")
    func fileIsPrivate() throws {
        // It holds SSH authorized keys and cloud-init user data.
        let path = Self.temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = Self.store(path)
        let vmId = UUID()

        #expect(
            store.save([vmId: PersistedMetadataRecord(generation: 1, metadata: Self.metadata(vmId), withdrawn: false)]))
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)

        // And a second save keeps it that way — `.atomic` replaces the file by
        // rename, so the mode has to be reapplied every time.
        #expect(
            store.save([vmId: PersistedMetadataRecord(generation: 2, metadata: Self.metadata(vmId), withdrawn: false)]))
        let modeAgain = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(modeAgain?.int16Value == 0o600)
    }

    @Test("An absent file restores nothing rather than an empty world")
    func absentFile() {
        #expect(Self.store(Self.temporaryPath()).load() == .unknown)
    }

    @Test("A corrupt or foreign file restores nothing, and is not partially believed")
    func unreadableFiles() throws {
        // A half-restored set is indistinguishable from a complete one to the
        // listener, which would then answer 404 — a confident lie — for the
        // instances that failed to decode.
        for contents in ["{", "[]", "{\"not-a-uuid\": {\"generation\": 1, \"withdrawn\": false}}"] {
            let path = Self.temporaryPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            try contents.write(toFile: path, atomically: true, encoding: .utf8)
            #expect(Self.store(path).load() == .unknown, "\(contents) must not be believed")
        }
    }

    @Test("An unreadable file may be overwritten, unlike a snapshot inventory")
    func unreadableFileIsRecoverable() throws {
        // Nothing here acts on absence: the control plane re-sends everything
        // on every sync, so refusing to overwrite would make the outage
        // permanent instead of one sync long.
        let path = Self.temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "{".write(toFile: path, atomically: true, encoding: .utf8)
        let store = Self.store(path)
        #expect(store.load() == .unknown)

        let vmId = UUID()
        #expect(
            store.save([vmId: PersistedMetadataRecord(generation: 1, metadata: Self.metadata(vmId), withdrawn: false)]))
        guard case .records(let loaded) = store.load() else {
            Issue.record("the file should be readable again")
            return
        }
        #expect(loaded.count == 1)
    }

    // MARK: - Readiness

    @Test("A store that has neither synced nor restored knows nothing")
    func coldStore() async {
        let store = MetadataStore()
        #expect(await store.origin() == .cold)
    }

    @Test("Restoring is knowledge, even when the restored set is empty")
    func restoredStore() async {
        // "This host served nothing when it last ran" is an answer; "I have not
        // looked" is not.
        let store = MetadataStore()
        await store.restore([:])
        #expect(await store.origin() == .restored)
    }

    @Test("A sync outranks a restore, even one carrying no VMs")
    func syncedStore() async {
        let store = MetadataStore()
        await store.restore([:])
        await store.markSyncApplied()
        #expect(await store.origin() == .live)
    }

    // MARK: - Export and restore

    @Test("Export carries generations and seals, not just payloads")
    func exportIncludesWithdrawals() async {
        let store = MetadataStore()
        let served = UUID()
        let gone = UUID()
        await store.apply(Self.metadata(served), generation: 3, for: served)
        await store.apply(Self.metadata(gone), generation: 4, for: gone)
        await store.withdraw(gone, generation: 5, because: .tornDown)

        let exported = await store.exportRecords()
        #expect(exported[served]?.generation == 3)
        #expect(exported[served]?.metadata != nil)
        #expect(exported[gone]?.withdrawn == true)
        #expect(exported[gone]?.metadata == nil)
        #expect(exported[gone]?.generation == 5)
    }

    @Test("A restored withdrawal still refuses a replay of the sync that preceded it")
    func restoreKeepsTheSeal() async {
        let vmId = UUID()
        let persisted: [UUID: PersistedMetadataRecord] = [
            vmId: PersistedMetadataRecord(generation: 5, metadata: nil, withdrawn: true)
        ]
        let store = MetadataStore()
        await store.restore(persisted)

        // The same generation that withdrew it must not bring it back.
        let replay = await store.apply(Self.metadata(vmId), generation: 5, for: vmId)
        #expect(replay == .stale(recorded: 5))
        #expect(await store.metadata(for: vmId) == nil)

        // A strictly newer sync still corrects it — level-triggering survives.
        let newer = await store.apply(Self.metadata(vmId), generation: 6, for: vmId)
        #expect(newer == .applied)
        #expect(await store.metadata(for: vmId) != nil)
    }

    @Test("A restore racing a sync cannot roll a VM backward")
    func restoreIsForwardOnly() async {
        let vmId = UUID()
        let store = MetadataStore()
        await store.apply(Self.metadata(vmId, hostname: "current"), generation: 10, for: vmId)

        await store.restore([
            vmId: PersistedMetadataRecord(
                generation: 2, metadata: Self.metadata(vmId, hostname: "stale"), withdrawn: false)
        ])

        #expect(await store.metadata(for: vmId)?.hostname == "current")
        #expect(await store.appliedGeneration(for: vmId) == 10)
    }

    @Test("A store round-trips through the durable copy with its guards intact")
    func storeSurvivesRestart() async {
        let path = Self.temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let file = Self.store(path)

        let served = UUID()
        let gone = UUID()
        let before = MetadataStore()
        await before.apply(Self.metadata(served, hostname: "web-01"), generation: 3, for: served)
        await before.withdraw(gone, generation: 4, because: .tornDown)
        #expect(file.save(await before.exportRecords()))

        // A fresh process reads it back.
        let after = MetadataStore()
        guard case .records(let records) = file.load() else {
            Issue.record("the durable copy should be readable")
            return
        }
        await after.restore(records)

        #expect(await after.origin() == .restored)
        #expect(await after.metadata(for: served)?.hostname == "web-01")
        #expect(await after.metadata(for: gone) == nil)
        #expect(await after.snapshot().count == 1)
    }
}
