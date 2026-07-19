import Foundation
import Logging
import Testing

@testable import StratoAgentCore

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
        jailed: Bool = true
    ) -> WarmSnapshotKey {
        WarmSnapshotKey(
            imageDigest: digest,
            guestVersion: guestVersion,
            arch: "aarch64",
            firecrackerFingerprint: "4194304-1752700000",
            vcpus: vcpus,
            memoryMiB: memoryMiB,
            configCapacityBytes: configCapacityBytes,
            jailed: jailed)
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
}
