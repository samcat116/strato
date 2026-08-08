import Foundation
import Libvirt
import StratoShared
import Testing

@testable import StratoAgentCore

/// Guest observation read from libvirtd rather than from the VM's `qga.sock`
/// (STR-134, issue #563).
///
/// The source is the same guest agent over the same channel, so the assertions
/// that matter are about *not changing what the control plane is told*: a
/// hostname it can match a DNS zone against, and interfaces keyed by a
/// lowercased MAC it can match `VMNetworkInterface` rows against. A MAC that
/// arrives uppercased, or an address filed under the wrong family, is invisible
/// until an operator wonders why a VM shows no IP.
@Suite("libvirt guest info")
struct LibvirtGuestInfoTests {

    static func hostname(_ value: String) -> [TypedParam] {
        [TypedParam(field: "hostname", value: .string(value))]
    }

    static let interfaces = [
        DomainInterface(
            name: "lo", hwaddr: "00:00:00:00:00:00",
            addrs: [
                DomainIPAddr(type: 0, addr: "127.0.0.1", prefix: 8),
                DomainIPAddr(type: 1, addr: "::1", prefix: 128),
            ]),
        DomainInterface(
            name: "enp1s0", hwaddr: "52:54:00:AB:CD:EF",
            addrs: [
                DomainIPAddr(type: 0, addr: "10.0.0.42", prefix: 24),
                DomainIPAddr(type: 1, addr: "fe80::5054:ff:feab:cdef", prefix: 64),
            ]),
    ]

    @Test("both queries answering reports the whole guest")
    func fullReport() throws {
        let info = try #require(
            LibvirtGuestInfo.parse(
                hostnameParams: Self.hostname("web-01"), interfaces: Self.interfaces))

        #expect(info.qgaAvailable)
        #expect(info.hostname == "web-01")
        #expect(info.interfaces.map(\.name) == ["lo", "enp1s0"])
        // Lowercased, because it is the join key the control plane matches a
        // `VMNetworkInterface` MAC against.
        #expect(info.interfaces[1].hardwareAddress == "52:54:00:ab:cd:ef")
        #expect(info.interfaces[1].addresses.map(\.family) == [.ipv4, .ipv6])
        #expect(info.interfaces[1].addresses[0].address == "10.0.0.42")
        #expect(info.interfaces[1].addresses[0].prefixLength == 24)
        #expect(info.interfaces[1].addresses[1].address == "fe80::5054:ff:feab:cdef")
    }

    /// The two calls fail separately, and either answering is a positive
    /// liveness signal worth reporting — which is what `qgaAvailable` is for.
    @Test("one query answering is still a report")
    func partialReport() throws {
        let noInterfaces = try #require(
            LibvirtGuestInfo.parse(hostnameParams: Self.hostname("web-01"), interfaces: nil))
        #expect(noInterfaces.qgaAvailable)
        #expect(noInterfaces.hostname == "web-01")
        #expect(noInterfaces.interfaces.isEmpty)

        let noHostname = try #require(
            LibvirtGuestInfo.parse(hostnameParams: nil, interfaces: Self.interfaces))
        #expect(noHostname.qgaAvailable)
        #expect(noHostname.hostname == nil)
        #expect(noHostname.interfaces.count == 2)
    }

    /// A guest with no agent installed, or one still booting: a normal outcome
    /// that nothing converges on, never an error.
    @Test("neither query answering is no report at all")
    func noReport() {
        #expect(LibvirtGuestInfo.parse(hostnameParams: nil, interfaces: nil) == nil)
    }

    /// An empty hostname is a guest that has not told us its hostname, and the
    /// value would otherwise reach the VM's DNS zone as a blank label.
    @Test("an empty or missing hostname is dropped")
    func emptyHostname() throws {
        #expect(
            try #require(LibvirtGuestInfo.parse(hostnameParams: Self.hostname(""), interfaces: nil))
                .hostname == nil)
        #expect(
            try #require(LibvirtGuestInfo.parse(hostnameParams: [], interfaces: nil)).hostname == nil)
        // A parameter of the wrong shape is ignored rather than stringified.
        #expect(
            try #require(
                LibvirtGuestInfo.parse(
                    hostnameParams: [TypedParam(field: "hostname", value: .uint(7))],
                    interfaces: nil)
            ).hostname == nil)
    }

    /// `virIPAddrType` is append-only upstream, and reporting an address under
    /// the wrong family would have the control plane match it against the wrong
    /// `VMNetworkInterface`.
    @Test("an address family this build cannot read is dropped, not guessed")
    func unknownAddressFamily() throws {
        let iface = DomainInterface(
            name: "eth0", hwaddr: nil,
            addrs: [
                DomainIPAddr(type: 99, addr: "something", prefix: 0),
                DomainIPAddr(type: 0, addr: "10.0.0.7", prefix: 24),
                DomainIPAddr(type: 0, addr: "  ", prefix: 24),
            ])
        let info = try #require(LibvirtGuestInfo.parse(hostnameParams: nil, interfaces: [iface]))

        #expect(info.interfaces[0].addresses.map(\.address) == ["10.0.0.7"])
        // Some guests report loopback with no hardware address at all.
        #expect(info.interfaces[0].hardwareAddress == nil)
    }

    /// A prefix that cannot be one is reported as absent rather than passed
    /// through as a number the control plane would render into a CIDR.
    @Test("an impossible prefix length is absent")
    func impossiblePrefix() throws {
        let iface = DomainInterface(
            name: "eth0", hwaddr: nil, addrs: [DomainIPAddr(type: 1, addr: "2001:db8::1", prefix: 4096)])
        let info = try #require(LibvirtGuestInfo.parse(hostnameParams: nil, interfaces: [iface]))
        #expect(info.interfaces[0].addresses[0].prefixLength == nil)
    }
}
