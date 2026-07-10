import Foundation
import Testing

@testable import StratoShared

@Suite struct IPv6AddressTests {
    @Test func parsesAndCanonicalizesCompressedForms() {
        let cases: [(input: String, canonical: String)] = [
            ("::", "::"),
            ("::1", "::1"),
            ("0:0:0:0:0:0:0:1", "::1"),
            ("fd00::1", "fd00::1"),
            ("FD00:0000:0000:0000:0000:0000:0000:0001", "fd00::1"),
            ("2001:0db8::0001", "2001:db8::1"),
            ("2001:db8:0:0:1:0:0:1", "2001:db8::1:0:0:1"),  // leftmost longest run wins
            ("1:2:3:4:5:6:7:8", "1:2:3:4:5:6:7:8"),
            ("fe80::0204:61ff:fe9d:f156", "fe80::204:61ff:fe9d:f156"),
            ("::ffff:192.0.2.1", "::ffff:c000:201"),
            ("2001:db8::0:1", "2001:db8::1"),
            ("1:0:0:2:0:0:0:3", "1:0:0:2::3"),  // second run is longer
        ]
        for (input, canonical) in cases {
            let parsed = IPv6Address(input)
            #expect(parsed != nil, "'\(input)' should parse")
            #expect(parsed?.description == canonical, "'\(input)' → '\(parsed?.description ?? "nil")', wanted '\(canonical)'")
            // Canonical forms are fixed points.
            let reparsed = parsed.flatMap { IPv6Address($0.description) }
            #expect(reparsed == parsed)
        }
    }

    @Test func rejectsInvalidForms() {
        let invalid = [
            "", ":", ":::", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "12345::",
            "g::1", "fe80::1%eth0", "1.2.3.4", "::1.2.3.4.5", "1::2::3",
            "192.0.2.1:8080", "fd00:x::1",
        ]
        for string in invalid {
            #expect(IPv6Address(string) == nil, "'\(string)' should not parse")
        }
    }

    @Test func classifiesAddressKinds() {
        #expect(IPv6Address("::")?.isUnspecified == true)
        #expect(IPv6Address("::1")?.isLoopback == true)
        #expect(IPv6Address("ff02::1")?.isMulticast == true)
        #expect(IPv6Address("fe80::1")?.isLinkLocal == true)
        #expect(IPv6Address("febf::1")?.isLinkLocal == true)
        #expect(IPv6Address("fec0::1")?.isLinkLocal == false)
        #expect(IPv6Address("fd12:3456:789a::1")?.isUniqueLocal == true)
        #expect(IPv6Address("fc00::1")?.isUniqueLocal == true)
        #expect(IPv6Address("2001:db8::1")?.isUniqueLocal == false)
        #expect(IPv6Address("2001:db8::1")?.isMulticast == false)
    }

    @Test func maskingClearsHostBits() {
        let address = IPv6Address("fd12:3456:789a:1:2:3:4:5")!
        #expect(address.masked(prefix: 64).description == "fd12:3456:789a:1::")
        #expect(address.masked(prefix: 48).description == "fd12:3456:789a::")
        #expect(address.masked(prefix: 0).description == "::")
        #expect(address.masked(prefix: 128) == address)
        #expect(address.masked(prefix: 112).description == "fd12:3456:789a:1:2:3:4:0")
    }

    @Test func linkLocalEUI64MatchesKnownVectors() {
        // 00:0c:29:ab:cd:ef → flip U/L bit of first octet, insert ff:fe.
        #expect(
            IPv6Address.linkLocalEUI64(fromMAC: "00:0c:29:ab:cd:ef")?.description
                == "fe80::20c:29ff:feab:cdef")
        #expect(
            IPv6Address.linkLocalEUI64(fromMAC: "52:54:00:12:34:56")?.description
                == "fe80::5054:ff:fe12:3456")
        #expect(IPv6Address.linkLocalEUI64(fromMAC: "not-a-mac") == nil)
        #expect(IPv6Address.linkLocalEUI64(fromMAC: "00:0c:29:ab:cd") == nil)
    }

    @Test func generatedULAIsWellFormed() {
        // Deterministic global ID: only the low 40 bits may be used.
        let cidr = IPv6Address.makeULASubnet64(randomGlobalID: { 0xffff_ff12_3456_789a })
        #expect(cidr.description == "fd12:3456:789a::/64")
        #expect(cidr.prefix == 64)
        #expect(cidr.base.isUniqueLocal)

        let random = IPv6Address.makeULASubnet64()
        #expect(random.base.isUniqueLocal)
        #expect((random.base.hi >> 56) == 0xfd)
        #expect(random.base.hi & 0xffff == 0, "subnet ID must be zero")
        #expect(random.base.lo == 0)
    }

    @Test func replacingInterfaceIDKeepsPrefix() {
        let base = IPv6Address("fd12:3456:789a::")!
        #expect(base.replacingInterfaceID(0x100).description == "fd12:3456:789a::100")
        #expect(base.replacingInterfaceID(0x1ff).description == "fd12:3456:789a::1ff")
    }
}

@Suite struct IPv6CIDRTests {
    @Test func parsesAndCanonicalizes() {
        let cidr = IPv6CIDR("FD12:3456:789A:0000::1/64")
        #expect(cidr != nil)
        #expect(cidr?.description == "fd12:3456:789a::/64")
        #expect(cidr?.prefix == 64)

        #expect(IPv6CIDR("fd00::/129") == nil)
        #expect(IPv6CIDR("fd00::") == nil)
        #expect(IPv6CIDR("fd00::/-1") == nil)
        #expect(IPv6CIDR("10.0.0.0/24") == nil)
    }

    @Test func containsAndFirstHost() {
        let cidr = IPv6CIDR("fd12:3456:789a::/64")!
        #expect(cidr.contains(IPv6Address("fd12:3456:789a::100")!))
        #expect(!cidr.contains(IPv6Address("fd12:3456:789b::100")!))
        #expect(cidr.firstHost.description == "fd12:3456:789a::1")
    }

    @Test func overlapIsSymmetricAndPrefixAware() {
        let a = IPv6CIDR("fd12:3456:789a::/64")!
        let b = IPv6CIDR("fd12:3456:789a:0:1234::/80")!
        let c = IPv6CIDR("fd12:3456:789b::/64")!
        #expect(a.overlaps(b) && b.overlaps(a))
        #expect(!a.overlaps(c) && !c.overlaps(a))
        #expect(a.overlaps(IPv6CIDR("::/0")!))
    }
}

@Suite struct IPv4CIDRTests {
    @Test func parseAndOverlap() {
        let a = IPv4CIDR("10.0.0.0/24")!
        let b = IPv4CIDR("10.0.0.128/25")!
        let c = IPv4CIDR("10.0.1.0/24")!
        #expect(a.overlaps(b) && b.overlaps(a))
        #expect(!a.overlaps(c))
        #expect(a.contains(IPv4Address("10.0.0.7")!))
        #expect(!a.contains(IPv4Address("10.0.1.7")!))
        #expect(a.firstHost.description == "10.0.0.1")
        #expect(IPv4CIDR("10.0.0.0/33") == nil)
        #expect(IPv4CIDR("10.0.0.0") == nil)
        #expect(IPv4CIDR("fd00::/64") == nil)
    }
}
