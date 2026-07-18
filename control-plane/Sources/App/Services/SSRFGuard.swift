import Foundation
import NIOPosix
import Vapor

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Guards server-side URL fetches (image / artifact downloads) against SSRF.
///
/// A `sourceURL` is attacker-controlled, and the control plane fetches it
/// itself, so without this an image import could point at the cloud metadata
/// endpoint (`169.254.169.254`), a loopback admin port, or any host reachable
/// only from inside the control plane's network. `validate(url:)` resolves the
/// host and rejects it unless every address it resolves to is a routable
/// public address.
///
/// The check runs at two points: in the controller for a fast, well-formed 400
/// before any DB rows are created, and again in `ImageFetchService` on the URL
/// actually about to be fetched, which also covers redirect targets.
///
/// KNOWN GAP: the fetch re-resolves the host when it connects, so a low-TTL
/// record can rebind the name to an internal address between this check and
/// the connect. `validate` returns the addresses it approved so a future
/// change can pin the connection to them (AsyncHTTPClient's `dnsOverride`);
/// no caller does that yet.
enum SSRFGuard {
    /// Blocked because the resolved address is not a public, routable host.
    struct BlockedHostError: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    /// Whether fetches to private / loopback / link-local hosts are permitted.
    ///
    /// Off by default (production). The redirect tests fetch from `127.0.0.1`
    /// and local dev mirrors are commonly private, so `.testing`/`.development`
    /// allow them, as does an explicit `IMAGE_FETCH_ALLOW_PRIVATE_HOSTS=true`
    /// opt-out for operators who run an internal mirror on purpose.
    static func allowsPrivateHosts(for environment: Environment) -> Bool {
        if let override = Environment.get("IMAGE_FETCH_ALLOW_PRIVATE_HOSTS").flatMap(Bool.init) {
            return override
        }
        return environment == .testing || environment == .development
    }

    /// Validates that `url` is safe to fetch server-side, returning the IP
    /// literals that passed validation (empty when private hosts are allowed).
    ///
    /// Requires an http/https URL with a host, and — unless private hosts are
    /// allowed for this environment — that every address the host resolves to
    /// is a routable public address. Throws `BlockedHostError` otherwise.
    ///
    /// Resolution runs on `threadPool` because `getaddrinfo` is a blocking
    /// syscall: called inline it would park a NIO event-loop thread (or a
    /// cooperative-pool thread from an actor) for the length of the lookup, and
    /// the host being resolved is attacker-supplied — a deliberately stalling
    /// authoritative nameserver would otherwise be a cheap way to starve the
    /// server's threads.
    @discardableResult
    static func validate(url: URL, environment: Environment, on threadPool: NIOThreadPool) async throws -> [String] {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw BlockedHostError(reason: "Source URL must use http or https")
        }
        guard let host = url.host, !host.isEmpty else {
            throw BlockedHostError(reason: "Source URL is missing a host")
        }

        if allowsPrivateHosts(for: environment) {
            return []
        }

        // Resolve AND classify inside the pool: `ResolvedAddress` wraps C
        // sockaddr types, so the boundary only carries the resulting strings.
        return try await threadPool.runIfActive {
            let addresses = try resolve(host: host)
            guard !addresses.isEmpty else {
                throw BlockedHostError(reason: "Could not resolve host '\(host)'")
            }
            for address in addresses where !address.isPubliclyRoutable {
                throw BlockedHostError(
                    reason: "Refusing to fetch from non-public address (\(address.description)) for host '\(host)'")
            }
            return addresses.map { $0.description }
        }
    }

    /// Resolves `host` to its IP addresses. A bare IP literal resolves to
    /// itself; a name is resolved via the system resolver so that the addresses
    /// classified are the ones the HTTP client will actually connect to.
    private static func resolve(host: String) throws -> [ResolvedAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        // `SOCK_STREAM` imports as `Int32` on Darwin but as the `__socket_type`
        // C enum on Glibc, while `ai_socktype` is `Int32` on both.
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let head = result else {
            throw BlockedHostError(reason: "Could not resolve host '\(host)'")
        }
        defer { freeaddrinfo(head) }

        var addresses: [ResolvedAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let node = cursor {
            if let sockaddr = node.pointee.ai_addr {
                if node.pointee.ai_family == AF_INET {
                    sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ptr in
                        addresses.append(.v4(ptr.pointee.sin_addr))
                    }
                } else if node.pointee.ai_family == AF_INET6 {
                    sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { ptr in
                        addresses.append(.v6(ptr.pointee.sin6_addr))
                    }
                }
            }
            cursor = node.pointee.ai_next
        }
        return addresses
    }

    /// A resolved IP address with the classification `validate` needs.
    private enum ResolvedAddress {
        case v4(in_addr)
        case v6(in6_addr)

        var description: String {
            switch self {
            case .v4(let addr):
                var mutable = addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                return inet_ntop(AF_INET, &mutable, &buffer, socklen_t(INET_ADDRSTRLEN))
                    .map { String(cString: $0) } ?? ""
            case .v6(let addr):
                var mutable = addr
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                return inet_ntop(AF_INET6, &mutable, &buffer, socklen_t(INET6_ADDRSTRLEN))
                    .map { String(cString: $0) } ?? ""
            }
        }

        /// True only for globally routable unicast addresses. Anything private,
        /// loopback, link-local (incl. `169.254.169.254`), CGNAT, multicast, or
        /// otherwise special-use is rejected.
        var isPubliclyRoutable: Bool {
            switch self {
            case .v4(let addr):
                // `s_addr` is in network byte order; read the octets directly.
                let raw = withUnsafeBytes(of: addr.s_addr) { Array($0) }
                return Self.isPublicIPv4(raw)
            case .v6(let addr):
                let raw = withUnsafeBytes(of: addr) { Array($0) }
                return Self.isPublicIPv6(raw)
            }
        }

        private static func isPublicIPv4(_ b: [UInt8]) -> Bool {
            guard b.count == 4 else { return false }
            switch b[0] {
            case 0: return false  // 0.0.0.0/8 "this network"
            case 10: return false  // 10.0.0.0/8 private
            case 127: return false  // 127.0.0.0/8 loopback
            case 169 where b[1] == 254: return false  // 169.254.0.0/16 link-local (metadata)
            case 172 where (16...31).contains(b[1]): return false  // 172.16.0.0/12 private
            case 192 where b[1] == 168: return false  // 192.168.0.0/16 private
            case 192 where b[1] == 0 && b[2] == 0: return false  // 192.0.0.0/24 IETF
            case 100 where (64...127).contains(b[1]): return false  // 100.64.0.0/10 CGNAT
            case 198 where (18...19).contains(b[1]): return false  // 198.18.0.0/15 benchmarking
            case 198 where b[1] == 51 && b[2] == 100: return false  // 198.51.100.0/24 TEST-NET-2
            case 203 where b[1] == 0 && b[2] == 113: return false  // 203.0.113.0/24 TEST-NET-3
            case 192 where b[1] == 0 && b[2] == 2: return false  // 192.0.2.0/24 TEST-NET-1
            case 224...255: return false  // multicast + reserved/broadcast
            default: return true
            }
        }

        private static func isPublicIPv6(_ b: [UInt8]) -> Bool {
            guard b.count == 16 else { return false }
            // ::/128 unspecified and ::1/128 loopback.
            if b[0...14].allSatisfy({ $0 == 0 }) && (b[15] == 0 || b[15] == 1) {
                return false
            }
            // fe80::/10 link-local, fec0::/10 site-local (deprecated).
            if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return false }
            if b[0] == 0xFE && (b[1] & 0xC0) == 0xC0 { return false }
            // fc00::/7 unique local.
            if (b[0] & 0xFE) == 0xFC { return false }
            // ff00::/8 multicast.
            if b[0] == 0xFF { return false }
            // IPv4-mapped (::ffff:0:0/96) and IPv4-compatible: classify by the
            // embedded v4 address rather than trusting the wrapper.
            if b[0...9].allSatisfy({ $0 == 0 }) {
                if b[10] == 0xFF && b[11] == 0xFF {
                    return isPublicIPv4(Array(b[12...15]))
                }
                if !(b[12...15].allSatisfy({ $0 == 0 })) {
                    return isPublicIPv4(Array(b[12...15]))
                }
            }
            return true
        }
    }
}
