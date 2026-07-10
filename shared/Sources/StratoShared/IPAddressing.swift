import Foundation

// Shared IP address values used by the control plane (IPAM, validation), the
// agent (OVN programming, guest provisioning), and the wire DTOs. Foundation
// has no portable address types, so these are ours. IPv6 strings MUST be
// canonicalized (RFC 5952) at every write boundary: the database enforces
// address uniqueness by string comparison, so "fd00::1" and "FD00:0:0::1"
// must never both reach storage.

/// Address family discriminator, stored alongside addresses in the database
/// and used to split mixed lists (e.g. DNS servers) when programming
/// family-specific config.
public enum IPFamily: String, Codable, Sendable {
    case ipv4
    case ipv6
}

// MARK: - IPv4

/// Minimal IPv4 address value for subnet math.
public struct IPv4Address: CustomStringConvertible, Equatable, Hashable, Sendable {
    public let raw: UInt32

    public init(raw: UInt32) {
        self.raw = raw
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = (value << 8) | UInt32(octet)
        }
        self.raw = value
    }

    /// The prefix length when this address is a contiguous netmask
    /// (e.g. 255.255.255.0 → 24); nil for non-contiguous masks.
    public var prefixLength: Int? {
        let ones = raw.nonzeroBitCount
        // A valid mask is `ones` set bits followed only by zeros.
        guard raw == (ones == 0 ? 0 : ~UInt32(0) << (32 - ones)) else { return nil }
        return ones
    }

    public var description: String {
        "\((raw >> 24) & 0xff).\((raw >> 16) & 0xff).\((raw >> 8) & 0xff).\(raw & 0xff)"
    }
}

/// An IPv4 network in CIDR notation. `base` is the address as written (not
/// masked); use `networkAddress` for the masked form.
public struct IPv4CIDR: Equatable, Sendable {
    public let base: IPv4Address
    public let prefix: Int

    public init(base: IPv4Address, prefix: Int) {
        self.base = base
        self.prefix = prefix
    }

    public init?(_ string: String) {
        let parts = string.split(separator: "/")
        guard parts.count == 2,
            let base = IPv4Address(String(parts[0])),
            let prefix = Int(parts[1]),
            (0...32).contains(prefix)
        else {
            return nil
        }
        self.base = base
        self.prefix = prefix
    }

    public var mask: UInt32 {
        prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
    }

    public var networkAddress: IPv4Address {
        IPv4Address(raw: base.raw & mask)
    }

    public func contains(_ address: IPv4Address) -> Bool {
        (address.raw & mask) == (base.raw & mask)
    }

    public func overlaps(_ other: IPv4CIDR) -> Bool {
        let narrow = Swift.min(prefix, other.prefix)
        let sharedMask: UInt32 = narrow == 0 ? 0 : ~UInt32(0) << (32 - narrow)
        return (base.raw & sharedMask) == (other.base.raw & sharedMask)
    }

    /// The first host address (conventionally the gateway).
    public var firstHost: IPv4Address {
        IPv4Address(raw: networkAddress.raw + 1)
    }
}

// MARK: - IPv6

/// IPv6 address value backed by two 64-bit halves (network-order: `hi` holds
/// the first 8 bytes). Parses full and `::`-compressed textual forms
/// (including embedded dotted-quad tails like `::ffff:192.0.2.1`); rejects
/// zone IDs. `description` is the RFC 5952 canonical form — lowercase hex,
/// no leading zeros, longest zero run compressed.
public struct IPv6Address: CustomStringConvertible, Equatable, Hashable, Sendable {
    public let hi: UInt64
    public let lo: UInt64

    public init(hi: UInt64, lo: UInt64) {
        self.hi = hi
        self.lo = lo
    }

    public init?(_ string: String) {
        // Zone IDs (fe80::1%eth0) are host-scoped and never valid in our data.
        guard !string.contains("%") else { return nil }

        let halves = string.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }

        func groups(of part: String) -> [UInt16]? {
            guard !part.isEmpty else { return [] }
            var result: [UInt16] = []
            let pieces = part.split(separator: ":", omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                if piece.contains(".") {
                    // Embedded IPv4 tail — only valid as the final piece.
                    guard index == pieces.count - 1, let v4 = IPv4Address(String(piece)) else { return nil }
                    result.append(UInt16(v4.raw >> 16))
                    result.append(UInt16(v4.raw & 0xffff))
                } else {
                    guard piece.count >= 1, piece.count <= 4, let value = UInt16(piece, radix: 16) else {
                        return nil
                    }
                    result.append(value)
                }
            }
            return result
        }

        var words: [UInt16]
        if halves.count == 2 {
            guard let head = groups(of: halves[0]), let tail = groups(of: halves[1]),
                head.count + tail.count <= 7
            else { return nil }
            words = head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
        } else {
            guard let all = groups(of: halves[0]), all.count == 8 else { return nil }
            words = all
        }

        var hi: UInt64 = 0
        var lo: UInt64 = 0
        for word in words[0..<4] { hi = (hi << 16) | UInt64(word) }
        for word in words[4..<8] { lo = (lo << 16) | UInt64(word) }
        self.hi = hi
        self.lo = lo
    }

    /// RFC 5952 canonical text form.
    public var description: String {
        var words: [UInt16] = []
        for shift in stride(from: 48, through: 0, by: -16) { words.append(UInt16((hi >> UInt64(shift)) & 0xffff)) }
        for shift in stride(from: 48, through: 0, by: -16) { words.append(UInt16((lo >> UInt64(shift)) & 0xffff)) }

        // Longest run of zero words, leftmost wins ties; runs of one are not
        // compressed (RFC 5952 §4.2.2).
        var bestStart = -1
        var bestLength = 0
        var runStart = -1
        var runLength = 0
        for (index, word) in words.enumerated() {
            if word == 0 {
                if runStart < 0 { runStart = index }
                runLength += 1
                if runLength > bestLength {
                    bestStart = runStart
                    bestLength = runLength
                }
            } else {
                runStart = -1
                runLength = 0
            }
        }

        if bestLength >= 2 {
            let head = words[0..<bestStart].map { String($0, radix: 16) }.joined(separator: ":")
            let tail = words[(bestStart + bestLength)...].map { String($0, radix: 16) }.joined(separator: ":")
            return "\(head)::\(tail)"
        }
        return words.map { String($0, radix: 16) }.joined(separator: ":")
    }

    public var isUnspecified: Bool { hi == 0 && lo == 0 }
    public var isLoopback: Bool { hi == 0 && lo == 1 }
    /// ff00::/8
    public var isMulticast: Bool { (hi >> 56) == 0xff }
    /// fe80::/10
    public var isLinkLocal: Bool { (hi >> 54) == 0x3fa }
    /// fc00::/7 — unique local addresses (RFC 4193).
    public var isUniqueLocal: Bool { (hi >> 57) == 0x7e }

    /// The address with all bits beyond `prefix` cleared.
    public func masked(prefix: Int) -> IPv6Address {
        guard (0...128).contains(prefix) else { return self }
        if prefix >= 128 { return self }
        if prefix == 0 { return IPv6Address(hi: 0, lo: 0) }
        if prefix <= 64 {
            let mask: UInt64 = prefix == 0 ? 0 : ~UInt64(0) << (64 - prefix)
            return IPv6Address(hi: hi & mask, lo: 0)
        }
        let mask: UInt64 = ~UInt64(0) << (128 - prefix)
        return IPv6Address(hi: hi, lo: lo & mask)
    }

    /// The address with its low 64 bits (the /64 interface ID) replaced.
    public func replacingInterfaceID(_ interfaceID: UInt64) -> IPv6Address {
        IPv6Address(hi: hi, lo: interfaceID)
    }

    /// The canonical form of `string`, or nil if it isn't a valid IPv6
    /// address. Call at every boundary that writes an address to storage.
    public static func canonicalize(_ string: String) -> String? {
        IPv6Address(string)?.description
    }

    /// The modified-EUI-64 link-local address a guest derives from its MAC
    /// (flip the universal/local bit, insert ff:fe). Needed in OVN
    /// port_security so the guest's NDP and DHCPv6-client traffic — sourced
    /// from the link-local address — is not dropped.
    public static func linkLocalEUI64(fromMAC mac: String) -> IPv6Address? {
        let parts = mac.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard part.count == 2, let byte = UInt8(part, radix: 16) else { return nil }
            bytes.append(byte)
        }
        var lo: UInt64 = 0
        let eui: [UInt8] = [bytes[0] ^ 0x02, bytes[1], bytes[2], 0xff, 0xfe, bytes[3], bytes[4], bytes[5]]
        for byte in eui { lo = (lo << 8) | UInt64(byte) }
        return IPv6Address(hi: 0xfe80_0000_0000_0000, lo: lo)
    }

    /// A fresh RFC 4193 unique-local /64: `fd` + random 40-bit global ID
    /// (subnet ID 0). Randomness is the point — it keeps prefixes
    /// collision-resistant if networks are ever peered — so a fixed prefix
    /// must never replace this. `randomGlobalID` is injectable for tests.
    public static func makeULASubnet64(randomGlobalID: (() -> UInt64)? = nil) -> IPv6CIDR {
        let globalID = (randomGlobalID?() ?? UInt64.random(in: 0...UInt64.max)) & 0xff_ffff_ffff
        let hi: UInt64 = (0xfd << 56) | (globalID << 16)
        return IPv6CIDR(base: IPv6Address(hi: hi, lo: 0), prefix: 64)
    }
}

/// An IPv6 network in CIDR notation. `base` is the address as written (not
/// masked); use `networkAddress` for the masked form. `description` is
/// canonical (RFC 5952 address + prefix).
public struct IPv6CIDR: CustomStringConvertible, Equatable, Sendable {
    public let base: IPv6Address
    public let prefix: Int

    public init(base: IPv6Address, prefix: Int) {
        self.base = base
        self.prefix = prefix
    }

    public init?(_ string: String) {
        let parts = string.split(separator: "/")
        guard parts.count == 2,
            let base = IPv6Address(String(parts[0])),
            let prefix = Int(parts[1]),
            (0...128).contains(prefix)
        else {
            return nil
        }
        self.base = base
        self.prefix = prefix
    }

    public var networkAddress: IPv6Address {
        base.masked(prefix: prefix)
    }

    public var description: String {
        "\(networkAddress)/\(prefix)"
    }

    public func contains(_ address: IPv6Address) -> Bool {
        address.masked(prefix: prefix) == base.masked(prefix: prefix)
    }

    public func overlaps(_ other: IPv6CIDR) -> Bool {
        let narrow = Swift.min(prefix, other.prefix)
        return base.masked(prefix: narrow) == other.base.masked(prefix: narrow)
    }

    /// The first host address (conventionally the gateway), e.g.
    /// fd12:3456:789a::/64 → fd12:3456:789a::1. Meaningful for the /64
    /// tenant prefixes we allocate from; not defined for prefix 128.
    public var firstHost: IPv6Address {
        IPv6Address(hi: networkAddress.hi, lo: networkAddress.lo | 1)
    }
}
