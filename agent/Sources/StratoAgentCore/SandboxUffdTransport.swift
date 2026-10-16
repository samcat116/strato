#if os(Linux)
import CSandboxUFFD
import Foundation
import Glibc
import Synchronization

/// Bounded Firecracker v1.13.1-reference transport. Not a capability probe and
/// not installed in production. A live adapter still needs approved binary/jail
/// scope, killable process supervision and actual fault/restore verification.
public final class SandboxUffdTransport: Sendable {
    public enum TransportError: Error, Sendable, Equatable {
        case unsupportedProtocol, invalidLimits, wrongPeer, malformedMessage, invalidLayout
        case wrongDescriptor, notReady, cancelled, capacity, wrongLease, unsupportedEvent, io(Int32)
    }
    public struct Peer: Sendable, Equatable {
        public let pid: Int32
        public let uid: UInt32
        public let gid: UInt32
        public init(pid: Int32, uid: UInt32, gid: UInt32) { self.pid = pid; self.uid = uid; self.gid = gid }
    }
    public struct Region: Codable, Sendable, Equatable {
        public let host: UInt64
        public let size: UInt64
        public let offset: UInt64
        public let pageSize: UInt64
        let legacyPageSize: UInt64?
        enum CodingKeys: String, CodingKey {
            case host = "base_host_virt_addr", size, offset, pageSize = "page_size", legacyPageSize = "page_size_kib"
        }
    }
    public struct Fault: Sendable {
        public let address: UInt64
        public let page: Int
        fileprivate let lease: UUID
    }
    public enum CopyResult: Sendable, Equatable { case copied, alreadyResolved, retryAfterDrain }
    private struct State: Sendable {
        var socket: Int32
        var cancel: Int32
        var uffd: Int32 = -1
        var cancelled = false
        var active = 0
        var receiving = false
        var regions: [Region] = []
    }
    private let state: Mutex<State>
    private let peer: Peer
    private let bytes: Int
    private let lease = UUID()

    /// The caller must own the connected socket until this initializer returns.
    /// It is duplicated atomically with CLOEXEC; subsequent operations pin their
    /// own duplicates, preventing close/reuse from targeting another lease.
    public init(connectedSocket: Int32, peer: Peer, referenceRelease: String, memoryBytes: Int) throws {
        guard referenceRelease == "1.13.1" else { throw TransportError.unsupportedProtocol }
        guard peer.pid > 0, memoryBytes > 0, memoryBytes <= 1 << 30, memoryBytes % 4096 == 0 else {
            throw TransportError.invalidLimits
        }
        let socket = fcntl(connectedSocket, F_DUPFD_CLOEXEC, 0)
        guard socket >= 0 else { throw TransportError.io(errno) }
        let cancel = strato_uffd_cancel_new()
        guard cancel >= 0 else { _ = close(socket); throw TransportError.io(errno) }
        self.state = Mutex(State(socket: socket, cancel: cancel))
        self.peer = peer; self.bytes = memoryBytes
    }
    deinit {
        state.withLock { value in
            for fd in [value.socket, value.cancel, value.uffd] where fd >= 0 { _ = close(fd) }
        }
    }
    public var outstandingOperations: Int { state.withLock { $0.active } }

    /// Revocation wakes pollers and prevents new work. It does not claim process
    /// death or interrupt an ioctl already in flight. The owner must keep the
    /// lifecycle lease until outstanding work/owned process teardown is proven.
    public func cancel() {
        state.withLock { value in
            guard !value.cancelled else { return }
            value.cancelled = true
            _ = strato_uffd_cancel(value.cancel)
            for fd in [value.socket, value.uffd] where fd >= 0 { _ = close(fd) }
            value.socket = -1; value.uffd = -1
        }
    }

    public func receiveHandshake(timeoutMilliseconds: Int32 = 5000) throws {
        try limits(timeoutMilliseconds)
        try state.withLock { value in
            guard !value.cancelled else { throw TransportError.cancelled }
            guard !value.receiving, value.uffd < 0 else { throw TransportError.notReady }
            value.receiving = true
        }
        defer { state.withLock { $0.receiving = false } }
        do {
            try withDescriptors(requireUffd: false) { socket, cancel, _, _ in
                var pid: Int32 = 0; var uid: UInt32 = 0; var gid: UInt32 = 0
                guard strato_uffd_peer(socket, &pid, &uid, &gid) == 0 else { throw TransportError.io(errno) }
                guard Peer(pid: pid, uid: uid, gid: gid) == peer else { throw TransportError.wrongPeer }
                let clock = ContinuousClock();
                let deadline = clock.now.advanced(by: .milliseconds(Int64(timeoutMilliseconds)))
                var buffer = [UInt8](repeating: 0, count: 65536); var descriptor: Int32 = -1
                var count = buffer.withUnsafeMutableBytes {
                    strato_uffd_receive(socket, cancel, $0.baseAddress!, $0.count, timeoutMilliseconds, &descriptor)
                }
                guard count >= 0 else { throw TransportError.io(errno) }
                var transferred = false
                defer { if !transferred, descriptor >= 0 { _ = close(descriptor) } }
                var payload = Data(buffer.prefix(Int(count)))
                while try !Self.completeMessage(payload) {
                    guard payload.count < 65536 else { throw TransportError.malformedMessage }
                    let remaining = clock.now.duration(to: deadline)
                    let parts = remaining.components
                    let milliseconds = parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
                    guard milliseconds > 0 else { throw TransportError.io(ETIMEDOUT) }
                    count = buffer.withUnsafeMutableBytes {
                        strato_uffd_read_fragment(
                            socket, cancel, $0.baseAddress!, 65536 - payload.count, Int32(min(milliseconds, 60000)))
                    }
                    guard count > 0 else { throw TransportError.io(errno) }
                    payload.append(contentsOf: buffer.prefix(Int(count)))
                }
                let regions = try Self.decodeRegions(payload, memoryBytes: bytes)
                // Firecracker has already initialized UFFDIO_API. Calling it
                // again would fail, so do not pretend to renegotiate/query it.
                guard strato_uffd_descriptor_kind(descriptor) == 0 else { throw TransportError.wrongDescriptor }
                try state.withLock { value in
                    guard !value.cancelled else { throw TransportError.cancelled }
                    guard value.uffd < 0 else { throw TransportError.notReady }
                    value.uffd = descriptor; value.regions = regions; transferred = true
                }
            }
        } catch { cancel(); throw error }
    }

    /// An idle poll timeout is not a page-fault failure. Unsupported REMOVE,
    /// FORK, REMAP, UNMAP, WP/minor events fail closed in this no-balloon, 4 KiB
    /// prototype; no old snapshot page may be replayed after removal.
    public func nextFault(timeoutMilliseconds: Int32 = 1000) throws -> Fault? {
        try limits(timeoutMilliseconds)
        do {
            return try withDescriptors(requireUffd: true) { _, cancel, uffd, regions in
                var event = strato_uffd_event()
                guard strato_uffd_read_event(uffd, cancel, timeoutMilliseconds, &event) == 0 else {
                    if errno == ETIMEDOUT { return nil }
                    throw TransportError.io(errno)
                }
                guard event.kind == 1, event.flags & ~UInt64(1) == 0 else { throw TransportError.unsupportedEvent }
                let address = event.address & ~UInt64(4095)
                return Fault(address: address, page: try Self.page(address: address, regions: regions), lease: lease)
            }
        } catch { cancel(); throw error }
    }

    public func resolve(_ fault: Fault, data: Data) throws -> CopyResult {
        guard fault.lease == lease, data.count == 4096 else { throw TransportError.wrongLease }
        do {
            return try withDescriptors(requireUffd: true) { _, cancel, uffd, regions in
                guard try Self.page(address: fault.address, regions: regions) == fault.page else {
                    throw TransportError.invalidLayout
                }
                var poller = pollfd(fd: cancel, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 0) == 0 else { throw TransportError.cancelled }
                let result = data.withUnsafeBytes { strato_uffd_copy(uffd, fault.address, $0.baseAddress!, $0.count) }
                if result == 0 { return .copied }
                if errno == EEXIST { return .alreadyResolved }
                if errno == EAGAIN { return .retryAfterDrain }
                throw TransportError.io(errno)
            }
        } catch { cancel(); throw error }
    }

    static func decodeRegions(_ payload: Data, memoryBytes: Int) throws -> [Region] {
        guard payload.count <= 65536, memoryBytes > 0, memoryBytes <= 1 << 30, memoryBytes % 4096 == 0 else {
            throw TransportError.invalidLimits
        }
        let regions: [Region]
        do { regions = try JSONDecoder().decode([Region].self, from: payload) } catch {
            throw TransportError.malformedMessage
        }
        guard !regions.isEmpty, regions.count <= 32 else { throw TransportError.invalidLayout }
        var offset: UInt64 = 0
        for region in regions {
            let (end, overflow) = region.host.addingReportingOverflow(region.size)
            guard region.host > 0, region.host % 4096 == 0, region.size > 0, region.size % 4096 == 0,
                region.pageSize == 4096, region.legacyPageSize == nil || region.legacyPageSize == 4096,
                region.offset == offset, !overflow, end > region.host,
                region.size <= UInt64(memoryBytes) - offset
            else { throw TransportError.invalidLayout }
            offset += region.size
        }
        guard offset == UInt64(memoryBytes) else { throw TransportError.invalidLayout }
        let sorted = regions.sorted { $0.host < $1.host }
        for index in sorted.indices.dropFirst() {
            guard sorted[index - 1].host + sorted[index - 1].size <= sorted[index].host else {
                throw TransportError.invalidLayout
            }
        }
        return regions
    }
    static func page(address: UInt64, regions: [Region]) throws -> Int {
        guard address % 4096 == 0,
            let region = regions.first(where: { address >= $0.host && address - $0.host < $0.size })
        else { throw TransportError.invalidLayout }
        return Int((region.offset + (address - region.host)) / 4096)
    }
    static func completeMessage(_ data: Data) throws -> Bool {
        var stack: [UInt8] = []; var quoted = false; var escaped = false; var started = false; var complete = false
        for byte in data {
            if complete {
                guard [9, 10, 13, 32].contains(byte) else { throw TransportError.malformedMessage }; continue
            }
            if quoted {
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    quoted = false
                }
                continue
            }
            if !started {
                if [9, 10, 13, 32].contains(byte) { continue }
                guard byte == 91 else { throw TransportError.malformedMessage }
                started = true
            }
            if byte == 34 {
                quoted = true
            } else if byte == 91 || byte == 123 {
                stack.append(byte); guard stack.count <= 64 else { throw TransportError.malformedMessage }
            } else if byte == 93 || byte == 125 {
                guard let open = stack.popLast(), (open == 91 && byte == 93) || (open == 123 && byte == 125) else {
                    throw TransportError.malformedMessage
                }
                if stack.isEmpty { complete = true }
            }
        }
        return complete
    }
    private func limits(_ timeout: Int32) throws {
        guard timeout > 0, timeout <= 60000 else { throw TransportError.invalidLimits }
    }
    private func withDescriptors<T>(requireUffd: Bool, _ body: (Int32, Int32, Int32, [Region]) throws -> T) throws -> T
    {
        let handles: (Int32, Int32, Int32, [Region]) = try state.withLock { value in
            guard !value.cancelled else { throw TransportError.cancelled }
            guard value.active < 64 else { throw TransportError.capacity }
            guard !requireUffd || value.uffd >= 0 else { throw TransportError.notReady }
            var copies: [Int32] = []
            do {
                for fd in [value.socket, value.cancel, value.uffd] {
                    let copy = fd >= 0 ? fcntl(fd, F_DUPFD_CLOEXEC, 0) : -1
                    guard fd < 0 || copy >= 0 else { throw TransportError.io(errno) }
                    copies.append(copy)
                }
            } catch { for fd in copies where fd >= 0 { _ = close(fd) }; throw error }
            value.active += 1
            return (copies[0], copies[1], copies[2], value.regions)
        }
        defer {
            for fd in [handles.0, handles.1, handles.2] where fd >= 0 { _ = close(fd) }
            state.withLock { $0.active -= 1 }
        }
        return try body(handles.0, handles.1, handles.2, handles.3)
    }
}
#endif
