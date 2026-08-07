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
        try withStore { store, _ in
            let id = UUID()
            let saved = record(id, kind: .sandboxSnapshot, exported: true)
            #expect(store.save([id: saved]))

            guard case .loaded(let loaded) = store.load() else {
                Issue.record("expected .loaded")
                return
            }
            #expect(loaded[id] == saved)
            #expect(loaded[id]?.facts.qemuVersion == "9.1.0")
            #expect(loaded[id]?.exported == true)
        }
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
