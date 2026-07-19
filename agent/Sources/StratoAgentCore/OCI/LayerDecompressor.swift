import Foundation

/// Decompresses layer blobs to tar files by streaming them through the host's
/// gzip/zstd binaries (filter mode: blob on stdin, tar on stdout), so layer
/// size never pressures agent memory. Shelling out instead of linking
/// compression libraries keeps the package dependency-free; both tools are
/// ubiquitous on hypervisor hosts, and a missing one is reported as a
/// permanent host misconfiguration with the path that was probed.
public struct LayerDecompressor: Sendable {
    /// Runs the decompression subprocess; injectable for tests.
    public typealias StreamingRunner =
        @Sendable (
            _ executableURL: URL, _ arguments: [String], _ inputFile: URL, _ outputFile: URL,
            _ maxOutputBytes: Int?
        )
        async throws -> ProcessResult

    private let gzipPath: String?
    private let zstdPath: String?
    private let runStreaming: StreamingRunner

    /// Search order for each tool when no explicit path is configured.
    private static let gzipCandidates = ["/usr/bin/gzip", "/bin/gzip"]
    private static let zstdCandidates = ["/usr/bin/zstd", "/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]

    public init(
        gzipPath: String? = nil,
        zstdPath: String? = nil,
        runStreaming: @escaping StreamingRunner = {
            try await ProcessRunner.runStreaming(
                executableURL: $0, arguments: $1, inputFile: $2, outputFile: $3, maxOutputBytes: $4)
        }
    ) {
        self.gzipPath = gzipPath
        self.zstdPath = zstdPath
        self.runStreaming = runStreaming
    }

    /// Produces a plain tar file for a fetched layer blob. Uncompressed
    /// layers are returned as-is (no copy); compressed ones are written to
    /// `outputPath`.
    public func decompressedTarPath(
        blobPath: String, compression: OCILayerCompression, outputPath: String,
        maxDecompressedBytes: Int? = nil
    ) async throws -> String {
        let tool: (name: String, path: String?, candidates: [String])
        switch compression {
        case .none:
            return blobPath
        case .gzip:
            tool = ("gzip", gzipPath, Self.gzipCandidates)
        case .zstd:
            tool = ("zstd", zstdPath, Self.zstdCandidates)
        }

        let executable = try resolveExecutable(name: tool.name, configured: tool.path, candidates: tool.candidates)
        let result = try await runStreaming(
            URL(fileURLWithPath: executable), ["-dc"],
            URL(fileURLWithPath: blobPath), URL(fileURLWithPath: outputPath), maxDecompressedBytes)
        guard result.terminationStatus == 0 else {
            try? FileManager.default.removeItem(atPath: outputPath)
            let stderr = String(data: result.standardError, encoding: .utf8) ?? ""
            // For a digest-verified blob, a decompression failure means the
            // content itself is bad — permanent for this pinned digest.
            throw OCIError.layerUnpackFailed(
                detail: "\(tool.name) exited \(result.terminationStatus): \(stderr)")
        }
        return outputPath
    }

    private func resolveExecutable(name: String, configured: String?, candidates: [String]) throws -> String {
        if let configured {
            guard FileManager.default.isExecutableFile(atPath: configured) else {
                throw OCIError.hostMisconfiguration(detail: "\(name) not executable at \(configured)")
            }
            return configured
        }
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        throw OCIError.hostMisconfiguration(
            detail: "\(name) not found (looked in \(candidates.joined(separator: ", "))); "
                + "install it to unpack \(name)-compressed OCI layers")
    }
}
