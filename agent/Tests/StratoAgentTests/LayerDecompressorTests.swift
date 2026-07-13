import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Layer Decompressor")
struct LayerDecompressorTests {

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "decompressor-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func firstExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @Test("uncompressed layers are passed through without copying")
    func passthrough() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let blob = dir + "/layer.tar"
        try Data("tar-bytes".utf8).write(to: URL(fileURLWithPath: blob))

        let result = try await LayerDecompressor().decompressedTarPath(
            blobPath: blob, compression: OCILayerCompression.none, outputPath: dir + "/out.tar")
        #expect(result == blob)
    }

    @Test("gzip layers decompress through the host gzip")
    func gzipRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        var builder = TarTestBuilder()
        builder.addFile("hello.txt", content: Data("round-trip".utf8))
        let original = builder.finish()

        // Compress with the host gzip (also the tool under test's dependency,
        // so its presence is a fair prerequisite).
        guard let gzip = firstExecutable(["/usr/bin/gzip", "/bin/gzip"]) else {
            Issue.record("no gzip on this host")
            return
        }
        let plainPath = dir + "/layer.tar"
        try original.write(to: URL(fileURLWithPath: plainPath))
        let compress = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: gzip), arguments: ["-k", plainPath])
        #expect(compress.terminationStatus == 0)

        let output = dir + "/decompressed.tar"
        let result = try await LayerDecompressor().decompressedTarPath(
            blobPath: plainPath + ".gz", compression: .gzip, outputPath: output)
        #expect(result == output)
        let roundTripped = FileManager.default.contents(atPath: output)
        #expect(roundTripped == original)
    }

    @Test("zstd layers decompress when the host has zstd", .enabled(if: zstdPresent))
    func zstdRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        var builder = TarTestBuilder()
        builder.addFile("hello.txt", content: Data("zstd-trip".utf8))
        let original = builder.finish()

        let plainPath = dir + "/layer.tar"
        try original.write(to: URL(fileURLWithPath: plainPath))
        let zstd = firstExecutable(["/usr/bin/zstd", "/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"])!
        let compress = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: zstd), arguments: ["-q", "-k", plainPath])
        #expect(compress.terminationStatus == 0)

        let output = dir + "/decompressed.tar"
        _ = try await LayerDecompressor().decompressedTarPath(
            blobPath: plainPath + ".zst", compression: .zstd, outputPath: output)
        let roundTripped = FileManager.default.contents(atPath: output)
        #expect(roundTripped == original)
    }

    @Test("a missing tool is a permanent host misconfiguration")
    func missingTool() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let blob = dir + "/layer.tar.gz"
        try Data("x".utf8).write(to: URL(fileURLWithPath: blob))

        let decompressor = LayerDecompressor(gzipPath: "/nonexistent/gzip")
        do {
            _ = try await decompressor.decompressedTarPath(
                blobPath: blob, compression: .gzip, outputPath: dir + "/out.tar")
            Issue.record("expected hostMisconfiguration")
        } catch let error as OCIError {
            guard case .hostMisconfiguration = error else {
                Issue.record("expected hostMisconfiguration, got \(error)")
                return
            }
            #expect(error.failureClassification == .permanent)
        }
    }

    @Test("corrupt compressed content fails as a permanent unpack error")
    func corruptContent() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let blob = dir + "/layer.tar.gz"
        try Data("this is not gzip".utf8).write(to: URL(fileURLWithPath: blob))

        do {
            _ = try await LayerDecompressor().decompressedTarPath(
                blobPath: blob, compression: .gzip, outputPath: dir + "/out.tar")
            Issue.record("expected layerUnpackFailed")
        } catch let error as OCIError {
            guard case .layerUnpackFailed = error else {
                Issue.record("expected layerUnpackFailed, got \(error)")
                return
            }
            #expect(!FileManager.default.fileExists(atPath: dir + "/out.tar"))
        }
    }

    private static var zstdPresent: Bool {
        ["/usr/bin/zstd", "/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
