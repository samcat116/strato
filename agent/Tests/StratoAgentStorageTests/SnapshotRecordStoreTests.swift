import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

/// The agent's durable artifact inventory (STR-150).
///
/// The load contract is the whole subject. An artifact store cannot borrow
/// `VMManifestStore`'s "one bad entry costs one entry" rule, because *absence*
/// is the state a capture acts on: a record that quietly drops out reads as "no
/// such artifact", and the reconciler answers that by re-checkpointing a live
/// guest over the point in time the user is holding.
@Suite("Snapshot record store (STR-150)")
struct SnapshotRecordStoreTests {

    private static let cephStorage = DesiredVolumeStorage.ceph(
        CephVolumeStorage(
            clusterId: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            fsid: "22222222-3333-4444-8555-666666666666",
            pool: "volumes", namespace: "project-a",
            clientName: "client.strato-project-a",
            monEndpoints: ["v2:mon.example:3300"],
            credentialId: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
            keyring: "[client.strato-project-a]\nkey = secret",
            messengerMode: .secure))

    private func withStore(_ body: (SnapshotRecordStore, String) throws -> Void) throws {
        let directory = NSTemporaryDirectory() + "snapshot-records-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = (directory as NSString).appendingPathComponent("snapshot-records.json")
        try body(SnapshotRecordStore(path: path, logger: Logger(label: "test")), path)
    }

    private func record(
        _ id: UUID = UUID(), kind: SnapshotArtifactKind = .vmCheckpoint, exported: Bool = false
    ) -> SnapshotRecord {
        SnapshotRecord(
            snapshotId: id, kind: kind, parentId: UUID(),
            facts: ObservedSnapshotFacts(sizeBytes: 4096, qemuVersion: "9.1.0"),
            exported: exported)
    }

    @Test("A host that has never captured anything reads as fresh")
    func missingFileIsFresh() throws {
        try withStore { store, _ in
            guard case .fresh = store.load() else {
                Issue.record("expected .fresh for a missing record file")
                return
            }
        }
    }

    @Test("Records round-trip through the file, facts and export flag included")
    func recordsRoundTrip() throws {
        try withStore { store, path in
            let id = UUID()
            let saved = record(id, kind: .sandboxSnapshot, exported: true)
            #expect(store.save([id: saved]))

            let mode = try #require(
                FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
                    as? NSNumber)
            #expect(mode.intValue & 0o777 == 0o600)

            guard case .loaded(let loaded) = store.load() else {
                Issue.record("expected .loaded")
                return
            }
            #expect(loaded[id] == saved)
            #expect(loaded[id]?.facts.qemuVersion == "9.1.0")
            #expect(loaded[id]?.exported == true)
        }
    }

    @Test("A local volume snapshot keeps its worst-case disk commitment across restart")
    func localDiskCommitmentRoundTrips() throws {
        try withStore { store, _ in
            let id = UUID()
            let saved = SnapshotRecord(
                snapshotId: id,
                kind: .volumeSnapshot,
                parentId: UUID(),
                volumeStorage: .local,
                reservedDiskBytes: 80 << 30,
                facts: ObservedSnapshotFacts(sizeBytes: 4096))
            #expect(store.save([id: saved]))

            guard case .loaded(let loaded) = store.load() else {
                Issue.record("expected .loaded")
                return
            }
            #expect(loaded[id]?.reservedDiskBytes == 80 << 30)
        }
    }

    @Test("Replacing a legacy snapshot inventory tightens its permissions")
    func replacementTightensPermissions() throws {
        try withStore { store, path in
            #expect(FileManager.default.createFile(atPath: path, contents: Data("{}".utf8)))
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: path)

            #expect(store.save([:]))

            let mode = try #require(
                FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
                    as? NSNumber)
            #expect(mode.intValue & 0o777 == 0o600)
        }
    }

    @Test("A replayed Ceph snapshot keeps its backend after the parent leaves desired state")
    func cephStorageSurvivesReplayWithoutParent() throws {
        try withStore { store, _ in
            let id = UUID()
            let saved = SnapshotRecord(
                snapshotId: id, kind: .volumeSnapshot, parentId: UUID(),
                volumeStorage: Self.cephStorage,
                facts: ObservedSnapshotFacts(storagePath: "rbd://volumes/project-a/image@snap"))
            #expect(store.save([id: saved]))

            guard case .loaded(let loaded) = store.load() else {
                Issue.record("expected .loaded")
                return
            }
            #expect(loaded[id]?.volumeStorage == Self.cephStorage)
            #expect(
                VolumeSnapshotStorageRouting.resolve(
                    desiredStorage: nil,
                    recordedStorage: loaded[id]?.volumeStorage,
                    currentParentStorage: nil) == Self.cephStorage)
        }
    }

    @Test("Credential revocation scrubs keyrings from durable snapshot records")
    func credentialRevocationScrubsDurableKeyring() throws {
        try withStore { store, path in
            let revokedId = UUID()
            let localId = UUID()
            let revoked = SnapshotRecord(
                snapshotId: revokedId, kind: .volumeSnapshot, parentId: UUID(),
                volumeStorage: Self.cephStorage,
                facts: ObservedSnapshotFacts(storagePath: "rbd://volumes/project-a/image@snap"))
            let local = record(localId)
            #expect(store.save([revokedId: revoked, localId: local]))
            let before = try String(contentsOfFile: path, encoding: .utf8)
            #expect(before.contains("key = secret"))

            guard case .ceph(let configuration) = Self.cephStorage else {
                Issue.record("test fixture must be Ceph storage")
                return
            }
            let scrubbed = SnapshotRecordCredentialScrubber.removing(
                clusterId: configuration.clusterId,
                credentialId: configuration.credentialId,
                from: [revokedId: revoked, localId: local])
            #expect(store.save(scrubbed))

            let after = try String(contentsOfFile: path, encoding: .utf8)
            #expect(!after.contains("key = secret"))
            #expect(!after.contains(configuration.credentialId.uuidString))
            guard case .loaded(let loaded) = store.load() else {
                Issue.record("expected scrubbed records to remain readable")
                return
            }
            #expect(loaded[revokedId] == nil)
            #expect(loaded[localId] == local)
        }
    }

    @Test("Desired snapshot storage routes delete before the legacy local fallback")
    func desiredCephStorageRoutesDeleteWithoutParentOrRecord() {
        #expect(
            VolumeSnapshotStorageRouting.resolve(
                desiredStorage: Self.cephStorage,
                recordedStorage: nil,
                currentParentStorage: nil) == Self.cephStorage)
    }

    @Test("A file that is not a record object at all is unreadable")
    func corruptFileIsUnreadable() throws {
        try withStore { store, path in
            try "not json".write(toFile: path, atomically: true, encoding: .utf8)
            guard case .unreadable = store.load() else {
                Issue.record("expected .unreadable for a corrupt file")
                return
            }
        }
    }

    /// The finding this test exists for. A record carrying a `kind` this build
    /// does not understand — a rollback, a future family — must fail the *whole*
    /// load rather than dropping out of the inventory.
    ///
    /// Dropped, it would be absent from `observedSnapshotPresence()`, and
    /// `planCore` answers absence with `[.create]`: for a checkpoint that means
    /// pausing a live guest and writing a new internal snapshot under the same
    /// tag, silently replacing the user's point in time. `.unreadable` instead
    /// makes the agent report `snapshots: nil`, skip the snapshot half of the
    /// sync, and refuse to write over the file.
    @Test("One unreadable record makes the whole inventory unreadable")
    func oneBadRecordFailsTheLoad() throws {
        try withStore { store, path in
            let good = UUID()
            let bad = UUID()
            let json = """
                {
                  "\(good.uuidString)": {
                    "snapshotId": "\(good.uuidString)",
                    "kind": "VMCheckpoint",
                    "parentId": "\(UUID().uuidString)",
                    "facts": {},
                    "exported": false
                  },
                  "\(bad.uuidString)": {
                    "snapshotId": "\(bad.uuidString)",
                    "kind": "RBDSnapshot",
                    "parentId": "\(UUID().uuidString)",
                    "facts": {},
                    "exported": false
                  }
                }
                """
            try json.write(toFile: path, atomically: true, encoding: .utf8)

            guard case .unreadable(let reason) = store.load() else {
                Issue.record("a record this build cannot read must fail the whole load")
                return
            }
            // The reason names the artifact, so an operator can find it.
            #expect(reason.contains(bad.uuidString))
        }
    }

    @Test("A key that is not a UUID also fails the load")
    func nonUUIDKeyFailsTheLoad() throws {
        try withStore { store, path in
            try #"{"not-a-uuid": {}}"#.write(toFile: path, atomically: true, encoding: .utf8)
            guard case .unreadable = store.load() else {
                Issue.record("expected .unreadable for an unparseable key")
                return
            }
        }
    }

    @Test("An empty inventory is a real answer, distinct from an unreadable one")
    func emptyInventoryIsLoaded() throws {
        try withStore { store, _ in
            #expect(store.save([:]))
            guard case .loaded(let loaded) = store.load() else {
                Issue.record("expected .loaded for a written-empty inventory")
                return
            }
            #expect(loaded.isEmpty)
        }
    }
}
