import Foundation
import Logging
import StratoShared

/// A rootfs ready for a sandbox to boot from.
public struct MaterializedRootfs: Sendable {
    /// Platform manifest digest the rootfs was built from (the cache key —
    /// and what observed state should report as the converged image).
    public let manifestDigest: String
    /// The ext4 image containing the flattened container filesystem.
    /// Cache-owned and shared between sandboxes pinning the same digest:
    /// the runtime must attach it read-only or copy/overlay it, never write.
    public let rootfsPath: String
    /// The staged `SandboxGuestConfig` JSON for the guest init (issue #419).
    public let configPath: String
    public let guestConfig: SandboxGuestConfig

    public init(
        manifestDigest: String, rootfsPath: String, configPath: String, guestConfig: SandboxGuestConfig
    ) {
        self.manifestDigest = manifestDigest
        self.rootfsPath = rootfsPath
        self.configPath = configPath
        self.guestConfig = guestConfig
    }
}

/// The agent's OCI image → sandbox rootfs pipeline (issue #418): registry
/// pull, layer flatten, ext4 build, digest-addressed cache — the piece the
/// sandbox runtime driver (#421) calls before booting a sandbox.
///
///     resolve manifest (index → this host's platform)
///     → cache hit? done
///     → free-space precheck → fetch config + layers (digest-verified)
///     → flatten layers (whiteouts applied) → stage config.json
///     → mkfs.ext4 -d → publish atomically into the cache
///
/// Concurrent requests for the same image coalesce onto one in-flight
/// materialization. Credentials come from `DesiredSandboxState` per call and
/// are never persisted — the only thing that outlives a call is cached
/// content addressed by digest, plus short-lived registry tokens inside the
/// client.
public actor SandboxImageService {
    /// Free-space heuristic: blob, decompressed tar, unpacked tree, and final
    /// image coexist at various points even with eager per-layer deletion of
    /// intermediates, and compressed layers typically expand ~3x.
    private static let spaceFactorOverCompressedSize: Int64 = 4

    private let logger: Logger
    private let client: OCIRegistryClient
    private let cache: OCIRootfsCache
    private let imageBuilder: any RootfsImageBuilder
    private let decompressor: LayerDecompressor
    private let workRoot: String

    private var inFlight: [String: Task<MaterializedRootfs, any Error>] = [:]

    /// Default cache root (platform-specific, same convention as
    /// `ImageCacheService.defaultCachePath`).
    public static var defaultCacheRootPath: String {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Caches/strato/sandbox-images"
        #else
        return "/var/cache/strato/sandbox-images"
        #endif
    }

    public init(
        logger: Logger,
        cacheRootPath: String? = nil,
        transport: any OCIHTTPTransport = URLSessionOCITransport(),
        clientConfiguration: OCIRegistryClient.Configuration = OCIRegistryClient.Configuration(),
        imageBuilder: (any RootfsImageBuilder)? = nil,
        decompressor: LayerDecompressor = LayerDecompressor(),
        cacheTTL: TimeInterval = OCIRootfsCache.defaultTTL,
        cacheMaxSizeBytes: Int64? = nil
    ) {
        let root = cacheRootPath ?? Self.defaultCacheRootPath
        self.logger = logger
        self.client = OCIRegistryClient(
            transport: transport, logger: logger, configuration: clientConfiguration)
        self.cache = OCIRootfsCache(
            rootPath: root, ttl: cacheTTL, maxSizeBytes: cacheMaxSizeBytes, logger: logger)
        self.imageBuilder = imageBuilder ?? Ext4ImageBuilder(logger: logger)
        self.decompressor = decompressor
        self.workRoot = root + "/work"
    }

    /// Materializes the rootfs for a sandbox image, returning immediately on
    /// a cache hit.
    ///
    /// - Parameters:
    ///   - image: The OCI reference as it appears in `SandboxSpec.image`.
    ///   - imageDigest: The control plane's pinned digest
    ///     (`SandboxSpec.imageDigest`); may name either a platform manifest
    ///     or an index. Nil means the agent resolves the tag itself,
    ///     accepting the mutability (pre-#414 control planes).
    ///   - credential: Short-lived pull credential from
    ///     `DesiredSandboxState.registryCredential`. Used for this pull only.
    public func materializeRootfs(
        image: String,
        imageDigest: String? = nil,
        credential: RegistryCredential? = nil,
        architecture: CPUArchitecture = .current
    ) async throws -> MaterializedRootfs {
        guard let parsed = OCIImageReference.parse(image) else {
            throw OCIError.invalidReference(image)
        }
        var ref = parsed
        if let imageDigest {
            guard OCIImageReference.isValidDigest(imageDigest) else {
                throw OCIError.invalidReference("\(image)@\(imageDigest)")
            }
            ref = OCIImageReference(
                registry: ref.registry, repository: ref.repository, tag: ref.tag, digest: imageDigest)
        }

        let key = "\(ref.registry)/\(ref.repository)@\(ref.digest ?? "tag=" + ref.tag)|\(architecture.rawValue)"
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task {
            try await self.performMaterialization(
                ref: ref, credential: credential, architecture: architecture)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// Evicts idle cache entries; the runtime calls this periodically.
    public func cleanupCache() async {
        await cache.cleanup()
    }

    // MARK: - Pipeline

    private func performMaterialization(
        ref: OCIImageReference, credential: RegistryCredential?, architecture: CPUArchitecture
    ) async throws -> MaterializedRootfs {
        // Warm path: a pinned digest can hit the cache with no network at
        // all — directly, or through a remembered index→platform alias.
        if let pinned = ref.digest {
            if let hit = await cachedRootfs(manifestDigest: pinned) {
                return hit
            }
            if let aliased = await cache.aliasTarget(indexDigest: pinned, architecture: architecture),
                let hit = await cachedRootfs(manifestDigest: aliased)
            {
                return hit
            }
        }

        let resolved = try await client.resolveManifest(
            for: ref, architecture: architecture, credential: credential)
        if let pinned = ref.digest, pinned != resolved.manifestDigest {
            // The pin named an index; remember its narrowing so the next
            // lookup is offline.
            await cache.storeAlias(
                indexDigest: pinned, architecture: architecture, manifestDigest: resolved.manifestDigest)
        }
        if let hit = await cachedRootfs(manifestDigest: resolved.manifestDigest) {
            return hit
        }

        // Validate every layer before spending bandwidth on any of them.
        let layerCompressions: [OCILayerCompression] = try resolved.manifest.layers.map { layer in
            guard let compression = OCILayerCompression.forLayerMediaType(layer.mediaType) else {
                throw OCIError.unsupportedMediaType(layer.mediaType)
            }
            return compression
        }

        let compressedBytes = resolved.manifest.layers.reduce(Int64(0)) { $0 + max($1.size, 0) }
        try await cache.precheckFreeSpace(
            requiredBytes: compressedBytes * Self.spaceFactorOverCompressedSize)

        logger.info(
            "Materializing sandbox rootfs",
            metadata: [
                "image": .string("\(ref.registry)/\(ref.repository):\(ref.tag)"),
                "digest": .string(resolved.manifestDigest),
                "layers": .stringConvertible(resolved.manifest.layers.count),
                "compressedBytes": .stringConvertible(compressedBytes),
            ])

        let workDir = workRoot + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: workDir) }

        // Image config → the guest-facing runtime config.
        let configBlobPath = workDir + "/config.blob"
        try await client.fetchBlob(
            resolved.manifest.config, from: ref, credential: credential, to: configBlobPath)
        guard let configData = FileManager.default.contents(atPath: configBlobPath),
            let imageConfig = try? JSONDecoder().decode(OCIImageConfig.self, from: configData)
        else {
            throw OCIError.malformedResponse(detail: "undecodable image config for \(ref.repository)")
        }
        let guestConfig = SandboxGuestConfig(imageConfig: imageConfig)

        // Fetch → decompress → apply, layer by layer, deleting intermediates
        // eagerly so peak disk usage stays near the largest layer, not the
        // whole image.
        let treePath = workDir + "/rootfs"
        let flattener = try OCIImageFlattener(rootPath: treePath, logger: logger)
        for (index, layer) in resolved.manifest.layers.enumerated() {
            let blobPath = workDir + "/layer-\(index).blob"
            try await client.fetchBlob(layer, from: ref, credential: credential, to: blobPath)
            let tarPath = try await decompressor.decompressedTarPath(
                blobPath: blobPath, compression: layerCompressions[index],
                outputPath: workDir + "/layer-\(index).tar")
            do {
                try flattener.apply(layerTarPath: tarPath)
            } catch let error as TarArchiveReader.TarError {
                throw OCIError.layerUnpackFailed(detail: "layer \(layer.digest): \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(atPath: blobPath)
            if tarPath != blobPath {
                try? FileManager.default.removeItem(atPath: tarPath)
            }
        }
        try flattener.finalize()

        // Stage config + image, then publish the directory atomically.
        let stagingDir = try await cache.stagingDirectory(for: resolved.manifestDigest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (try encoder.encode(guestConfig)).write(
            to: URL(fileURLWithPath: stagingDir + "/" + OCIRootfsCache.configFileName))
        try await imageBuilder.buildImage(
            fromTree: treePath, at: stagingDir + "/" + OCIRootfsCache.rootfsFileName)

        let published = try await cache.publish(manifestDigest: resolved.manifestDigest)
        logger.info(
            "Sandbox rootfs materialized",
            metadata: [
                "digest": .string(published.manifestDigest),
                "rootfs": .string(published.rootfsPath),
            ])

        // The cache only grows when a materialization publishes, so this is
        // the natural point to enforce the idle TTL and size budget.
        await cache.cleanup()
        return MaterializedRootfs(
            manifestDigest: published.manifestDigest,
            rootfsPath: published.rootfsPath,
            configPath: published.configPath,
            guestConfig: guestConfig
        )
    }

    /// Cache lookup that also revalidates the staged config; an entry whose
    /// config no longer decodes is invalidated so the caller re-pulls.
    private func cachedRootfs(manifestDigest: String) async -> MaterializedRootfs? {
        guard let cached = await cache.lookup(manifestDigest: manifestDigest) else { return nil }
        guard let data = FileManager.default.contents(atPath: cached.configPath),
            let guestConfig = try? JSONDecoder().decode(SandboxGuestConfig.self, from: data)
        else {
            logger.warning(
                "Invalidating cached rootfs with undecodable guest config",
                metadata: ["digest": .string(manifestDigest)])
            await cache.invalidate(manifestDigest: manifestDigest)
            return nil
        }
        return MaterializedRootfs(
            manifestDigest: cached.manifestDigest,
            rootfsPath: cached.rootfsPath,
            configPath: cached.configPath,
            guestConfig: guestConfig
        )
    }
}
