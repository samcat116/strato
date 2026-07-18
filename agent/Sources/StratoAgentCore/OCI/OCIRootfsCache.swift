import Foundation
import Logging
import StratoShared

/// A materialized sandbox rootfs in the cache.
public struct CachedSandboxRootfs: Sendable {
    /// The platform manifest digest the entry is keyed by.
    public let manifestDigest: String
    public let rootfsPath: String
    /// The staged guest config (`SandboxGuestConfig` JSON) next to the rootfs.
    public let configPath: String

    public init(manifestDigest: String, rootfsPath: String, configPath: String) {
        self.manifestDigest = manifestDigest
        self.rootfsPath = rootfsPath
        self.configPath = configPath
    }
}

/// Content-addressed cache of materialized sandbox root filesystems, keyed by
/// **platform manifest digest** — unlike the identity-addressed
/// `{projectId}/{imageId}` layout of `ImageCacheService`, because two
/// sandboxes anywhere that pin the same digest are byte-identical by
/// definition. v1 granularity is the flattened image (no layer dedup).
///
/// Layout under the cache root:
///
///     images/<hex>/rootfs.ext4        one directory per manifest digest
///     images/<hex>/config.json        the staged guest config
///     images/<hex>.partial/           staging; renamed into place on publish
///     aliases/<hex>.<arch>            index digest → platform manifest digest
///
/// Aliases let a sandbox pinned to an *index* digest (what `docker push`
/// usually reports) hit the cache without a network round-trip to re-narrow
/// the index. A cache entry's directory mtime is its last-use time; `cleanup`
/// evicts entries idle past the TTL, plus stale aliases and crashed staging
/// directories.
public actor OCIRootfsCache {
    public static let rootfsFileName = "rootfs.ext4"
    public static let configFileName = "config.json"

    /// Default retention for unused sandbox rootfs entries.
    public static let defaultTTL: TimeInterval = 7 * 24 * 60 * 60
    /// Staging directories older than this belong to crashed materializations.
    private static let stalePartialAge: TimeInterval = 24 * 60 * 60

    private let rootPath: String
    private let ttl: TimeInterval
    private let logger: Logger

    private var imagesPath: String { rootPath + "/images" }
    private var aliasesPath: String { rootPath + "/aliases" }

    public init(rootPath: String, ttl: TimeInterval = OCIRootfsCache.defaultTTL, logger: Logger) {
        self.rootPath = rootPath
        self.ttl = ttl
        self.logger = logger
    }

    // MARK: - Lookup

    /// Returns the cached rootfs for a manifest digest, refreshing its
    /// last-use time. Nil on miss (including structurally incomplete entries,
    /// which are removed).
    public func lookup(manifestDigest: String) -> CachedSandboxRootfs? {
        guard let directory = imageDirectory(for: manifestDigest) else { return nil }
        let rootfsPath = directory + "/" + Self.rootfsFileName
        let configPath = directory + "/" + Self.configFileName
        guard FileManager.default.fileExists(atPath: directory) else { return nil }
        guard FileManager.default.fileExists(atPath: rootfsPath),
            FileManager.default.fileExists(atPath: configPath)
        else {
            // A digest directory without both files is debris from a crash
            // predating atomic publication semantics, or manual tampering.
            logger.warning(
                "Removing structurally incomplete rootfs cache entry",
                metadata: ["digest": .string(manifestDigest)])
            try? FileManager.default.removeItem(atPath: directory)
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory)
        return CachedSandboxRootfs(
            manifestDigest: manifestDigest, rootfsPath: rootfsPath, configPath: configPath)
    }

    /// Removes a cache entry (e.g. one whose config no longer decodes).
    public func invalidate(manifestDigest: String) {
        guard let directory = imageDirectory(for: manifestDigest) else { return }
        try? FileManager.default.removeItem(atPath: directory)
    }

    // MARK: - Index aliases

    /// The platform manifest digest a (index digest, architecture) pair
    /// resolved to earlier, if remembered and still cached.
    public func aliasTarget(indexDigest: String, architecture: CPUArchitecture) -> String? {
        guard let path = aliasPath(indexDigest: indexDigest, architecture: architecture),
            let raw = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OCIImageReference.isValidDigest(target) else {
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }
        return target
    }

    public func storeAlias(indexDigest: String, architecture: CPUArchitecture, manifestDigest: String) {
        guard let path = aliasPath(indexDigest: indexDigest, architecture: architecture),
            OCIImageReference.isValidDigest(manifestDigest)
        else { return }
        do {
            try FileManager.default.createDirectory(atPath: aliasesPath, withIntermediateDirectories: true)
            try manifestDigest.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            // Aliases are an optimization; losing one costs a manifest fetch.
            logger.debug(
                "Failed to store rootfs cache alias", metadata: ["error": .string(String(describing: error))]
            )
        }
    }

    // MARK: - Publication

    /// Returns a fresh (emptied) staging directory for a digest, a `.partial`
    /// sibling of the final location so `publish` is a single rename on one
    /// filesystem.
    public func stagingDirectory(for manifestDigest: String) throws -> String {
        guard let directory = imageDirectory(for: manifestDigest) else {
            throw OCIError.malformedResponse(detail: "malformed manifest digest \(manifestDigest)")
        }
        let staging = directory + ".partial"
        try? FileManager.default.removeItem(atPath: staging)
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        return staging
    }

    /// Atomically publishes the staged entry. If the digest was published
    /// concurrently by another path, the existing entry wins and the staging
    /// directory is discarded — content-addressing makes both identical.
    public func publish(manifestDigest: String) throws -> CachedSandboxRootfs {
        guard let directory = imageDirectory(for: manifestDigest) else {
            throw OCIError.malformedResponse(detail: "malformed manifest digest \(manifestDigest)")
        }
        let staging = directory + ".partial"
        if !FileManager.default.fileExists(atPath: directory) {
            try FileManager.default.moveItem(atPath: staging, toPath: directory)
        } else {
            try? FileManager.default.removeItem(atPath: staging)
        }
        guard let published = lookup(manifestDigest: manifestDigest) else {
            throw OCIError.layerUnpackFailed(
                detail: "published cache entry for \(manifestDigest) is incomplete")
        }
        return published
    }

    // MARK: - Space and cleanup

    /// Fails fast (as a permanent, operator-actionable error) when the cache
    /// filesystem can't hold a projected materialization.
    public func precheckFreeSpace(requiredBytes: Int64) throws {
        try? FileManager.default.createDirectory(atPath: imagesPath, withIntermediateDirectories: true)
        guard requiredBytes > 0 else { return }
        if let free = HostPreflight.freeDiskSpace(atPath: imagesPath), free < requiredBytes {
            throw OCIError.insufficientDiskSpace(
                detail: "materializing this image needs about \(HostPreflight.byteString(requiredBytes)) "
                    + "but only \(HostPreflight.byteString(free)) is free on the filesystem backing "
                    + "\(imagesPath). Free up space or point the sandbox image cache at a larger filesystem."
            )
        }
    }

    /// Evicts idle images (directory mtime older than the TTL), aliases whose
    /// target is gone, and staging directories old enough to be crash debris.
    public func cleanup(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-ttl)

        for name in (try? FileManager.default.contentsOfDirectory(atPath: imagesPath)) ?? [] {
            let path = imagesPath + "/" + name
            if name.hasSuffix(".partial") {
                if isOlder(path: path, than: now.addingTimeInterval(-Self.stalePartialAge)) {
                    try? FileManager.default.removeItem(atPath: path)
                }
                continue
            }
            if isOlder(path: path, than: cutoff) {
                logger.info("Evicting idle sandbox rootfs", metadata: ["entry": .string(name)])
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        for name in (try? FileManager.default.contentsOfDirectory(atPath: aliasesPath)) ?? [] {
            let path = aliasesPath + "/" + name
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let targetHex = target.hasPrefix("sha256:") ? String(target.dropFirst("sha256:".count)) : ""
            if targetHex.isEmpty || !FileManager.default.fileExists(atPath: imagesPath + "/" + targetHex) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    // MARK: - Paths

    /// `images/<hex>` for a valid digest, nil otherwise. Validation matters:
    /// digest strings arrive from registry responses and must never become
    /// path components unchecked.
    private func imageDirectory(for digest: String) -> String? {
        guard OCIImageReference.isValidDigest(digest) else { return nil }
        return imagesPath + "/" + String(digest.dropFirst("sha256:".count))
    }

    private func aliasPath(indexDigest: String, architecture: CPUArchitecture) -> String? {
        guard OCIImageReference.isValidDigest(indexDigest) else { return nil }
        let hex = String(indexDigest.dropFirst("sha256:".count))
        return aliasesPath + "/" + hex + "." + architecture.rawValue
    }

    private func isOlder(path: String, than cutoff: Date) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let modified = attributes[.modificationDate] as? Date
        else { return false }
        return modified < cutoff
    }
}
