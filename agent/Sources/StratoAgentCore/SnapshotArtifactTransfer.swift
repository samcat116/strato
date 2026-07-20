import Crypto
import Foundation
import Logging
import StratoShared

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Streams sandbox snapshot artifacts between agent disk and the control
/// plane's signed transfer routes (issue #428).
///
/// Uploads use file-backed `URLSession` upload tasks so a multi-gigabyte
/// memory file never sits in agent memory; downloads land in a `.partial`
/// staging sibling, are verified against the control-plane-recorded size and
/// SHA-256, and only then publish via atomic rename — the destination path
/// never holds unverified bytes, mirroring `ImageCacheService`'s discipline.
public enum SnapshotArtifactTransfer {
    public enum TransferError: Error, LocalizedError {
        case invalidURL(String)
        case fileNotFound(String)
        case uploadFailed(kind: String, reason: String)
        case downloadFailed(kind: String, reason: String)
        case sizeMismatch(kind: String, expected: Int64, actual: Int64)
        case checksumMismatch(kind: String, expected: String, actual: String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL(let url):
                return "invalid transfer URL: \(url)"
            case .fileNotFound(let path):
                return "artifact file not found: \(path)"
            case .uploadFailed(let kind, let reason):
                return "uploading snapshot artifact '\(kind)' failed: \(reason)"
            case .downloadFailed(let kind, let reason):
                return "downloading snapshot artifact '\(kind)' failed: \(reason)"
            case .sizeMismatch(let kind, let expected, let actual):
                return "snapshot artifact '\(kind)' size mismatch: expected \(expected) bytes, got \(actual)"
            case .checksumMismatch(let kind, let expected, let actual):
                return "snapshot artifact '\(kind)' checksum mismatch: expected \(expected), got \(actual)"
            }
        }
    }

    /// Uploads one artifact file with a streaming PUT. The control plane
    /// hashes what it stores, so no client-side digest is sent.
    public static func upload(
        filePath: String, to uploadURL: String, kind: SandboxSnapshotArtifactKind
    ) async throws {
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw TransferError.fileNotFound(filePath)
        }
        guard let url = URL(string: uploadURL) else {
            throw TransferError.invalidURL(uploadURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let response: URLResponse
        do {
            (_, response) = try await uploadTask(
                request: request, fromFile: URL(fileURLWithPath: filePath))
        } catch {
            throw TransferError.uploadFailed(kind: kind.rawValue, reason: "\(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw TransferError.uploadFailed(kind: kind.rawValue, reason: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TransferError.uploadFailed(kind: kind.rawValue, reason: "HTTP \(http.statusCode)")
        }
    }

    /// Downloads one artifact described by `descriptor` to `destinationPath`,
    /// verifying size and SHA-256 before the atomic publish. Idempotent: a
    /// destination that already verifies is kept as-is without a download.
    public static func download(
        _ descriptor: SandboxSnapshotArtifactDescriptor, to destinationPath: String
    ) async throws {
        if FileManager.default.fileExists(atPath: destinationPath),
            fileSize(destinationPath) == descriptor.sizeBytes,
            (try? sha256Hex(of: destinationPath))?.lowercased() == descriptor.sha256.lowercased()
        {
            return
        }
        guard let url = URL(string: descriptor.downloadURL) else {
            throw TransferError.invalidURL(descriptor.downloadURL)
        }

        let directory = (destinationPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let kind = descriptor.kind.rawValue
        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await URLSession.shared.download(from: url)
        } catch {
            throw TransferError.downloadFailed(kind: kind, reason: "\(error)")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.downloadFailed(kind: kind, reason: "HTTP \(status)")
        }

        // Stage beside the destination so the final rename is atomic even
        // when the system temp directory is a different filesystem.
        let stagingPath = destinationPath + ".partial." + UUID().uuidString
        do {
            try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: stagingPath))
            let actualSize = fileSize(stagingPath)
            guard actualSize == descriptor.sizeBytes else {
                throw TransferError.sizeMismatch(
                    kind: kind, expected: descriptor.sizeBytes, actual: actualSize)
            }
            let actualChecksum = try sha256Hex(of: stagingPath)
            guard actualChecksum.lowercased() == descriptor.sha256.lowercased() else {
                throw TransferError.checksumMismatch(
                    kind: kind, expected: descriptor.sha256, actual: actualChecksum)
            }
            // rename(2): atomically replaces a destination that appeared
            // concurrently instead of failing like FileManager.moveItem.
            guard rename(stagingPath, destinationPath) == 0 else {
                let code = errno
                throw TransferError.downloadFailed(
                    kind: kind, reason: "publishing failed: \(String(cString: strerror(code)))")
            }
        } catch {
            try? FileManager.default.removeItem(atPath: stagingPath)
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    static func sha256Hex(of filePath: String) throws -> String {
        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            throw TransferError.fileNotFound(filePath)
        }
        defer { try? fileHandle.close() }
        var hasher = SHA256()
        while true {
            let data = fileHandle.readData(ofLength: 1024 * 1024)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(_ path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64 ?? 0) ?? 0
    }

    /// File-backed upload with an async facade. The callback-based
    /// `uploadTask(with:fromFile:)` exists on both Darwin and
    /// swift-corelibs-foundation, unlike the async convenience overloads.
    private static func uploadTask(
        request: URLRequest, fromFile fileURL: URL
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.uploadTask(with: request, fromFile: fileURL) {
                data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let response else {
                    continuation.resume(
                        throwing: TransferError.uploadFailed(
                            kind: "unknown", reason: "no response"))
                    return
                }
                continuation.resume(returning: (data ?? Data(), response))
            }
            task.resume()
        }
    }
}
