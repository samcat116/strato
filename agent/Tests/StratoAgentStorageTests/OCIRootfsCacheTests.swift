import Foundation
import Logging
import Synchronization
import Testing
import StratoAgentTestSupport

@testable import StratoAgentCore

@Suite("OCI Rootfs Cache")
struct OCIRootfsCacheTests {

    @Test("invalidation during verification leaves a replacement entry untouched")
    func invalidationDuringVerification() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let started = AsyncStream<Void>.makeStream()
        // Only the dedicated verification queue waits on this semaphore.
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = Mutex(0)
        let cache = OCIRootfsCache(
            rootPath: root, logger: Logger(label: "test"),
            hashFile: { path in
                let first = calls.withLock { count in
                    count += 1; return count == 1
                }
                if first {
                    started.continuation.yield(())
                    release.wait()
                }
                return try FileHashing.sha256Hex(ofFileAt: path)
            })
        let published = try await stageAndPublish(cache, digest: digest)
        let directory = (published.rootfsPath as NSString).deletingLastPathComponent
        let completion = try Data(contentsOf: URL(fileURLWithPath: directory + "/" + OCIRootfsCache.completionFileName))
        let pending = Task { await cache.lookup(manifestDigest: digest) }
        var events = started.stream.makeAsyncIterator()
        _ = await events.next()
        // This must finish while hashing is suspended: the cache actor stays
        // responsive, and the old proof must not delete this successor.
        await cache.invalidate(manifestDigest: digest)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Data("wrong".utf8).write(to: URL(fileURLWithPath: published.rootfsPath))
        try Data("{}".utf8).write(to: URL(fileURLWithPath: published.configPath))
        try completion.write(to: URL(fileURLWithPath: directory + "/" + OCIRootfsCache.completionFileName))
        release.signal()
        #expect(await pending.value == nil)
        #expect(FileManager.default.fileExists(atPath: published.rootfsPath))
        // A later, independent lookup still detects the successor's damage.
        #expect(await cache.lookup(manifestDigest: digest) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory))
    }

    @Test(
        "concurrent warm cache lookup benchmark",
        .enabled(
            if:
                ProcessInfo.processInfo.environment["STRATO_CACHE_BENCHMARK"] == "1"))
    func concurrentLookupBenchmark() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = makeCache(root)
        let staging = try await cache.stagingDirectory(for: digest)
        try Data(repeating: 0x5a, count: 64 * 1024 * 1024).write(
            to: URL(fileURLWithPath: staging + "/" + OCIRootfsCache.rootfsFileName))
        try Data("{}".utf8).write(to: URL(fileURLWithPath: staging + "/" + OCIRootfsCache.configFileName))
        _ = try await cache.publish(manifestDigest: digest)
        let clock = ContinuousClock()
        for pass in 0..<3 {
            let start = clock.now
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<16 {
                    group.addTask { #expect(await cache.lookup(manifestDigest: digest) != nil) }
                }
            }
            print(
                "Rootfs lookup benchmark pass=\(pass) callers=16 bytes=67108864 elapsed=\(start.duration(to: clock.now))"
            )
        }
    }

    private let digest = "sha256:" + String(repeating: "1", count: 64)
    private let otherDigest = "sha256:" + String(repeating: "2", count: 64)

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
        let completionData = try Data(
            contentsOf: URL(
                fileURLWithPath: (published.rootfsPath as NSString).deletingLastPathComponent
                    + "/" + OCIRootfsCache.completionFileName))
        let completion = try #require(
            JSONSerialization.jsonObject(with: completionData) as? [String: Any])
        #expect((completion["rootfsSizeBytes"] as? NSNumber)?.int64Value == 5)
        let expectedRootfsHash = try FileHashing.sha256Hex(ofFileAt: published.rootfsPath)
        #expect(completion["rootfsSHA256"] as? String == expectedRootfsHash)
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

    @Test("a pre-durability entry without a completion sidecar is never served")
    func entryWithoutCompletionSidecar() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = makeCache(root)

        let hex = String(digest.dropFirst("sha256:".count))
        let entryDir = root + "/images/" + hex
        try FileManager.default.createDirectory(atPath: entryDir, withIntermediateDirectories: true)
        try Data("image".utf8).write(
            to: URL(fileURLWithPath: entryDir + "/" + OCIRootfsCache.rootfsFileName))
        try Data("{}".utf8).write(
            to: URL(fileURLWithPath: entryDir + "/" + OCIRootfsCache.configFileName))

        let result = await cache.lookup(manifestDigest: digest)

        #expect(result == nil)
        #expect(!FileManager.default.fileExists(atPath: entryDir))
    }

    @Test("a rootfs truncated after publication is invalidated on lookup")
    func truncatedRootfsMisses() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = makeCache(root)
        let published = try await stageAndPublish(cache, digest: digest)

        try Data("bad".utf8).write(to: URL(fileURLWithPath: published.rootfsPath))
        let result = await cache.lookup(manifestDigest: digest)

        #expect(result == nil)
        let entryDir = (published.rootfsPath as NSString).deletingLastPathComponent
        #expect(!FileManager.default.fileExists(atPath: entryDir))
    }

    @Test("a same-size rootfs overwrite is invalidated on lookup")
    func sameSizeRootfsDamageMisses() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = makeCache(root)
        let published = try await stageAndPublish(cache, digest: digest)
        #expect(await cache.lookup(manifestDigest: digest) != nil)

        try Data("wrong".utf8).write(to: URL(fileURLWithPath: published.rootfsPath))
        let result = await cache.lookup(manifestDigest: digest)

        #expect(result == nil)
        let entryDir = (published.rootfsPath as NSString).deletingLastPathComponent
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

    @Test("cleanup retains aged staging while builder termination is unconfirmed")
    func cleanupPreservesAgedBuildingStage() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cache = makeCache(root, ttl: 1, maxSizeBytes: 0)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let marked = try await cache.stagingDirectory(for: digest)
        let abandoned = try await cache.stagingDirectory(for: otherDigest)
        let payload = Data("potentially active output".utf8)
        try payload.write(to: URL(fileURLWithPath: marked + "/rootfs.ext4"))
        try Data().write(to: URL(fileURLWithPath: marked + "/.building"))
        for path in [marked, abandoned] {
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-172_800)], ofItemAtPath: path)
        }
        await cache.cleanup(now: now)
        #expect(FileManager.default.fileExists(atPath: marked + "/.building"))
        #expect(FileManager.default.contents(atPath: marked + "/rootfs.ext4") == payload)
        #expect(!FileManager.default.fileExists(atPath: abandoned))
        await #expect(throws: SubprocessStagingBlockedError.self) {
            try await cache.stagingDirectory(for: digest)
        }
    }

    @Test("cleanup evicts LRU entries beyond the size budget, protecting recent ones")
    func sizeBudgetCleanup() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // The budget is below one completed entry, so only the recent-use
        // grace window protects the newer publication.
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
