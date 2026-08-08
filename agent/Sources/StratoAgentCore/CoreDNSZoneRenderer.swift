import Foundation
import StratoShared

/// Renders one network's resolver configuration: a Corefile and the zone files
/// it references (STR-40, roadmap #769 phase 4).
///
/// Pure by construction, like `CloudInitProvisioner.networkConfigYAML` and
/// `DomainXMLBuilder`, and for the sharper version of their reason. A zone file
/// is a document with its own grammar that a CoreDNS parses at load time: one
/// malformed line does not cost a record, it costs the whole zone, and a whole
/// zone is every name on the network. So the construction lives where tests can
/// reach it and the process supervision — which cannot be imported from tests —
/// only writes bytes and starts a binary.
///
/// ## What this backend expresses that the OVN one does not
///
/// `OVNDNSRecords.flatten` answers A/AAAA/PTR because that is the whole of
/// `Logical_Switch.dns_records`. A zone file has the full vocabulary, so CNAME,
/// TXT and SRV are realized here — which is the point of the phase. OVN stays in
/// front regardless: it intercepts UDP/53 whatever the destination and answers
/// what it can, so this backend dying degrades a network to "internal A/AAAA/PTR
/// still resolve, everything else does not" rather than to no DNS at all.
public enum CoreDNSZoneRenderer {
    /// The record types a zone file publishes here.
    ///
    /// Deliberately not "everything the model has": each type below has a
    /// checked value shape in `validated(_:)`, and a type with no check would be
    /// interpolated into the file unexamined. Adding one means adding its
    /// validation in the same commit.
    public static let supportedTypes: Set<String> = ["A", "AAAA", "CNAME", "TXT", "SRV", "PTR"]

    /// The TTL used for a record the control plane sent without one, and for the
    /// synthesized SOA/NS. Matches `DNSRecord.defaultTTL`, which is where an
    /// authored record's TTL comes from when the operator does not choose.
    public static let defaultTTL = 300

    /// One file to write.
    public struct RenderedFile: Equatable, Sendable {
        /// Path relative to the network's configuration directory.
        public let relativePath: String
        public let contents: String

        public init(relativePath: String, contents: String) {
            self.relativePath = relativePath
            self.contents = contents
        }
    }

    /// Everything one network's resolver needs on disk, plus what could not be
    /// rendered.
    public struct Rendering: Equatable, Sendable {
        /// `Corefile` first, then the zone files it references.
        public let files: [RenderedFile]
        /// Human-readable notes about records that were dropped. Never a
        /// failure — see `validated(_:)`.
        public let diagnostics: [String]

        public init(files: [RenderedFile], diagnostics: [String]) {
            self.files = files
            self.diagnostics = diagnostics
        }
    }

    // MARK: - Entry point

    /// Renders the resolver configuration for one network.
    ///
    /// `zones` are the zones attached to this network — the caller filters
    /// `DesiredDNSZone.networkIds`, because a sync carries every zone this agent
    /// has anything to do with and each namespace serves only its own network's.
    ///
    /// `upstreams` are the network's `dnsServers`, which under this feature are
    /// forwarders rather than what the guest is told. An empty list renders no
    /// `forward` at all: the resolver then answers its zones and REFUSEs
    /// everything else, which is a fast, legible failure. Synthesizing a public
    /// default instead would put a tenant's queries somewhere the operator never
    /// chose.
    /// One network's inputs to the host-wide rendering.
    public struct Network: Sendable, Equatable {
        public let networkId: UUID
        /// This network's own resolver addresses, which is what its server
        /// blocks `bind` and therefore what tells CoreDNS which network a query
        /// arrived for. Distinct per network — that distinctness is what lets
        /// one process in the host namespace serve them all.
        public let bindAddresses: [String]
        public let zones: [DesiredDNSZone]
        public let upstreams: [String]
        public let searchDomain: String?

        public init(
            networkId: UUID, bindAddresses: [String], zones: [DesiredDNSZone], upstreams: [String],
            searchDomain: String?
        ) {
            self.networkId = networkId
            self.bindAddresses = bindAddresses
            self.zones = zones
            self.upstreams = upstreams
            self.searchDomain = searchDomain
        }
    }

    /// Renders the whole host's resolver configuration: one Corefile covering
    /// every network, and one zone file per network per origin.
    ///
    /// **One process, not one per network**, which is what moving to the host
    /// namespace buys. CoreDNS keys a server block on its zone *and* its bind
    /// addresses, so two networks can both serve `corp.example.com` with
    /// different contents from the same process — verified against 1.12.0
    /// before this was built on. The addresses being distinct per network is
    /// what makes that work, and is the same property that lets the host route
    /// each reply back to the right switch.
    ///
    /// Zone files are namespaced by network for exactly that reason: two
    /// networks may hold the same zone name with different records, so a flat
    /// `zones/<origin>.zone` would have one silently overwrite the other.
    public static func render(networks: [Network]) -> Rendering {
        var diagnostics: [String] = []
        var files: [RenderedFile] = []
        var blocks: [String] = []

        for network in networks.sorted(by: { $0.networkId.uuidString < $1.networkId.uuidString }) {
            let (networkFiles, origins, networkDiagnostics) = renderZones(for: network)
            files.append(contentsOf: networkFiles)
            diagnostics.append(contentsOf: networkDiagnostics)
            blocks.append(contentsOf: serverBlocks(for: network, origins: origins))
        }

        files.insert(
            RenderedFile(relativePath: "Corefile", contents: blocks.joined(separator: "\n\n") + "\n"),
            at: 0)
        return Rendering(files: files, diagnostics: diagnostics)
    }

    /// The zone files for one network, plus the origins its server blocks
    /// should reference.
    private static func renderZones(
        for network: Network
    ) -> (files: [RenderedFile], origins: [String], diagnostics: [String]) {
        var diagnostics: [String] = []

        // Everything is bucketed by **origin**, not by zone, and one file is
        // written per origin. Two things make that necessary rather than tidy:
        //
        //  - A `PTR` for 10.0.0.5 is owned by `0.0.10.in-addr.arpa`, never by
        //    the forward zone the address's name lives in. Writing one into the
        //    forward file would make CoreDNS refuse the zone as out of
        //    bailiwick, so PTRs are pulled out and regrouped.
        //  - `0.0.10.in-addr.arpa` is itself a legal `DNSZone` name, so an
        //    operator can author one. Emitting the forward zone and the
        //    synthesized reverse zone separately would then write two files at
        //    one path and two server blocks for one origin — and CoreDNS
        //    refuses to start on a duplicate zone block, which costs the network
        //    its whole resolver rather than one zone.
        var recordsByOrigin: [String: [DesiredDNSRecord]] = [:]
        var labelForOrigin: [String: String] = [:]

        for zone in network.zones.sorted(by: { $0.zoneName < $1.zoneName }) {
            let origin = normalizedOrigin(zone.zoneName)
            guard DNSNameSyntax.isValidDomainName(zone.zoneName) else {
                diagnostics.append("zone '\(zone.zoneName)' has an invalid name; skipped")
                continue
            }
            // Present even with no records, so an empty attached zone is still
            // served authoritatively. Without the entry the catch-all would
            // forward its names upstream, which is the wrong answer: an empty
            // internal zone should NXDOMAIN, not leak the query.
            if recordsByOrigin[origin] == nil { recordsByOrigin[origin] = [] }
            labelForOrigin[origin] = zone.zoneName

            for record in zone.records {
                let type = record.type.uppercased()
                guard supportedTypes.contains(type) else {
                    diagnostics.append("zone '\(zone.zoneName)': record type \(type) is not realized")
                    continue
                }
                if type == "PTR" {
                    // Grouped at the /24 and /64 boundary derived from the PTR
                    // name itself, not from the network's subnet — which this
                    // renderer does not have, and which would be the wrong key
                    // anyway for a zone attached to two networks. The
                    // consequence is that a reverse lookup in a prefix the agent
                    // has seen no record for falls through to the upstreams,
                    // which is correct: it is not our name to answer for.
                    guard let reverseOrigin = reverseOrigin(forPTRName: record.name) else {
                        diagnostics.append(
                            "zone '\(zone.zoneName)': PTR '\(record.name)' is not a reverse name; skipped")
                        continue
                    }
                    recordsByOrigin[reverseOrigin, default: []].append(record)
                    labelForOrigin[reverseOrigin] = labelForOrigin[reverseOrigin] ?? reverseOrigin
                } else {
                    recordsByOrigin[origin, default: []].append(record)
                }
            }
        }

        let origins = recordsByOrigin.keys.sorted()
        var files: [RenderedFile] = []
        for origin in origins {
            let records = recordsByOrigin[origin] ?? []
            let (body, zoneDiagnostics) = zoneBody(
                origin: origin, records: records, in: labelForOrigin[origin] ?? origin)
            diagnostics.append(contentsOf: zoneDiagnostics)
            files.append(
                RenderedFile(
                    relativePath: zoneFilePath(networkId: network.networkId, origin: origin),
                    contents: body))
        }
        return (files, origins, diagnostics)
    }

    // MARK: - Corefile

    /// One network's server blocks: one per zone it serves, plus a catch-all
    /// that forwards everything else.
    ///
    /// `bind` is what scopes each block to its network. Without it every block
    /// would answer on every address in the host namespace, and a guest on one
    /// network would resolve another's private names — the failure the distinct
    /// addresses exist to prevent.
    ///
    /// The `file` plugin's own `reload` is what makes a record edit cost no
    /// process restart, and the server-level `reload` does the same for an
    /// upstream-list edit. Both matter more now than they did with a process per
    /// network: a restart here is a gap for *every* network on the host, which
    /// is the cost of the single process and the reason nothing routine causes
    /// one.
    static func serverBlocks(for network: Network, origins: [String]) -> [String] {
        guard !network.bindAddresses.isEmpty else { return [] }
        let bind = "\n    bind \(network.bindAddresses.joined(separator: " "))"
        var blocks: [String] = []

        for origin in origins.sorted() {
            blocks.append(
                """
                \(origin):\(NetworkResolverEndpoint.port) {\(bind)
                    file \(zoneFilePath(networkId: network.networkId, origin: origin)) {
                        reload 10s
                    }
                    errors
                }
                """)
        }

        // The catch-all. Everything that is not one of this network's zones
        // lands here: guest lookups of public names, and reverse lookups outside
        // the prefixes it authors. This is the block the whole move to the host
        // namespace was for — `forward` here reaches the upstreams through the
        // *hypervisor's* routing, which is what a resolver inside the network's
        // own namespace could never do.
        var root = """
            .:\(NetworkResolverEndpoint.port) {\(bind)
                errors
                cache 30
                reload 10s
            """
        if !network.upstreams.isEmpty {
            root += "\n    forward . \(network.upstreams.joined(separator: " "))"
        }
        if let searchDomain = network.searchDomain,
            DNSNameSyntax.isValidDomainName(searchDomain)
        {
            // Not a resolution mechanism — the guest's own `search` list does
            // that — but recorded so the file explains itself to an operator
            // reading it on the host, which is the only place it is ever read.
            root += "\n    # network search domain: \(searchDomain)"
        }
        root += "\n}"
        blocks.append(root)
        return blocks
    }

    // MARK: - Zone files

    /// The body of one zone file.
    ///
    /// The serial is derived from `records` here rather than supplied by the
    /// caller: every zone this renders is seeded the same way, forward and
    /// synthesized-reverse alike, so there was nothing for a caller to choose.
    private static func zoneBody(
        origin: String, records: [DesiredDNSRecord], in zoneLabel: String
    ) -> (body: String, diagnostics: [String]) {
        var diagnostics: [String] = []

        // A CNAME may not coexist with other data at the same owner name (RFC
        // 1034 §3.6.2), and CoreDNS's `file` plugin refuses to load a zone that
        // violates it. Dropping the CNAME rather than the address records is the
        // right direction: the addresses are what the derived tier produced from
        // real VMs, and `DNSZoneAssembler.merge` has already decided derived
        // beats authored on a collision.
        var namesWithOtherData: Set<String> = []
        // The apex always carries the synthesized SOA and NS, so a CNAME there
        // violates the rule even in a zone with no other records. Reachable:
        // `DNSName.normalizedRecordName` accepts `@`, and the write-time
        // conflict check only compares against derived names and sibling rows —
        // of which the apex has none.
        namesWithOtherData.insert(origin)
        for record in records where record.type.uppercased() != "CNAME" {
            namesWithOtherData.insert(record.name.lowercased())
        }

        var lines: [String] = []
        for record in records.sorted(by: { ($0.name, $0.type) < ($1.name, $1.type) }) {
            let type = record.type.uppercased()
            guard DNSNameSyntax.isValidOwnerName(record.name) else {
                diagnostics.append("zone '\(zoneLabel)': owner name '\(record.name)' is invalid; skipped")
                continue
            }
            if type == "CNAME", namesWithOtherData.contains(record.name.lowercased()) {
                diagnostics.append(
                    "zone '\(zoneLabel)': CNAME at '\(record.name)' coexists with other data; skipped")
                continue
            }
            let ttl = record.ttl ?? defaultTTL
            for value in record.values {
                guard let rdata = validated(value, forType: type) else {
                    diagnostics.append(
                        "zone '\(zoneLabel)': \(type) value at '\(record.name)' is malformed; skipped")
                    continue
                }
                lines.append("\(absolute(record.name))\t\(ttl)\tIN\t\(type)\t\(rdata)")
            }
        }

        let body =
            """
            $ORIGIN \(origin).
            $TTL \(defaultTTL)
            @\t\(defaultTTL)\tIN\tSOA\t\(nameserverName) \(hostmasterName) (\
            \(serial(from: serialSeed(records))) 7200 3600 1209600 \(defaultTTL) )
            @\t\(defaultTTL)\tIN\tNS\t\(nameserverName)
            \(lines.joined(separator: "\n"))
            """ + "\n"
        return (body, diagnostics)
    }

    /// The SOA `MNAME` and the zone's single `NS`, deliberately **outside** every
    /// zone this renders.
    ///
    /// `.invalid` is reserved by RFC 2606 and can never be a real name, so
    /// nothing resolves it and nothing needs to: there are no secondaries and no
    /// zone transfers here, and a `file`-backed zone loads without its NS target
    /// existing. An in-zone name like `ns.<zone>` would have needed glue, and —
    /// the reason this is not merely tidier — would collide with a tenant's own
    /// record: a VM whose hostname is `ns`, or an authored `CNAME` at that name,
    /// would put a CNAME beside other data and make CoreDNS refuse the entire
    /// zone.
    static let nameserverName = "ns.strato.invalid."
    /// The SOA `RNAME`. Out of zone for `nameserverName`'s reason; nothing ever
    /// mails it.
    static let hostmasterName = "hostmaster.strato.invalid."

    ///
    /// The serial is derived from the zone's content digest, not from a clock or
    /// a counter. It changes when and only when the zone does, which is what a
    /// serial is for; it is **not monotonic**, which would matter if anything
    /// ever transferred these zones. Nothing does — each is rendered from
    /// desired state on the host that serves it — and a monotonic serial would
    /// need durable state the agent deliberately does not keep for anything it
    /// can rederive.
    static func serial(from seed: String) -> UInt32 {
        // FNV-1a over the seed, matching how `OVNDHCPOptionsBuilder.serverMAC`
        // derives a stable value from a string, rather than `hashValue` — whose
        // seed is randomized per process, so the serial would change on every
        // agent restart and a `reload`-watching CoreDNS would re-read every zone
        // for nothing.
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        // Non-zero: BIND-lineage tooling treats serial 0 as "unset".
        return UInt32(truncatingIfNeeded: hash) | 1
    }

    /// The seed a zone's serial is derived from: its own contents, in the same
    /// canonical order the file is written in.
    ///
    /// Deliberately **not** the control plane's `recordsHash`, though a forward
    /// zone has one. Two reasons. A synthesized reverse zone has no such hash at
    /// all — it is assembled here from PTRs spread across several forward
    /// zones, and an operator-authored reverse zone may contribute to the same
    /// origin. And a content-derived seed changes exactly when the *file*
    /// changes, whereas `recordsHash` also moves when a record this renderer
    /// drops does, which would bump a serial with no visible edit behind it.
    private static func serialSeed(_ records: [DesiredDNSRecord]) -> String {
        records
            .sorted { ($0.name, $0.type) < ($1.name, $1.type) }
            .map { "\($0.name)|\($0.type)|\($0.ttl ?? defaultTTL)|\($0.values.joined(separator: ","))" }
            .joined(separator: ";")
    }

    // MARK: - Names

    /// The zone origin without a trailing dot, lowercased.
    static func normalizedOrigin(_ name: String) -> String {
        var origin = name.lowercased()
        while origin.hasSuffix(".") { origin.removeLast() }
        return origin
    }

    /// A record's owner name as an absolute name. Written absolute rather than
    /// relative to `$ORIGIN` because the control plane already sends every name
    /// fully qualified (`DNSName.qualified`), and re-relativizing it would mean
    /// this renderer deciding whether a name is in bailiwick — a decision that
    /// is wrong exactly once and silently.
    static func absolute(_ name: String) -> String {
        name.hasSuffix(".") ? name : name + "."
    }

    /// The file a zone's records are written to, under its network's own
    /// directory.
    ///
    /// Namespaced by network because two networks may attach zones with the same
    /// name and different contents — the whole point of a per-network resolver —
    /// so a flat path would have one silently overwrite the other. Derived from
    /// the origin within that, so a zone renamed in the control plane lands in a
    /// new file and the old one is swept rather than two racing for one path.
    static func zoneFilePath(networkId: UUID, origin: String) -> String {
        "zones/\(networkId.uuidString.lowercased())/\(origin).zone"
    }

    /// The reverse zone a `PTR` owner name belongs to.
    ///
    /// `/24` for `in-addr.arpa` (drop the host label) and `/64` for `ip6.arpa`
    /// (drop the 16 host nibbles). Those are the boundaries Strato's own
    /// allocation works in — IPv6 subnets are always a `/64`, and a v4 tenant
    /// subnet is rarely larger than a `/24` — so a zone lines up with a subnet in
    /// the common case without this needing to know the subnet.
    ///
    /// Nil when the name is not a reverse name at all, which is a record the
    /// control plane should not have produced.
    static func reverseOrigin(forPTRName name: String) -> String? {
        let lowered = normalizedOrigin(name)
        let labels = lowered.split(separator: ".").map(String.init)
        if lowered.hasSuffix(".in-addr.arpa") {
            // <host>.<c>.<b>.<a>.in-addr.arpa → <c>.<b>.<a>.in-addr.arpa
            // 3 octets + `in-addr` + `arpa` is the zone itself; a PTR needs at
            // least one host label above it. Checked before the arithmetic
            // below, which would otherwise trap on a negative `dropFirst`.
            guard labels.count > 5 else { return nil }
            return labels.dropFirst(labels.count - 3 - 2).joined(separator: ".")
        }
        if lowered.hasSuffix(".ip6.arpa") {
            // 32 nibbles + "ip6" + "arpa"; a /64 keeps the leading 16 nibbles.
            guard labels.count > 2 + 16 else { return nil }
            return labels.dropFirst(labels.count - 16 - 2).joined(separator: ".")
        }
        return nil
    }

    // MARK: - Values

    /// A record value re-checked against its type's shape, and quoted where the
    /// zone-file grammar needs it.
    ///
    /// Re-validated rather than trusted on `OVNDNSRecords.flatten`'s reasoning,
    /// which is even sharper here: an unquoted space in a TXT value or a stray
    /// newline anywhere does not corrupt one record, it shifts every line after
    /// it and CoreDNS refuses to load the file — costing the network every name
    /// in the zone, and (because the Corefile references a file that will not
    /// parse) potentially the resolver's ability to start at all.
    static func validated(_ value: String, forType type: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isNewline }) else { return nil }
        switch type {
        case "A":
            return IPv4Address(trimmed) != nil ? trimmed : nil
        case "AAAA":
            return IPv6Address(trimmed) != nil ? trimmed : nil
        case "CNAME", "PTR":
            let target = normalizedOrigin(trimmed)
            return DNSNameSyntax.isValidDomainName(target) ? absolute(target) : nil
        case "TXT":
            return quotedTXT(trimmed)
        case "SRV":
            return validatedSRV(trimmed)
        default:
            return nil
        }
    }

    /// A TXT value as one or more quoted character-strings.
    ///
    /// Rejects a value carrying a `"` or `\` outright rather than escaping it.
    /// Escaping would be correct and is what a full zone-file writer does, but
    /// the value round-trips through the control plane's API and its OVN
    /// sibling unescaped, so an escape here would make the same record read
    /// differently depending on which backend answered.
    ///
    /// Split at 255 octets because a character-string cannot be longer, and a
    /// long TXT (a DKIM key) is expressed as several adjacent strings — which
    /// concatenate back into one value at the resolver.
    static func quotedTXT(_ value: String) -> String? {
        guard !value.contains("\""), !value.contains("\\") else { return nil }
        let bytes = Array(value.utf8)
        guard bytes.count <= 65_535 else { return nil }
        var chunks: [String] = []
        var index = 0
        while index < bytes.count {
            var end = min(index + 255, bytes.count)
            // Back the boundary up to a UTF-8 lead byte. Splitting mid-codepoint
            // would make the decode below fail and drop the whole value — so a
            // long non-ASCII TXT would vanish for a reason nothing about it
            // suggests. Continuation bytes are `10xxxxxx`.
            while end > index, end < bytes.count, bytes[end] & 0xC0 == 0x80 { end -= 1 }
            guard end > index, let chunk = String(bytes: bytes[index..<end], encoding: .utf8) else {
                return nil
            }
            chunks.append("\"\(chunk)\"")
            index = end
        }
        return chunks.isEmpty ? "\"\"" : chunks.joined(separator: " ")
    }

    /// An SRV value: `priority weight port target`, the same four fields the
    /// control plane validates on write (`DNSZoneService.validatedSRVValue`).
    static func validatedSRV(_ value: String) -> String? {
        let fields = value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 4,
            let priority = UInt16(fields[0]), let weight = UInt16(fields[1]),
            let port = UInt16(fields[2])
        else { return nil }
        let target = normalizedOrigin(fields[3])
        // A single `.` is the RFC 2782 "service definitively not available"
        // target, and it is not a domain name — so it needs its own arm rather
        // than falling into the grammar check.
        guard target.isEmpty || DNSNameSyntax.isValidDomainName(target) else { return nil }
        return "\(priority) \(weight) \(port) \(target.isEmpty ? "." : absolute(target))"
    }
}
