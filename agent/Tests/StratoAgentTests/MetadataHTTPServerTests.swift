#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import Logging
import NIOPosix
import StratoShared
import Testing

@testable import StratoAgentCore

/// The listener itself, over loopback: no namespace, no root, no guest.
///
/// What only this suite can show is that the pipeline, the response encoding
/// and the bounds actually work together — everything above it is asserted as
/// values in `MetadataResponderTests`.
@Suite("Metadata HTTP Server Tests", .serialized)
struct MetadataHTTPServerTests {

    // MARK: - Fixtures

    private static func instance(_ vmId: UUID, hostname: String? = nil, network: UUID, address: String)
        -> InstanceMetadata
    {
        let isV6 = address.contains(":")
        return InstanceMetadata(
            instanceId: vmId, hostname: hostname, projectId: UUID(),
            nics: [
                MetadataNIC(
                    deviceName: "net0", macAddress: "52:54:00:00:00:01", networkId: network,
                    networkName: "tenant",
                    ipAddress: isV6 ? nil : address, prefixLength: isV6 ? nil : 24,
                    ipv6Address: isV6 ? address : nil, ipv6PrefixLength: isV6 ? 128 : nil)
            ])
    }

    /// Stands a listener up on `host`, port 0, serving one instance at that
    /// address. Returns the port and a teardown.
    private static func serve(
        host: String = "127.0.0.1", vmId: UUID = UUID(), hostname: String? = "web-01"
    ) async throws -> (port: Int, vmId: UUID, stop: @Sendable () async -> Void) {
        let network = UUID()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let responder = MetadataResponder(
            snapshot: MetadataSnapshot(
                networkId: network, origin: .live,
                instances: [instance(vmId, hostname: hostname, network: network, address: host)]),
            logger: Logger(label: "test"))
        let server = MetadataHTTPServer(
            group: group, responder: responder, hopLimit: 1, logger: Logger(label: "test"))
        // A successful bind is itself evidence about the hop limit: the option
        // is applied to the listening socket through the bootstrap, so a
        // wrong-family `IP_TTL`/`IPV6_UNICAST_HOPS` would fail the bind rather
        // than pass silently.
        let port = try await server.listen(address: host, port: 0)
        return (
            port, vmId,
            {
                await server.shutdown()
                try? await group.shutdownGracefully()
            }
        )
    }

    // MARK: - The handshake, end to end

    @Test("A guest completes the IMDSv2 handshake and reads its own instance id")
    func handshake() async throws {
        let (port, vmId, stop) = try await Self.serve()
        defer { Task { await stop() } }

        let unauthenticated = try RawHTTP.roundTrip(
            port: port, request: "GET /latest/meta-data/instance-id HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        #expect(unauthenticated.status == 401)

        let minted = try RawHTTP.roundTrip(
            port: port,
            request: """
                PUT /latest/api/token HTTP/1.1\r
                Host: x\r
                \(MetadataHeaderName.tokenTTL): 60\r
                Connection: close\r
                \r

                """)
        #expect(minted.status == 200)
        #expect(!minted.body.isEmpty)

        let read = try RawHTTP.roundTrip(
            port: port,
            request: """
                GET /latest/meta-data/instance-id HTTP/1.1\r
                Host: x\r
                \(MetadataHeaderName.token): \(minted.body)\r
                Connection: close\r
                \r

                """)
        #expect(read.status == 200)
        #expect(read.body == vmId.uuidString)
    }

    @Test("A connection is reused across requests")
    func keepAlive() async throws {
        // cloud-init mints once and then reads several keys on one connection.
        let (port, vmId, stop) = try await Self.serve()
        defer { Task { await stop() } }

        let connection = try RawHTTP.Connection(port: port)
        defer { connection.disconnect() }

        let minted = try connection.roundTrip(
            "PUT /latest/api/token HTTP/1.1\r\nHost: x\r\n\(MetadataHeaderName.tokenTTL): 60\r\n\r\n")
        #expect(minted.status == 200)

        let first = try connection.roundTrip(
            "GET /latest/meta-data/instance-id HTTP/1.1\r\nHost: x\r\n\(MetadataHeaderName.token): \(minted.body)\r\n\r\n"
        )
        #expect(first.body == vmId.uuidString)

        let second = try connection.roundTrip(
            "GET /latest/meta-data/hostname HTTP/1.1\r\nHost: x\r\n\(MetadataHeaderName.token): \(minted.body)\r\n\r\n")
        #expect(second.body == "web-01")
    }

    @Test("An IPv6 guest is served on the ULA endpoint")
    func ipv6() async throws {
        let (port, vmId, stop) = try await Self.serve(host: "::1")
        defer { Task { await stop() } }

        let minted = try RawHTTP.roundTrip(
            port: port, host: "::1",
            request:
                "PUT /latest/api/token HTTP/1.1\r\nHost: x\r\n\(MetadataHeaderName.tokenTTL): 60\r\nConnection: close\r\n\r\n"
        )
        #expect(minted.status == 200)

        let read = try RawHTTP.roundTrip(
            port: port, host: "::1",
            request:
                "GET /latest/meta-data/instance-id HTTP/1.1\r\nHost: x\r\n\(MetadataHeaderName.token): \(minted.body)\r\nConnection: close\r\n\r\n"
        )
        #expect(read.body == vmId.uuidString)
    }

    // MARK: - Bounds

    @Test("An over-long request head is dropped rather than buffered")
    func oversizedHead() async throws {
        let (port, _, stop) = try await Self.serve()
        defer { Task { await stop() } }

        var request = "GET /latest/meta-data/instance-id HTTP/1.1\r\nHost: x\r\n"
        // Comfortably past the decoder's buffer cap.
        for index in 0..<400 {
            request += "X-Filler-\(index): \(String(repeating: "a", count: 64))\r\n"
        }
        request += "\r\n"

        let connection = try RawHTTP.Connection(port: port)
        defer { connection.disconnect() }
        // The peer closes, so a partial write is expected and is itself the
        // symptom.
        _ = try? connection.write(request)
        // Nothing at all comes back: a guest that ignores the limit gets the
        // connection taken away, not a courteous refusal it can loop on. And
        // the agent stops accumulating headers rather than answering from them.
        #expect(connection.readAvailable().isEmpty)
    }

    @Test("A request carrying a body is refused")
    func bodyRefused() async throws {
        let (port, _, stop) = try await Self.serve()
        defer { Task { await stop() } }

        let response = try RawHTTP.roundTrip(
            port: port,
            request: """
                PUT /latest/api/token HTTP/1.1\r
                Host: x\r
                \(MetadataHeaderName.tokenTTL): 60\r
                Content-Length: 4\r
                Connection: close\r
                \r
                junk
                """)
        #expect(response.status == 400)
    }

    @Test("Connections past the cap are closed without being served")
    func connectionCap() async throws {
        let (port, _, stop) = try await Self.serve()
        defer { Task { await stop() } }

        // Hold the cap open. Idle connections are enough: the cap is counted at
        // accept, before a byte is read.
        var held: [RawHTTP.Connection] = []
        defer { held.forEach { $0.disconnect() } }
        for _ in 0..<MetadataLimits.maxConnections {
            held.append(try RawHTTP.Connection(port: port))
        }

        let extra = try RawHTTP.Connection(port: port)
        defer { extra.disconnect() }
        _ = try? extra.write("GET /latest/meta-data/instance-id HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        #expect(extra.readAvailable().isEmpty)
    }
}

// MARK: - A minimal HTTP client

/// Raw sockets rather than a client library: these tests assert on framing and
/// on connections being closed, which a client that hides both would obscure.
enum RawHTTP {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: String
    }

    struct ClientError: Error, CustomStringConvertible {
        let description: String
    }

    final class Connection {
        private let fd: Int32

        init(port: Int, host: String = "127.0.0.1") throws {
            let isV6 = host.contains(":")
            fd = socket(isV6 ? AF_INET6 : AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            guard fd >= 0 else { throw ClientError(description: "socket: \(errno)") }

            // Bounded reads, so a bug here fails the test instead of hanging it.
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var result: Int32 = -1
            if isV6 {
                var address = sockaddr_in6()
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = UInt16(port).bigEndian
                inet_pton(AF_INET6, host, &address.sin6_addr)
                result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            } else {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = UInt16(port).bigEndian
                inet_pton(AF_INET, host, &address.sin_addr)
                result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard result == 0 else {
                _ = close(fd)
                throw ClientError(description: "connect: \(errno)")
            }
        }

        func disconnect() { _ = close(fd) }

        @discardableResult
        func write(_ string: String) throws -> Int {
            let bytes = Array(string.utf8)
            var written = 0
            while written < bytes.count {
                let sent = bytes.withUnsafeBufferPointer {
                    send(fd, $0.baseAddress! + written, bytes.count - written, Int32(MSG_NOSIGNAL))
                }
                guard sent > 0 else { throw ClientError(description: "send: \(errno)") }
                written += sent
            }
            return written
        }

        /// Everything readable until EOF or the receive timeout.
        func readAvailable() -> String {
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let read = recv(fd, &chunk, chunk.count, 0)
                if read <= 0 { break }
                data.append(contentsOf: chunk[0..<read])
            }
            return String(decoding: data, as: UTF8.self)
        }

        /// One request, one response, leaving the connection open.
        func roundTrip(_ request: String) throws -> Response {
            try write(request)
            var raw = ""
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                if let response = RawHTTP.parse(raw) { return response }
                let read = recv(fd, &chunk, chunk.count, 0)
                if read <= 0 { break }
                raw += String(decoding: chunk[0..<read], as: UTF8.self)
            }
            guard let response = RawHTTP.parse(raw) else {
                throw ClientError(description: "no complete response in \(raw.count) bytes")
            }
            return response
        }
    }

    static func roundTrip(port: Int, host: String = "127.0.0.1", request: String) throws -> Response {
        let connection = try Connection(port: port, host: host)
        defer { connection.disconnect() }
        return try connection.roundTrip(request)
    }

    /// Parses a response if `raw` holds a complete one, else nil.
    static func parse(_ raw: String) -> Response? {
        guard let separator = raw.range(of: "\r\n\r\n") else { return nil }
        let head = String(raw[raw.startIndex..<separator.lowerBound])
        var lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else { return nil }
        lines.removeFirst()

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).lowercased()
            headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        let bodyStart = separator.upperBound
        let available = String(raw[bodyStart...])
        guard let length = headers["content-length"].flatMap(Int.init) else {
            return Response(status: status, headers: headers, body: available)
        }
        guard available.utf8.count >= length else { return nil }
        return Response(status: status, headers: headers, body: String(available.prefix(length)))
    }
}
