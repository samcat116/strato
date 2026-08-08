import Crypto
import Fluent
import Foundation
import StratoShared
import Vapor

/// One assembled resource record set: an owner name, a type, and every value
/// published at that name for that type.
///
/// Values are a list because an RRset genuinely is one — a hostname with both
/// an IPv4 and an IPv6 address produces an `A` entry and an `AAAA` entry, and
/// a round-robin service produces several `A` values. Keeping the family in
/// `type` rather than flattening addresses into one blob is what makes the
/// output realization-agnostic: the OVN driver (phase 3) joins the A and AAAA
/// values for a name into the single space-separated string
/// `Logical_Switch.dns_records` takes, while a CoreDNS zone file (phase 4)
/// keeps them apart. Neither shape is baked in here.
struct AssembledDNSRecord: Content, Hashable, Sendable {
    /// Where the entry came from — the two tiers the roadmap keeps separate.
    enum Origin: String, Content, Sendable {
        /// Generated from a VM's hostname and its IPAM allocations. Never
        /// stored; recomputed on every assembly.
        case derived
        /// A `DNSRecord` row somebody wrote.
        case authored
    }

    /// Fully-qualified owner name, lowercased and without a trailing dot.
    let name: String
    let type: DNSRecordType
    /// The RRset's values, deduplicated and sorted so two assemblies of the
    /// same data compare equal (phase 3 hashes this to decide whether to
    /// rewrite the OVN row).
    let values: [String]
    let ttl: Int
    let view: DNSRecordView
    let origin: Origin
}

/// A zone's complete effective contents.
struct AssembledDNSZone: Content, Sendable {
    let zoneId: UUID
    let zoneName: String
    /// Sorted by `(name, type)` — a stable order, so callers can diff two
    /// assemblies without sorting first.
    let records: [AssembledDNSRecord]
}

/// Computes a zone's record set as **derived ∪ authored**, on demand.
///
/// This is the seam the roadmap's realization drivers sit behind: the OVN
/// `DNS` table writer (phase 3) and the per-network CoreDNS (phase 4) both
/// consume this output rather than re-deriving names from VM rows, so there is
/// exactly one place that knows what a zone contains.
///
/// Nothing is stored. Derived records are a pure function of the VM, NIC, and
/// address rows the control plane already owns — it is the only component that
/// knows every name → address mapping, because it owns IPAM — and persisting a
/// second copy would just be a cache to invalidate on every VM lifecycle
/// event.
enum DNSZoneAssembler {

    /// Assemble one zone.
    static func assemble(zone: DNSZone, on db: any Database) async throws -> AssembledDNSZone {
        let zoneID = try zone.requireID()
        guard let assembled = try await assemble(zones: [zoneID: zone.name], on: db).first else {
            // Unreachable: the batch returns one entry per id it was given.
            return AssembledDNSZone(zoneId: zoneID, zoneName: zone.name, records: [])
        }
        return assembled
    }

    /// Assemble several zones in a fixed number of queries.
    ///
    /// The desired-state sync assembles every zone attached to a site's
    /// networks on *every* poll of the topology authority, so the per-zone
    /// shape this replaces was O(zones) round trips against tables whose rows
    /// are O(VMs). Batching is four queries whether there is one zone or fifty.
    ///
    /// The single-zone entry point delegates here rather than the other way
    /// around, so there stays exactly one implementation of what a zone
    /// contains — the property this type exists to hold.
    ///
    /// Returned in the order `zones` iterates; callers that need a stable order
    /// impose their own.
    static func assemble(zones: [UUID: String], on db: any Database) async throws -> [AssembledDNSZone] {
        guard !zones.isEmpty else { return [] }
        let derived = try await derivedRecords(forZones: zones, on: db)
        let authored = try await authoredRecords(forZones: zones, on: db)
        return zones.map { zoneID, zoneName in
            AssembledDNSZone(
                zoneId: zoneID,
                zoneName: zoneName,
                records: merge(derived: derived[zoneID] ?? [], authored: authored[zoneID] ?? [])
            )
        }
    }

    // MARK: - Derived

    /// The forward and reverse records generated for every VM that registers
    /// into this zone.
    ///
    /// A VM registers into the zone once for each NIC it has on a network
    /// whose *primary* zone is this one — so a VM with two NICs on two
    /// networks that share a primary zone publishes both NICs' addresses under
    /// one name, which is the DNS-correct answer for a multi-homed host.
    ///
    /// VMs with no hostname (rows predating the column that were never
    /// backfilled) contribute nothing rather than falling back to a slug of
    /// their name: deriving on read is exactly what `VM.hostname` exists to
    /// avoid.
    static func derivedRecords(
        zoneID: UUID, zoneName: String, on db: any Database
    ) async throws -> [AssembledDNSRecord] {
        try await derivedRecords(forZones: [zoneID: zoneName], on: db)[zoneID] ?? []
    }

    /// The derived records of several zones at once, keyed by zone.
    ///
    /// Three queries regardless of how many zones are asked for: the networks
    /// registering into any of them, those networks' NICs with their addresses,
    /// and the NICs' VMs. Grouping is by `(zone, fqdn)`, so a VM with NICs on
    /// two networks that share a primary zone still publishes one name — and a
    /// VM on two networks with *different* primary zones lands in both, each
    /// carrying only the addresses that zone's networks allocated.
    private static func derivedRecords(
        forZones zones: [UUID: String], on db: any Database
    ) async throws -> [UUID: [AssembledDNSRecord]] {
        guard !zones.isEmpty else { return [:] }
        var zoneByNetwork: [UUID: UUID] = [:]
        for network in try await LogicalNetwork.query(on: db)
            .filter(\.$primaryDNSZone.$id ~~ Array(zones.keys))
            .all()
        {
            guard let networkID = network.id, let zoneID = network.$primaryDNSZone.id else { continue }
            zoneByNetwork[networkID] = zoneID
        }
        guard !zoneByNetwork.isEmpty else { return [:] }

        let interfaces = try await VMNetworkInterface.query(on: db)
            .filter(\.$logicalNetwork.$id ~~ Array(zoneByNetwork.keys))
            .with(\.$addresses)
            .all()
        guard !interfaces.isEmpty else { return [:] }

        let vmIDs = Array(Set(interfaces.map { $0.$vm.id }))
        var hostnames: [UUID: String] = [:]
        for vm in try await VM.query(on: db).filter(\.$id ~~ vmIDs).all() {
            guard let id = vm.id, let hostname = vm.hostname else { continue }
            hostnames[id] = hostname
        }

        // Group by (zone, fqdn, family) so a multi-NIC VM's addresses land in
        // one RRset, then emit the matching PTR for each address.
        var forward: [UUID: [DNSRecordType: [String: Set<String>]]] = [:]
        var reverse: [UUID: [String: Set<String>]] = [:]
        for interface in interfaces {
            guard let hostname = hostnames[interface.$vm.id],
                let zoneID = zoneByNetwork[interface.logicalNetworkID],
                let zoneName = zones[zoneID]
            else { continue }
            let fqdn = DNSName.qualified(name: hostname, inZone: zoneName)
            for address in interface.allocatedAddresses {
                guard let family = address.ipFamily else { continue }
                let type: DNSRecordType = family == .ipv6 ? .aaaa : .a
                forward[zoneID, default: [:]][type, default: [:]][fqdn, default: []].insert(address.address)
                if let reverseName = DNSName.reverseName(forAddress: address.address) {
                    reverse[zoneID, default: [:]][reverseName, default: []].insert(fqdn)
                }
            }
        }

        var records: [UUID: [AssembledDNSRecord]] = [:]
        for (zoneID, byType) in forward {
            for (type, byName) in byType {
                for (name, values) in byName {
                    records[zoneID, default: []].append(
                        AssembledDNSRecord(
                            name: name, type: type, values: values.sorted(),
                            ttl: DNSRecord.defaultTTL, view: .internal, origin: .derived))
                }
            }
        }
        for (zoneID, byName) in reverse {
            for (name, targets) in byName {
                records[zoneID, default: []].append(
                    AssembledDNSRecord(
                        name: name, type: .ptr, values: targets.sorted(),
                        ttl: DNSRecord.defaultTTL, view: .internal, origin: .derived))
            }
        }
        return records
    }

    /// The names derived records occupy in a zone — what an authored write is
    /// checked against, so a collision is rejected at write time with a clear
    /// error instead of being silently shadowed at realization time.
    static func derivedNames(
        zoneID: UUID, zoneName: String, on db: any Database
    ) async throws -> [String: Set<DNSRecordType>] {
        var names: [String: Set<DNSRecordType>] = [:]
        for record in try await derivedRecords(zoneID: zoneID, zoneName: zoneName, on: db) {
            names[record.name, default: []].insert(record.type)
        }
        return names
    }

    // MARK: - Authored

    static func authoredRecords(
        zoneID: UUID, zoneName: String, on db: any Database
    ) async throws -> [AssembledDNSRecord] {
        try await authoredRecords(forZones: [zoneID: zoneName], on: db)[zoneID] ?? []
    }

    /// The authored records of several zones at once, in one query.
    private static func authoredRecords(
        forZones zones: [UUID: String], on db: any Database
    ) async throws -> [UUID: [AssembledDNSRecord]] {
        guard !zones.isEmpty else { return [:] }
        let rows = try await DNSRecord.query(on: db).filter(\.$zone.$id ~~ Array(zones.keys)).all()
        // One entry per (zone, name, type) — an RRset. TTL and view are
        // properties of the set, not of its members (RFC 2181 §5.2), and the
        // write path enforces that, so every row here agrees with its siblings
        // and the first one's values stand for the set.
        //
        // Grouping any finer would let one `(name, type)` yield several entries,
        // which neither planned driver can express: OVN keeps one row per name
        // and a zone file writes one TTL per RRset. See `DNSZoneService`.
        struct Key: Hashable {
            let zoneID: UUID
            let name: String
            let type: DNSRecordType
        }
        var values: [Key: Set<String>] = [:]
        var settings: [Key: (ttl: Int, view: DNSRecordView)] = [:]
        for row in rows {
            let zoneID = row.$zone.id
            guard let zoneName = zones[zoneID] else { continue }
            let key = Key(
                zoneID: zoneID, name: DNSName.qualified(name: row.name, inZone: zoneName),
                type: row.type)
            values[key, default: []].insert(row.value)
            // Lowest TTL and narrowest view win, so a row that predates the
            // write-time rule (or slipped through a race) degrades toward
            // caching less and publishing less, never the other way.
            let existing = settings[key]
            settings[key] = (
                ttl: min(existing?.ttl ?? row.ttl, row.ttl),
                view: Self.narrower(existing?.view ?? row.view, row.view)
            )
        }
        var records: [UUID: [AssembledDNSRecord]] = [:]
        for (key, values) in values {
            let setting = settings[key] ?? (ttl: DNSRecord.defaultTTL, view: .both)
            records[key.zoneID, default: []].append(
                AssembledDNSRecord(
                    name: key.name, type: key.type, values: values.sorted(),
                    ttl: setting.ttl, view: setting.view, origin: .authored))
        }
        return records
    }

    /// The more restrictive of two views, for the degradation rule above:
    /// `both` publishes everywhere, so anything else narrows it, and two
    /// disagreeing single-sided views collapse to `internal` (the side that
    /// never leaves the deployment).
    private static func narrower(_ lhs: DNSRecordView, _ rhs: DNSRecordView) -> DNSRecordView {
        if lhs == rhs { return lhs }
        if lhs == .both { return rhs }
        if rhs == .both { return lhs }
        return .internal
    }

    // MARK: - Merge

    /// Union the two tiers into one deterministically ordered set.
    ///
    /// Derived wins a collision, and the write path is what makes that never
    /// happen: authored writes are rejected against `derivedNames`. Preferring
    /// derived here is the safe direction for the race that check cannot
    /// close (a VM created between the check and the write) — a machine's own
    /// address answering for its own name is the one thing that must not
    /// silently break.
    private static func merge(
        derived: [AssembledDNSRecord], authored: [AssembledDNSRecord]
    ) -> [AssembledDNSRecord] {
        var occupied: Set<String> = []
        for record in derived { occupied.insert("\(record.name)|\(record.type.rawValue)") }
        let surviving = authored.filter { !occupied.contains("\($0.name)|\($0.type.rawValue)") }
        // Ordered on every field, not just `(name, type)`. Both tiers now emit
        // one entry per `(name, type)` so ties should be impossible — but
        // `sort` is not stable and the input comes from `Dictionary` iteration,
        // so a tie that did arise would order differently on each assembly and
        // phase 3 would hash it to a spurious OVN rewrite. Ordering totally
        // costs nothing and removes the failure mode rather than relying on an
        // invariant enforced somewhere else.
        return (derived + surviving).sorted {
            ($0.name, $0.type.rawValue, $0.ttl, $0.view.rawValue, $0.values.joined(separator: ","))
                < ($1.name, $1.type.rawValue, $1.ttl, $1.view.rawValue, $1.values.joined(separator: ","))
        }
    }
}

// MARK: - Wire projection (STR-39)

extension DNSZoneAssembler {
    /// The desired-state entry for an assembled zone: what the topology
    /// authority realizes, and where.
    ///
    /// Records travel typed rather than pre-flattened into the map OVN's `DNS`
    /// table takes, so the receiving driver decides what it can express — see
    /// `DesiredDNSRecord`. TTL travels as of wire v37 (STR-40): it did not
    /// under phase 3, deliberately, because OVN's responder has no per-record
    /// TTL and a field no driver read would have changed the digest without
    /// changing anything realized. A zone file writes one TTL per RRset, so the
    /// resolver driver is the reader that field was waiting for.
    ///
    /// `.external`-view records are dropped here rather than on the agent.
    /// Split horizon is a control-plane concept (roadmap phase 6) and the
    /// internal resolver is by definition the internal side; sending records
    /// marked for publication elsewhere would make the agent responsible for a
    /// distinction it has no other reason to know about.
    static func desiredZone(_ assembled: AssembledDNSZone, networkIDs: [UUID]) -> DesiredDNSZone {
        let records = assembled.records
            .filter { $0.view != .external }
            .map {
                DesiredDNSRecord(
                    name: $0.name, type: $0.type.rawValue, values: $0.values, ttl: $0.ttl)
            }
        return DesiredDNSZone(
            zoneId: assembled.zoneId,
            zoneName: assembled.zoneName,
            networkIds: networkIDs.sorted { $0.uuidString < $1.uuidString },
            records: records,
            recordsHash: recordsHash(records))
    }

    /// A digest of a zone's wire records, so the agent can skip an OVSDB
    /// transaction for a zone that hasn't changed.
    ///
    /// Over the whole *projected* set — every record an agent is sent,
    /// including the types the OVN backend cannot express, and excluding the
    /// `.external`-view records `desiredZone` withheld. The stamp means "this
    /// row was written from this version of the zone as the agent sees it": a
    /// hash that ignored the unrealizable records would leave a row claiming to
    /// be current after an edit it deliberately didn't realize, and one that
    /// counted the withheld records would move without anything on the agent
    /// changing. `AssembledDNSZone` is already totally ordered, and both tiers
    /// emit one entry per `(name, type)`, so the input here is canonical
    /// without re-sorting.
    ///
    /// Fields are length-prefixed rather than joined with a separator: a TXT
    /// record's value is arbitrary text, so any delimiter is one an operator
    /// can author, and two different zones hashing equal is the one failure
    /// mode a change detector must not have.
    ///
    /// The TTL is folded in as of wire v37, because a zone file writes one and
    /// so a TTL-only edit has to reach the resolver. It changes every stamp
    /// once on upgrade: the OVN driver then rewrites each zone one time and
    /// re-stamps it, which is exactly what the drift compare exists for.
    static func recordsHash(_ records: [DesiredDNSRecord]) -> String {
        var hasher = SHA256()
        func update(_ field: String) {
            let bytes = Data(field.utf8)
            withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { hasher.update(data: Data($0)) }
            hasher.update(data: bytes)
        }
        for record in records {
            update(record.name)
            update(record.type)
            withUnsafeBytes(of: UInt32(record.values.count).bigEndian) { hasher.update(data: Data($0)) }
            for value in record.values { update(value) }
            // Absent and present-but-default are different claims — a zone
            // whose TTL the control plane declines to state is not the same
            // input as one that states 300 — so the marker byte distinguishes
            // them rather than hashing nil as zero.
            if let ttl = record.ttl {
                hasher.update(data: Data([1]))
                withUnsafeBytes(of: UInt32(bitPattern: Int32(truncatingIfNeeded: ttl)).bigEndian) {
                    hasher.update(data: Data($0))
                }
            } else {
                hasher.update(data: Data([0]))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
