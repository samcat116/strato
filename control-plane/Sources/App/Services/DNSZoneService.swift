import Fluent
import SQLKit
import StratoShared
import Vapor

/// The write-side rules of the DNS model (issue #770): what a record's value
/// may be, which authored records may coexist with the derived ones, and where
/// a VM's hostname has to be unique.
///
/// Kept beside `DNSZoneAssembler` rather than in the controller because the
/// same rules bind more than one route — a record write, a zone attach, a VM
/// rename, and VM creation can each introduce the same collision.
enum DNSZoneService {

    // MARK: - Record values

    /// Validate and canonicalize a record's RDATA for its type.
    ///
    /// Canonicalizing at write time (an IPv6 literal to RFC 5952, a target
    /// name to lowercase with no root dot) is what lets the uniqueness index
    /// on `(zone, name, type, value)` mean what it says: two spellings of one
    /// address must not both be storable.
    static func validatedValue(_ raw: String, type: DNSRecordType) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw Abort(.badRequest, reason: "Record value must not be empty")
        }

        switch type {
        case .a:
            // Rendered back from the parsed value rather than stored as typed:
            // Swift's integer parsing accepts leading zeros and a leading `+`,
            // so `10.0.0.1`, `010.0.0.1`, and `+10.0.0.1` all parse to one
            // address and would otherwise be three storable rows past the
            // uniqueness index — and three A values on the wire for one name.
            guard let parsed = IPAMService.parseIPv4(value) else {
                throw Abort(.badRequest, reason: "An A record's value must be an IPv4 address, got '\(raw)'")
            }
            return IPAMService.formatIPv4(parsed)
        case .aaaa:
            guard let canonical = IPv6Address.canonicalize(value) else {
                throw Abort(.badRequest, reason: "An AAAA record's value must be an IPv6 address, got '\(raw)'")
            }
            return canonical
        case .cname, .ptr:
            return try validatedTargetName(value, type: type)
        case .txt:
            // One TXT character-string is at most 255 octets (RFC 1035 §3.3).
            // Multi-string TXT records exist but nothing consumes them yet, so
            // one string is the honest limit rather than a silent truncation.
            guard value.utf8.count <= 255 else {
                throw Abort(.badRequest, reason: "A TXT record's value must not exceed 255 bytes")
            }
            guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
                throw Abort(.badRequest, reason: "A TXT record's value must not contain control characters")
            }
            return value
        case .srv:
            return try validatedSRVValue(value)
        }
    }

    /// A CNAME/PTR target: a domain name, stored lowercased with no trailing
    /// dot (the same normalization every other name in the model gets).
    private static func validatedTargetName(_ value: String, type: DNSRecordType) throws -> String {
        var target = value.lowercased()
        while target.hasSuffix(".") { target.removeLast() }
        let labels = target.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !labels.isEmpty, target.count <= DNSName.maxNameLength, labels.allSatisfy(DNSName.isValidLabel)
        else {
            throw Abort(
                .badRequest,
                reason: "A \(type.rawValue) record's value must be a domain name, got '\(value)'")
        }
        return target
    }

    /// `priority weight port target`, the zone-file form of SRV RDATA.
    private static func validatedSRVValue(_ value: String) throws -> String {
        let fields = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 4 else {
            throw Abort(
                .badRequest,
                reason: "An SRV record's value must be 'priority weight port target', got '\(value)'")
        }
        var numbers: [Int] = []
        for (index, field) in fields.prefix(3).enumerated() {
            let label = ["priority", "weight", "port"][index]
            guard let number = Int(field), (0...65535).contains(number) else {
                throw Abort(.badRequest, reason: "An SRV record's \(label) must be 0–65535, got '\(field)'")
            }
            numbers.append(number)
        }
        let target = try validatedTargetName(fields[3], type: .srv)
        return "\(numbers[0]) \(numbers[1]) \(numbers[2]) \(target)"
    }

    // MARK: - Serializing a zone's record writes

    /// Take the zone's advisory lock for the rest of the transaction.
    ///
    /// The record-write invariants — CNAME exclusivity, the RRset's shared
    /// TTL, the per-zone cap — are all read-then-write and none is expressible
    /// as an index, so they only hold if a zone's writes are serialized.
    /// A transaction-scoped Postgres advisory lock, released on commit or
    /// rollback, and a no-op on any non-Postgres database (like
    /// `IPAMService`'s allocation lock).
    static func lockZone(_ zoneID: UUID, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase, sql.dialect.name == "postgresql" else { return }
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtext(\(bind: "dnszone:\(zoneID.uuidString)")))")
            .run()
    }

    /// Apply one TTL/view to every record in an RRset — see the type doc on
    /// `assertRRsetSettingsAgree` for why the set, not the record, owns them.
    static func applyRRsetSettings(
        zoneID: UUID, name: String, type: DNSRecordType, ttl: Int, view: DNSRecordView,
        on db: any Database
    ) async throws {
        try await DNSRecord.query(on: db)
            .filter(\.$zone.$id == zoneID)
            .filter(\.$name == name)
            .filter(\.$type == type)
            .set(\.$ttl, to: ttl)
            .set(\.$view, to: view)
            .update()
    }

    // MARK: - Authored/derived conflicts

    /// Refuse an authored record that would collide with the zone's derived
    /// records, or break CNAME's exclusivity rule.
    ///
    /// Both checks are at write time on purpose. A silently shadowed record is
    /// the worst outcome available: the API reports a name the resolver never
    /// answers with, and nothing anywhere says why.
    ///
    /// Only creation calls this: a record's name and type are its identity and
    /// are immutable, so the only conflict a value edit can introduce is a
    /// duplicate within one RRset, which the uniqueness index catches.
    static func assertNoConflict(
        zone: DNSZone, name: String, type: DNSRecordType, on db: any Database
    ) async throws {
        let zoneID = try zone.requireID()
        let fqdn = DNSName.qualified(name: name, inZone: zone.name)
        let derived = try await DNSZoneAssembler.derivedNames(zoneID: zoneID, zoneName: zone.name, on: db)
        let derivedTypes = derived[fqdn] ?? []

        if derivedTypes.contains(type) {
            throw Abort(
                .conflict,
                reason: "'\(fqdn)' already has a \(type.rawValue) record derived from a VM on this zone's "
                    + "primary network; rename the VM's hostname or choose another record name")
        }
        // RFC 1034 §3.6.2: a CNAME owner may hold no other data.
        if type == .cname && !derivedTypes.isEmpty {
            throw Abort(
                .conflict,
                reason: "'\(fqdn)' is a VM's derived name and already has address records; a CNAME cannot "
                    + "share an owner name with other data")
        }

        let siblings = try await DNSRecord.query(on: db)
            .filter(\.$zone.$id == zoneID)
            .filter(\.$name == name)
            .all()
        if type == .cname, let other = siblings.first {
            throw Abort(
                .conflict,
                reason: "'\(fqdn)' already has a \(other.type.rawValue) record; a CNAME cannot share an "
                    + "owner name with other data")
        }
        if type != .cname, siblings.contains(where: { $0.type == .cname }) {
            throw Abort(
                .conflict,
                reason: "'\(fqdn)' is a CNAME; a CNAME cannot share an owner name with other data")
        }
    }

    /// Refuse a record whose TTL or view disagrees with the RRset it joins.
    ///
    /// RFC 2181 §5.2: the records of an RRset share one TTL. Nothing in the
    /// schema can express that — the unique index is
    /// `(zone_id, name, type, value)`, so two rows at one `(name, type)` with
    /// different TTLs are storable — and neither planned realization driver
    /// could represent it if they were: OVN keeps one row per name, and a zone
    /// file writes one TTL per RRset. Rejecting here is what keeps the model
    /// from carrying a state its drivers would each have to invent a
    /// resolution for.
    static func assertRRsetSettingsAgree(
        zone: DNSZone, name: String, type: DNSRecordType, ttl: Int, view: DNSRecordView,
        excluding recordID: UUID? = nil, on db: any Database
    ) async throws {
        let zoneID = try zone.requireID()
        var query = DNSRecord.query(on: db)
            .filter(\.$zone.$id == zoneID)
            .filter(\.$name == name)
            .filter(\.$type == type)
        if let recordID {
            query = query.filter(\.$id != recordID)
        }
        guard let sibling = try await query.first() else { return }
        let fqdn = DNSName.qualified(name: name, inZone: zone.name)
        guard sibling.ttl == ttl else {
            throw Abort(
                .conflict,
                reason: "The \(type.rawValue) records at '\(fqdn)' share a TTL of \(sibling.ttl) "
                    + "(RFC 2181 §5.2); pass ttl=\(sibling.ttl), or update the record set's TTL first")
        }
        guard sibling.view == view else {
            throw Abort(
                .conflict,
                reason: "The \(type.rawValue) records at '\(fqdn)' are published to the "
                    + "'\(sibling.view.rawValue)' view; pass view=\(sibling.view.rawValue), or update the "
                    + "record set's view first")
        }
    }

    // MARK: - Hostnames

    /// The zones a VM registers derived records into: the primary zone of
    /// every network it has a NIC on. Usually zero or one.
    static func registrationZones(vmID: UUID, on db: any Database) async throws -> [DNSZone] {
        let networkIDs = try await VMNetworkInterface.query(on: db)
            .filter(\.$vm.$id == vmID)
            .all()
            .map { $0.$logicalNetwork.id }
        guard !networkIDs.isEmpty else { return [] }
        return try await registrationZones(networkIDs: networkIDs, on: db)
    }

    /// The primary zones of a set of networks, deduplicated.
    static func registrationZones(networkIDs: [UUID], on db: any Database) async throws -> [DNSZone] {
        let zoneIDs = try await LogicalNetwork.query(on: db)
            .filter(\.$id ~~ Array(Set(networkIDs)))
            .all()
            .compactMap { $0.$primaryDNSZone.id }
        guard !zoneIDs.isEmpty else { return [] }
        return try await DNSZone.query(on: db).filter(\.$id ~~ Array(Set(zoneIDs))).all()
    }

    /// Whether `hostname` is free in every zone `vmID` registers into.
    ///
    /// Two things can take the name: another VM registering into the same zone
    /// (a derived collision), and an authored record at the same owner name.
    static func hostnameIsAvailable(
        _ hostname: String, forVM vmID: UUID?, in zones: [DNSZone], on db: any Database
    ) async throws -> Bool {
        for zone in zones {
            let zoneID = try zone.requireID()
            let networkIDs = try await LogicalNetwork.query(on: db)
                .filter(\.$primaryDNSZone.$id == zoneID)
                .all()
                .compactMap(\.id)
            if !networkIDs.isEmpty {
                var query = VM.query(on: db)
                    .join(VMNetworkInterface.self, on: \VMNetworkInterface.$vm.$id == \VM.$id)
                    .filter(VMNetworkInterface.self, \.$logicalNetwork.$id ~~ networkIDs)
                    .filter(\.$hostname == hostname)
                if let vmID {
                    query = query.filter(\.$id != vmID)
                }
                if try await query.count() > 0 { return false }
            }
            let authored = try await DNSRecord.query(on: db)
                .filter(\.$zone.$id == zoneID)
                .filter(\.$name == hostname)
                .count()
            if authored > 0 { return false }
        }
        return true
    }

    /// A free hostname for a VM being created, starting from the slug of its
    /// name and suffixing `-2`, `-3`, … until one is available.
    ///
    /// Creation defaults must not fail on a name collision: two VMs called
    /// "web server" in the same project is an ordinary thing to do, and a 409
    /// on VM *create* over an implicit DNS label would be baffling. Explicit
    /// hostname writes are strict instead — there the caller named the value,
    /// so a conflict is worth reporting.
    static func availableHostname(
        basedOn name: String, forVM vmID: UUID?, in zones: [DNSZone], on db: any Database
    ) async throws -> String {
        let base = DNSName.slugify(name)
        guard !zones.isEmpty else { return base }
        if try await hostnameIsAvailable(base, forVM: vmID, in: zones, on: db) { return base }
        for suffix in 2...50 {
            // Keep the result inside the 63-octet label limit by trimming the
            // stem, not the disambiguator — the suffix is the part that makes
            // it unique.
            let tail = "-\(suffix)"
            let stem = String(base.prefix(DNSName.maxLabelLength - tail.count))
            let candidate = stem + tail
            if try await hostnameIsAvailable(candidate, forVM: vmID, in: zones, on: db) { return candidate }
        }
        // Fall back to something that cannot collide rather than failing the
        // create over a name nobody asked for.
        return "vm-" + UUID().uuidString.prefix(8).lowercased()
    }

    /// Refuse a primary-zone assignment that would be born in conflict.
    ///
    /// Making a zone a network's primary retroactively registers every VM
    /// already on that network, so a duplicate hostname among them — or one
    /// that an authored record already owns — becomes a collision the moment
    /// the pointer is set. Catching it here means the invariant "hostnames are
    /// unique within the zones a VM registers into" holds from the assignment
    /// onward, rather than being something assembly quietly papers over.
    static func assertPrimaryZoneAssignable(
        zone: DNSZone, networkID: UUID, on db: any Database
    ) async throws {
        let zoneID = try zone.requireID()

        // Every network that would register into the zone once this one does.
        var networkIDs = try await LogicalNetwork.query(on: db)
            .filter(\.$primaryDNSZone.$id == zoneID)
            .all()
            .compactMap(\.id)
        if !networkIDs.contains(networkID) { networkIDs.append(networkID) }

        let vmIDs = try await VMNetworkInterface.query(on: db)
            .filter(\.$logicalNetwork.$id ~~ networkIDs)
            .all()
            .map { $0.$vm.id }
        var seen: Set<String> = []
        if !vmIDs.isEmpty {
            for vm in try await VM.query(on: db).filter(\.$id ~~ Array(Set(vmIDs))).all() {
                guard let hostname = vm.hostname else { continue }
                guard seen.insert(hostname).inserted else {
                    throw Abort(
                        .conflict,
                        reason: "More than one VM on these networks has the hostname '\(hostname)'; "
                            + "rename one before making '\(zone.name)' their primary zone")
                }
            }
        }
        guard !seen.isEmpty else { return }

        let clashing = try await DNSRecord.query(on: db)
            .filter(\.$zone.$id == zoneID)
            .filter(\.$name ~~ Array(seen))
            .first()
        if let clashing {
            throw Abort(
                .conflict,
                reason: "Zone '\(zone.name)' already has a \(clashing.type.rawValue) record at "
                    + "'\(clashing.name)', which a VM on this network would register as; delete the "
                    + "record or rename the VM first")
        }
    }

    /// Enforce an explicitly requested hostname: valid label, free everywhere
    /// the VM registers.
    static func validatedExplicitHostname(
        _ raw: String, forVM vmID: UUID?, in zones: [DNSZone], on db: any Database
    ) async throws -> String {
        let hostname = try DNSName.normalizedHostname(raw)
        guard try await hostnameIsAvailable(hostname, forVM: vmID, in: zones, on: db) else {
            let zoneNames = zones.map(\.name).sorted().joined(separator: ", ")
            throw Abort(
                .conflict,
                reason: "Hostname '\(hostname)' is already taken in zone(s) \(zoneNames)")
        }
        return hostname
    }
}
