import Foundation
import Dispatch
import Logging
import Synchronization
import Testing

@testable import StratoAgentCore

private final class FailingWarmCacheFileManager: FileManager, @unchecked Sendable {
    enum FailurePoint: Equatable { case enumeration, removal }

    private let failurePoint: FailurePoint

    init(_ failurePoint: FailurePoint) {
        self.failurePoint = failurePoint
        super.init()
    }

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        if failurePoint == .enumeration { throw CocoaError(.fileReadNoPermission) }
        return try super.contentsOfDirectory(atPath: path)
    }

    override func removeItem(atPath path: String) throws {
        if failurePoint == .removal { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(atPath: path)
    }
}

/// Coverage for the warm-start template snapshot cache (issue #426): key
/// derivation, the lookup/publish/invalidate lifecycle, and the LRU sweep
/// integration. Pure filesystem — no Firecracker required.
@Suite("Warm Sandbox Snapshot Cache Tests")
struct WarmSandboxSnapshotCacheTests {

    private let logger = Logger(label: "warm-cache-tests")

    private func makeKey(
        digest: String = "sha256:0123456789abcdef",
        guestVersion: String = "6.12.9+init0.3.0",
        vcpus: Int = 2,
        memoryMiB: Int64 = 512,
        configCapacityBytes: Int = 256 * 1024,
        jailed: Bool = true,
        cpuTemplate: String? = nil,
        nicCount: Int = 0
    ) -> WarmSnapshotKey {
        WarmSnapshotKey(
            imageDigest: digest,
            guestVersion: guestVersion,
            arch: "aarch64",
            firecrackerFingerprint: "4194304-1752700000",
            vcpus: vcpus,
            memoryMiB: memoryMiB,
            configCapacityBytes: configCapacityBytes,
            jailed: jailed,
            cpuTemplate: cpuTemplate,
            nicCount: nicCount)
    }

    private func makeTempRoot() throws -> String {
        let root = NSTemporaryDirectory() + "warm-cache-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    /// Stage a complete artifact set (including the required meta sidecar)
    /// and publish it for `key`.
    private func publishEntry(
        _ cache: WarmSandboxSnapshotCache, key: WarmSnapshotKey, fill: String = "x",
        templateNonce: String = "template-nonce"
    ) throws -> WarmSnapshotEntry {
        let staging = try cache.makeStagingDirectory()
        for file in [
            WarmSandboxSnapshotCache.memoryFile,
            WarmSandboxSnapshotCache.vmstateFile,
            WarmSandboxSnapshotCache.rootfsFile,
        ] {
            try Data(fill.utf8).write(to: URL(fileURLWithPath: staging + "/" + file))
        }
        let meta = WarmSandboxSnapshotCache.Meta(
            templateId: "warm-template-test", templateNonce: templateNonce,
            imageDigest: key.imageDigest, guestVersion: key.guestVersion,
            firecrackerVersion: "1.10.0", createdAtUnixSeconds: 1_752_700_000)
        try JSONEncoder().encode(meta).write(
            to: URL(fileURLWithPath: staging + "/" + WarmSandboxSnapshotCache.metaFile))
        return try cache.publish(stagingDirectory: staging, for: key)
    }

    // MARK: - Key derivation

    @Test("directory names are filesystem-safe and carry every key component")
    func directoryNameIsSanitizedAndComplete() {
        let key = makeKey(digest: "sha256:abc/../def", guestVersion: "6.12+init/0.3")
        let name = key.directoryName
        #expect(!name.contains(":"), "colons must be sanitized: \(name)")
        #expect(!name.contains("/"), "path separators must be sanitized: \(name)")
        #expect(name.contains("2c"))
        #expect(name.contains("512m"))
        #expect(name.contains("jailed"))
    }

    @Test("distinct machine shapes, images, and jail modes never collide")
    func distinctKeysDistinctDirectories() {
        let base = makeKey()
        #expect(makeKey(vcpus: 4).directoryName != base.directoryName)
        #expect(makeKey(memoryMiB: 1024).directoryName != base.directoryName)
        #expect(makeKey(configCapacityBytes: 512 * 1024).directoryName != base.directoryName)
        #expect(makeKey(jailed: false).directoryName != base.directoryName)
        #expect(makeKey(digest: "sha256:fedcba").directoryName != base.directoryName)
        #expect(makeKey(guestVersion: "other").directoryName != base.directoryName)
    }

    @Test("a CPU template is part of the key; passthrough keeps its pre-#428 name")
    func cpuTemplateKeysDistinctEntries() {
        let passthrough = makeKey()
        let templated = makeKey(cpuTemplate: "T2")
        #expect(templated.directoryName != passthrough.directoryName)
        #expect(makeKey(cpuTemplate: "T2A").directoryName != templated.directoryName)
        // Nil template must produce the exact historical name so existing
        // cache entries survive the agent upgrade.
        #expect(!passthrough.directoryName.contains("tpl"))
    }

    /// The whole point of the NIC-shape component (STR-104): Firecracker can
    /// repoint a restored network device but never add or drop one, so a
    /// template built without a NIC must *miss* for a networked sandbox and
    /// send it down the cold path — rather than warm-restoring it into a
    /// microVM with no interface that reports perfectly healthy.
    @Test("a template's NIC shape is part of the key; no-NIC keeps its pre-STR-104 name")
    func nicShapeKeysDistinctEntries() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = WarmSandboxSnapshotCache(rootPath: root)

        let networkless = makeKey()
        let networked = makeKey(nicCount: 1)
        #expect(networked.directoryName != networkless.directoryName)
        #expect(networked.directoryName.contains("1nic"))
        // Nil/zero must produce the exact historical name so entries built by
        // an older agent stay hits for exactly the sandboxes they were valid
        // for.
        #expect(!networkless.directoryName.contains("nic"))

        _ = try publishEntry(cache, key: networkless)
        #expect(cache.lookup(networked) == nil, "a no-NIC template cannot warm-start a networked sandbox")
        #expect(cache.lookup(networkless) != nil)
    }

    @Test("sanitizing two different digests cannot alias them")
    func sanitizationPreservesDistinctness() {
        // ":" and "/" both map to "-", but the full digest hex is retained,
        // so real registry digests (distinct hex) stay distinct.
        let a = makeKey(digest: "sha256:aaaa").directoryName
        let b = makeKey(digest: "sha256:bbbb").directoryName
        #expect(a != b)
    }

    // MARK: - Lifecycle

    @Test("lookup misses an empty cache and hits a published entry")
    func lookupMissThenHit() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = WarmSandboxSnapshotCache(rootPath: root)
        let key = makeKey()

        #expect(cache.lookup(key) == nil)
        let published = try publishEntry(cache, key: key)
        let found = try #require(cache.lookup(key))
        #expect(found == published)
        #expect(FileManager.default.fileExists(atPath: found.memoryPath))
        #expect(FileManager.default.fileExists(atPath: found.vmstatePath))
        #expect(FileManager.default.fileExists(atPath: found.rootfsPath))
    }

    @Test("an incomplete entry is a miss, not a hit")
    func incompleteEntryMisses() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = WarmSandboxSnapshotCache(rootPath: root)
        let key = makeKey()

        _ = try publishEntry(cache, key: key)
        let entry = try #require(cache.lookup(key))
        try FileManager.default.removeItem(atPath: entry.rootfsPath)
        #expect(cache.lookup(key) == nil, "a partially deleted entry must not be restorable")
    }

    @Test("a rootfs truncated after publication is invalidated on lookup")
    func truncatedRootfsMisses() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = WarmSandboxSnapshotCache(rootPath: root)
        let key = makeKey()

        let entry = try publishEntry(cache, key: key, fill: "complete")
        try Data("bad".utf8).write(to: URL(fileURLWithPath: entry.rootfsPath))

        #expect(cache.lookup(key) == nil)
        #expect(!FileManager.default.fileExists(atPath: entry.directory))
    }

    @Test("a same-size rootfs overwrite is invalidated on lookup")
    func sameSizeRootfsDamageMisses() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = WarmSandboxSnapshotCache(rootPath: root)
        let key = makeKey()

        let entry = try publishEntry(cache, key: key, fill: "complete")
        try Data("damaged!".utf8).write(to: URL(fileURLWithPath: entry.rootfsPath))

        #expect(cache.lookup(key) == nil)
        #expect(!FileManager.default.fileExists(atPath: entry.directory))
    }

    @Test("a pre-durability entry without artifact integrity is never served")
    func entryWithoutArtifactIntegrityMisses() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = WarmSandboxSnapshotCache(rootPath: root)
        let key = makeKey()
        let entryDirectory = cache.entryDirectory(for: key)
        try FileManager.default.createDirectory(atPath: entryDirectory, withIntermediateDirectories: true)
        for file in [
            WarmSandboxSnapshotCache.memoryFile,
            WarmSandboxSnapshotCache.vmstateFile,
            WarmSandboxSnapshotCache.rootfsFile,
        ] {
            try Data("payload".utf8).write(to: URL(fileURLWithPath: entryDirectory + "/" + file))
        }
        let oldMeta = WarmSandboxSnapshotCache.Meta(
            templateId: "old-template", templateNonce: "old-nonce",
            imageDigest: key.imageDigest, guestVersion: key.guestVersion,
            firecrackerVersion: "1.10.0", createdAtUnixSeconds: 1_752_700_000)
        try JSONEncoder().encode(oldMeta).write(
            to: URL(fileURLWithPath: entryDirectory + "/" + WarmSandboxSnapshotCache.metaFile))

        #expect(cache.lookup(key) == nil)
        #expect(!FileManager.default.fileExists(atPath: entryDirectory))
    }

    @Test("publish is atomic-rename and losing the race is success")
    func publishToleratesExistingEntry() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = WarmSandboxSnapshotCache(rootPath: root)
        let key = makeKey()

        _ = try publishEntry(cache, key: key, fill: "first")
        // A second publish for the same key (raced build) must succeed and
        // leave the winner's artifacts in place.
        let second = try publishEntry(cache, key: key, fill: "second")
        let contents = try String(
            contentsOfFile: second.memoryPath, encoding: .utf8)
        #expect(contents == "first", "the first publish wins; the loser's staging is discarded")
        // No staging directories may linger either way.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root)
            .filter { $0.hasPrefix(".staging-") }
        #expect(leftovers.isEmpty)
    }

    @Test("loadMeta round-trips the template identity binding")
    func loadMetaRoundTrips() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = WarmSandboxSnapshotCache(rootPath: root)
        let key = makeKey()

        #expect(cache.loadMeta(key) == nil, "no entry, no meta")
        _ = try publishEntry(cache, key: key, templateNonce: "n-tpl")
        let meta = try #require(cache.loadMeta(key))
        #expect(meta.templateId == "warm-template-test")
        #expect(meta.templateNonce == "n-tpl")
        #expect(meta.artifactIntegrity?.memorySizeBytes == 1)
        #expect(meta.artifactIntegrity?.vmstateSizeBytes == 1)
        #expect(meta.artifactIntegrity?.rootfsSizeBytes == 1)
        let expectedRootfsHash = try FileHashing.sha256Hex(
            ofFileAt: cache.entryDirectory(for: key) + "/" + WarmSandboxSnapshotCache.rootfsFile)
        #expect(meta.artifactIntegrity?.rootfsSHA256 == expectedRootfsHash)
    }

    @Test("an entry without its meta sidecar is a miss")
    func entryWithoutMetaMisses() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = WarmSandboxSnapshotCache(rootPath: root)
        let key = makeKey()

        _ = try publishEntry(cache, key: key)
        try FileManager.default.removeItem(
            atPath: cache.entryDirectory(for: key) + "/" + WarmSandboxSnapshotCache.metaFile)
        #expect(cache.lookup(key) == nil, "the identity binding requires the meta sidecar")
    }

    @Test("invalidate removes the entry and is idempotent")
    func invalidateRemoves() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = WarmSandboxSnapshotCache(rootPath: root)
        let key = makeKey()

        _ = try publishEntry(cache, key: key)
        cache.invalidate(key)
        #expect(cache.lookup(key) == nil)
        cache.invalidate(key)  // second invalidate: no throw, no effect
    }

    @Test("staging directories are excluded from entry listings")
    func stagingExcludedFromEntries() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = WarmSandboxSnapshotCache(rootPath: root)

        _ = try publishEntry(cache, key: makeKey())
        _ = try cache.makeStagingDirectory()  // deliberately left behind
        let entries = cache.entryDirectories()
        #expect(entries.count == 1)
        #expect(!entries[0].contains(".staging-"))
    }

    @Test("abandoned staging directories are removed once old, fresh ones kept")
    func abandonedStagingCleanup() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = WarmSandboxSnapshotCache(rootPath: root)

        let abandoned = try cache.makeStagingDirectory()
        try Data(repeating: 0, count: 4096).write(
            to: URL(fileURLWithPath: abandoned + "/" + WarmSandboxSnapshotCache.memoryFile))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: abandoned)
        let live = try cache.makeStagingDirectory()

        cache.removeAbandonedStaging()

        #expect(!FileManager.default.fileExists(atPath: abandoned), "old staging must be removed")
        #expect(FileManager.default.fileExists(atPath: live), "a live build's staging must survive")

        // The ungated startup sweep (no build can be in flight) collects
        // everything, however fresh — a restart shortly after a crash must
        // not strand young debris behind the age gate forever.
        cache.removeAbandonedStaging(olderThan: 0)
        #expect(!FileManager.default.fileExists(atPath: live))
    }

    @Test("startup staging cleanup errors do not block the caller")
    func abandonedStagingCleanupErrorsDoNotThrow() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = WarmSandboxSnapshotCache(rootPath: root)
        let staging = try cache.makeStagingDirectory()

        for failure in [
            FailingWarmCacheFileManager.FailurePoint.enumeration,
            FailingWarmCacheFileManager.FailurePoint.removal,
        ] {
            let failures = cache.removeAbandonedStaging(
                olderThan: 0,
                fileManager: FailingWarmCacheFileManager(failure))
            #expect(failures.count == 1)
            #expect(failures[0].path == (failure == .enumeration ? root : staging))
            #expect(!failures[0].reason.isEmpty)
        }
        #expect(FileManager.default.fileExists(atPath: staging))
    }

    // MARK: - Eviction

    @Test("sweep evicts the least-recently-used entry past the budget")
    func sweepEvictsLRU() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = WarmSandboxSnapshotCache(rootPath: root)
        let oldKey = makeKey(digest: "sha256:old")
        let newKey = makeKey(digest: "sha256:new")

        _ = try publishEntry(cache, key: oldKey, fill: String(repeating: "a", count: 4096))
        _ = try publishEntry(cache, key: newKey, fill: String(repeating: "b", count: 4096))
        // Age the old entry out of the recent-use grace window; refresh the new.
        let old = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: cache.entryDirectory(for: oldKey))
        DiskCacheLRU.touch(entryDirectory: cache.entryDirectory(for: newKey))

        let result = cache.sweep(budgetBytes: 8192, logger: logger)
        #expect(result.evicted.count == 1)
        #expect(cache.lookup(oldKey) == nil)
        #expect(cache.lookup(newKey) != nil)
    }

    @Test("sweep cannot evict an entry while lookup verifies its checksum")
    func sweepWaitsForLookup() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let key = makeKey()
        let publishingCache = WarmSandboxSnapshotCache(rootPath: root)
        let entry = try publishEntry(
            publishingCache, key: key, fill: String(repeating: "a", count: 4096))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: entry.directory)

        let hashingStarted = Mutex(false)
        let finishHashing = DispatchSemaphore(value: 0)
        defer { finishHashing.signal() }
        let cache = WarmSandboxSnapshotCache(
            rootPath: root,
            rootfsHasher: { path in
                hashingStarted.withLock { $0 = true }
                finishHashing.wait()
                return try FileHashing.sha256Hex(ofFileAt: path)
            })

        let lookup = Task.detached { cache.lookup(key) }
        while !hashingStarted.withLock({ $0 }) { await Task.yield() }

        let sweepStarted = Mutex(false)
        let sweepFinished = Mutex(false)
        let sweepLogger = logger
        let sweep = Task.detached {
            sweepStarted.withLock { $0 = true }
            let result = cache.sweep(budgetBytes: 0, logger: sweepLogger)
            sweepFinished.withLock { $0 = true }
            return result
        }
        while !sweepStarted.withLock({ $0 }) { await Task.yield() }

        try await Task.sleep(for: .milliseconds(50))
        #expect(!sweepFinished.withLock { $0 })
        #expect(FileManager.default.fileExists(atPath: entry.rootfsPath))

        finishHashing.signal()
        #expect(await lookup.value != nil)
        let sweepResult = await sweep.value
        #expect(sweepResult.evicted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: entry.rootfsPath))
    }
}
