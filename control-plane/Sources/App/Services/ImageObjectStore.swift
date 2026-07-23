import Foundation
import NIOCore
import Vapor

/// Where the control plane keeps image bytes.
///
/// Object keys are the same relative paths the database has always stored in
/// `Image.storagePath` / `ImageArtifact.storagePath`
/// (`{projectId}/{imageId}/{filename}`, or `{projectId}/{imageId}/{kind}/{filename}`
/// for typed artifacts), so switching backends needs no migration of existing
/// rows — only of the bytes themselves.
///
/// Agents never talk to a store directly. They fetch through the control
/// plane's `/download` route, which is what lets that route's authentication
/// change independently of where the bytes live (agent SVID mTLS since issue
/// #493, HMAC-signed URLs before it).
protocol ImageObjectStore: Sendable {
    /// Opens a streaming writer. Callers must `finish()` on success or
    /// `abort()` on failure; an unfinished write leaves no visible object.
    func openWriter(key: String) async throws -> any ImageObjectWriter

    func delete(key: String) async throws

    /// Deletes every object under a key prefix — used when an image is deleted
    /// and all of its artifacts go with it.
    func deletePrefix(_ prefix: String) async throws

    func exists(key: String) async throws -> Bool

    func size(key: String) async throws -> Int64

    /// Builds a download response for `key`, honouring a `Range` request header.
    ///
    /// Implementations must NOT set `Content-Length` themselves. See
    /// `FilesystemImageObjectStore.stream` for the incident this rule comes from.
    func stream(key: String, filename: String, on req: Request) async throws -> Response
}

/// A streaming sink for one object.
///
/// Deliberately not `AnyObject`-constrained to a class hierarchy: the S3
/// implementation holds multipart-upload state, the filesystem one holds a file
/// descriptor, and neither should leak into the protocol.
protocol ImageObjectWriter: Sendable {
    /// Appends bytes. Backends may buffer internally (S3 parts have a 5 MiB
    /// minimum), so bytes are not necessarily durable until `finish()`.
    func write(_ buffer: ByteBuffer) async throws

    /// Publishes the object. After this returns, the key is readable.
    func finish() async throws

    /// Discards everything written so far. Must not throw — it runs on the
    /// failure path, where a second error would mask the first.
    func abort() async
}

// MARK: - Key construction

enum ImageObjectKey {
    /// `{projectId}/{imageId}/{filename}` — an image's primary disk.
    static func image(projectId: UUID, imageId: UUID, filename: String) -> String {
        "\(projectId)/\(imageId)/\(filename)"
    }

    /// `{projectId}/{imageId}/{kind}/{filename}` — a typed artifact. The kind
    /// segment keeps artifacts of different kinds from colliding on filename
    /// (a `rootfs` and a `disk-image` may both be called `disk.img`).
    static func artifact(projectId: UUID, imageId: UUID, kind: String, filename: String) -> String {
        "\(projectId)/\(imageId)/\(kind)/\(filename)"
    }

    /// Every object belonging to one image.
    static func imagePrefix(projectId: UUID, imageId: UUID) -> String {
        "\(projectId)/\(imageId)"
    }
}

// MARK: - Range requests

/// A parsed single-range `Range: bytes=...` header.
///
/// Only the single-range forms are understood. Multi-range requests
/// (`bytes=0-99,200-299`) would need a `multipart/byteranges` body; no agent
/// issues them, so they're treated as absent and answered with the full object.
struct ByteRangeRequest: Equatable {
    /// Inclusive first byte.
    var start: Int64
    /// Inclusive last byte, or nil for "to the end".
    var end: Int64?

    /// Parses `bytes=start-end`, `bytes=start-`, or `bytes=-suffixLength`
    /// against a known total size. Returns nil when the header is absent,
    /// malformed, or unsatisfiable — callers then serve the whole object.
    static func parse(_ header: String?, totalSize: Int64) -> ByteRangeRequest? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("bytes="), totalSize > 0 else { return nil }

        let spec = String(trimmed.dropFirst("bytes=".count))
        // Multi-range: not supported, fall back to the whole object.
        guard !spec.contains(",") else { return nil }

        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let firstText = String(parts[0])
        let lastText = String(parts[1])

        if firstText.isEmpty {
            // Suffix form: the last N bytes.
            guard let suffix = Int64(lastText), suffix > 0 else { return nil }
            let length = min(suffix, totalSize)
            return ByteRangeRequest(start: totalSize - length, end: totalSize - 1)
        }

        guard let start = Int64(firstText), start >= 0, start < totalSize else { return nil }

        if lastText.isEmpty {
            return ByteRangeRequest(start: start, end: totalSize - 1)
        }
        guard let requestedEnd = Int64(lastText), requestedEnd >= start else { return nil }
        return ByteRangeRequest(start: start, end: min(requestedEnd, totalSize - 1))
    }

    /// The `bytes=` value to forward to an upstream that speaks HTTP ranges.
    var headerValue: String {
        if let end {
            return "bytes=\(start)-\(end)"
        }
        return "bytes=\(start)-"
    }

    func contentRangeValue(totalSize: Int64) -> String {
        "bytes \(start)-\(end ?? totalSize - 1)/\(totalSize)"
    }
}

// MARK: - Application wiring

extension Application {
    private struct ImageObjectStoreKey: StorageKey, LockKey {
        typealias Value = any ImageObjectStore
    }

    /// The configured image store.
    ///
    /// Defaults to the filesystem backend so existing deployments keep working
    /// untouched; object storage is opt-in via `IMAGE_STORAGE_BACKEND=s3`.
    /// Tests assign a store directly instead of mutating the process
    /// environment, which is unsafe while parallel tests read it (setenv racing
    /// getenv from another thread segfaults on glibc).
    var imageObjectStore: any ImageObjectStore {
        get {
            lazyService(ImageObjectStoreKey.self) {
                FilesystemImageObjectStore(rootPath: FilesystemImageObjectStore.defaultRootPath)
            }
        }
        set {
            setStorageValue(ImageObjectStoreKey.self, to: newValue)
        }
    }
}
