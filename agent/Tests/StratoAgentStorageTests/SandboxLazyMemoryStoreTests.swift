#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation
import Testing
@testable import StratoAgentCore

@Suite("Lazy memory durable private artifacts")
struct SandboxLazyMemoryStoreTests {
    private let compatibility = String(repeating: "a", count: 64)
    private func withStore(maximumBytes: Int = 1 << 20, _ body: (String, SandboxLazyMemoryStore) async throws -> Void)
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lazy-store-\(UUID())")
            .resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try SandboxLazyMemoryStore(directory: root, maximumBytes: maximumBytes)
        try await body(root, store)
    }

    @Test func enumerationDescriptorsCannotLeakAcrossExec() async throws {
        try await withStore { root, _ in
            let fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            #expect(fd >= 0)
            defer { _ = close(fd) }
            let duplicate = try SandboxLazyMemoryStore.duplicateDirectoryDescriptor(fd)
            defer { _ = close(duplicate) }
            #expect(fcntl(duplicate, F_GETFD) & FD_CLOEXEC == FD_CLOEXEC)
        }
    }

    #if os(Linux)
    @Test func shutdownUnlocksWhileForkChildRetainsDescriptor() async throws {
        try await withStore { root, store in
            let (child, releaseDescriptor) = try forkDescriptorHolder()
            defer {
                // EOF releases the child without signals or an exec. Reap it
                // even if opening the second store throws.
                _ = close(releaseDescriptor)
                var status: Int32 = 0
                while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            }
            #expect(kill(child, 0) == 0)
            #expect(throws: (any Error).self) { try SandboxLazyMemoryStore(directory: root) }
            try await store.shutdown()
            // close alone cannot release flock while a forked child retains
            // the same open-file description. Explicit LOCK_UN must do so.
            let reopened = try SandboxLazyMemoryStore(directory: root)
            #expect(kill(child, 0) == 0)
            try await reopened.shutdown()
        }
    }

    private func forkDescriptorHolder() throws -> (pid_t, Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        guard fcntl(readDescriptor, F_SETFD, FD_CLOEXEC) == 0,
            fcntl(writeDescriptor, F_SETFD, FD_CLOEXEC) == 0
        else {
            _ = close(readDescriptor)
            _ = close(writeDescriptor)
            throw POSIXError(.EIO)
        }
        let child = fork()
        if child == 0 {
            // No Foundation, allocation, actor operations, or exec after
            // fork: retain inherited descriptors until the parent closes
            // its writer, then exit using only POSIX operations.
            _ = close(writeDescriptor)
            var byte: UInt8 = 0
            while read(readDescriptor, &byte, 1) < 0 && errno == EINTR {}
            _ = close(readDescriptor)
            _exit(0)
        }
        _ = close(readDescriptor)
        guard child > 0 else {
            _ = close(writeDescriptor)
            throw POSIXError(.EIO)
        }
        return (child, writeDescriptor)
    }
    #endif

    @Test func publishReopenAndPrivateIdentity() async throws {
        try await withStore { root, store in
            let key = try await store.publishBase(
                data: Data(repeating: 7, count: 8192), compatibilityDigest: compatibility, trustClass: "fixture")
            #expect(
                try await store.publishBase(
                    data: Data(repeating: 7, count: 8192), compatibilityDigest: compatibility, trustClass: "fixture")
                    == key)
            let identity = SandboxLazyMemoryStore.Identity(sandboxID: UUID(), checkpointID: UUID(), generation: 3)
            let token = try await store.publishDelta(
                identity: identity, baseKey: key, compatibilityDigest: compatibility, trustClass: "fixture",
                pages: [0: Data(repeating: 9, count: 4096)])
            #expect(try await store.diskUsage().deltaBytes > 4096)
            try await store.shutdown()
            let reopened = try SandboxLazyMemoryStore(directory: root)
            let delta = try await reopened.recoverDelta(
                token: token, identity: identity, baseKey: key, compatibilityDigest: compatibility,
                trustClass: "fixture")
            #expect(try delta.read(page: 0) == Data(repeating: 9, count: 4096))
            #expect(try delta.read(page: 1) == Data(repeating: 7, count: 4096))
            for wrong in [
                SandboxLazyMemoryStore.Identity(sandboxID: UUID(), checkpointID: identity.checkpointID, generation: 3),
                SandboxLazyMemoryStore.Identity(
                    sandboxID: identity.sandboxID, checkpointID: identity.checkpointID, generation: 4),
            ] {
                await #expect(throws: SandboxLazyMemoryStore.StoreError.invalidRecord) {
                    try await reopened.recoverDelta(
                        token: token, identity: wrong, baseKey: key, compatibilityDigest: compatibility,
                        trustClass: "fixture")
                }
            }
            await #expect(throws: SandboxLazyMemoryStore.StoreError.pinned) { try await reopened.evict(key: key) }
            try await reopened.evict(key: token)
            try await reopened.evict(key: key)
            await #expect(throws: SandboxLazyMemoryStore.StoreError.missing) {
                try await reopened.loadBase(key: key, compatibilityDigest: compatibility, trustClass: "fixture")
            }
        }
    }

    @Test func pinsAndStagingRecovery() async throws {
        try await withStore { root, store in
            let key = try await store.publishBase(
                data: Data(repeating: 0, count: 4096), compatibilityDigest: compatibility, trustClass: "fixture")
            let pin = try await store.pin(baseKey: key, compatibilityDigest: compatibility, trustClass: "fixture")
            await #expect(throws: SandboxLazyMemoryStore.StoreError.pinned) { try await store.evict(key: key) }
            await #expect(throws: SandboxLazyMemoryStore.StoreError.pinned) { try await store.shutdown() }
            let stage = root + "/stage-" + UUID().uuidString.lowercased()
            try FileManager.default.createDirectory(
                atPath: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data([1]).write(to: URL(fileURLWithPath: stage + "/partial"))
            #expect(try await store.diskUsage().stagingBytes == 1)
            try await store.recoverStaging()
            #expect(try await store.diskUsage().stagingBytes == 0)
            #expect(try await store.diskUsage().baseBytes > 4096)
            #expect(!FileManager.default.fileExists(atPath: stage))
            _ = try await store.loadBase(key: key, compatibilityDigest: compatibility, trustClass: "fixture")
            let newerPin = try await store.pin(baseKey: key, compatibilityDigest: compatibility, trustClass: "fixture")
            await store.unpin(token: pin)
            await store.unpin(token: pin)
            await #expect(throws: SandboxLazyMemoryStore.StoreError.pinned) { try await store.evict(key: key) }
            await store.unpin(token: newerPin)
            try await store.evict(key: key)
        }
    }

    @Test func integrityTrustAndBudgetFailures() async throws {
        try await withStore(maximumBytes: 9000) { root, store in
            let key = try await store.publishBase(
                data: Data(repeating: 0, count: 4096), compatibilityDigest: compatibility, trustClass: "fixture")
            await #expect(throws: SandboxLazyMemoryStore.StoreError.invalidRecord) {
                try await store.loadBase(key: key, compatibilityDigest: compatibility, trustClass: "other")
            }
            await #expect(throws: SandboxLazyMemoryStore.StoreError.limitExceeded) {
                try await store.publishBase(
                    data: Data(repeating: 1, count: 8192), compatibilityDigest: compatibility, trustClass: "fixture")
            }
            let path = root + "/" + key + "/memory"
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: path))
            await #expect(throws: SandboxLazyMemoryPages.PageError.digestMismatch) {
                try await store.loadBase(key: key, compatibilityDigest: compatibility, trustClass: "fixture")
            }
        }
    }

    @Test func deltaPayloadAndIndexCorruptionNeverRecover() async throws {
        try await withStore { root, store in
            let key = try await store.publishBase(
                data: Data(repeating: 7, count: 4096), compatibilityDigest: compatibility, trustClass: "fixture")
            let identity = SandboxLazyMemoryStore.Identity(sandboxID: UUID(), checkpointID: UUID(), generation: 1)
            let pages = [0: Data(repeating: 9, count: 4096)]
            let token = try await store.publishDelta(
                identity: identity, baseKey: key, compatibilityDigest: compatibility, trustClass: "fixture",
                pages: pages)
            let before = try await store.diskUsage()
            #expect(
                try await store.publishDelta(
                    identity: identity, baseKey: key, compatibilityDigest: compatibility, trustClass: "fixture",
                    pages: pages) == token)
            #expect(try await store.diskUsage() == before)
            let page = root + "/" + token + "/page-0"
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: page)
            try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: page))
            await #expect(throws: SandboxLazyMemoryStore.StoreError.integrityMismatch) {
                try await store.recoverDelta(
                    token: token, identity: identity, baseKey: key, compatibilityDigest: compatibility,
                    trustClass: "fixture")
            }
            let index = root + "/" + token + "/manifest"
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index)
            try Data("{}".utf8).write(to: URL(fileURLWithPath: index))
            await #expect(throws: SandboxLazyMemoryStore.StoreError.integrityMismatch) {
                try await store.recoverDelta(
                    token: token, identity: identity, baseKey: key, compatibilityDigest: compatibility,
                    trustClass: "fixture")
            }
            await #expect(throws: SandboxLazyMemoryStore.StoreError.integrityMismatch) {
                try await store.evict(key: key)
            }
        }
    }

    @Test func symlinkHardlinkAndConcurrentOwnerRejection() async throws {
        try await withStore { root, store in
            #expect(throws: (any Error).self) { try SandboxLazyMemoryStore(directory: root) }
            let key = try await store.publishBase(
                data: Data(repeating: 0, count: 4096), compatibilityDigest: compatibility, trustClass: "fixture")
            let memory = root + "/" + key + "/memory"
            let alias = root + "/" + key + "/alias"
            try FileManager.default.linkItem(atPath: memory, toPath: alias)
            await #expect(throws: SandboxLazyMemoryStore.StoreError.invalidRecord) {
                try await store.loadBase(key: key, compatibilityDigest: compatibility, trustClass: "fixture")
            }
            try FileManager.default.removeItem(atPath: alias)
            try FileManager.default.removeItem(atPath: memory)
            try FileManager.default.createSymbolicLink(atPath: memory, withDestinationPath: "/dev/zero")
            await #expect(throws: (any Error).self) {
                try await store.loadBase(key: key, compatibilityDigest: compatibility, trustClass: "fixture")
            }
            await #expect(throws: SandboxLazyMemoryStore.StoreError.invalidRecord) {
                try await store.loadBase(key: "../escape", compatibilityDigest: compatibility, trustClass: "fixture")
            }
        }
    }
}
