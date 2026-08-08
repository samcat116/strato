#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import Logging

/// What a durable metadata copy read amounts to.
public enum MetadataInventory: Sendable, Equatable {
    /// Nothing to restore: no file, or one this build could not read. Both are
    /// the same state to a listener — this host knows nothing — and both are
    /// recoverable by the next sync, which is why they are not distinguished
    /// beyond the log line the read emits.
    case unknown
    case records([UUID: PersistedMetadataRecord])
}

/// The agent's durable copy of what its metadata service serves (STR-56).
///
/// ## Why this exists at all
///
/// `MetadataStore` is in memory, so without it a restarted agent re-adopts
/// running guests it can tell nothing about until the next sync — and if the
/// control plane is unreachable at that moment, for as long as that lasts. That
/// is the same control-plane outage the whole fail-static design claims immunity
/// to, arriving through the other door. A guest that re-reads its metadata
/// during that window (a cloud-init retry, a config agent) would be told the
/// host has never heard of it.
///
/// ## What it costs
///
/// This file holds SSH authorized keys and cloud-init user data, so it is
/// written `0600`. That is not a new class of exposure — the seed-ISO path
/// (`CloudInitProvisioner`) already writes the same content under the VM
/// storage directory — but it is a new file holding it, and it is written on
/// every sync rather than once at create.
///
/// ## Why an unreadable file may be overwritten
///
/// `SnapshotRecordStore` forbids writing over a file it could not read, because
/// there absence *acts*: a missing record makes the reconciler re-checkpoint a
/// live guest. Nothing here acts on absence. The control plane holds the
/// authoritative copy and re-sends all of it on every sync, so the worst an
/// unreadable file costs is 503s until the next one lands — and refusing to
/// overwrite it would make that permanent.
public struct MetadataSnapshotStore: Sendable {
    public let path: String
    private let logger: Logger

    public init(path: String, logger: Logger) {
        self.path = path
        self.logger = logger
    }

    /// The durable copy, or `.unknown` when there is nothing trustworthy to
    /// restore.
    ///
    /// A partial read is not offered. Unlike the VM manifest, where one bad
    /// entry costs one VM, a half-restored metadata set is indistinguishable
    /// from a complete one to every reader — the listener would answer 404 for
    /// the instances that failed to decode, which is a confident lie. Refusing
    /// the whole file yields 503 instead: honest, and corrected by the next
    /// sync.
    public func load() -> MetadataInventory {
        guard FileManager.default.fileExists(atPath: path) else { return .unknown }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let raw = try JSONDecoder().decode([String: PersistedMetadataRecord].self, from: data)
            var records: [UUID: PersistedMetadataRecord] = [:]
            for (key, value) in raw {
                guard let vmId = UUID(uuidString: key) else {
                    return unreadable("contains a key that is not a VM id: \(key)")
                }
                records[vmId] = value
            }
            return .records(records)
        } catch {
            return unreadable("\(error)")
        }
    }

    /// Atomically replaces the durable copy, `0600` from the moment it holds a
    /// byte.
    ///
    /// Written into a file this method creates `0600` and then `rename(2)`d over
    /// the target, rather than through `Data.write(options: .atomic)`. The
    /// difference matters only because of what is in here: `.atomic` writes its
    /// own temporary file and the mode of *that* file is not ours to choose, so
    /// chmod-after-write leaves a window in which SSH authorized keys and
    /// cloud-init user data sit on disk under whatever mode Foundation picked.
    /// A post-write assertion cannot catch that window, which is why the shape
    /// is different here from `SnapshotRecordStore` — that one holds no secrets.
    @discardableResult
    public func save(_ records: [UUID: PersistedMetadataRecord]) -> Bool {
        let temporaryPath = path + ".tmp"
        do {
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(
                Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) }))

            // Removed first so the attributes are applied to a file this call
            // creates: `createFile` on an existing path truncates it and leaves
            // the old mode.
            try? FileManager.default.removeItem(atPath: temporaryPath)
            guard
                FileManager.default.createFile(
                    atPath: temporaryPath, contents: nil, attributes: [.posixPermissions: 0o600])
            else {
                throw MetadataSnapshotStoreError.couldNotCreateTemporaryFile(temporaryPath)
            }
            try data.write(to: URL(fileURLWithPath: temporaryPath))
            // Same directory, so this is the atomic replace `.atomic` would have
            // done — with a mode we chose.
            guard rename(temporaryPath, path) == 0 else {
                throw MetadataSnapshotStoreError.couldNotReplace(path, errno: errno)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(atPath: temporaryPath)
            logger.error(
                """
                Failed to write the metadata record file; a restart before the next successful write \
                will serve nothing until the first sync lands
                """,
                metadata: ["path": .string(path), "error": .string("\(error)")])
            return false
        }
    }

    private func unreadable(_ reason: String) -> MetadataInventory {
        logger.error(
            """
            Metadata record file is unreadable; this host's metadata service will answer \
            "not available yet" until the next desired-state sync repopulates it
            """,
            metadata: ["path": .string(path), "reason": .string(reason)])
        return .unknown
    }
}

enum MetadataSnapshotStoreError: Error, CustomStringConvertible {
    case couldNotCreateTemporaryFile(String)
    case couldNotReplace(String, errno: CInt)

    var description: String {
        switch self {
        case .couldNotCreateTemporaryFile(let path):
            return "could not create \(path)"
        case .couldNotReplace(let path, let code):
            return "could not replace \(path): errno \(code)"
        }
    }
}
