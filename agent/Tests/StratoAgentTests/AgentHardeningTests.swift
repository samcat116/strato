import Foundation
import Testing

@testable import StratoAgentCore

/// Regression tests for the pass-4 agent hardening: the decompression-bomb
/// ceiling and the cache-path filename confinement. Both are pure functions, so
/// they run without spawning subprocesses or touching the network.
@Suite("Agent hardening")
struct AgentHardeningTests {

    // MARK: - Decompression ceiling

    @Test("Ceiling is derived from the compressed size, never below the 1 GiB floor")
    func decompressionCeilingFloorAndScale() {
        let floor = 1 << 30
        // Tiny compressed layer → floor applies (a bomb is stopped well before
        // it fills the disk; a small legit layer still decompresses).
        #expect(SandboxImageService.decompressionCeiling(compressedBytes: 1) == floor)
        #expect(SandboxImageService.decompressionCeiling(compressedBytes: 0) == floor)
        #expect(SandboxImageService.decompressionCeiling(compressedBytes: -5) == floor)
        // Large compressed layer → 200x scale dominates the floor.
        let big: Int64 = 100 * 1024 * 1024  // 100 MiB
        #expect(SandboxImageService.decompressionCeiling(compressedBytes: big) == Int(big) * 200)
    }

    @Test("Ceiling saturates instead of overflowing on an absurd declared size")
    func decompressionCeilingNoOverflow() {
        #expect(SandboxImageService.decompressionCeiling(compressedBytes: Int64.max) == Int.max)
    }

    // MARK: - Cache-path filename confinement

    @Test("A traversal filename reduces to an in-directory placeholder")
    func safeComponentBlocksTraversal() {
        #expect(ImageCacheService.safeComponent("../../etc/cron.d/x") == "x")  // lastPathComponent
        #expect(ImageCacheService.safeComponent("..") == "_invalid_")
        #expect(ImageCacheService.safeComponent(".") == "_invalid_")
        #expect(ImageCacheService.safeComponent("") == "_invalid_")
        #expect(ImageCacheService.safeComponent("/etc/shadow") == "shadow")
    }

    @Test("A normal filename is preserved verbatim")
    func safeComponentPreservesNormal() {
        #expect(ImageCacheService.safeComponent("disk.qcow2") == "disk.qcow2")
        #expect(ImageCacheService.safeComponent("vmlinuz-6.1.0") == "vmlinuz-6.1.0")
    }

    // MARK: - Output ceiling enforcement

    /// The ceiling is only a security control if the runner actually stops a
    /// runaway producer, so this exercises `runStreaming` itself rather than
    /// the arithmetic: `cat /dev/zero` writes without end, and the run must
    /// terminate it, delete the partial output, and throw.
    @Test("runStreaming terminates a producer that blows past the ceiling")
    func runStreamingEnforcesOutputCeiling() async throws {
        let outputPath = NSTemporaryDirectory() + "/ceiling-\(UUID().uuidString).out"
        defer { try? FileManager.default.removeItem(atPath: outputPath) }
        let limit = 1 << 20  // 1 MiB

        await #expect(throws: ProcessRunnerError.self) {
            try await ProcessRunner.runStreaming(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: [],
                inputFile: URL(fileURLWithPath: "/dev/zero"),
                outputFile: URL(fileURLWithPath: outputPath),
                maxOutputBytes: limit)
        }
        // The partial output is removed, so a caller that ignores the error
        // cannot mistake a truncated file for a complete one.
        #expect(!FileManager.default.fileExists(atPath: outputPath))
    }

    @Test("runStreaming leaves an under-ceiling run untouched")
    func runStreamingAllowsOutputUnderCeiling() async throws {
        let inputPath = NSTemporaryDirectory() + "/ceiling-in-\(UUID().uuidString)"
        let outputPath = NSTemporaryDirectory() + "/ceiling-out-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: inputPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }
        let payload = Data(repeating: 0x41, count: 4096)
        try payload.write(to: URL(fileURLWithPath: inputPath))

        let result = try await ProcessRunner.runStreaming(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            inputFile: URL(fileURLWithPath: inputPath),
            outputFile: URL(fileURLWithPath: outputPath),
            maxOutputBytes: 1 << 20)

        #expect(result.terminationStatus == 0)
        #expect(ProcessRunner.fileSize(atPath: outputPath) == Int64(payload.count))
    }

    // MARK: - Cloud-init key rendering

    @Test("A key cannot escape its YAML scalar or smuggle an escape sequence")
    func sshKeyRenderingIsInert() {
        let hostile = "ssh-rsa AAAA\"\nruncmd:\n  - touch /tmp/pwned"
        // systemCloudConfig carries no list keys of its own, so every `  - `
        // line below belongs to the rendered authorized-keys block.
        let document = CloudInitProvisioner.systemCloudConfig(
            authorizedKeys: [hostile, #"ssh-ed25519 AAAA\nfoo"#])

        // The raw newline is gone, so nothing lands at the document's top level.
        #expect(!document.contains("\nruncmd:"))
        // The quote is escaped rather than dropped, and a literal backslash in
        // the key stays literal instead of decoding to a newline in the guest.
        #expect(document.contains(#"\""#))
        #expect(document.contains(#"\\n"#))
        // One list entry per key, however hostile the input.
        let entries = document.split(separator: "\n").filter { $0.hasPrefix("  - ") }
        #expect(entries.count == 2)
    }
}
