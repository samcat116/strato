import Foundation
import Logging

/// A warm-start snapshot's identity (issue #426): everything that must match
/// for a template snapshot to be safely restored into a new sandbox.
///
/// Firecracker snapshots are tied to the VMM build, the machine shape, and
/// the exact rootfs bytes the guest had mounted at snapshot time, so the key
/// covers all of them:
///
/// - `imageDigest` — the flattened rootfs the template booted (the restored
///   guest's page cache must describe the same bytes);
/// - `guestVersion`/`arch` — the guest kernel + init that produced the held
///   memory image;
/// - `firecrackerFingerprint` — a cheap identity for the Firecracker binary
///   (snapshots do not load across Firecracker versions);
/// - `vcpus`/`memoryMiB` — the machine shape baked into memory + vmstate;
/// - `configCapacityBytes` — the config drive's block-device capacity, also
///   baked into the saved virtio state (restores stage a different document
///   at the same capacity);
/// - `jailed` — jailed snapshots record chroot-relative drive paths,
///   unjailed ones absolute paths, so the two never mix;
/// - `cpuTemplate` — the guest-visible CPU surface baked into the held
///   memory (issue #428); a templated sandbox must never restore a
///   passthrough template snapshot or vice versa;
/// - `nicCount` — how many network devices the template's topology has
///   (STR-104). Firecracker will not add or drop devices on load, so a
///   template built without a NIC can only ever produce a sandbox without
///   one. Keying on the shape is what makes that a cache miss and a cold
///   boot, rather than a warm restore that reports healthy while the
///   sandbox has no interface at all.
public struct WarmSnapshotKey: Sendable, Equatable {
    public let imageDigest: String
    public let guestVersion: String
    public let arch: String
    public let firecrackerFingerprint: String
    public let vcpus: Int
    public let memoryMiB: Int64
    public let configCapacityBytes: Int
    public let jailed: Bool
    public let cpuTemplate: String?
    public let nicCount: Int

    public init(
        imageDigest: String,
        guestVersion: String,
        arch: String,
        firecrackerFingerprint: String,
        vcpus: Int,
        memoryMiB: Int64,
        configCapacityBytes: Int,
        jailed: Bool,
        cpuTemplate: String? = nil,
        nicCount: Int = 0
    ) {
        self.imageDigest = imageDigest
        self.guestVersion = guestVersion
        self.arch = arch
        self.firecrackerFingerprint = firecrackerFingerprint
        self.vcpus = vcpus
        self.memoryMiB = memoryMiB
        self.configCapacityBytes = configCapacityBytes
        self.jailed = jailed
        self.cpuTemplate = cpuTemplate
        self.nicCount = nicCount
    }

    /// The cache entry directory name for this key. Every component is
    /// filesystem-sanitized; the digest keeps its full hex so distinct images
    /// can never collide into one entry (a collision would boot the wrong
    /// workload).
    public var directoryName: String {
        var components = [
            Self.sanitize(imageDigest),
            Self.sanitize(guestVersion),
            Self.sanitize(arch),
            Self.sanitize(firecrackerFingerprint),
            "\(vcpus)c",
            "\(memoryMiB)m",
            "\(configCapacityBytes)cfg",
            jailed ? "jailed" : "flat",
        ]
        // Appended only when set, so pre-existing passthrough cache entries
        // keep their names (and stay valid) across the agent upgrade.
        if let cpuTemplate {
            components.append(Self.sanitize(cpuTemplate) + "tpl")
        }
        // Same reasoning: a networkless template's directory name is unchanged
        // by STR-104, so entries built by an older agent stay hits for exactly
        // the sandboxes they were always valid for.
        if nicCount > 0 {
            components.append("\(nicCount)nic")
        }
        return components.joined(separator: "_")
    }

    /// Replace everything outside `[A-Za-z0-9._-]` with `-` so registry
    /// digests (`sha256:...`) and arbitrary version strings become safe
    /// single-path-component names.
    static func sanitize(_ component: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return String(component.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }
}

/// A resolved warm cache entry: the artifact paths a restore stages from.
public struct WarmSnapshotEntry: Sendable, Equatable {
    public let directory: String
    public var memoryPath: String { directory + "/" + WarmSandboxSnapshotCache.memoryFile }
    public var vmstatePath: String { directory + "/" + WarmSandboxSnapshotCache.vmstateFile }
    public var rootfsPath: String { directory + "/" + WarmSandboxSnapshotCache.rootfsFile }

    public init(directory: String) {
        self.directory = directory
    }
}

/// Agent-local cache of warm-start template snapshots (issue #426), keyed by
/// ``WarmSnapshotKey``, one directory per entry:
///
/// ```
/// <root>/
///   <key.directoryName>/
///     memory.snap      # template guest memory, snapshotted at the held point
///     vmstate.snap     # matching VMM/device state
///     rootfs.ext4      # the template's rootfs AS OF the snapshot (mounted
///                      # once by the template guest — restores must clone
///                      # exactly these bytes, not the pristine image)
///     meta.json        # diagnostics + durable artifact integrity proof
///   .staging-<uuid>/   # in-progress builds, atomically renamed into place
/// ```
///
/// Follows the `OCIRootfsCache` publish discipline (stage into a dot-prefixed
/// directory, atomic rename) and delegates eviction to ``DiskCacheLRU`` with
/// directory-mtime-as-last-use, so a `touch` on lookup keeps hot entries
/// resident.
public struct WarmSandboxSnapshotCache: Sendable {
    /// One abandoned staging path housekeeping could not inspect or remove.
    /// Staging debris consumes disk but cannot identify or authorize a live
    /// workload, so callers report these failures without gating creation.
    public typealias StagingCleanupFailure = DiskCacheLRU.StagingCleanupFailure

    public static let memoryFile = "memory.snap"
    public static let vmstateFile = "vmstate.snap"
    public static let rootfsFile = "rootfs.ext4"
    public static let metaFile = "meta.json"

    public let rootPath: String

    public init(rootPath: String) {
        self.rootPath = rootPath
    }

    /// Sidecar written next to the artifacts. `templateId`/`templateNonce`
    /// are load-bearing: the snapshotted guest memory carries them, and the
    /// restore path requires a held guest to echo exactly this identity
    /// before launching a workload into it. The rest is diagnostics.
    public struct Meta: Codable, Sendable, Equatable {
        public struct ArtifactIntegrity: Codable, Sendable, Equatable {
            public let memorySizeBytes: Int64
            public let vmstateSizeBytes: Int64
            public let rootfsSizeBytes: Int64
            public let rootfsSHA256: String

            init(
                memorySizeBytes: Int64, vmstateSizeBytes: Int64,
                rootfsSizeBytes: Int64, rootfsSHA256: String
            ) {
                self.memorySizeBytes = memorySizeBytes
                self.vmstateSizeBytes = vmstateSizeBytes
                self.rootfsSizeBytes = rootfsSizeBytes
                self.rootfsSHA256 = rootfsSHA256
            }
        }

        /// The throwaway template microVM's id, echoed by the held guest.
        public let templateId: String
        /// The template's boot nonce, echoed by the held guest.
        public let templateNonce: String
        public let imageDigest: String
        public let guestVersion: String
        /// Firecracker's `vmm_version` at snapshot time (SwiftFirecracker
        /// surfaces it as `vmlinuxVersion`).
        public let firecrackerVersion: String
        public let createdAtUnixSeconds: Int64
        /// Nil only for a staged or pre-STR-311 sidecar. Published entries
        /// require this proof and therefore treat older entries as misses.
        public let artifactIntegrity: ArtifactIntegrity?

        public init(
            templateId: String, templateNonce: String, imageDigest: String,
            guestVersion: String, firecrackerVersion: String, createdAtUnixSeconds: Int64
        ) {
            self.templateId = templateId
            self.templateNonce = templateNonce
            self.imageDigest = imageDigest
            self.guestVersion = guestVersion
            self.firecrackerVersion = firecrackerVersion
            self.createdAtUnixSeconds = createdAtUnixSeconds
            self.artifactIntegrity = nil
        }

        fileprivate init(copying meta: Meta, artifactIntegrity: ArtifactIntegrity) {
            self.templateId = meta.templateId
            self.templateNonce = meta.templateNonce
            self.imageDigest = meta.imageDigest
            self.guestVersion = meta.guestVersion
            self.firecrackerVersion = meta.firecrackerVersion
            self.createdAtUnixSeconds = meta.createdAtUnixSeconds
            self.artifactIntegrity = artifactIntegrity
        }
    }

    /// Read an entry's meta sidecar. Nil when missing or undecodable —
    /// callers treat that as "entry unusable" (the identity binding cannot
    /// be verified without it).
    public func loadMeta(_ key: WarmSnapshotKey, fileManager: FileManager = .default) -> Meta? {
        let path = entryDirectory(for: key) + "/" + Self.metaFile
        guard let data = fileManager.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    public func entryDirectory(for key: WarmSnapshotKey) -> String {
        rootPath + "/" + key.directoryName
    }

    /// The published entry for `key`, or nil when absent or incomplete (a
    /// partially deleted entry is treated as a miss; the meta sidecar is
    /// required because restores verify the template identity it carries).
    /// A hit refreshes the entry's LRU timestamp.
    public func lookup(_ key: WarmSnapshotKey, fileManager: FileManager = .default) -> WarmSnapshotEntry? {
        let entry = WarmSnapshotEntry(directory: entryDirectory(for: key))
        let metaPath = entry.directory + "/" + Self.metaFile
        for required in [entry.memoryPath, entry.vmstatePath, entry.rootfsPath, metaPath] {
            guard fileManager.fileExists(atPath: required) else {
                try? fileManager.removeItem(atPath: entry.directory)
                return nil
            }
        }
        guard let meta = loadMeta(key, fileManager: fileManager),
            let integrity = meta.artifactIntegrity,
            integrity.memorySizeBytes >= 0,
            integrity.vmstateSizeBytes >= 0,
            integrity.rootfsSizeBytes >= 0,
            integrity.rootfsSHA256.count == 64,
            integrity.rootfsSHA256.allSatisfy({ $0.isHexDigit }),
            fileSize(at: entry.memoryPath, fileManager: fileManager) == integrity.memorySizeBytes,
            fileSize(at: entry.vmstatePath, fileManager: fileManager) == integrity.vmstateSizeBytes,
            fileSize(at: entry.rootfsPath, fileManager: fileManager) == integrity.rootfsSizeBytes,
            let rootfsSHA256 = try? FileHashing.sha256Hex(ofFileAt: entry.rootfsPath),
            rootfsSHA256 == integrity.rootfsSHA256
        else {
            try? fileManager.removeItem(atPath: entry.directory)
            return nil
        }
        DiskCacheLRU.touch(entryDirectory: entry.directory)
        return entry
    }

    /// A fresh staging directory under the cache root (same filesystem as the
    /// final entry, so publish is one atomic rename). The dot prefix keeps it
    /// out of eviction scans.
    public func makeStagingDirectory(fileManager: FileManager = .default) throws -> String {
        let staging = rootPath + "/.staging-" + UUID().uuidString.lowercased()
        try fileManager.createDirectory(atPath: staging, withIntermediateDirectories: true)
        return staging
    }

    /// Publish a fully staged directory as the entry for `key`. Losing a
    /// publish race is success: the winner's artifacts are equivalent (same
    /// key), so the loser's staging is simply discarded.
    @discardableResult
    public func publish(
        stagingDirectory: String, for key: WarmSnapshotKey, fileManager: FileManager = .default
    ) throws -> WarmSnapshotEntry {
        try fileManager.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
        let target = entryDirectory(for: key)
        if lookup(key, fileManager: fileManager) != nil {
            try fileManager.removeItem(atPath: stagingDirectory)
            return WarmSnapshotEntry(directory: target)
        }

        let stagedEntry = WarmSnapshotEntry(directory: stagingDirectory)
        let stagedMetaPath = stagingDirectory + "/" + Self.metaFile
        let stagedMetaData = try Data(contentsOf: URL(fileURLWithPath: stagedMetaPath))
        let stagedMeta = try JSONDecoder().decode(Meta.self, from: stagedMetaData)
        guard
            let memorySizeBytes = fileSize(at: stagedEntry.memoryPath, fileManager: fileManager),
            let vmstateSizeBytes = fileSize(at: stagedEntry.vmstatePath, fileManager: fileManager),
            let rootfsSizeBytes = fileSize(at: stagedEntry.rootfsPath, fileManager: fileManager)
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        let completedMeta = Meta(
            copying: stagedMeta,
            artifactIntegrity: Meta.ArtifactIntegrity(
                memorySizeBytes: memorySizeBytes,
                vmstateSizeBytes: vmstateSizeBytes,
                rootfsSizeBytes: rootfsSizeBytes,
                rootfsSHA256: try FileHashing.sha256Hex(ofFileAt: stagedEntry.rootfsPath)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(completedMeta).write(to: URL(fileURLWithPath: stagedMetaPath))

        do {
            try DurableFileWriter().publishDirectory(
                stagingPath: stagingDirectory, to: target,
                completionFileName: Self.metaFile)
        } catch let error as DurableFileWriteError {
            // A concurrent publish can land between the check and the move;
            // losing that rename race is fine. A later durability failure
            // must still surface even though our renamed target is visible.
            if error.operation == "rename",
                let published = lookup(key, fileManager: fileManager)
            {
                try fileManager.removeItem(atPath: stagingDirectory)
                return published
            } else {
                throw error
            }
        }
        return WarmSnapshotEntry(directory: target)
    }

    /// Drop the entry for `key` (e.g. its restore failed — stale Firecracker
    /// state, corrupt artifacts). Missing is fine.
    public func invalidate(_ key: WarmSnapshotKey, fileManager: FileManager = .default) {
        try? fileManager.removeItem(atPath: entryDirectory(for: key))
    }

    /// All published entry directories (staging directories excluded).
    public func entryDirectories(fileManager: FileManager = .default) -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: rootPath) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.map { rootPath + "/" + $0 }.sorted()
    }

    /// Remove `.staging-*` directories older than `olderThan`. Staging
    /// directories are excluded from the budget sweep by design, so one
    /// abandoned by a crash mid-build (multi-GB memory/rootfs files) would
    /// otherwise hold disk forever. Callers that can prove no build is in
    /// flight (e.g. a startup sweep that runs before any build can start)
    /// pass 0 to collect everything regardless of age or mtime readability;
    /// the default hour-long gate keeps a live build's staging safe
    /// otherwise (and skips entries whose mtime cannot be read, since
    /// liveness cannot be ruled out for them). Inspection and removal failures
    /// are returned for operator reporting; cache debris is housekeeping and
    /// must not gate unrelated workload creation.
    @discardableResult
    public func removeAbandonedStaging(
        olderThan: TimeInterval = 3600, now: Date = Date(), fileManager: FileManager = .default
    ) -> [StagingCleanupFailure] {
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: rootPath)
        } catch {
            guard !DiskCacheLRU.isFileNotFound(error) else { return [] }
            return [StagingCleanupFailure(path: rootPath, reason: error.localizedDescription)]
        }
        return DiskCacheLRU.removeStaleStaging(
            candidates: names.filter { $0.hasPrefix(".staging-") }.map { rootPath + "/" + $0 },
            olderThan: olderThan,
            now: now,
            fileManager: fileManager)
    }

    /// Evict least-recently-used entries until the cache fits `budgetBytes`,
    /// honoring ``DiskCacheLRU``'s recent-use grace window.
    @discardableResult
    public func sweep(budgetBytes: Int64, now: Date = Date(), logger: Logger) -> DiskCacheLRU.SweepResult {
        DiskCacheLRU.sweep(
            entryDirectories: entryDirectories(), budgetBytes: budgetBytes, now: now, logger: logger)
    }

    private func fileSize(at path: String, fileManager: FileManager) -> Int64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
            let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }
}
