import Crypto
import Foundation
import Logging
import StratoShared

/// Streams sandbox snapshot artifacts between agent disk and the control
/// plane's transfer routes (issue #428).
///
/// Descriptors and upload targets carry control-plane-relative paths; they
/// resolve against the base URL the agent already dials — the Envoy mTLS
/// listener — and the actual byte movement goes through the injected
/// transport, which presents the agent's SVID (`MTLSArtifactDownloader` in
/// production, plain closures in tests). Downloads land in a `.partial`
/// staging sibling, are verified against the control-plane-recorded size and
/// SHA-256, and only then publish via atomic rename — the destination path
/// never holds unverified bytes, mirroring `ImageCacheService`'s discipline.
public struct SnapshotArtifactTransfer: Sendable {
    /// Fetches `url` and streams the body to the destination path.
    public typealias FileDownloader = @Sendable (URL, String) async throws -> Void
    /// PUTs the file at the source path to `url` as a streaming body.
    public typealias FileUploader = @Sendable (URL, String) async throws -> Void

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

    /// The control plane's HTTP(S) base, derived from the dialed WebSocket
    /// URL, that relative transfer paths resolve against.
    let controlPlaneBaseURL: String
    let downloadFile: FileDownloader
    let uploadFile: FileUploader

    public init(
        controlPlaneBaseURL: String,
        downloadFile: @escaping FileDownloader,
        uploadFile: @escaping FileUploader
    ) {
        self.controlPlaneBaseURL = controlPlaneBaseURL
        self.downloadFile = downloadFile
        self.uploadFile = uploadFile
    }

    /// Uploads one artifact file with a streaming PUT. The control plane
    /// hashes what it stores, so no client-side digest is sent.
    public func upload(
        filePath: String, to uploadURL: String, kind: SandboxSnapshotArtifactKind
    ) async throws {
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw TransferError.fileNotFound(filePath)
        }
        let url = try resolve(uploadURL)
        do {
            try await uploadFile(url, filePath)
        } catch let error as TransferError {
            throw error
        } catch {
            throw TransferError.uploadFailed(kind: kind.rawValue, reason: "\(error)")
        }
    }

    /// Downloads one artifact described by `descriptor` to `destinationPath`,
    /// verifying size and SHA-256 before the atomic publish. Idempotent: a
    /// destination that already verifies is kept as-is without a download.
    public func download(
        _ descriptor: SandboxSnapshotArtifactDescriptor, to destinationPath: String
    ) async throws {
        if FileManager.default.fileExists(atPath: destinationPath),
            Self.fileSize(destinationPath) == descriptor.sizeBytes,
            (try? Self.sha256Hex(of: destinationPath))?.lowercased() == descriptor.sha256.lowercased()
        {
            return
        }
        let url = try resolve(descriptor.downloadURL)

        let directory = (destinationPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let kind = descriptor.kind.rawValue
        // Stage beside the destination so the final rename is atomic even on
        // hosts where the temp directory is a different filesystem.
        let stagingPath = destinationPath + ".partial." + UUID().uuidString
        do {
            do {
                try await downloadFile(url, stagingPath)
            } catch {
                throw TransferError.downloadFailed(kind: kind, reason: "\(error)")
            }
            let actualSize = Self.fileSize(stagingPath)
            guard actualSize == descriptor.sizeBytes else {
                throw TransferError.sizeMismatch(
                    kind: kind, expected: descriptor.sizeBytes, actual: actualSize)
            }
            let actualChecksum = try Self.sha256Hex(of: stagingPath)
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
            throw error
        }
    }

    func resolve(_ relativePath: String) throws -> URL {
        guard let url = URL(string: controlPlaneBaseURL + relativePath) else {
            throw TransferError.invalidURL(controlPlaneBaseURL + relativePath)
        }
        return url
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
}
