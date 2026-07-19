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
///   unjailed ones absolute paths, so the two never mix.
public struct WarmSnapshotKey: Sendable, Equatable {
    public let imageDigest: String
    public let guestVersion: String
    public let arch: String
    public let firecrackerFingerprint: String
    public let vcpus: Int
    public let memoryMiB: Int64
    public let configCapacityBytes: Int
    public let jailed: Bool

    public init(
        imageDigest: String,
        guestVersion: String,
        arch: String,
        firecrackerFingerprint: String,
        vcpus: Int,
        memoryMiB: Int64,
        configCapacityBytes: Int,
        jailed: Bool
    ) {
        self.imageDigest = imageDigest
        self.guestVersion = guestVersion
        self.arch = arch
        self.firecrackerFingerprint = firecrackerFingerprint
        self.vcpus = vcpus
        self.memoryMiB = memoryMiB
        self.configCapacityBytes = configCapacityBytes
        self.jailed = jailed
    }

    /// The cache entry directory name for this key. Every component is
    /// filesystem-sanitized; the digest keeps its full hex so distinct images
    /// can never collide into one entry (a collision would boot the wrong
    /// workload).
    public var directoryName: String {
        let components = [
            Self.sanitize(imageDigest),
            Self.sanitize(guestVersion),
            Self.sanitize(arch),
            Self.sanitize(firecrackerFingerprint),
            "\(vcpus)c",
            "\(memoryMiB)m",
            "\(configCapacityBytes)cfg",
            jailed ? "jailed" : "flat",
        ]
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
///     meta.json        # diagnostics (Firecracker version, sizes, source)
///   .staging-<uuid>/   # in-progress builds, atomically renamed into place
/// ```
///
/// Follows the `OCIRootfsCache` publish discipline (stage into a dot-prefixed
/// directory, atomic rename) and delegates eviction to ``DiskCacheLRU`` with
/// directory-mtime-as-last-use, so a `touch` on lookup keeps hot entries
/// resident.
public struct WarmSandboxSnapshotCache: Sendable {
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
            guard fileManager.fileExists(atPath: required) else { return nil }
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
        if fileManager.fileExists(atPath: target) {
            try? fileManager.removeItem(atPath: stagingDirectory)
            return WarmSnapshotEntry(directory: target)
        }
        do {
            try fileManager.moveItem(atPath: stagingDirectory, toPath: target)
        } catch {
            // A concurrent publish can land between the check and the move;
            // losing that race is fine, anything else is a real failure.
            if fileManager.fileExists(atPath: target) {
                try? fileManager.removeItem(atPath: stagingDirectory)
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

    /// Evict least-recently-used entries until the cache fits `budgetBytes`,
    /// honoring ``DiskCacheLRU``'s recent-use grace window.
    @discardableResult
    public func sweep(budgetBytes: Int64, now: Date = Date(), logger: Logger) -> DiskCacheLRU.SweepResult {
        DiskCacheLRU.sweep(
            entryDirectories: entryDirectories(), budgetBytes: budgetBytes, now: now, logger: logger)
    }
}
