#if os(Linux)
import Foundation
import Glibc
import Logging
import StratoAgentCore
import StratoShared
import Synchronization
import Testing

@testable import StratoAgentRuntime
@testable import SwiftFirecracker

@Suite("adopted guest automatic fence release")
struct SandboxAdoptedFenceReleaseTests {
    enum ProbeCase: CaseIterable, Sendable { case idle, legacy, wrongIdentity }

    @Test func fixtureShutdownInterruptsAccept() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try AdoptedGuestSocketFixture(path: root.path + "/guest.sock", replies: [Data()])
        fixture.closeListener()
        // Shutdown wakes accept rather than waiting for the five-second poll
        // timeout, even if serving has not yet been scheduled.
        await #expect(throws: AdoptedGuestSocketFixture.Failure.socket) {
            try await fixture.requests.value
        }
        // Closing after the worker finished must not close a reused descriptor.
        fixture.closeListener()
    }

    @Test(arguments: ProbeCase.allCases)
    func pausedAdoptionLearnsActualCapabilityBeforeRelease(probe: ProbeCase) async throws {
        let version = probe == .legacy ? 4 : 5
        let compatible = probe == .idle
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let nonce = "adopted-identity"
        let fence = SandboxAutomaticSuspensionFence(
            operationId: UUID(), generation: 7, activityRevision: 3, admissionToken: UUID(), guestProtocolVersion: 5)
        var record = SandboxSuspensionRecord(
            sandboxId: id, snapshotId: UUID(), generation: 7, activityEpoch: 1, jailUID: 100000,
            spec: SandboxSpec(image: "fixture", cpus: 1, memoryBytes: 128 * 1024 * 1024))
        record.guestFence = SandboxSuspensionGuestFence(request: fence, identityNonce: nonce)
        let pong = try JSONSerialization.data(withJSONObject: [
            "type": "pong", "sandbox_id": id.uuidString, "nonce": probe == .wrongIdentity ? "stale-identity" : nonce,
            "control_protocol_version": version,
        ])
        let released = try JSONEncoder().encode(
            SandboxIdleGuestResponse(
                type: .fence, sandboxId: id.uuidString, nonce: nonce,
                operationId: try UUID(protocolString: fence.operationID),
                admissionToken: try UUID(protocolString: fence.admissionToken), state: .released))
        let socketPath = root.path + "/guest.sock"
        let fixture = try AdoptedGuestSocketFixture(
            path: socketPath, replies: compatible ? [pong, released, released] : [pong])
        defer { fixture.closeListener() }
        let box = AdoptedFenceRuntimeBox()
        let transport = SandboxIdleFenceTransport(
            minimumQuietMilliseconds: 1,
            exchange: { context, request in
                try await box.exchange(context, request: request)
            }, validate: { _ in })
        let logger = Logger(label: "adopted-fence-test")
        let binary = root.path + "/missing-firecracker"
        let runtime = try FirecrackerSandboxRuntime(
            logger: logger,
            client: FirecrackerClient(
                firecrackerBinaryPath: binary, socketDirectory: root.path + "/sockets", logger: logger),
            imageService: SandboxImageService(logger: logger, cacheRootPath: root.path + "/images"),
            socketDirectory: root.path + "/sockets", sandboxStoragePath: root.path,
            guestImagePath: root.path + "/missing-kernel", firecrackerBinaryPath: binary,
            jailer: SandboxJailerConfig(
                jailerBinaryPath: root.path + "/missing-jailer", chrootBaseDir: root.path + "/jails", uidBase: 100000),
            jailUIDAllocator: SandboxJailUIDAllocator(uidBase: 100000), legacyJailerUIDBase: 100000,
            jailNewSandboxes: true, warmStartEnabled: false, automaticSuspensionTransport: transport)
        await box.install(runtime)
        await runtime.seedAdoptedFenceForTest(record, socketPath: socketPath)
        #expect(await runtime.adoptedCapabilityForTest(id) == nil)
        if compatible {
            let result = try await runtime.releaseAutomaticSuspensionFence(record)
            #expect(result.guestFence?.state == .released)
            #expect(await runtime.adoptedCapabilityForTest(id) == 5)
            let persisted = try SandboxSuspensionStore(directory: root.path + "/suspension-records").load(sandboxId: id)
            #expect(persisted?.guestFence?.state == .released)
            let requests = try await fixture.requests.value
            #expect(requests == ["ping", "release_idle", "query_idle"])
            await runtime.forgetAdoptedGuestForTest(id)
            // Released and absent fences need no guest contact or capability.
            #expect(try await runtime.releaseAutomaticSuspensionFence(result).guestFence?.state == .released)
            var unfenced = record
            unfenced.guestFence = nil
            #expect(try await runtime.releaseAutomaticSuspensionFence(unfenced).guestFence == nil)
        } else {
            await #expect(throws: SandboxSuspensionGuard.GateError.stale) {
                try await runtime.releaseAutomaticSuspensionFence(record)
            }
            #expect(await runtime.adoptedCapabilityForTest(id) == nil)
            #expect(try await fixture.requests.value == ["ping"])
        }
    }
}

private actor AdoptedFenceRuntimeBox {
    var runtime: FirecrackerSandboxRuntime?
    func install(_ runtime: FirecrackerSandboxRuntime) { self.runtime = runtime }
    func exchange(_ context: SandboxSuspensionFenceContext, request: SandboxIdleGuestRequest) async throws
        -> SandboxIdleGuestResponse
    {
        guard let runtime else { throw SandboxSuspensionGuard.GateError.stale }
        return try await runtime.exchangeIdleFence(context, request: request)
    }
}

extension FirecrackerSandboxRuntime {
    fileprivate func seedAdoptedFenceForTest(_ record: SandboxSuspensionRecord, socketPath: String) {
        let id = record.sandboxId.uuidString
        sandboxes[id] = Managed(
            spec: record.spec, rootfsPath: socketPath + ".rootfs", configPath: socketPath + ".config",
            vsockUdsPath: socketPath, identityNonce: record.guestFence!.identityNonce, jail: nil,
            manager: FirecrackerManager(socketPath: socketPath + ".missing-api"), lastExitCode: nil)
    }
    fileprivate func forgetAdoptedGuestForTest(_ id: UUID) { sandboxes.removeValue(forKey: id.uuidString) }
    fileprivate func adoptedCapabilityForTest(_ id: UUID) -> Int? {
        sandboxes[id.uuidString]?.guestControlProtocolVersion
    }
}

private final class AdoptedGuestSocketFixture: @unchecked Sendable {
    enum Failure: Error, Equatable { case socket, timeout, protocolMismatch }
    // The worker owns close; cancellation only shuts the listener down under
    // the same lock. No poll/accept can observe a recycled descriptor.
    private final class Listener: Sendable {
        let descriptor: Int32
        private let finished = Mutex(false)
        init(_ descriptor: Int32) { self.descriptor = descriptor }
        func stop() {
            finished.withLock { finished in
                if !finished { _ = shutdown(descriptor, Int32(SHUT_RDWR)) }
            }
        }
        func finish() {
            finished.withLock { finished in
                guard !finished else { return }
                _ = Glibc.close(descriptor)
                finished = true
            }
        }
    }
    private let listener: Listener
    let requests: Task<[String], any Error>
    init(path: String, replies: [Data]) throws {
        let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard descriptor >= 0 else { throw Failure.socket }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            _ = Glibc.close(descriptor); throw Failure.socket
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else { _ = Glibc.close(descriptor); throw Failure.socket }
        let listener = Listener(descriptor)
        self.listener = listener
        // poll/read are blocking syscalls. Task.detached would occupy the
        // cooperative executor needed by the runtime to answer the fixture.
        requests = Task {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    defer { listener.finish() }
                    continuation.resume(
                        with: Result {
                            try Self.serve(descriptor: descriptor, replies: replies)
                        })
                }
            }
        }
    }
    private static func serve(descriptor: Int32, replies: [Data]) throws -> [String] {
        var kinds: [String] = []
        for reply in replies {
            var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&readiness, 1, 5000) > 0 else { throw Failure.timeout }
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { throw Failure.socket }
            defer { _ = Glibc.close(client) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let connect = try Self.readLine(client)
            guard connect.hasPrefix("CONNECT ") else { throw Failure.protocolMismatch }
            try Self.writeLine(Data("OK 123\n".utf8), client)
            let request = try Self.readLine(client)
            guard let json = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any],
                let type = json["type"] as? String
            else { throw Failure.protocolMismatch }
            kinds.append(type)
            try Self.writeLine(reply + Data([10]), client)
        }
        return kinds
    }
    func closeListener() { listener.stop() }
    private static func readLine(_ descriptor: Int32) throws -> String {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < 4096 {
            guard read(descriptor, &byte, 1) == 1 else { throw Failure.socket }
            if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        throw Failure.protocolMismatch
    }
    private static func writeLine(_ data: Data, _ descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = send(
                    descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
                guard count > 0 else { throw Failure.socket }
                offset += count
            }
        }
    }
}
#endif
