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
            instanceId: vmId, hostname: hostname, projectId: UUID(),
            sshAuthorizedKeys: ["ssh-ed25519 AAA"], serviceEnabled: true)
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

    @Test("The record file is never on disk under a wider mode, even momentarily")
    func temporaryFileIsAlsoPrivate() throws {
        // The mode is asserted on the *temporary* file, because that is where
        // the window was: an atomic write puts the secrets in a file whose mode
        // is not ours to choose and then renames it, so a post-write check
        // cannot see the exposure it is meant to rule out.
        let path = Self.temporaryPath()
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".tmp")
        }
        // Stand in for a leftover temporary from a crashed save, world-readable.
        FileManager.default.createFile(
            atPath: path + ".tmp", contents: Data("stale".utf8), attributes: [.posixPermissions: 0o644])

        let vmId = UUID()
        #expect(
            Self.store(path).save([
                vmId: PersistedMetadataRecord(generation: 1, metadata: Self.metadata(vmId), withdrawn: false)
            ]))

        // The stale temporary was replaced rather than reused, and nothing is
        // left behind holding SSH keys.
        #expect(!FileManager.default.fileExists(atPath: path + ".tmp"))
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)
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

    // MARK: - Arbitrating a restore against the first sync

    @Test("A VM deleted while the agent was down does not come back as a servable ghost")
    func unconfirmedRestoreIsRetired() async {
        // The reachable path: the agent is down, the VM is deleted and reaped,
        // so no sync ever carries a `wantsAbsent` entry and no teardown runs.
        // Nothing else in the store removes a record, so without arbitration the
        // payload stays servable for the life of the host — and IPAM hands its
        // address to somebody else.
        let survivor = UUID()
        let deleted = UUID()
        let store = MetadataStore()
        await store.restore([
            survivor: PersistedMetadataRecord(
                generation: 4, metadata: Self.metadata(survivor, hostname: "still-here"), withdrawn: false),
            deleted: PersistedMetadataRecord(
                generation: 4, metadata: Self.metadata(deleted, hostname: "long-gone"), withdrawn: false),
        ])
        #expect(await store.snapshot().count == 2)

        // The first authoritative sync names only the survivor.
        await store.apply(Self.metadata(survivor, hostname: "still-here"), generation: 5, for: survivor)
        let retired = await store.confirmRestored(namedBy: [survivor])

        #expect(retired == [deleted])
        #expect(await store.metadata(for: deleted) == nil)
        #expect(await store.snapshot().keys.sorted { $0.uuidString < $1.uuidString } == [survivor])
    }

    @Test("A retired ghost is withdrawn rather than deleted, so a replay cannot resurrect it")
    func retiredGhostKeepsItsSeal() async {
        // Deleting outright would fix the disclosure and reopen the
        // resurrection the seal exists for.
        let ghost = UUID()
        let store = MetadataStore()
        await store.restore([
            ghost: PersistedMetadataRecord(generation: 4, metadata: Self.metadata(ghost), withdrawn: false)
        ])
        await store.confirmRestored(namedBy: [])

        #expect(await store.appliedGeneration(for: ghost) == 4)
        #expect(await store.apply(Self.metadata(ghost), generation: 4, for: ghost) == .stale(recorded: 4))
        #expect(await store.metadata(for: ghost) == nil)

        // A genuinely newer sync — the VM being recreated — still gets through.
        #expect(await store.apply(Self.metadata(ghost), generation: 5, for: ghost) == .applied)
    }

    @Test("A record this process learned from a sync is never retired by arbitration")
    func syncedRecordsAreNotProvisional() async {
        // STR-98's rule stands for records a sync vouched for: omission is not
        // an instruction. Arbitration applies only to what came off the disk.
        let vmId = UUID()
        let store = MetadataStore()
        await store.apply(Self.metadata(vmId, hostname: "web-01"), generation: 2, for: vmId)

        let retired = await store.confirmRestored(namedBy: [])
        #expect(retired.isEmpty)
        #expect(await store.metadata(for: vmId)?.hostname == "web-01")
    }

    @Test("Arbitration runs once: a later sync cannot retire what the first one confirmed")
    func arbitrationIsOneShot() async {
        let vmId = UUID()
        let store = MetadataStore()
        await store.restore([
            vmId: PersistedMetadataRecord(generation: 1, metadata: Self.metadata(vmId), withdrawn: false)
        ])

        // The first sync names it, so it is confirmed and no longer provisional.
        await store.confirmRestored(namedBy: [vmId])
        #expect(await store.metadata(for: vmId) != nil)

        // A later sync that happens not to carry it must not retire it — that is
        // an ordinary omission.
        #expect(await store.confirmRestored(namedBy: []).isEmpty)
        #expect(await store.metadata(for: vmId) != nil)
    }

    @Test("Retiring a restored tombstone is not reported as a loss")
    func restoredTombstonesRetireQuietly() async {
        // The ordinary end state of a VM that left cleanly: it is already
        // withdrawn, so there is nothing to warn about.
        let gone = UUID()
        let store = MetadataStore()
        await store.restore([
            gone: PersistedMetadataRecord(generation: 3, metadata: nil, withdrawn: true)
        ])
        #expect(await store.confirmRestored(namedBy: []).isEmpty)
        #expect(await store.appliedGeneration(for: gone) == 3)
    }
}
