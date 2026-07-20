import Crypto
import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("ImageCacheService")
struct ImageCacheServiceTests {

    // MARK: - Fixtures

    private static let imageBytes = Data("a cold image that two workloads both want".utf8)

    private static var imageChecksum: String {
        SHA256.hash(data: imageBytes).map { String(format: "%02x", $0) }.joined()
    }

    private func makeImageInfo(artifacts: [ArtifactInfo] = []) -> ImageInfo {
        ImageInfo(
            imageId: UUID(),
            projectId: UUID(),
            filename: "disk.qcow2",
            checksum: Self.imageChecksum,
            size: Int64(Self.imageBytes.count),
            downloadURL: "https://control-plane.example/images/disk.qcow2",
            artifacts: artifacts
        )
    }

    private func makeTempDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "/image-cache-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Records every fetch and can hold them all open, so a test can guarantee the window
    /// where the old check-then-download raced: both callers past the cache check, neither
    /// finished downloading.
    private actor FetchRecorder {
        private(set) var fetches = 0
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func beginAndWait() async {
            fetches += 1
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            released = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    /// A fetcher that writes the fixture bytes to a fresh temp file, mimicking URLSession's
    /// contract of handing the caller ownership of a downloaded temporary file.
    private func recordingFetcher(
        recorder: FetchRecorder, bytes: Data = ImageCacheServiceTests.imageBytes
    ) -> ImageCacheService.Fetcher {
        { _ in
            await recorder.beginAndWait()
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory() + "/download-" + UUID().uuidString)
            try bytes.write(to: tempURL)
            return tempURL
        }
    }

    // MARK: - Concurrency

    @Test("Concurrent creates against one cold image download it once and both succeed")
    func concurrentCallersShareOneDownload() async throws {
        let cachePath = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: cachePath) }

        let recorder = FetchRecorder()
        let service = ImageCacheService(
            logger: Logger(label: "test"),
            cachePath: cachePath,
            controlPlaneURL: "https://control-plane.example",
            fetch: recordingFetcher(recorder: recorder)
        )
        let imageInfo = makeImageInfo()

        // Two workloads placed on this agent at the same time, both needing the same
        // not-yet-cached image.
        let callers = (0..<2).map { _ in
            Task { try await service.getImagePath(imageInfo: imageInfo) }
        }

        while await recorder.fetches == 0 {
            await Task.yield()
        }
        // Give the second caller time to reach the cache check while the first is suspended
        // mid-download — the exact interleaving that used to produce two downloads racing to
        // publish the same path.
        try await Task.sleep(for: .milliseconds(50))
        await recorder.release()

        let expectedPath = await service.buildCachePath(imageInfo: imageInfo)
        for caller in callers {
            let path = try await caller.value
            #expect(path == expectedPath)
        }

        let fetches = await recorder.fetches
        #expect(fetches == 1)
        #expect(FileManager.default.allFilesRecursively(under: cachePath).allSatisfy { !$0.contains(".partial") })
        let cached = try Data(contentsOf: URL(fileURLWithPath: expectedPath))
        #expect(cached == Self.imageBytes)
    }

    @Test("Concurrent artifact requests for one artifact download it once")
    func concurrentArtifactCallersShareOneDownload() async throws {
        let cachePath = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: cachePath) }

        let recorder = FetchRecorder()
        let service = ImageCacheService(
            logger: Logger(label: "test"),
            cachePath: cachePath,
            controlPlaneURL: "https://control-plane.example",
            fetch: recordingFetcher(recorder: recorder)
        )
        let artifact = ArtifactInfo(
            kind: .kernel,
            filename: "vmlinux",
            checksum: Self.imageChecksum,
            size: Int64(Self.imageBytes.count),
            downloadURL: "https://control-plane.example/images/vmlinux"
        )
        let imageInfo = makeImageInfo(artifacts: [artifact])

        let callers = (0..<3).map { _ in
            Task { try await service.getArtifactPath(imageInfo: imageInfo, kind: .kernel) }
        }

        while await recorder.fetches == 0 {
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(50))
        await recorder.release()

        let expectedPath = await service.buildArtifactCachePath(imageInfo: imageInfo, artifact: artifact)
        for caller in callers {
            let path = try await caller.value
            #expect(path == expectedPath)
        }
        let fetches = await recorder.fetches
        #expect(fetches == 1)
    }

    @Test("A replaced artifact does not join the outgoing bytes' flight")
    func differentChecksumDoesNotJoinTheSameFlight() async throws {
        let cachePath = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: cachePath) }

        // `uploadArtifact` replaces an artifact of a kind in place, so a re-upload under the
        // same filename keeps the destination path and changes only the checksum. A create
        // carrying the new ImageInfo must not join the in-flight download of the old bytes.
        let replacementBytes = Data("the replacement bytes uploaded over the old ones".utf8)
        let replacementChecksum = SHA256.hash(data: replacementBytes)
            .map { String(format: "%02x", $0) }.joined()

        let recorder = FetchRecorder()
        let service = ImageCacheService(
            logger: Logger(label: "test"),
            cachePath: cachePath,
            controlPlaneURL: "https://control-plane.example",
            fetch: { url in
                await recorder.beginAndWait()
                let tempURL = URL(fileURLWithPath: NSTemporaryDirectory() + "/download-" + UUID().uuidString)
                let bytes = url.absoluteString.contains("v2") ? replacementBytes : Self.imageBytes
                try bytes.write(to: tempURL)
                return tempURL
            }
        )

        let original = makeImageInfo()
        // Same imageId/projectId/filename — so the same destination path — but new bytes.
        let replaced = ImageInfo(
            imageId: original.imageId,
            projectId: original.projectId,
            filename: original.filename,
            checksum: replacementChecksum,
            size: Int64(replacementBytes.count),
            downloadURL: original.downloadURL + "?v2"
        )

        let first = Task { try await service.getImagePath(imageInfo: original) }
        while await recorder.fetches == 0 {
            await Task.yield()
        }
        let second = Task { try await service.getImagePath(imageInfo: replaced) }
        // Let the second caller reach the cache check while the first is mid-download.
        try await Task.sleep(for: .milliseconds(50))
        await recorder.release()

        _ = try await first.value
        _ = try await second.value

        // Two distinct checksums means two flights, not one shared result.
        let fetches = await recorder.fetches
        #expect(fetches == 2)
    }

    @Test("A cached image is served without downloading again")
    func cacheHitSkipsDownload() async throws {
        let cachePath = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: cachePath) }

        let recorder = FetchRecorder()
        await recorder.release()
        let service = ImageCacheService(
            logger: Logger(label: "test"),
            cachePath: cachePath,
            controlPlaneURL: "https://control-plane.example",
            fetch: recordingFetcher(recorder: recorder)
        )
        let imageInfo = makeImageInfo()

        _ = try await service.getImagePath(imageInfo: imageInfo)
        _ = try await service.getImagePath(imageInfo: imageInfo)

        let fetches = await recorder.fetches
        #expect(fetches == 1)
    }

    // MARK: - Publish

    /// Note: this covers publish *idempotency* — a re-download over an occupied destination
    /// replaces it rather than failing. The narrower interleaving the atomic rename exists for
    /// (the destination appearing between another writer's existence check and its own move)
    /// is not deterministically reproducible from here; the rename(2) publish removes the
    /// window rather than being observable through it.
    @Test("Downloading over an occupied cache path replaces it")
    func publishReplacesAnExistingDestination() async throws {
        let cachePath = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: cachePath) }

        let recorder = FetchRecorder()
        await recorder.release()
        let service = ImageCacheService(
            logger: Logger(label: "test"),
            cachePath: cachePath,
            controlPlaneURL: "https://control-plane.example",
            fetch: recordingFetcher(recorder: recorder)
        )
        let imageInfo = makeImageInfo()
        let destination = await service.buildCachePath(imageInfo: imageInfo)

        // Stand in for another writer having published the same image between this caller's
        // cache check and its own publish: bytes that don't match the checksum, so the cache
        // check misses and the download path runs all the way to the rename.
        try FileManager.default.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("stale bytes from a concurrent writer".utf8)
            .write(to: URL(fileURLWithPath: destination))

        let path = try await service.getImagePath(imageInfo: imageInfo)
        #expect(path == destination)
        let cached = try Data(contentsOf: URL(fileURLWithPath: destination))
        #expect(cached == Self.imageBytes)
    }

    // MARK: - Failures

    @Test("Checksum mismatches fail without publishing bytes to the cache path")
    func checksumMismatchLeavesCacheClean() async throws {
        let cachePath = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: cachePath) }

        let recorder = FetchRecorder()
        await recorder.release()
        let service = ImageCacheService(
            logger: Logger(label: "test"),
            cachePath: cachePath,
            controlPlaneURL: "https://control-plane.example",
            fetch: recordingFetcher(recorder: recorder, bytes: Data("not the expected bytes".utf8))
        )
        let imageInfo = makeImageInfo()

        await #expect(throws: ImageCacheError.self) {
            _ = try await service.getImagePath(imageInfo: imageInfo)
        }

        let destination = await service.buildCachePath(imageInfo: imageInfo)
        #expect(!FileManager.default.fileExists(atPath: destination))
        // No staging file survives a failed download either.
        #expect(FileManager.default.allFilesRecursively(under: cachePath).allSatisfy { !$0.contains(".partial") })
    }

    @Test("Transient fetch failures are retried, and the retry's bytes are published")
    func transientFailuresAreRetried() async throws {
        let cachePath = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: cachePath) }

        let attempts = Counter()
        let service = ImageCacheService(
            logger: Logger(label: "test"),
            cachePath: cachePath,
            controlPlaneURL: "https://control-plane.example",
            fetch: { _ in
                let attempt = await attempts.increment()
                if attempt == 1 {
                    throw ImageCacheService.TransientDownloadFailure(reason: "HTTP 503")
                }
                let tempURL = URL(fileURLWithPath: NSTemporaryDirectory() + "/download-" + UUID().uuidString)
                try Self.imageBytes.write(to: tempURL)
                return tempURL
            }
        )
        let imageInfo = makeImageInfo()

        let path = try await service.getImagePath(imageInfo: imageInfo)
        let cached = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(cached == Self.imageBytes)
        let total = await attempts.value
        #expect(total == 2)
    }

    private actor Counter {
        private(set) var value = 0
        func increment() -> Int {
            value += 1
            return value
        }
    }

    // MARK: - Download URL resolution (issue #493)

    private actor URLRecorder {
        private(set) var urls: [URL] = []
        func record(_ url: URL) { urls.append(url) }
    }

    /// A fetcher that records the URL it was asked for and serves the fixture bytes.
    private func urlRecordingFetcher(recorder: URLRecorder) -> ImageCacheService.Fetcher {
        { url in
            await recorder.record(url)
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory() + "/download-" + UUID().uuidString)
            try Self.imageBytes.write(to: tempURL)
            return tempURL
        }
    }

    @Test("A relative download path resolves against the control-plane base URL")
    func relativeDownloadURLResolvesAgainstBase() async throws {
        let cachePath = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: cachePath) }

        let recorder = URLRecorder()
        let service = ImageCacheService(
            logger: Logger(label: "test"),
            cachePath: cachePath,
            controlPlaneURL: "https://cp.example:8443",
            fetch: urlRecordingFetcher(recorder: recorder)
        )

        // The v13+ wire format: a control-plane-relative path with no scheme,
        // host, or credential — the agent supplies the base it already dials.
        let imageId = UUID()
        let projectId = UUID()
        let info = ImageInfo(
            imageId: imageId,
            projectId: projectId,
            filename: "disk.qcow2",
            checksum: Self.imageChecksum,
            size: Int64(Self.imageBytes.count),
            downloadURL: "/api/projects/\(projectId)/images/\(imageId)/download"
        )

        _ = try await service.getImagePath(imageInfo: info)

        let fetched = await recorder.urls
        #expect(
            fetched.map(\.absoluteString) == [
                "https://cp.example:8443/api/projects/\(projectId)/images/\(imageId)/download"
            ])
    }

    @Test("An absolute download URL passes through unresolved")
    func absoluteDownloadURLPassesThrough() async throws {
        let cachePath = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: cachePath) }

        let recorder = URLRecorder()
        let service = ImageCacheService(
            logger: Logger(label: "test"),
            cachePath: cachePath,
            controlPlaneURL: "https://cp.example:8443",
            fetch: urlRecordingFetcher(recorder: recorder)
        )

        _ = try await service.getImagePath(imageInfo: makeImageInfo())

        let fetched = await recorder.urls
        #expect(fetched.map(\.absoluteString) == ["https://control-plane.example/images/disk.qcow2"])
    }
}

extension FileManager {
    /// Every file under `path`, recursively, as relative paths — used to assert that no
    /// staging artifacts are left behind.
    fileprivate func allFilesRecursively(under path: String) -> [String] {
        guard let enumerator = enumerator(atPath: path) else { return [] }
        return enumerator.compactMap { $0 as? String }
    }
}
