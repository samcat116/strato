import Foundation
import NIOCore
import SotoS3
import Vapor

/// Stores image bytes in any S3-compatible object store.
///
/// Deliberately not tied to AWS: `IMAGE_S3_ENDPOINT` points at whatever
/// implementation the operator runs (MinIO, Garage, Ceph RGW, R2, or real S3).
/// Soto addresses custom endpoints path-style by default, which is what
/// self-hosted implementations expect; `IMAGE_S3_VIRTUAL_HOST_STYLE=true`
/// switches to virtual-host addressing for providers that require it.
///
/// Bytes still reach agents through the control plane's `/download` route
/// rather than a presigned URL. That keeps a single, swappable authentication
/// point on the fetch path (agent SVID mTLS since issue #493), keeps bucket
/// credentials inside the control plane, and
/// means agents need no network route to the object store.
struct S3ImageObjectStore: ImageObjectStore {
    let s3: S3
    let bucket: String

    /// Size of each multipart part. S3 requires every part except the last to
    /// be at least 5 MiB; 16 MiB keeps the part count for a multi-gigabyte
    /// image well under the 10,000-part ceiling (16 MiB × 10,000 ≈ 156 GiB)
    /// while bounding how much of an upload sits in memory at once.
    static let partSize = 16 * 1024 * 1024

    func openWriter(key: String) async throws -> any ImageObjectWriter {
        let upload = try await s3.createMultipartUpload(
            .init(bucket: bucket, key: key)
        )
        guard let uploadId = upload.uploadId else {
            throw ImageError.storageFailed("S3 did not return an upload ID for \(key)")
        }
        return S3ImageObjectWriter(s3: s3, bucket: bucket, key: key, uploadId: uploadId)
    }

    func delete(key: String) async throws {
        _ = try await s3.deleteObject(.init(bucket: bucket, key: key))
    }

    func deletePrefix(_ prefix: String) async throws {
        // Normalise to a directory-style prefix so `{project}/{image}` can't
        // also match `{project}/{image}2`.
        let normalized = prefix.hasSuffix("/") ? prefix : prefix + "/"

        var continuationToken: String?
        repeat {
            let listing = try await s3.listObjectsV2(
                .init(bucket: bucket, continuationToken: continuationToken, prefix: normalized)
            )
            let keys = (listing.contents ?? []).compactMap(\.key)
            if !keys.isEmpty {
                _ = try await s3.deleteObjects(
                    .init(
                        bucket: bucket,
                        delete: S3.Delete(objects: keys.map { S3.ObjectIdentifier(key: $0) })
                    )
                )
            }
            continuationToken = (listing.isTruncated ?? false) ? listing.nextContinuationToken : nil
        } while continuationToken != nil
    }

    /// True when the error means "no such object", across the two shapes Soto
    /// reports it in: a typed `notFound`/`noSuchKey`, or — because some S3
    /// implementations answer HEAD on a missing key with a bare 404 and no
    /// parsable error body — an untyped raw error carrying a 404.
    private static func isNotFound(_ error: any Error) -> Bool {
        if let error = error as? S3ErrorType, error == .notFound || error == .noSuchKey {
            return true
        }
        if let error = error as? AWSRawError, error.context.responseCode == .notFound {
            return true
        }
        return false
    }

    func exists(key: String) async throws -> Bool {
        do {
            _ = try await s3.headObject(.init(bucket: bucket, key: key))
            return true
        } catch  where Self.isNotFound(error) {
            return false
        }
    }

    func size(key: String) async throws -> Int64 {
        let head = try await s3.headObject(.init(bucket: bucket, key: key))
        guard let length = head.contentLength else {
            throw ImageError.storageFailed("Could not determine object size for \(key)")
        }
        return length
    }

    func stream(key: String, filename: String, on req: Request) async throws -> Response {
        // A row can outlive its object (a failed write, an out-of-band delete).
        // That's a 404, the same as the filesystem backend gives — without this
        // catch the head call escaped as an unhandled Soto error and the caller
        // saw a 500.
        let head: S3.HeadObjectOutput
        do {
            head = try await s3.headObject(.init(bucket: bucket, key: key))
        } catch  where Self.isNotFound(error) {
            throw Abort(.notFound, reason: "Image file not found")
        }
        guard let totalSize = head.contentLength else {
            throw Abort(.internalServerError, reason: "Could not determine object size")
        }

        // Resolve the range against the real object size before asking S3, so an
        // unsatisfiable or malformed header degrades to a full-object response
        // instead of an S3 error surfacing as a 500.
        let range = ByteRangeRequest.parse(req.headers.first(name: .range), totalSize: totalSize)

        let object: S3.GetObjectOutput
        do {
            object = try await s3.getObject(
                .init(bucket: bucket, key: key, range: range?.headerValue)
            )
        } catch  where Self.isNotFound(error) {
            // Deleted between the head and the get.
            throw Abort(.notFound, reason: "Image file not found")
        }

        let response = Response(status: range == nil ? .ok : .partialContent)
        response.headers.replaceOrAdd(
            name: .contentDisposition, value: "attachment; filename=\"\(filename)\"")
        response.headers.replaceOrAdd(name: .contentType, value: "application/octet-stream")
        response.headers.replaceOrAdd(name: .acceptRanges, value: "bytes")
        if let range {
            response.headers.replaceOrAdd(
                name: .contentRange, value: range.contentRangeValue(totalSize: totalSize))
        }

        // Same rule as the filesystem backend: do NOT set Content-Length here.
        // Vapor derives it from the streaming body, and setting it alongside
        // that emitted the header twice — nginx rejects a duplicate header line
        // with a 502, which once broke image downloads for every agent so no VM
        // could boot.
        let body = object.body
        response.body = Response.Body(
            asyncStream: { writer in
                do {
                    for try await buffer in body {
                        try await writer.write(.buffer(buffer))
                    }
                    try await writer.write(.end)
                } catch {
                    try? await writer.write(.error(error))
                }
            }
        )

        return response
    }
}

/// Buffers into ≥5 MiB parts and uploads them as it goes, so a multi-gigabyte
/// image never lands in memory whole.
private actor S3ImageObjectWriter: ImageObjectWriter {
    private let s3: S3
    private let bucket: String
    private let key: String
    private let uploadId: String

    private var pending: ByteBuffer
    private var completedParts: [S3.CompletedPart] = []
    private var nextPartNumber = 1
    private var aborted = false

    init(s3: S3, bucket: String, key: String, uploadId: String) {
        self.s3 = s3
        self.bucket = bucket
        self.key = key
        self.uploadId = uploadId
        self.pending = ByteBufferAllocator().buffer(capacity: S3ImageObjectStore.partSize)
    }

    func write(_ buffer: ByteBuffer) async throws {
        guard !aborted else {
            throw ImageError.storageFailed("Write to an aborted upload")
        }
        var buffer = buffer
        pending.writeBuffer(&buffer)

        while pending.readableBytes >= S3ImageObjectStore.partSize {
            guard let part = pending.readSlice(length: S3ImageObjectStore.partSize) else { break }
            try await uploadPart(part)
        }
        pending.discardReadBytes()
    }

    func finish() async throws {
        // The final part is the only one allowed below the 5 MiB minimum.
        //
        // It is uploaded even when empty: S3 rejects `completeMultipartUpload`
        // with an empty part list, so a zero-byte object needs one zero-byte
        // part rather than none.
        if pending.readableBytes > 0 || completedParts.isEmpty {
            let tail = pending.readSlice(length: pending.readableBytes) ?? ByteBuffer()
            try await uploadPart(tail)
        }

        _ = try await s3.completeMultipartUpload(
            .init(
                bucket: bucket,
                key: key,
                multipartUpload: S3.CompletedMultipartUpload(parts: completedParts),
                uploadId: uploadId
            )
        )
    }

    func abort() async {
        aborted = true
        // Best effort: leaving the multipart upload dangling would keep billing
        // for its parts, but a failure here must not mask the original error.
        _ = try? await s3.abortMultipartUpload(
            .init(bucket: bucket, key: key, uploadId: uploadId)
        )
    }

    private func uploadPart(_ buffer: ByteBuffer) async throws {
        let partNumber = nextPartNumber
        nextPartNumber += 1

        let result = try await s3.uploadPart(
            .init(
                body: AWSHTTPBody(buffer: buffer),
                bucket: bucket,
                key: key,
                partNumber: partNumber,
                uploadId: uploadId
            )
        )
        completedParts.append(S3.CompletedPart(eTag: result.eTag, partNumber: partNumber))
    }
}
