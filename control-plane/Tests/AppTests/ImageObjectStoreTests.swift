import Foundation
import NIOCore
import Testing
import Vapor

@testable import App

@Suite("Image object store", .serialized)
final class ImageObjectStoreTests {

    // MARK: - Helpers

    static func createTempStorageDirectory() throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let storagePath = tempDir.appendingPathComponent("strato-test-storage-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: storagePath, withIntermediateDirectories: true)
        return storagePath
    }

    static func cleanupTempStorageDirectory(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    static func buffer(_ content: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: content.utf8.count)
        buffer.writeString(content)
        return buffer
    }

    /// Writes `content` to `key` through the store's streaming writer.
    static func write(_ content: String, to key: String, in store: some ImageObjectStore) async throws {
        let writer = try await store.openWriter(key: key)
        try await writer.write(buffer(content))
        try await writer.finish()
    }

    // MARK: - Key building

    @Test("Image key is project/image/filename")
    func imageKey() {
        let projectId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let imageId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let key = ImageObjectKey.image(projectId: projectId, imageId: imageId, filename: "disk.qcow2")

        #expect(key == "\(projectId)/\(imageId)/disk.qcow2")
    }

    @Test("Artifact key inserts the kind segment so kinds can't collide on filename")
    func artifactKey() {
        let projectId = UUID()
        let imageId = UUID()

        let rootfs = ImageObjectKey.artifact(
            projectId: projectId, imageId: imageId, kind: "rootfs", filename: "disk.img")
        let disk = ImageObjectKey.artifact(
            projectId: projectId, imageId: imageId, kind: "disk-image", filename: "disk.img")

        #expect(rootfs != disk)
        #expect(rootfs == "\(projectId)/\(imageId)/rootfs/disk.img")
    }

    @Test("Image prefix covers every object for one image")
    func imagePrefix() {
        let projectId = UUID()
        let imageId = UUID()

        let prefix = ImageObjectKey.imagePrefix(projectId: projectId, imageId: imageId)

        let disk = ImageObjectKey.image(projectId: projectId, imageId: imageId, filename: "d.qcow2")
        let kernel = ImageObjectKey.artifact(
            projectId: projectId, imageId: imageId, kind: "kernel", filename: "vmlinuz")
        #expect(disk.hasPrefix(prefix))
        #expect(kernel.hasPrefix(prefix))
    }

    // MARK: - Filesystem backend

    @Test("Write then read back content, size and existence")
    func writeAndReadBack() async throws {
        let root = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(root) }
        let store = FilesystemImageObjectStore(rootPath: root)
        let key = "project/image/disk.qcow2"

        try await Self.write("hello world", to: key, in: store)

        #expect(try await store.exists(key: key))
        #expect(try await store.size(key: key) == 11)
        let onDisk = try String(contentsOfFile: "\(root)/\(key)", encoding: .utf8)
        #expect(onDisk == "hello world")
    }

    @Test("Writer creates intermediate directories")
    func createsIntermediateDirectories() async throws {
        let root = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(root) }
        let store = FilesystemImageObjectStore(rootPath: root)

        try await Self.write("x", to: "a/b/c/d/file.img", in: store)

        #expect(try await store.exists(key: "a/b/c/d/file.img"))
    }

    @Test("Multiple writes concatenate in order")
    func multipleWritesConcatenate() async throws {
        let root = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(root) }
        let store = FilesystemImageObjectStore(rootPath: root)
        let key = "p/i/multi.img"

        let writer = try await store.openWriter(key: key)
        try await writer.write(Self.buffer("one"))
        try await writer.write(Self.buffer("two"))
        try await writer.write(Self.buffer("three"))
        try await writer.finish()

        let onDisk = try String(contentsOfFile: "\(root)/\(key)", encoding: .utf8)
        #expect(onDisk == "onetwothree")
    }

    @Test("An empty write produces a zero-byte object")
    func emptyWrite() async throws {
        let root = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(root) }
        let store = FilesystemImageObjectStore(rootPath: root)
        let key = "p/i/empty.img"

        let writer = try await store.openWriter(key: key)
        try await writer.finish()

        #expect(try await store.exists(key: key))
        #expect(try await store.size(key: key) == 0)
    }

    @Test("An unfinished write leaves nothing at the key")
    func unfinishedWriteIsInvisible() async throws {
        let root = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(root) }
        let store = FilesystemImageObjectStore(rootPath: root)
        let key = "p/i/partial.img"

        let writer = try await store.openWriter(key: key)
        try await writer.write(Self.buffer("half an image"))
        // No finish() — this is the crash/failure path.

        #expect(try await store.exists(key: key) == false)
    }

    @Test("Aborting a write removes the staging file and leaves the key empty")
    func abortCleansUp() async throws {
        let root = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(root) }
        let store = FilesystemImageObjectStore(rootPath: root)
        let key = "p/i/aborted.img"

        let writer = try await store.openWriter(key: key)
        try await writer.write(Self.buffer("doomed"))
        await writer.abort()

        #expect(try await store.exists(key: key) == false)
        // The staging sibling must be gone too, not just unpublished.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: "\(root)/p/i")
        #expect(siblings.isEmpty)
    }

    @Test("A failed rewrite does not destroy the object already at that key")
    func failedRewritePreservesExisting() async throws {
        let root = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(root) }
        let store = FilesystemImageObjectStore(rootPath: root)
        let key = "p/i/disk.qcow2"

        try await Self.write("good bytes", to: key, in: store)

        // A second upload to the same key that dies mid-flight.
        let writer = try await store.openWriter(key: key)
        try await writer.write(Self.buffer("corrupt"))
        await writer.abort()

        let onDisk = try String(contentsOfFile: "\(root)/\(key)", encoding: .utf8)
        #expect(onDisk == "good bytes")
    }

    @Test("Finishing over an existing key replaces it")
    func overwriteReplaces() async throws {
        let root = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(root) }
        let store = FilesystemImageObjectStore(rootPath: root)
        let key = "p/i/disk.qcow2"

        try await Self.write("first", to: key, in: store)
        try await Self.write("second", to: key, in: store)

        let onDisk = try String(contentsOfFile: "\(root)/\(key)", encoding: .utf8)
        #expect(onDisk == "second")
    }

    @Test("Delete removes one object and leaves siblings alone")
    func deleteOne() async throws {
        let root = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(root) }
        let store = FilesystemImageObjectStore(rootPath: root)

        try await Self.write("a", to: "p/i/a.img", in: store)
        try await Self.write("b", to: "p/i/b.img", in: store)

        try await store.delete(key: "p/i/a.img")

        #expect(try await store.exists(key: "p/i/a.img") == false)
        #expect(try await store.exists(key: "p/i/b.img"))
    }

    @Test("Deleting a missing object is not an error")
    func deleteMissingIsNoop() async throws {
        let root = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(root) }
        let store = FilesystemImageObjectStore(rootPath: root)

        try await store.delete(key: "p/i/never-existed.img")
    }

    @Test("Delete prefix removes an image's disk and all of its artifacts")
    func deletePrefixRemovesEverything() async throws {
        let root = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(root) }
        let store = FilesystemImageObjectStore(rootPath: root)
        let projectId = UUID()
        let imageId = UUID()

        let disk = ImageObjectKey.image(projectId: projectId, imageId: imageId, filename: "d.qcow2")
        let kernel = ImageObjectKey.artifact(
            projectId: projectId, imageId: imageId, kind: "kernel", filename: "vmlinuz")
        try await Self.write("disk", to: disk, in: store)
        try await Self.write("kernel", to: kernel, in: store)

        try await store.deletePrefix(ImageObjectKey.imagePrefix(projectId: projectId, imageId: imageId))

        #expect(try await store.exists(key: disk) == false)
        #expect(try await store.exists(key: kernel) == false)
    }

    @Test("Delete prefix leaves other images in the same project alone")
    func deletePrefixIsScopedToOneImage() async throws {
        let root = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(root) }
        let store = FilesystemImageObjectStore(rootPath: root)
        let projectId = UUID()
        let doomed = UUID()
        let survivor = UUID()

        let doomedKey = ImageObjectKey.image(projectId: projectId, imageId: doomed, filename: "d.qcow2")
        let survivorKey = ImageObjectKey.image(
            projectId: projectId, imageId: survivor, filename: "s.qcow2")
        try await Self.write("doomed", to: doomedKey, in: store)
        try await Self.write("survivor", to: survivorKey, in: store)

        try await store.deletePrefix(ImageObjectKey.imagePrefix(projectId: projectId, imageId: doomed))

        #expect(try await store.exists(key: doomedKey) == false)
        #expect(try await store.exists(key: survivorKey))
    }

    @Test("Size throws for a missing object")
    func sizeOfMissingThrows() async throws {
        let root = try Self.createTempStorageDirectory()
        defer { Self.cleanupTempStorageDirectory(root) }
        let store = FilesystemImageObjectStore(rootPath: root)

        await #expect(throws: (any Error).self) {
            _ = try await store.size(key: "p/i/missing.img")
        }
    }

    @Test("Default root path honours IMAGE_STORAGE_PATH, else a platform default")
    func defaultRootPath() {
        let path = FilesystemImageObjectStore.defaultRootPath
        #expect(!path.isEmpty)
        if Environment.get("IMAGE_STORAGE_PATH") == nil {
            #if os(macOS)
            #expect(path.contains("Library/Application Support/strato/images"))
            #else
            #expect(path == "/var/lib/strato/images")
            #endif
        }
    }
}

@Suite("Byte range parsing")
struct ByteRangeRequestTests {

    @Test("Absent header means no range")
    func absentHeader() {
        #expect(ByteRangeRequest.parse(nil, totalSize: 100) == nil)
    }

    @Test("Closed range")
    func closedRange() {
        let range = ByteRangeRequest.parse("bytes=10-19", totalSize: 100)
        #expect(range == ByteRangeRequest(start: 10, end: 19))
    }

    @Test("Open-ended range runs to the last byte")
    func openEndedRange() {
        let range = ByteRangeRequest.parse("bytes=10-", totalSize: 100)
        #expect(range == ByteRangeRequest(start: 10, end: 99))
    }

    @Test("Suffix range counts back from the end")
    func suffixRange() {
        let range = ByteRangeRequest.parse("bytes=-20", totalSize: 100)
        #expect(range == ByteRangeRequest(start: 80, end: 99))
    }

    @Test("A suffix longer than the object clamps to the whole object")
    func oversizeSuffix() {
        let range = ByteRangeRequest.parse("bytes=-500", totalSize: 100)
        #expect(range == ByteRangeRequest(start: 0, end: 99))
    }

    @Test("An end past the object clamps to the last byte")
    func endBeyondObject() {
        let range = ByteRangeRequest.parse("bytes=90-500", totalSize: 100)
        #expect(range == ByteRangeRequest(start: 90, end: 99))
    }

    @Test("A start at or past the end is unsatisfiable, so serve the whole object")
    func startBeyondObject() {
        #expect(ByteRangeRequest.parse("bytes=100-", totalSize: 100) == nil)
        #expect(ByteRangeRequest.parse("bytes=500-600", totalSize: 100) == nil)
    }

    @Test("Multi-range is unsupported and falls back to the whole object")
    func multiRangeUnsupported() {
        // Answering these would need a multipart/byteranges body; serving the
        // whole object is a legal response and no agent asks for them.
        #expect(ByteRangeRequest.parse("bytes=0-9,20-29", totalSize: 100) == nil)
    }

    @Test("Malformed headers fall back to the whole object")
    func malformedHeaders() {
        #expect(ByteRangeRequest.parse("items=0-9", totalSize: 100) == nil)
        #expect(ByteRangeRequest.parse("bytes=abc-def", totalSize: 100) == nil)
        #expect(ByteRangeRequest.parse("bytes=", totalSize: 100) == nil)
        #expect(ByteRangeRequest.parse("bytes=20-10", totalSize: 100) == nil)
    }

    @Test("Header and Content-Range round-trip")
    func headerFormatting() {
        let range = ByteRangeRequest(start: 10, end: 19)
        #expect(range.headerValue == "bytes=10-19")
        #expect(range.contentRangeValue(totalSize: 100) == "bytes 10-19/100")
    }
}
