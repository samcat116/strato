import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

/// The zone-file renderer is where a record edit becomes a document CoreDNS
/// parses as a whole. That is the reason for the density here: one malformed
/// line does not cost a record, it costs every name in the zone — and, because
/// the Corefile references a file that will not parse, potentially the
/// resolver's ability to start at all.
@Suite("CoreDNS Zone Renderer")
struct CoreDNSZoneRendererTests {

    private let zoneId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let networkId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func zone(
        name: String = "corp.example.com",
        records: [DesiredDNSRecord],
        hash: String = "abc123"
    ) -> DesiredDNSZone {
        DesiredDNSZone(
            zoneId: zoneId, zoneName: name, networkIds: [networkId], records: records,
            recordsHash: hash)
    }

    private func file(_ rendering: CoreDNSZoneRenderer.Rendering, _ path: String) -> String? {
        rendering.files.first { $0.relativePath == path }?.contents
    }

    /// The path a zone lands at for the single network these tests render.
    private func zonePath(_ origin: String) -> String {
        CoreDNSZoneRenderer.zoneFilePath(networkId: networkId, origin: origin)
    }

    /// One network's worth of inputs, which is what most of these assert on.
    private func render(
        zones: [DesiredDNSZone], upstreams: [String] = [], searchDomain: String? = nil,
        bindAddresses: [String] = ["169.254.1.0", "fd00:ec2:1::100"]
    ) -> CoreDNSZoneRenderer.Rendering {
        CoreDNSZoneRenderer.render(networks: [
            CoreDNSZoneRenderer.Network(
                networkId: networkId, bindAddresses: bindAddresses, zones: zones,
                upstreams: upstreams, searchDomain: searchDomain)
        ])
    }

    // MARK: - Forward zones

    @Test("A forward zone gets an SOA, an NS, and its records")
    func forwardZoneShape() throws {
        let rendering = render(
            zones: [
                zone(records: [
                    DesiredDNSRecord(
                        name: "web.corp.example.com", type: "A", values: ["10.0.0.5"], ttl: 60)
                ])
            ],
            upstreams: ["1.1.1.1"], searchDomain: nil)

        let body = try #require(file(rendering, zonePath("corp.example.com")))
        #expect(body.contains("$ORIGIN corp.example.com."))
        // CoreDNS's `file` plugin refuses a zone without an SOA outright.
        #expect(body.contains("IN\tSOA"))
        #expect(body.contains("IN\tNS"))
        #expect(body.contains("web.corp.example.com.\t60\tIN\tA\t10.0.0.5"))
    }

    @Test("The nameserver is outside every zone, so it cannot collide with a tenant record")
    func nameserverIsOutOfZone() throws {
        // An in-zone `ns.<zone>` would need glue and — the reason this matters —
        // would collide with a VM whose hostname is `ns`. An authored CNAME at
        // that name would then put a CNAME beside other data and make CoreDNS
        // refuse the entire zone.
        let rendering = render(
            zones: [
                zone(records: [
                    DesiredDNSRecord(name: "ns.corp.example.com", type: "A", values: ["10.0.0.9"])
                ])
            ],
            upstreams: [], searchDomain: nil)
        let body = try #require(file(rendering, zonePath("corp.example.com")))
        #expect(body.contains("ns.strato.invalid."))
        #expect(body.contains("hostmaster.strato.invalid."))
        // The tenant's own `ns` record is untouched and is the only A at that name.
        #expect(body.contains("ns.corp.example.com.\t300\tIN\tA\t10.0.0.9"))
    }

    @Test("A record with no TTL renders at the zone default")
    func missingTTLFallsBack() throws {
        // A pre-v37 control plane sends no TTL; the record still has to render.
        let rendering = render(
            zones: [zone(records: [DesiredDNSRecord(name: "a.corp.example.com", type: "A", values: ["10.0.0.1"])])],
            upstreams: [], searchDomain: nil)
        let body = try #require(file(rendering, zonePath("corp.example.com")))
        #expect(body.contains("a.corp.example.com.\t\(CoreDNSZoneRenderer.defaultTTL)\tIN\tA\t10.0.0.1"))
    }

    @Test("The full record vocabulary is realized — this is what phase 4 is for")
    func fullVocabulary() throws {
        let rendering = render(
            zones: [
                zone(records: [
                    DesiredDNSRecord(name: "a.corp.example.com", type: "A", values: ["10.0.0.1"]),
                    DesiredDNSRecord(name: "a.corp.example.com", type: "AAAA", values: ["fd00::1"]),
                    DesiredDNSRecord(name: "www.corp.example.com", type: "CNAME", values: ["a.corp.example.com"]),
                    DesiredDNSRecord(name: "corp.example.com", type: "TXT", values: ["v=spf1 -all"]),
                    DesiredDNSRecord(
                        name: "_sip._tcp.corp.example.com", type: "SRV", values: ["10 20 5060 a.corp.example.com"]),
                ])
            ],
            upstreams: [], searchDomain: nil)
        let body = try #require(file(rendering, zonePath("corp.example.com")))
        #expect(body.contains("IN\tA\t10.0.0.1"))
        #expect(body.contains("IN\tAAAA\tfd00::1"))
        #expect(body.contains("IN\tCNAME\ta.corp.example.com."))
        #expect(body.contains("IN\tTXT\t\"v=spf1 -all\""))
        #expect(body.contains("IN\tSRV\t10 20 5060 a.corp.example.com."))
        #expect(rendering.diagnostics.isEmpty)
    }

    @Test("A and AAAA stay separate lines, unlike the OVN driver's joined string")
    func familiesStaySeparate() throws {
        // The whole point of records travelling typed: each driver decides its
        // own shape from one assembled set.
        let rendering = render(
            zones: [
                zone(records: [
                    DesiredDNSRecord(name: "a.corp.example.com", type: "A", values: ["10.0.0.1"]),
                    DesiredDNSRecord(name: "a.corp.example.com", type: "AAAA", values: ["fd00::1"]),
                ])
            ],
            upstreams: [], searchDomain: nil)
        let body = try #require(file(rendering, zonePath("corp.example.com")))
        #expect(!body.contains("10.0.0.1 fd00::1"))
    }

    // MARK: - Reverse zones

    @Test("PTRs are pulled out of the forward file into a synthesized reverse zone")
    func reverseZoneIsSynthesized() throws {
        // A PTR for 10.0.0.5 is owned by 0.0.10.in-addr.arpa, never by the
        // forward zone the address's name lives in. Writing one into the forward
        // file would make CoreDNS refuse the zone as out of bailiwick.
        let rendering = render(
            zones: [
                zone(records: [
                    DesiredDNSRecord(name: "web.corp.example.com", type: "A", values: ["10.0.0.5"]),
                    DesiredDNSRecord(
                        name: "5.0.0.10.in-addr.arpa", type: "PTR", values: ["web.corp.example.com"]),
                ])
            ],
            upstreams: [], searchDomain: nil)

        let forward = try #require(file(rendering, zonePath("corp.example.com")))
        #expect(!forward.contains("in-addr.arpa"))

        let reverse = try #require(file(rendering, zonePath("0.0.10.in-addr.arpa")))
        #expect(reverse.contains("$ORIGIN 0.0.10.in-addr.arpa."))
        #expect(reverse.contains("5.0.0.10.in-addr.arpa.\t300\tIN\tPTR\tweb.corp.example.com."))
    }

    @Test("Reverse zones group at the /24 boundary")
    func reverseGroupsPerTwentyFour() {
        let rendering = render(
            zones: [
                zone(records: [
                    DesiredDNSRecord(name: "5.0.0.10.in-addr.arpa", type: "PTR", values: ["a.corp.example.com"]),
                    DesiredDNSRecord(name: "6.0.0.10.in-addr.arpa", type: "PTR", values: ["b.corp.example.com"]),
                    DesiredDNSRecord(name: "7.1.0.10.in-addr.arpa", type: "PTR", values: ["c.corp.example.com"]),
                ])
            ],
            upstreams: [], searchDomain: nil)
        let paths = Set(rendering.files.map(\.relativePath))
        #expect(paths.contains(zonePath("0.0.10.in-addr.arpa")))
        #expect(paths.contains(zonePath("1.0.10.in-addr.arpa")))
    }

    @Test("An IPv6 reverse zone groups at the /64 boundary")
    func reverseGroupsPerSixtyFour() throws {
        // 32 nibbles + ip6 + arpa; a /64 keeps the leading 16 nibbles.
        let name =
            "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0."
            + "0.0.0.0.0.0.0.0.0.0.d.f.0.0.0.0.ip6.arpa"
        let rendering = render(
            zones: [zone(records: [DesiredDNSRecord(name: name, type: "PTR", values: ["a.corp.example.com"])])],
            upstreams: [], searchDomain: nil)
        let origin = try #require(CoreDNSZoneRenderer.reverseOrigin(forPTRName: name))
        #expect(origin == "0.0.0.0.0.0.0.0.0.0.d.f.0.0.0.0.ip6.arpa")
        #expect(rendering.files.contains { $0.relativePath == zonePath(origin) })
    }

    @Test("PTRs from several forward zones merge into one reverse zone")
    func reverseZonesMergeAcrossForwardZones() throws {
        // This is what makes reverse space not a zone of its own: an authored
        // PTR in a hand-made zone and a derived one from a forward zone join the
        // same pool rather than contending for authority.
        let other = DesiredDNSZone(
            zoneId: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            zoneName: "0.0.10.in-addr.arpa", networkIds: [networkId],
            records: [
                DesiredDNSRecord(name: "9.0.0.10.in-addr.arpa", type: "PTR", values: ["hand.made.example"])
            ],
            recordsHash: "def456")
        let rendering = render(
            zones: [
                zone(records: [
                    DesiredDNSRecord(name: "5.0.0.10.in-addr.arpa", type: "PTR", values: ["web.corp.example.com"])
                ]),
                other,
            ],
            upstreams: [], searchDomain: nil)
        let reverse = try #require(file(rendering, zonePath("0.0.10.in-addr.arpa")))
        #expect(reverse.contains("5.0.0.10.in-addr.arpa."))
        #expect(reverse.contains("9.0.0.10.in-addr.arpa."))
    }

    @Test("A PTR that is not a reverse name is a diagnostic, not a broken zone")
    func nonReversePTRIsDiagnostic() {
        let rendering = render(
            zones: [
                zone(records: [DesiredDNSRecord(name: "web.corp.example.com", type: "PTR", values: ["a.example"])])
            ],
            upstreams: [], searchDomain: nil)
        #expect(rendering.diagnostics.contains { $0.contains("not a reverse name") })
    }

    @Test("A truncated reverse name does not trap")
    func shortReverseNameIsRejected() {
        // The arithmetic that drops the host labels would go negative on a name
        // shorter than the zone it implies.
        #expect(CoreDNSZoneRenderer.reverseOrigin(forPTRName: "10.in-addr.arpa") == nil)
        #expect(CoreDNSZoneRenderer.reverseOrigin(forPTRName: "0.10.in-addr.arpa") == nil)
        #expect(CoreDNSZoneRenderer.reverseOrigin(forPTRName: "0.0.10.in-addr.arpa") == nil)
        #expect(CoreDNSZoneRenderer.reverseOrigin(forPTRName: "a.b.ip6.arpa") == nil)
    }

    // MARK: - Defensive drops

    @Test("A CNAME beside other data is dropped, not the addresses")
    func cnameBesideDataIsDropped() throws {
        // RFC 1034 §3.6.2, and CoreDNS refuses to load a zone that violates it —
        // so the choice is which one to drop. The addresses win: they are what
        // the derived tier produced from real VMs, and the assembler has already
        // decided derived beats authored on a collision.
        let rendering = render(
            zones: [
                zone(records: [
                    DesiredDNSRecord(name: "web.corp.example.com", type: "A", values: ["10.0.0.5"]),
                    DesiredDNSRecord(name: "web.corp.example.com", type: "CNAME", values: ["other.example.com"]),
                ])
            ],
            upstreams: [], searchDomain: nil)
        let body = try #require(file(rendering, zonePath("corp.example.com")))
        #expect(body.contains("IN\tA\t10.0.0.5"))
        #expect(!body.contains("CNAME"))
        #expect(rendering.diagnostics.contains { $0.contains("coexists with other data") })
    }

    @Test("A CNAME at the apex is dropped — the synthesized SOA and NS are other data")
    func apexCNAMEIsDropped() throws {
        // `DNSName.normalizedRecordName` accepts `@`, and the write-time
        // conflict check only compares derived names and sibling rows — the apex
        // has neither, so an apex CNAME reaches the renderer. Emitting it beside
        // the SOA and NS this renderer always writes would make CoreDNS refuse
        // the whole zone.
        let rendering = render(
            zones: [
                zone(records: [
                    DesiredDNSRecord(name: "corp.example.com", type: "CNAME", values: ["elsewhere.example"])
                ])
            ],
            upstreams: [], searchDomain: nil)
        let body = try #require(file(rendering, zonePath("corp.example.com")))
        #expect(!body.contains("CNAME"))
        #expect(rendering.diagnostics.contains { $0.contains("coexists with other data") })
    }

    @Test("A long non-ASCII TXT chunks on codepoint boundaries rather than vanishing")
    func longUnicodeTXTChunksSafely() throws {
        // Slicing mid-codepoint makes the UTF-8 decode fail and drops the whole
        // value, for a reason nothing about the record suggests.
        let value = String(repeating: "é", count: 200)  // 400 bytes
        let quoted = try #require(CoreDNSZoneRenderer.quotedTXT(value))
        #expect(quoted.contains("\" \""))
        // Every chunk is valid text, and they concatenate back to the original.
        let rejoined = quoted.split(separator: " ").map {
            String($0.dropFirst().dropLast())
        }.joined()
        #expect(rejoined == value)
    }

    @Test("A TXT value carrying a quote or backslash is refused rather than escaped")
    func txtEscapesAreRefused() {
        // Escaping would be correct for a zone file and is what a full writer
        // does, but the value round-trips through the API and the OVN driver
        // unescaped — so an escape here would make one record read differently
        // depending on which backend answered.
        #expect(CoreDNSZoneRenderer.quotedTXT("say \"hi\"") == nil)
        #expect(CoreDNSZoneRenderer.quotedTXT("back\\slash") == nil)
        #expect(CoreDNSZoneRenderer.quotedTXT("plain") == "\"plain\"")
    }

    @Test("A long TXT is split into adjacent character-strings")
    func longTXTIsChunked() throws {
        // A character-string cannot exceed 255 octets; adjacent strings
        // concatenate back into one value at the resolver.
        let value = String(repeating: "a", count: 300)
        let quoted = try #require(CoreDNSZoneRenderer.quotedTXT(value))
        #expect(quoted.hasPrefix("\"" + String(repeating: "a", count: 255) + "\" \""))
        #expect(quoted.hasSuffix(String(repeating: "a", count: 45) + "\""))
    }

    @Test("A newline in any value is refused")
    func newlinesAreRefused() {
        // A stray newline shifts every line after it and CoreDNS refuses the
        // whole file — the failure this validation exists for.
        #expect(CoreDNSZoneRenderer.validated("10.0.0.1\n; evil", forType: "A") == nil)
        #expect(CoreDNSZoneRenderer.validated("a.example\nb.example", forType: "CNAME") == nil)
    }

    @Test("Values are re-checked against their type's shape")
    func valuesAreTypeChecked() {
        #expect(CoreDNSZoneRenderer.validated("10.0.0.1", forType: "A") == "10.0.0.1")
        #expect(CoreDNSZoneRenderer.validated("fd00::1", forType: "A") == nil)
        #expect(CoreDNSZoneRenderer.validated("fd00::1", forType: "AAAA") == "fd00::1")
        #expect(CoreDNSZoneRenderer.validated("10.0.0.1", forType: "AAAA") == nil)
        #expect(CoreDNSZoneRenderer.validated("a.example.com", forType: "CNAME") == "a.example.com.")
        #expect(CoreDNSZoneRenderer.validated("not a name", forType: "CNAME") == nil)
    }

    @Test("SRV keeps its four fields, and the RFC 2782 null target")
    func srvIsValidated() {
        #expect(
            CoreDNSZoneRenderer.validatedSRV("10 20 5060 sip.example.com") == "10 20 5060 sip.example.com.")
        // A single `.` means "definitively not available" and is not a name.
        #expect(CoreDNSZoneRenderer.validatedSRV("0 0 0 .") == "0 0 0 .")
        #expect(CoreDNSZoneRenderer.validatedSRV("10 20 sip.example.com") == nil)
        #expect(CoreDNSZoneRenderer.validatedSRV("10 20 99999 sip.example.com") == nil)
    }

    @Test("A wildcard owner name renders; a malformed one is a diagnostic")
    func wildcardsAreAllowed() throws {
        let rendering = render(
            zones: [
                zone(records: [
                    DesiredDNSRecord(name: "*.corp.example.com", type: "A", values: ["10.0.0.9"]),
                    DesiredDNSRecord(name: "bad name.corp.example.com", type: "A", values: ["10.0.0.10"]),
                ])
            ],
            upstreams: [], searchDomain: nil)
        let body = try #require(file(rendering, zonePath("corp.example.com")))
        #expect(body.contains("*.corp.example.com."))
        #expect(rendering.diagnostics.contains { $0.contains("is invalid") })
    }

    @Test("An unrealizable record type is a diagnostic, not a failure")
    func unknownTypesAreReported() {
        let rendering = render(
            zones: [
                zone(records: [DesiredDNSRecord(name: "corp.example.com", type: "CAA", values: ["0 issue \"x\""])])
            ],
            upstreams: [], searchDomain: nil)
        #expect(rendering.diagnostics.contains { $0.contains("CAA") })
    }

    // MARK: - Corefile

    @Test("The Corefile binds only the resolver's addresses")
    func corefileBindsResolverAddressesOnly() throws {
        // `bind` is what scopes a block to its network. Without it every block
        // would answer on every address in the host namespace, and a guest on
        // one network would resolve another's private names — the failure the
        // distinct addresses exist to prevent.
        let rendering = render(zones: [zone(records: [])], upstreams: ["1.1.1.1"])
        let corefile = try #require(file(rendering, "Corefile"))
        #expect(corefile.contains("bind 169.254.1.0 fd00:ec2:1::100"))
        // Never the metadata address, whose contract is HTTP on its own foot.
        #expect(!corefile.contains("169.254.169.254"))
    }

    @Test("An IPv6-less host binds only the v4 address")
    func bindListIsCallerSupplied() throws {
        // CoreDNS refuses to start when `bind` names an address that does not
        // exist — and now refuses for *every* network at once, since one process
        // serves them all. That is the sharpest edge the single process adds.
        let rendering = render(zones: [], bindAddresses: ["169.254.1.0"])
        let corefile = try #require(file(rendering, "Corefile"))
        #expect(corefile.contains("bind 169.254.1.0"))
        #expect(!corefile.contains("fd00:ec2:1::"))
    }

    @Test("Two networks serving the same zone name get separate files and blocks")
    func twoNetworksOneZoneName() throws {
        // The property the whole single-process design rests on, verified
        // against CoreDNS 1.12.0 before it was built on: a server block is keyed
        // on its zone *and* its bind addresses, so two networks can both serve
        // `corp.example.com` with different contents. A flat zone-file path
        // would have one silently overwrite the other.
        let other = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        func network(_ id: UUID, address: String, ip: String) -> CoreDNSZoneRenderer.Network {
            CoreDNSZoneRenderer.Network(
                networkId: id, bindAddresses: [address],
                zones: [
                    DesiredDNSZone(
                        zoneId: UUID(), zoneName: "corp.example.com", networkIds: [id],
                        records: [
                            DesiredDNSRecord(name: "web.corp.example.com", type: "A", values: [ip])
                        ],
                        recordsHash: ip)
                ],
                upstreams: [], searchDomain: nil)
        }
        let rendering = CoreDNSZoneRenderer.render(networks: [
            network(networkId, address: "169.254.1.0", ip: "10.0.0.1"),
            network(other, address: "169.254.1.1", ip: "10.9.9.9"),
        ])

        let mine = try #require(file(rendering, zonePath("corp.example.com")))
        let theirs = try #require(
            file(
                rendering,
                CoreDNSZoneRenderer.zoneFilePath(networkId: other, origin: "corp.example.com")))
        #expect(mine.contains("10.0.0.1"))
        #expect(theirs.contains("10.9.9.9"))

        let corefile = try #require(file(rendering, "Corefile"))
        #expect(corefile.components(separatedBy: "corp.example.com:53 {").count - 1 == 2)
        #expect(corefile.contains("bind 169.254.1.0"))
        #expect(corefile.contains("bind 169.254.1.1"))
    }

    @Test("Upstreams become a forward stanza, and an empty list becomes none")
    func forwardingIsOptional() throws {
        let withUpstreams = try #require(
            file(
                render(zones: [], upstreams: ["1.1.1.1", "8.8.8.8"], searchDomain: nil),
                "Corefile"))
        #expect(withUpstreams.contains("forward . 1.1.1.1 8.8.8.8"))

        // No `forward` rather than a synthesized public default: REFUSED is a
        // fast legible failure, and picking a resolver for the tenant would put
        // their queries somewhere the operator never chose.
        let without = try #require(
            file(render(zones: [], upstreams: [], searchDomain: nil), "Corefile"))
        #expect(!without.contains("forward"))
    }

    @Test("Every rendered zone gets a server block referencing its file")
    func everyZoneIsServed() throws {
        let rendering = render(
            zones: [
                zone(records: [
                    DesiredDNSRecord(name: "5.0.0.10.in-addr.arpa", type: "PTR", values: ["a.corp.example.com"])
                ])
            ],
            upstreams: [], searchDomain: nil)
        let corefile = try #require(file(rendering, "Corefile"))
        #expect(corefile.contains("corp.example.com:53 {"))
        #expect(corefile.contains("file \(zonePath("corp.example.com"))"))
        #expect(corefile.contains("0.0.10.in-addr.arpa:53 {"))
        #expect(corefile.contains("file \(zonePath("0.0.10.in-addr.arpa"))"))
        // Every referenced file is one this rendering actually writes; a
        // dangling reference is a CoreDNS that refuses to start.
        for path in rendering.files.map(\.relativePath) where path != "Corefile" {
            #expect(corefile.contains(path))
        }
    }

    @Test("Zone files reload without a process restart")
    func zonesAutoReload() throws {
        // A restart is a window in which the network resolves only what OVN can
        // answer, so a record edit must not need one.
        let rendering = render(zones: [zone(records: [])], upstreams: [], searchDomain: nil)
        let corefile = try #require(file(rendering, "Corefile"))
        #expect(corefile.contains("reload 10s"))
    }

    @Test("The Corefile is always the first file, so it is written last only by choice")
    func corefileIsFirst() {
        let rendering = render(zones: [zone(records: [])], upstreams: [], searchDomain: nil)
        #expect(rendering.files.first?.relativePath == "Corefile")
    }

    @Test("The search domain is recorded, and a malformed one is simply omitted")
    func searchDomainIsRecorded() throws {
        let good = try #require(
            file(
                render(zones: [], upstreams: [], searchDomain: "corp.example.com"),
                "Corefile"))
        #expect(good.contains("# network search domain: corp.example.com"))

        let bad = try #require(
            file(render(zones: [], upstreams: [], searchDomain: "not a domain"), "Corefile"))
        #expect(!bad.contains("network search domain"))
    }

    // MARK: - Serials

    @Test("The serial changes with the zone's contents and only with them")
    func serialTracksContent() {
        #expect(CoreDNSZoneRenderer.serial(from: "abc") == CoreDNSZoneRenderer.serial(from: "abc"))
        #expect(CoreDNSZoneRenderer.serial(from: "abc") != CoreDNSZoneRenderer.serial(from: "abd"))
        // Non-zero: BIND-lineage tooling reads serial 0 as "unset".
        #expect(CoreDNSZoneRenderer.serial(from: "") != 0)
    }

    @Test("The serial follows the rendered contents, not the control plane's hash")
    func serialFollowsRenderedContents() throws {
        func body(hash: String, records: [DesiredDNSRecord]) throws -> String {
            try #require(
                file(
                    render(zones: [zone(records: records, hash: hash)], upstreams: [], searchDomain: nil),
                    zonePath("corp.example.com")))
        }
        // `recordsHash` also moves when a record this renderer drops changes,
        // which would bump a serial with no visible edit behind it. A synthesized
        // reverse zone has no such hash at all, so one rule serves both.
        #expect(try body(hash: "one", records: []) == (try body(hash: "two", records: [])))
        #expect(
            try body(hash: "one", records: [])
                != (try body(
                    hash: "one",
                    records: [DesiredDNSRecord(name: "a.corp.example.com", type: "A", values: ["10.0.0.1"])])))
    }

    @Test("A TTL-only edit moves a zone's serial")
    func reverseSerialTracksTTL() throws {
        func reverse(ttl: Int) throws -> String {
            let rendering = render(
                zones: [
                    zone(records: [
                        DesiredDNSRecord(
                            name: "5.0.0.10.in-addr.arpa", type: "PTR", values: ["a.corp.example.com"],
                            ttl: ttl)
                    ])
                ],
                upstreams: [], searchDomain: nil)
            return try #require(file(rendering, zonePath("0.0.10.in-addr.arpa")))
        }
        #expect(try reverse(ttl: 60) != (try reverse(ttl: 120)))
    }

    // MARK: - Determinism

    @Test("A replayed render is byte-identical")
    func renderIsDeterministic() {
        // The supervisor compares a digest of the rendering to decide whether to
        // write; a render that reordered itself would rewrite every zone file on
        // every sync and have the `file` plugin re-read them each time.
        let records = [
            DesiredDNSRecord(name: "b.corp.example.com", type: "A", values: ["10.0.0.2"]),
            DesiredDNSRecord(name: "a.corp.example.com", type: "AAAA", values: ["fd00::1"]),
            DesiredDNSRecord(name: "a.corp.example.com", type: "A", values: ["10.0.0.1"]),
        ]
        let first = render(zones: [zone(records: records)], upstreams: ["1.1.1.1"], searchDomain: "corp.example.com")
        let second = render(
            zones: [zone(records: records.reversed())], upstreams: ["1.1.1.1"],
            searchDomain: "corp.example.com")
        #expect(first.files == second.files)
    }

    @Test("A zone with an invalid name is skipped rather than written")
    func invalidZoneNameIsSkipped() {
        let rendering = render(zones: [zone(name: "not a zone", records: [])], upstreams: [], searchDomain: nil)
        #expect(rendering.files.count == 1)  // the Corefile alone
        #expect(rendering.diagnostics.contains { $0.contains("invalid name") })
    }
}
