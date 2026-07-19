import Foundation
import NIOCore
import NIOPosix
import Vapor

/// Stores image bytes on the control plane's local filesystem.
///
/// This is the default backend and behaves exactly as the control plane always
/// has: object keys become paths under a root directory, so an existing
/// `IMAGE_STORAGE_PATH` volume keeps working across the upgrade with no
/// migration.
///
/// Note that a single-host filesystem does not survive the control plane being
/// replicated or rescheduled — see the Kubernetes caveat in
/// `docs/architecture/storage.md`. Deployments that need durability across
/// replicas should use `S3ImageObjectStore`.
struct FilesystemImageObjectStore: ImageObjectStore {
    let rootPath: String
    let threadPool: NIOThreadPool

    init(rootPath: String, threadPool: NIOThreadPool = .singleton) {
        self.rootPath = rootPath
        self.threadPool = threadPool
    }

    /// Platform-appropriate default, overridable with `IMAGE_STORAGE_PATH`.
    static var defaultRootPath: String {
        if let configured = Environment.get("IMAGE_STORAGE_PATH") {
            return configured
        }
        #if os(macOS)
        // On macOS, use the user's data directory (writable without root).
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/strato/images"
        #else
        // On Linux, use the system data directory.
        return "/var/lib/strato/images"
        #endif
    }

    func path(for key: String) -> String {
        "\(rootPath)/\(key)"
    }

    func openWriter(key: String) async throws -> any ImageObjectWriter {
        let destination = path(for: key)
        let directory = (destination as NSString).deletingLastPathComponent

        // Stage next to the destination rather than in the system temp dir:
        // the two may be different filesystems, which would turn the publish
        // rename into a cross-device copy of a multi-gigabyte image.
        let staging = "\(destination).partial.\(UUID().uuidString)"

        try await threadPool.runIfActive {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: nil)
            Self.sweepStaleStagingFiles(in: directory)
            guard FileManager.default.createFile(atPath: staging, contents: nil) else {
                throw ImageError.storageFailed("Failed to create staging file for \(key)")
            }
        }

        guard let handle = FileHandle(forWritingAtPath: staging) else {
            try? FileManager.default.removeItem(atPath: staging)
            throw ImageError.storageFailed("Failed to open staging file for \(key)")
        }

        return FilesystemImageObjectWriter(
            handle: handle,
            stagingPath: staging,
            destinationPath: destination,
            threadPool: threadPool
        )
    }

    /// Age past which an abandoned `.partial.*` file is assumed dead.
    ///
    /// Comfortably longer than any legitimate upload: a 4 GiB image over a slow
    /// link is still hours short of this, so an in-flight sibling upload is
    /// never swept out from under itself.
    static let stagingFileTTL: TimeInterval = 24 * 60 * 60

    /// Removes abandoned staging files left in `directory` by a control plane
    /// that died mid-upload.
    ///
    /// Without this they are invisible garbage: nothing references them, and
    /// only deleting the whole image would ever clear them. Swept here, on the
    /// directory an upload is about to write to, rather than by a boot-time
    /// walk of the entire store — the work lands where it's cheap and where a
    /// leak would otherwise accumulate. Best-effort throughout; a failure to
    /// tidy must never fail the upload.
    private static func sweepStaleStagingFiles(in directory: String) {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(atPath: directory)
        else { return }

        let cutoff = Date().addingTimeInterval(-stagingFileTTL)
        for entry in entries where entry.contains(".partial.") {
            let candidate = "\(directory)/\(entry)"
            guard
                let attributes = try? FileManager.default.attributesOfItem(atPath: candidate),
                let modified = attributes[.modificationDate] as? Date,
                modified < cutoff
            else { continue }
            try? FileManager.default.removeItem(atPath: candidate)
        }
    }

    func delete(key: String) async throws {
        let fullPath = path(for: key)
        try await threadPool.runIfActive {
            if FileManager.default.fileExists(atPath: fullPath) {
                try FileManager.default.removeItem(atPath: fullPath)
            }
        }
    }

    func deletePrefix(_ prefix: String) async throws {
        let fullPath = path(for: prefix)
        try await threadPool.runIfActive {
            if FileManager.default.fileExists(atPath: fullPath) {
                try FileManager.default.removeItem(atPath: fullPath)
            }
        }
    }

    func exists(key: String) async throws -> Bool {
        let fullPath = path(for: key)
        return try await threadPool.runIfActive {
            FileManager.default.fileExists(atPath: fullPath)
        }
    }

    func size(key: String) async throws -> Int64 {
        let fullPath = path(for: key)
        return try await threadPool.runIfActive {
            let attributes = try FileManager.default.attributesOfItem(atPath: fullPath)
            guard let size = attributes[.size] as? Int64 else {
                throw ImageError.storageFailed("Could not determine file size")
            }
            return size
        }
    }

    func stream(key: String, filename: String, on req: Request) async throws -> Response {
        let fullPath = path(for: key)

        guard try await exists(key: key) else {
            throw Abort(.notFound, reason: "Image file not found")
        }

        // `asyncStreamFile` handles `Range` itself, answering with a 206 and a
        // matching Content-Range.
        let response = try await req.fileio.asyncStreamFile(at: fullPath)

        // Deliberately does NOT set Content-Length. asyncStreamFile already
        // sets it from the body's byte count, and for a `Range` request that
        // count is the requested slice, not the whole file (the response is a
        // 206 with a matching Content-Range). Adding it here emitted the header
        // twice, which nginx rejects outright ("upstream sent duplicate header
        // line") with a 502 — that broke image downloads for every agent in the
        // nginx-fronted deployment, so no VM could boot. Overriding it with the
        // full file size instead would be just as wrong: partial responses
        // would advertise more bytes than they stream, hanging or failing
        // validation on resumable downloads.
        //
        // Content-Disposition is ours to set; asyncStreamFile never sets it.
        response.headers.replaceOrAdd(
            name: .contentDisposition, value: "attachment; filename=\"\(filename)\"")

        return response
    }
}

/// Writes to a staging file and publishes with `rename(2)` so a failed or
/// interrupted upload never leaves a truncated image at the real key — an agent
/// fetching one would get bytes that fail checksum verification at best, and
/// boot a corrupt disk at worst.
private final class FilesystemImageObjectWriter: ImageObjectWriter, @unchecked Sendable {
    private let handle: FileHandle
    private let stagingPath: String
    private let destinationPath: String
    private let threadPool: NIOThreadPool

    init(handle: FileHandle, stagingPath: String, destinationPath: String, threadPool: NIOThreadPool) {
        self.handle = handle
        self.stagingPath = stagingPath
        self.destinationPath = destinationPath
        self.threadPool = threadPool
    }

    func write(_ buffer: ByteBuffer) async throws {
        guard buffer.readableBytes > 0 else { return }
        // One copy, not two: `readBytes` into `[UInt8]` and then `Data(bytes)`
        // duplicated every chunk of a multi-gigabyte upload.
        let data = Data(buffer.readableBytesView)
        let handle = self.handle
        try await threadPool.runIfActive {
            try handle.write(contentsOf: data)
        }
    }

    func finish() async throws {
        let handle = self.handle
        let staging = stagingPath
        let destination = destinationPath
        try await threadPool.runIfActive {
            try handle.close()
            // POSIX rename rather than FileManager.moveItem: moveItem throws
            // when the destination exists, which would make replacing an
            // artifact a check-then-move race. rename(2) is atomic and
            // overwrites.
            guard rename(staging, destination) == 0 else {
                throw ImageError.storageFailed(
                    "Failed to publish image file: \(String(cString: strerror(errno)))")
            }
        }
    }

    func abort() async {
        let handle = self.handle
        let staging = stagingPath
        try? await threadPool.runIfActive {
            try? handle.close()
            try? FileManager.default.removeItem(atPath: staging)
        }
    }
}
