#if os(Linux)
import CSandboxUFFD
import Foundation
import Glibc
import Testing
@testable import StratoAgentCore

@Suite("Concrete UFFD transport fixtures — no live restore proof")
struct SandboxUffdTransportTests {
    private let payload = Data(
        "[{\"base_host_virt_addr\":4096,\"size\":4096,\"offset\":0,\"page_size\":4096,\"page_size_kib\":4096}]".utf8)
    private func pair() throws -> [Int32] {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0, &sockets) == 0 else {
            throw SandboxUffdTransport.TransportError.io(errno)
        }
        return sockets
    }
    private func send(_ socket: Int32, data: Data, fds: [Int32]) throws {
        let result = data.withUnsafeBytes { bytes in
            fds.withUnsafeBufferPointer { descriptors in
                strato_uffd_send(socket, bytes.baseAddress!, bytes.count, descriptors.baseAddress, descriptors.count)
            }
        }
        guard result == 0 else { throw SandboxUffdTransport.TransportError.io(errno) }
    }
    private func transport(_ socket: Int32, pid: Int32 = getpid()) throws -> SandboxUffdTransport {
        try .init(
            connectedSocket: socket, peer: .init(pid: pid, uid: geteuid(), gid: getegid()),
            referenceRelease: "1.13.1", memoryBytes: 4096)
    }

    @Test func descriptorPassingCloexecAndCountLimits() throws {
        let sockets = try pair()
        defer { sockets.forEach { _ = close($0) } }
        let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
        defer { _ = close(fd) }
        let cancellation = strato_uffd_cancel_new()
        defer { _ = close(cancellation) }
        try send(sockets[0], data: payload, fds: [fd])
        var buffer = [UInt8](repeating: 0, count: 65536)
        var received: Int32 = -1
        let count = buffer.withUnsafeMutableBytes {
            strato_uffd_receive(sockets[1], cancellation, $0.baseAddress!, $0.count, 1000, &received)
        }
        #expect(count == payload.count)
        #expect(received >= 0)
        #expect(fcntl(received, F_GETFD) & FD_CLOEXEC == FD_CLOEXEC)
        _ = close(received)
        for descriptors in [[], [fd, fd], Array(repeating: fd, count: 16)] {
            try send(sockets[0], data: payload, fds: descriptors)
            received = -1
            let result = buffer.withUnsafeMutableBytes {
                strato_uffd_receive(sockets[1], cancellation, $0.baseAddress!, $0.count, 1000, &received)
            }
            #expect(result == -1 && errno == EPROTO)
            #expect(received == -1)
        }
    }

    @Test func wrongPeerAndNonUffdDescriptorAreRejected() throws {
        let sockets = try pair()
        defer { sockets.forEach { _ = close($0) } }
        let wrong = try transport(sockets[1], pid: getpid() + 1)
        #expect(throws: SandboxUffdTransport.TransportError.wrongPeer) { try wrong.receiveHandshake() }
        let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
        defer { _ = close(fd) }
        try send(sockets[0], data: payload, fds: [fd])
        let receiver = try transport(sockets[1])
        #expect(throws: SandboxUffdTransport.TransportError.wrongDescriptor) { try receiver.receiveHandshake() }
        #expect(receiver.outstandingOperations == 0)
        #expect(throws: SandboxUffdTransport.TransportError.cancelled) { try receiver.nextFault() }
    }

    @Test func fragmentedHandshakeAndUnexpectedExtraDescriptors() throws {
        let sockets = try pair()
        defer { sockets.forEach { _ = close($0) } }
        let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
        defer { _ = close(fd) }
        try send(sockets[0], data: Data(payload.prefix(1)), fds: [fd])
        try send(sockets[0], data: Data(payload.dropFirst()), fds: [])
        let receiver = try transport(sockets[1])
        #expect(throws: SandboxUffdTransport.TransportError.wrongDescriptor) { try receiver.receiveHandshake() }
        // A second descriptor in a continuation must fail, not leak into the
        // worker or be mistaken for a second sandbox's memory descriptor.
        let extra = try pair()
        defer { extra.forEach { _ = close($0) } }
        try send(extra[0], data: Data("[".utf8), fds: [fd])
        try send(extra[0], data: Data("]".utf8), fds: [fd])
        let bad = try transport(extra[1])
        #expect(throws: SandboxUffdTransport.TransportError.io(EPROTO)) { try bad.receiveHandshake() }
    }

    @Test func handshakeDeadlineAndCancellationWakePollers() async throws {
        let sockets = try pair()
        defer { sockets.forEach { _ = close($0) } }
        let expired = try transport(sockets[1])
        #expect(throws: SandboxUffdTransport.TransportError.io(ETIMEDOUT)) {
            try expired.receiveHandshake(timeoutMilliseconds: 20)
        }
        let cancelled = try transport(sockets[1])
        let operation = Task.detached { try cancelled.receiveHandshake(timeoutMilliseconds: 5000) }
        let clock = ContinuousClock(); let admission = clock.now.advanced(by: .seconds(2))
        while cancelled.outstandingOperations == 0 && clock.now < admission { await Task.yield() }
        cancelled.cancel()
        do { try await operation.value; Issue.record("cancelled handshake accepted") } catch {
            #expect(
                error as? SandboxUffdTransport.TransportError == .io(ECANCELED)
                    || error as? SandboxUffdTransport.TransportError == .cancelled)
        }
        #expect(cancelled.outstandingOperations == 0)
    }

    @Test func layoutsAndMessageBoundsAreChecked() throws {
        let regions = try SandboxUffdTransport.decodeRegions(payload, memoryBytes: 4096)
        #expect(try SandboxUffdTransport.page(address: 4096, regions: regions) == 0)
        #expect(throws: SandboxUffdTransport.TransportError.invalidLayout) {
            try SandboxUffdTransport.page(address: 8192, regions: regions)
        }
        let overlap = Data(
            "[{\"base_host_virt_addr\":4096,\"size\":4096,\"offset\":0,\"page_size\":4096},{\"base_host_virt_addr\":4096,\"size\":4096,\"offset\":4096,\"page_size\":4096}]"
                .utf8)
        #expect(throws: SandboxUffdTransport.TransportError.invalidLayout) {
            try SandboxUffdTransport.decodeRegions(overlap, memoryBytes: 8192)
        }
        let overflow = Data(
            "[{\"base_host_virt_addr\":18446744073709547520,\"size\":4096,\"offset\":0,\"page_size\":4096}]".utf8)
        #expect(throws: SandboxUffdTransport.TransportError.invalidLayout) {
            try SandboxUffdTransport.decodeRegions(overflow, memoryBytes: 4096)
        }
        #expect(throws: SandboxUffdTransport.TransportError.invalidLayout) {
            try SandboxUffdTransport.decodeRegions(payload, memoryBytes: 8192)
        }
        #expect(try !SandboxUffdTransport.completeMessage(Data(payload.prefix(10))))
        #expect(try SandboxUffdTransport.completeMessage(payload))
        #expect(throws: SandboxUffdTransport.TransportError.malformedMessage) {
            try SandboxUffdTransport.completeMessage(payload + Data("[]".utf8))
        }
        #expect(throws: SandboxUffdTransport.TransportError.invalidLimits) {
            try SandboxUffdTransport.decodeRegions(Data(repeating: 32, count: 65537), memoryBytes: 4096)
        }
    }

    @Test func rawEventFixturesAndShortReadsFailClosed() throws {
        // Linux UAPI uffd_msg is 32 packed bytes. These are parser fixtures, not UFFD descriptors.
        let sockets = try pair()
        defer { sockets.forEach { _ = close($0) } }
        let cancellation = strato_uffd_cancel_new()
        defer { _ = close(cancellation) }
        for (tag, kind) in [(UInt8(0x12), Int32(1)), (0x15, 2), (0x13, 3)] {
            var bytes = Data(repeating: 0, count: 32)
            bytes[0] = tag
            var first: UInt64 = tag == 0x12 ? 1 : 4096
            var second: UInt64 = 8192
            withUnsafeBytes(of: &first) { bytes.replaceSubrange(8..<16, with: $0) }
            withUnsafeBytes(of: &second) { bytes.replaceSubrange(16..<24, with: $0) }
            try send(sockets[0], data: bytes, fds: [])
            var event = strato_uffd_event()
            #expect(strato_uffd_read_event(sockets[1], cancellation, 1000, &event) == 0)
            #expect(event.kind == kind)
            if kind == 1 { #expect(event.address == 8192 && event.flags == 1) }
            if kind == 2 { #expect(event.address == 4096 && event.end == 8192) }
        }
        try send(sockets[0], data: Data([0x12]), fds: [])
        var event = strato_uffd_event()
        #expect(strato_uffd_read_event(sockets[1], cancellation, 1000, &event) == -1 && errno == EPROTO)
        #expect(strato_uffd_read_event(sockets[1], cancellation, 10, &event) == -1 && errno == ETIMEDOUT)
        #expect(strato_uffd_cancel(cancellation) == 0)
        #expect(strato_uffd_read_event(sockets[1], cancellation, 1000, &event) == -1 && errno == ECANCELED)
    }

    @Test func ioctlNegativePathNeverQualifiesCapability() throws {
        let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
        defer { _ = close(fd) }
        let data = Data(repeating: 0, count: 4096)
        let result = data.withUnsafeBytes { strato_uffd_copy(fd, 4096, $0.baseAddress!, $0.count) }
        #expect(result == -1 && errno == ENOTTY)
        #expect(strato_uffd_descriptor_kind(fd) == -1)
        #expect(
            try SandboxRestoreMemoryPreparation.prepare(filePath: "memory").fallbackReason.contains("uffd-disabled"))
    }
}
#endif
