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
}
