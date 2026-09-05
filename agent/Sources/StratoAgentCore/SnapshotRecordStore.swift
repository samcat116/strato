import Foundation
import Logging
import StratoShared

/// One snapshot artifact this host holds, and everything the control plane
/// learns about it (ADR 0001 stage 8, STR-150).
///
/// This is the agent's *memory* of a capture, and it exists for the same reason
/// `VMManifestStore` does: the artifact's own bytes cannot answer the questions
/// the observed report has to answer on every heartbeat. A qcow2 internal
/// snapshot's footprint and the QEMU build that wrote it come out of a
/// `qemu-img info` subprocess; a Firecracker checkpoint's fork-layout version
/// and CPU template are not recoverable from the files at all. Re-probing them
/// per artifact per report is not affordable on a dense host, and re-deriving
/// them is in several cases impossible — so they are recorded once, when the
/// only party that can measure them does.
///
/// That argument is about *those* artifacts, and one fact escapes it: a volume
/// snapshot's footprint is a `stat` of a plain file, and it has to be re-read,
/// because an overlay grows after capture and the control plane exposes that
/// live allocation (STR-181). The re-measurement happens on the report path as
/// `ObservedSnapshotFacts.currentSizeBytes` (see ``SnapshotFootprint``). Nothing
/// writes it back here, so this record stays what it says it is — the memory of
/// the capture.
public struct SnapshotRecord: Codable, Sendable, Equatable {
    public let snapshotId: UUID
    public let kind: SnapshotArtifactKind
    /// The volume/VM/sandbox the artifact was captured from. Recorded because
    /// deleting it needs the pair — the agent re-derives an artifact's location
    /// from (parent, snapshot) exactly as it did at capture.
    public let parentId: UUID
    /// Backend coordinates used for a volume snapshot. Optional so records
    /// written before wire v54 remain readable; legacy entries fall back to a
    /// current parent volume only when no authoritative snapshot value exists.
    public let volumeStorage: DesiredVolumeStorage?
    /// Worst-case host-local bytes this artifact may add. Volume snapshot
    /// overlays can grow to the parent's full virtual size after capture, so
    /// their commitment must survive agent restarts even while still sparse.
    public let reservedDiskBytes: Int64?
    public var facts: ObservedSnapshotFacts
    /// Whether this host has finished streaming the artifact to the export
    /// slots a sync asked for. Durable, so an agent restart mid-rollout does
    /// not re-upload a whole archive that already landed.
    public var exported: Bool

    public init(
        snapshotId: UUID,
        kind: SnapshotArtifactKind,
        parentId: UUID,
        volumeStorage: DesiredVolumeStorage? = nil,
        reservedDiskBytes: Int64? = nil,
        facts: ObservedSnapshotFacts,
        exported: Bool = false
    ) {
        self.snapshotId = snapshotId
        self.kind = kind
        self.parentId = parentId
        self.volumeStorage = volumeStorage
        self.reservedDiskBytes = reservedDiskBytes
        self.facts = facts
        self.exported = exported
    }
}

/// One ordering for volume-snapshot backend identity, shared by capture and
/// deletion so a later refactor cannot reintroduce a local default ahead of
/// the durable Ceph coordinates.
public enum VolumeSnapshotStorageRouting {
    public static func resolve(
        desiredStorage: DesiredVolumeStorage?,
        recordedStorage: DesiredVolumeStorage?,
        currentParentStorage: DesiredVolumeStorage?
    ) -> DesiredVolumeStorage {
        recordedStorage ?? desiredStorage ?? currentParentStorage ?? .local
    }
}

/// Removes durable copies of a revoked Ceph credential from snapshot metadata.
/// Snapshot records predate the revocation ledger and carry full desired
/// storage so an off-parent delete can still route; that includes the keyring,
/// so a credential tombstone must scrub records that are no longer desired.
public enum SnapshotRecordCredentialScrubber {
    public static func removing(
        clusterId: UUID,
        credentialId: UUID,
        from records: [UUID: SnapshotRecord]
    ) -> [UUID: SnapshotRecord] {
        records.filter { _, record in
            guard case .ceph(let configuration) = record.volumeStorage else { return true }
            return configuration.clusterId != clusterId
                || configuration.credentialId != credentialId
        }
    }
}

/// The result of reading the snapshot inventory, with "I don't know" spelled
/// differently from "there is nothing here" — `ManifestLoad`'s distinction, for
/// the same reason and with sharper stakes.
///
/// An empty inventory is authoritative to everything downstream: the control
/// plane reads omission from a full list as confirmation that an artifact's
/// bytes are gone, and reaps the row. A host that cannot read its own record
/// file must therefore be able to say so rather than report nothing.
public enum SnapshotInventory: Sendable {
    /// No record file: a host that has never captured anything. The only case
    /// that may be read as "this host holds no artifacts".
    case fresh
    case loaded([UUID: SnapshotRecord])
    /// The file exists but could not be read or parsed.
    case unreadable(reason: String)
}

/// Persists the snapshot artifacts an agent holds, across all three families,
/// to one file.
///
/// One file rather than three because the reconciler treats them as one
/// inventory and the report carries one list; the record's `kind` is what
/// routes a capture or a delete to a backend.
///
/// Records are decoded one at a time so the *reason* a load failed is per-entry
/// and reportable — but unlike `VMManifestStore`, a single unreadable entry
/// fails the whole load. See `load()` for why an artifact store cannot afford
/// that rule: absence is the state a capture acts on.
public struct SnapshotRecordStore: Sendable {
    public let path: String
    let logger: Logger

    public init(path: String, logger: Logger) {
        self.path = path
        self.logger = logger
    }

    public func load() -> SnapshotInventory {
        guard FileManager.default.fileExists(atPath: path) else { return .fresh }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            return unreadable("could not be read: \(error)")
        }

        // Decoded to raw JSON per entry first, so an artifact carrying a field
        // (or a `kind`) this build does not understand drops alone.
        let raw: [String: JSONValue]
        do {
            raw = try JSONDecoder().decode([String: JSONValue].self, from: data)
        } catch {
            return unreadable("is not a readable snapshot record object: \(error)")
        }

        var records: [UUID: SnapshotRecord] = [:]
        var skipped: [String] = []
        for (key, value) in raw {
            guard let id = UUID(uuidString: key) else {
                skipped.append(key)
                continue
            }
            do {
                records[id] = try value.decode(as: SnapshotRecord.self)
            } catch {
                skipped.append(key)
            }
        }
        guard skipped.isEmpty else {
            // One unreadable record makes the *whole* inventory unreadable, and
            // this is where an artifact store has to depart from
            // `VMManifestStore`'s "one bad entry costs one entry" rule.
            //
            // A manifest entry that drops out becomes a `.quarantined` presence:
            // known to exist, unroutable, never re-created. There is no
            // equivalent here, and not by omission — `planSnapshots` partitions
            // the presence map by `artifact.kind`, and a record that failed to
            // decode has no kind to partition by, so a quarantined entry would
            // fall out of every family's map and read as absent anyway.
            //
            // Absent is the one state that *acts*: a capture is the create
            // strategy for an artifact the host does not have, so a dropped
            // record would make the reconciler re-checkpoint a live guest over
            // the point in time the user is holding — silently, since the
            // control-plane row is untouched and its entry keeps riding every
            // sync. The safety property this conversion rests on holds against a
            // replayed sync; it cannot hold against a lossy inventory read, so
            // the read refuses to be lossy.
            //
            // The cost is one sync's worth of snapshot convergence on this host
            // and a leak an operator can see. The artifacts stay on disk either
            // way; what this buys is that none of them is overwritten.
            return unreadable(
                "contains \(skipped.count) record(s) this build cannot read "
                    + "(\(skipped.sorted().joined(separator: ", ")))")
        }
        return .loaded(records)
    }

    /// Atomically and durably writes the inventory. Callers must not write
    /// while the file is unreadable — the first write after a failed read is
    /// what turns a recoverable file into a permanent loss,
    /// `VMManifestStore.save`'s rule.
    @discardableResult
    public func save(_ records: [UUID: SnapshotRecord]) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(
                Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) }))
            // A volume-snapshot record carries its Ceph desired storage so a
            // later agent can route deletion after the parent volume moves.
            // That storage includes the cephx keyring; publish the inventory
            // with owner-only permissions, including when replacing a legacy
            // file that was created with the writer's ordinary 0666 mode.
            try DurableFileWriter().write(data, to: path, permissions: 0o600)
            return true
        } catch {
            logger.error("Failed to write snapshot records at \(path): \(error)")
            return false
        }
    }

    private func unreadable(_ reason: String) -> SnapshotInventory {
        logger.error(
            """
            Snapshot record file is unreadable; this host cannot say which checkpoints it holds, \
            so it will report none and converge no snapshot work until the file is repaired or removed
            """,
            metadata: ["path": .string(path), "reason": .string(reason)])
        return .unreadable(reason: reason)
    }
}
