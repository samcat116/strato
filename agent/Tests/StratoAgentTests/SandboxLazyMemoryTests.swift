import Crypto
import Foundation
import Testing
@testable import StratoAgentCore

@Suite("Sandbox lazy memory preparatory contracts")
struct SandboxLazyMemoryTests {
    private func base() throws -> SandboxLazyMemoryPages.Base {
        let bytes = Data(repeating: 7, count: 8192)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return try .init(data: bytes, digest: digest, trustClass: "disposable")
    }

    @Test func immutableBaseAndPrivateDelta() throws {
        let base = try base()
        var a = try SandboxLazyMemoryPages(base: base, trustClass: "disposable", maximumDirtyPages: 1)
        let b = try SandboxLazyMemoryPages(base: base, trustClass: "disposable", maximumDirtyPages: 1)
        var secret = Data(repeating: 9, count: 4096)
        try a.write(page: 0, data: secret)
        secret[0] = 0
        #expect(try a.read(page: 0) == Data(repeating: 9, count: 4096))
        #expect(try b.read(page: 0) == Data(repeating: 7, count: 4096))
        #expect(throws: SandboxLazyMemoryPages.PageError.deltaFull) {
            try a.write(page: 1, data: secret)
        }
        // Updating an existing page stays within the delta allocation bound.
        try a.write(page: 0, data: secret)
        a.cancel()
        #expect(throws: SandboxLazyMemoryPages.PageError.cancelled) { try a.read(page: 0) }
        #expect(try b.read(page: 0) == Data(repeating: 7, count: 4096))
    }

    @Test func digestTrustAndBounds() throws {
        #expect(throws: SandboxLazyMemoryPages.PageError.digestMismatch) {
            try SandboxLazyMemoryPages.Base(data: Data(repeating: 0, count: 4096), digest: "wrong", trustClass: "a")
        }
        let base = try base()
        #expect(throws: SandboxLazyMemoryPages.PageError.incompatibleTrustClass) {
            try SandboxLazyMemoryPages(base: base, trustClass: "other", maximumDirtyPages: 1)
        }
        var pages = try SandboxLazyMemoryPages(base: base, trustClass: "disposable", maximumDirtyPages: 1)
        for invalid in [-1, 2, Int.max] {
            #expect(throws: SandboxLazyMemoryPages.PageError.invalidPage) { try pages.read(page: invalid) }
        }
        #expect(throws: SandboxLazyMemoryPages.PageError.invalidPage) {
            try pages.write(page: 0, data: Data([1]))
        }
    }

    @Test func productionAlwaysUsesExplicitFileFallback() throws {
        let plan = try SandboxRestoreMemoryPreparation.prepare(filePath: "/snapshot/memory")
        #expect(plan.path == "/snapshot/memory")
        #expect(plan.fallbackReason.contains("uffd-disabled"))
    }

    @Test func cancelledPreparationDoesNotStartRestore() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SandboxRestoreMemoryPreparation.prepare(filePath: "/snapshot/memory")
        }
        do {
            _ = try await task.value
            Issue.record("cancelled preparation succeeded")
        } catch {
            #expect(error is CancellationError)
        }
    }
}
