import Crypto
import Foundation
import Testing

@testable import StratoAgentCore

@Suite("File Hashing")
struct FileHashingTests {
    @Test("Empty files produce the standard lowercase SHA-256 digest")
    func emptyFile() throws {
        let contents = Data()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-file-hashing-")
            .appendingPathExtension(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try contents.write(to: fileURL)

        let digest = try FileHashing.sha256Hex(ofFileAt: fileURL.path)
        let inMemoryDigest = SHA256.hash(data: contents)
            .map { String(format: "%02x", $0) }.joined()

        #expect(inMemoryDigest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(digest == inMemoryDigest)
    }

    @Test("Missing files produce a generic file-hashing error")
    func missingFile() throws {
        let path = NSTemporaryDirectory() + "/missing-file-" + UUID().uuidString

        do {
            _ = try FileHashing.sha256Hex(ofFileAt: path)
            Issue.record("expected fileNotFound")
        } catch let error as FileHashing.Error {
            #expect(error == .fileNotFound(path))
        }
    }

    @Test("Files larger than one chunk produce the lowercase SHA-256 digest")
    func multiChunkFile() throws {
        let contents = Data(repeating: 0x61, count: 1_048_577)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-hashing-")
            .appendingPathExtension(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try contents.write(to: fileURL)

        let digest = try FileHashing.sha256Hex(ofFileAt: fileURL.path)
        let inMemoryDigest = SHA256.hash(data: contents)
            .map { String(format: "%02x", $0) }.joined()

        #expect(inMemoryDigest == "4a3f0c0c213adea174f9a3d4c13177315b588bdb2e9c1012d3d0bf0453ca0f6a")
        #expect(digest == inMemoryDigest)
    }

    @Test("Unreadable file contents produce a generic read-failure error")
    func readFailure() throws {
        #if os(macOS)
        // Character devices that are configured through ioctls can be opened
        // for reading but reject ordinary read(2), giving this branch a
        // deterministic Darwin fixture.
        let path = "/dev/dtracehelper"
        #else
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-hashing-directory-")
            .appendingPathExtension(UUID().uuidString)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        // Linux permits opening a directory read-only, then rejects read(2).
        let path = directoryURL.path
        #endif

        do {
            _ = try FileHashing.sha256Hex(ofFileAt: path)
            Issue.record("expected readFailed")
        } catch let error as FileHashing.Error {
            guard case .readFailed(let actualPath, _) = error else {
                Issue.record("expected readFailed, got \(error)")
                return
            }
            #expect(actualPath == path)
        }
    }

    @Test("Snapshot artifact hashing preserves its missing-file error")
    func snapshotArtifactMissingFile() throws {
        let path = NSTemporaryDirectory() + "/missing-snapshot-artifact-" + UUID().uuidString

        do {
            _ = try SnapshotArtifactTransfer.sha256Hex(of: path)
            Issue.record("expected fileNotFound")
        } catch let error as SnapshotArtifactTransfer.TransferError {
            guard case .fileNotFound(let actualPath) = error else {
                Issue.record("expected fileNotFound, got \(error)")
                return
            }
            #expect(actualPath == path)
        }
    }

    @Test("Agent update hashing preserves its missing-file error")
    func agentUpdateMissingFile() throws {
        let path = NSTemporaryDirectory() + "/missing-agent-update-" + UUID().uuidString

        #expect(throws: AgentUpdateError.downloadFailed("downloaded artifact missing at \(path)")) {
            _ = try AgentUpdater.sha256Hex(ofFileAt: path)
        }
    }

    @Test("OCI blob hashing preserves its missing-file error")
    func ociBlobMissingFile() throws {
        let path = NSTemporaryDirectory() + "/missing-oci-blob-" + UUID().uuidString

        do {
            _ = try OCIRegistryClient.sha256Hex(ofFileAt: path)
            Issue.record("expected transferFailed")
        } catch let error as OCIError {
            guard case .transferFailed(let detail) = error else {
                Issue.record("expected transferFailed, got \(error)")
                return
            }
            #expect(detail == "downloaded file missing at \(path)")
        }
    }
}
