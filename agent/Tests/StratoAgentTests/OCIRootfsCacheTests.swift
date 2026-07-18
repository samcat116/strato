import Foundation
import Logging
import Testing

@testable import StratoAgentCore

@Suite("OCI Rootfs Cache")
struct OCIRootfsCacheTests {

    private let digest = "sha256:" + String(repeating: "1", count: 64)
    private let otherDigest = "sha256:" + String(repeating: "2", count: 64)

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "rootfs-cache-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeCache(
        _ root: String, ttl: TimeInterval = OCIRootfsCache.defaultTTL, maxSizeBytes: Int64? = nil
    ) -> OCIRootfsCache {
        OCIRootfsCache(rootPath: root, ttl: ttl, maxSizeBytes: maxSizeBytes, logger: Logger(label: "test"))
    }

    private func stageAndPublish(_ cache: OCIRootfsCache, digest: String) async throws -> CachedSandboxRootfs {
        let staging = try await cache.stagingDirectory(for: digest)
        try Data("image".utf8).write(
            to: URL(fileURLWithPath: staging + "/" + OCIRootfsCache.rootfsFileName))
        try Data("{}".utf8).write(
            to: URL(fileURLWithPath: staging + "/" + OCIRootfsCache.configFileName))
        return try await cache.publish(manifestDigest: digest)
    }

    @Test("publish is atomic and lookup finds the entry")
    func publishAndLookup() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = makeCache(root)

        let missBefore = await cache.lookup(manifestDigest: digest)
        #expect(missBefore == nil)

        let published = try await stageAndPublish(cache, digest: digest)
        #expect(FileManager.default.fileExists(atPath: published.rootfsPath))
        let hex = String(digest.dropFirst("sha256:".count))
        #expect(!FileManager.default.fileExists(atPath: root + "/images/" + hex + ".partial"))

        let hit = await cache.lookup(manifestDigest: digest)
        #expect(hit?.rootfsPath == published.rootfsPath)
        #expect(hit?.configPath == published.configPath)
    }

    @Test("a concurrent publish keeps the existing entry")
    func doublePublish() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = makeCache(root)

        let first = try await stageAndPublish(cache, digest: digest)
        // Second publication of the same digest: existing entry wins.
        let staging = try await cache.stagingDirectory(for: digest)
        try Data("other-image".utf8).write(
            to: URL(fileURLWithPath: staging + "/" + OCIRootfsCache.rootfsFileName))
        try Data("{}".utf8).write(
            to: URL(fileURLWithPath: staging + "/" + OCIRootfsCache.configFileName))
        let second = try await cache.publish(manifestDigest: digest)

        #expect(second.rootfsPath == first.rootfsPath)
        let content = FileManager.default.contents(atPath: second.rootfsPath)
        #expect(content == Data("image".utf8))
        #expect(!FileManager.default.fileExists(atPath: staging))
    }

    @Test("structurally incomplete entries read as misses and are removed")
    func incompleteEntry() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = makeCache(root)

        let hex = String(digest.dropFirst("sha256:".count))
        let entryDir = root + "/images/" + hex
        try FileManager.default.createDirectory(atPath: entryDir, withIntermediateDirectories: true)
        try Data("image".utf8).write(
            to: URL(fileURLWithPath: entryDir + "/" + OCIRootfsCache.rootfsFileName))
        // No config.json → incomplete.

        let result = await cache.lookup(manifestDigest: digest)
        #expect(result == nil)
        #expect(!FileManager.default.fileExists(atPath: entryDir))
    }

    @Test("malformed digests never become filesystem paths")
    func malformedDigests() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = makeCache(root)

        let traversal = await cache.lookup(manifestDigest: "sha256:../../../etc")
        #expect(traversal == nil)
        await #expect(throws: OCIError.self) {
            _ = try await cache.stagingDirectory(for: "not-a-digest")
        }
    }

    @Test("index aliases resolve and survive only while their target exists")
    func aliases() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = makeCache(root)

        let indexDigest = "sha256:" + String(repeating: "9", count: 64)
        _ = try await stageAndPublish(cache, digest: digest)
        await cache.storeAlias(indexDigest: indexDigest, architecture: .arm64, manifestDigest: digest)

        let target = await cache.aliasTarget(indexDigest: indexDigest, architecture: .arm64)
        #expect(target == digest)
        // Architecture is part of the key.
        let otherArch = await cache.aliasTarget(indexDigest: indexDigest, architecture: .x86_64)
        #expect(otherArch == nil)

        // Cleanup drops the alias once the target entry is gone.
        await cache.invalidate(manifestDigest: digest)
        await cache.cleanup()
        let afterCleanup = await cache.aliasTarget(indexDigest: indexDigest, architecture: .arm64)
        #expect(afterCleanup == nil)
    }

    @Test("cleanup evicts idle entries and stale staging directories")
    func ttlCleanup() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = makeCache(root, ttl: 3600)

        let idle = try await stageAndPublish(cache, digest: digest)
        let fresh = try await stageAndPublish(cache, digest: otherDigest)

        // Backdate the idle entry beyond the TTL, and plant a crashed
        // staging directory older than a day.
        let idleDir = (idle.rootfsPath as NSString).deletingLastPathComponent
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: idleDir)
        let stalePartial = root + "/images/" + String(repeating: "3", count: 64) + ".partial"
        try FileManager.default.createDirectory(atPath: stalePartial, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -100_000)], ofItemAtPath: stalePartial)

        await cache.cleanup()

        #expect(!FileManager.default.fileExists(atPath: idleDir))
        #expect(!FileManager.default.fileExists(atPath: stalePartial))
        #expect(FileManager.default.fileExists(atPath: fresh.rootfsPath))
    }

    @Test("cleanup evicts LRU entries beyond the size budget, protecting recent ones")
    func sizeBudgetCleanup() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // Each published entry is ~7 bytes ("image" + "{}"); a 10-byte budget
        // holds exactly one.
        let cache = makeCache(root, maxSizeBytes: 10)

        let older = try await stageAndPublish(cache, digest: digest)
        let newer = try await stageAndPublish(cache, digest: otherDigest)

        // Backdate the older entry past the eviction grace window (but well
        // within the idle TTL, so only the size budget can evict it).
        let olderDir = (older.rootfsPath as NSString).deletingLastPathComponent
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: olderDir)

        await cache.cleanup()

        #expect(!FileManager.default.fileExists(atPath: older.rootfsPath))
        #expect(FileManager.default.fileExists(atPath: newer.rootfsPath))
    }

    @Test("entries inside the grace window survive cleanup even over budget")
    func sizeBudgetGrace() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = makeCache(root, maxSizeBytes: 1)

        let entry = try await stageAndPublish(cache, digest: digest)
        await cache.cleanup()

        #expect(FileManager.default.fileExists(atPath: entry.rootfsPath))
    }

    @Test("lookups refresh the entry's last-use time")
    func lookupTouches() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = makeCache(root, ttl: 3600)

        let entry = try await stageAndPublish(cache, digest: digest)
        let entryDir = (entry.rootfsPath as NSString).deletingLastPathComponent
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: entryDir)

        // A lookup between backdating and cleanup keeps the entry alive.
        _ = await cache.lookup(manifestDigest: digest)
        await cache.cleanup()
        #expect(FileManager.default.fileExists(atPath: entry.rootfsPath))
    }
}
