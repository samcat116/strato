import Crypto
import Foundation
import NIOCore
import Vapor

/// Streams a `multipart/form-data` upload straight into an ``ImageObjectStore``.
///
/// The alternative — `req.body.collect()` then `FormDataDecoder` — needs the
/// whole body contiguous in memory, so a 4 GiB image cost 4 GiB of control-plane
/// RAM before a single byte was stored, and concurrent uploads multiplied that.
/// Here the file part is written to the store as it arrives; peak memory is a
/// single body chunk.
///
/// `MultipartParser`'s callbacks are synchronous and non-throwing, so they can't
/// write to the store (async) or fail. They instead append to a pending buffer
/// and record any error; the async driver loop flushes and rethrows between
/// `execute` calls. That also gives natural backpressure — we don't read the
/// next body chunk until the previous one has been handed to the store.
enum StreamingMultipartReceiver {
    /// Cap on a single non-file form field. These carry names, descriptions and
    /// flags; anything larger is malformed or hostile, and unlike the file part
    /// they're held in memory whole.
    static let maxFieldBytes = 64 * 1024

    /// Cap on how many non-file fields one upload may carry. `maxFieldBytes`
    /// bounds each field but not how many of them accumulate in memory, so
    /// without this a client could stream unlimited small fields and grow the
    /// dictionary without ever tripping the per-field limit. No real upload
    /// sends more than a handful.
    static let maxFieldCount = 64

    struct Result {
        /// Non-file form fields, decoded as UTF-8.
        var fields: [String: String]
        /// The fields that had been parsed when the file part began.
        ///
        /// Separate from `fields` because `MultipartParser.execute` drains a
        /// whole body chunk before control returns here: with a small upload
        /// that arrives in one chunk, `fields` is already complete by the first
        /// flush, while a chunked upload would only have the earlier parts.
        /// Anything that must be decided before bytes are written — the object
        /// key above all — reads this, so the outcome doesn't depend on where
        /// chunk boundaries happen to fall.
        var fieldsBeforeFile: [String: String]
        /// The uploaded file's declared filename, if a file part was present.
        var filename: String?
        /// The object key the bytes were written to.
        var key: String?
        /// Total bytes written.
        var size: Int64
        /// SHA-256 of the bytes actually stored — never client-supplied.
        var checksum: String
        /// First bytes of the file, for format sniffing.
        var headerBytes: [UInt8]

        func field(_ name: String) -> String? {
            let value = fields[name]
            return (value?.isEmpty ?? true) ? nil : value
        }
    }

    /// Consumes `req.body`, writing the part named `fileFieldName` to the store.
    ///
    /// - Parameter key: maps the file part's declared filename, plus whatever
    ///   text fields have been parsed *so far*, to an object key. Called once,
    ///   when the file part's first bytes arrive — validate the filename here
    ///   and throw to reject the upload before any bytes land. The dictionary is
    ///   `fieldsBeforeFile`, so a key that depends on another form field
    ///   requires the client to send that field ahead of the file part; throw a
    ///   clear error if it's missing.
    /// - Throws: `Abort(.payloadTooLarge)` past `maxBytes`. On any failure the
    ///   partially written object is aborted, so no truncated image is visible.
    static func receive(
        req: Request,
        into store: any ImageObjectStore,
        fileFieldName: String,
        maxBytes: Int64,
        key makeKey: @Sendable (String, [String: String]) throws -> String
    ) async throws -> Result {
        guard let boundary = req.headers.contentType?.parameters["boundary"] else {
            throw Abort(.badRequest, reason: "Missing boundary in multipart form")
        }

        let state = ParserState(fileFieldName: fileFieldName)
        let parser = MultipartParser(boundary: boundary)

        parser.onHeader = { name, value in
            state.setHeader(name: name, value: value)
        }
        parser.onBody = { buffer in
            state.appendBody(&buffer)
        }
        parser.onPartComplete = {
            state.completePart()
        }

        var writer: (any ImageObjectWriter)?
        var hasher = SHA256()
        var size: Int64 = 0
        var headerBytes: [UInt8] = []
        var key: String?

        // Flushes whatever the parser has buffered for the file part.
        func flush() async throws {
            guard let chunk = state.takePendingFile(), chunk.readableBytes > 0 else { return }

            if writer == nil {
                guard let filename = state.fileFilename else {
                    throw Abort(.badRequest, reason: "File part is missing a filename")
                }
                let resolved = try makeKey(filename, state.fieldsBeforeFile)
                key = resolved
                writer = try await store.openWriter(key: resolved)
            }

            size += Int64(chunk.readableBytes)
            if size > maxBytes {
                throw Abort(
                    .payloadTooLarge,
                    reason: "Upload exceeds the maximum allowed size of \(maxBytes) bytes")
            }

            let readable = chunk
            if let bytes = readable.getBytes(at: readable.readerIndex, length: readable.readableBytes) {
                if headerBytes.count < ImageValidationService.headerProbeLength {
                    headerBytes.append(
                        contentsOf: bytes.prefix(ImageValidationService.headerProbeLength - headerBytes.count))
                }
                hasher.update(data: bytes)
            }

            try await writer?.write(chunk)
        }

        do {
            for try await chunk in req.body {
                try Task.checkCancellation()
                try parser.execute(chunk)
                try state.throwIfFailed()
                try await flush()
            }
            try state.throwIfFailed()
            try await flush()

            try await writer?.finish()
        } catch {
            await writer?.abort()
            throw error
        }

        let digest = hasher.finalize()
        return Result(
            fields: state.fields,
            fieldsBeforeFile: state.fieldsBeforeFile,
            filename: state.fileFilename,
            key: key,
            size: size,
            checksum: digest.map { String(format: "%02x", $0) }.joined(),
            headerBytes: headerBytes
        )
    }
}

/// Mutable parsing state shared with `MultipartParser`'s synchronous callbacks.
///
/// A class rather than captured `var`s because the callbacks are escaping
/// closures. `@unchecked Sendable` is sound here: `MultipartParser.execute` runs
/// its callbacks inline on the calling task, and the driver loop above is the
/// only caller, so there is never concurrent access.
private final class ParserState: @unchecked Sendable {
    private let fileFieldName: String

    private(set) var fields: [String: String] = [:]
    /// Snapshot of `fields` taken when the file part's headers arrived.
    private(set) var fieldsBeforeFile: [String: String] = [:]
    private(set) var fileFilename: String?

    private var currentName: String?
    private var currentFilename: String?
    private var currentIsFile = false
    private var currentFieldValue = ByteBuffer()
    private var pendingFile = ByteBuffer()
    private var failure: (any Error)?

    init(fileFieldName: String) {
        self.fileFieldName = fileFieldName
    }

    func setHeader(name: String, value: String) {
        guard name.lowercased() == "content-disposition" else { return }
        currentName = Self.parameter("name", in: value)
        currentFilename = Self.parameter("filename", in: value)
        // A part is the file part when it's named as such AND declares a
        // filename — a text field called "file" isn't an upload.
        currentIsFile = currentName == fileFieldName && currentFilename != nil
        if currentIsFile {
            // A second file part would append to the writer already opened
            // under the first part's key while overwriting `fileFilename`, so
            // the row would record one filename and the bytes would live under
            // another. Reject rather than silently store the mismatch.
            guard fileFilename == nil else {
                failure = Abort(
                    .badRequest,
                    reason: "Only one '\(fileFieldName)' part is allowed per upload")
                return
            }
            fileFilename = currentFilename
            fieldsBeforeFile = fields
        }
    }

    func appendBody(_ buffer: inout ByteBuffer) {
        if currentIsFile {
            pendingFile.writeBuffer(&buffer)
        } else {
            guard currentName != nil else { return }
            if currentFieldValue.readableBytes + buffer.readableBytes > StreamingMultipartReceiver.maxFieldBytes {
                failure = Abort(
                    .badRequest,
                    reason:
                        "Form field '\(currentName ?? "?")' exceeds \(StreamingMultipartReceiver.maxFieldBytes) bytes")
                return
            }
            currentFieldValue.writeBuffer(&buffer)
        }
    }

    func completePart() {
        if !currentIsFile, let name = currentName {
            if fields[name] == nil, fields.count >= StreamingMultipartReceiver.maxFieldCount {
                failure = Abort(
                    .badRequest,
                    reason:
                        "Upload carries more than \(StreamingMultipartReceiver.maxFieldCount) form fields")
            } else {
                fields[name] = currentFieldValue.readString(length: currentFieldValue.readableBytes) ?? ""
            }
        }
        currentName = nil
        currentFilename = nil
        currentIsFile = false
        currentFieldValue = ByteBuffer()
    }

    /// Hands off everything buffered for the file part, leaving the buffer empty.
    func takePendingFile() -> ByteBuffer? {
        guard pendingFile.readableBytes > 0 else { return nil }
        let taken = pendingFile
        pendingFile = ByteBuffer()
        return taken
    }

    func throwIfFailed() throws {
        if let failure {
            self.failure = nil
            throw failure
        }
    }

    /// Extracts `name="value"` (or bare `name=value`) from a header value.
    private static func parameter(_ key: String, in header: String) -> String? {
        for component in header.split(separator: ";") {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("\(key)=") else { continue }
            var value = String(trimmed.dropFirst(key.count + 1))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }
}
