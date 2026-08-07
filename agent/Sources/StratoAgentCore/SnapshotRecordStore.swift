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
public struct SnapshotRecord: Codable, Sendable, Equatable {
    public let snapshotId: UUID
    public let kind: SnapshotArtifactKind
    /// The volume/VM/sandbox the artifact was captured from. Recorded because
    /// deleting it needs the pair — the agent re-derives an artifact's location
    /// from (parent, snapshot) exactly as it did at capture.
    public let parentId: UUID
    public var facts: ObservedSnapshotFacts
    /// Whether this host has finished streaming the artifact to the export
    /// slots a sync asked for. Durable, so an agent restart mid-rollout does
    /// not re-upload a whole archive that already landed.
    public var exported: Bool

    public init(
        snapshotId: UUID,
        kind: SnapshotArtifactKind,
        parentId: UUID,
        facts: ObservedSnapshotFacts,
        exported: Bool = false
    ) {
        self.snapshotId = snapshotId
        self.kind = kind
        self.parentId = parentId
        self.facts = facts
        self.exported = exported
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
/// Records are decoded one at a time, `VMManifestStore`'s rule: one artifact
/// this build cannot read must cost one artifact, not the host's whole
/// inventory — which, read as an empty list, would reap every snapshot row the
/// control plane holds for this agent.
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
        let raw: [String: AnyCodableValue]
        do {
            raw = try JSONDecoder().decode([String: AnyCodableValue].self, from: data)
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
        if !skipped.isEmpty {
            // Loud, and deliberately *not* fatal to the load: these artifacts
            // stay on disk and are simply not reported, so the control plane
            // treats them as absent. That is a leak an operator can see and
            // clean up — the opposite trade from discarding the whole file,
            // which would report a host full of artifacts as empty.
            logger.error(
                "Skipping snapshot records this build cannot read; their artifacts are leaked on this host",
                metadata: [
                    "path": .string(path),
                    "skipped": .stringConvertible(skipped.count),
                    "readable": .stringConvertible(records.count),
                    "snapshotIds": .string(skipped.sorted().joined(separator: ",")),
                ])
        }
        return .loaded(records)
    }

    /// Atomically writes the inventory. Callers must not write while the file
    /// is unreadable — the first write after a failed read is what turns a
    /// recoverable file into a permanent loss, `VMManifestStore.save`'s rule.
    @discardableResult
    public func save(_ records: [UUID: SnapshotRecord]) -> Bool {
        do {
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(
                Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) }))
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
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
