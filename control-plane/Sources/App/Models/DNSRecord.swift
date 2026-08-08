import Fluent
import Vapor

/// The record types the model can carry.
///
/// Deliberately wider than any realization driver: the OVN `DNS` table
/// answers A/AAAA/PTR only, and a link-local CoreDNS (roadmap phase 4) is what
/// makes the rest resolvable. Drivers reject what they cannot do with a clear
/// error rather than the model pretending those records don't exist — an
/// operator authoring a `TXT` before phase 4 lands should get "no backend on
/// this network realizes TXT yet", not a validation error that implies Strato
/// will never support it.
enum DNSRecordType: String, Codable, Sendable, CaseIterable {
    case a = "A"
    case aaaa = "AAAA"
    case cname = "CNAME"
    case txt = "TXT"
    case srv = "SRV"
    case ptr = "PTR"
}

/// Which side of a split horizon a record belongs to.
///
/// Carried from phase 1 so split-horizon is not a retrofit onto a column that
/// doesn't exist. Nothing consumes it until external publication (roadmap
/// phase 6); until then every record is served internally regardless.
enum DNSRecordView: String, Codable, Sendable, CaseIterable {
    /// Served only to VMs inside the overlay.
    case `internal`
    /// Published only to the operator's external DNS.
    case external
    /// Both — the default, and what every record is until phase 6.
    case both
}

/// A user-authored DNS record.
///
/// The other half of a zone's contents is *derived* — VM hostname → allocated
/// addresses, plus the matching PTR — which is assembled on demand and never
/// stored (`DNSZoneAssembler`). Authored records are the tier where CNAME,
/// TXT, and SRV live, matching what OpenStack Designate and Proxmox's
/// PowerDNS plugin both do: auto-generate only A and PTR, and let operators
/// write the rest.
final class DNSRecord: Model, @unchecked Sendable {
    static let schema = "dns_records"

    /// Default TTL when a record doesn't set one. Five minutes: long enough to
    /// be worth caching, short enough that a correction propagates within a
    /// coffee break.
    static let defaultTTL = 300

    /// TTL bounds. Zero is legal DNS ("do not cache") but a footgun against
    /// resolvers that treat it as a busy loop, and a year is the practical
    /// ceiling every implementation agrees on.
    static let ttlRange = 1...31_536_000

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "zone_id")
    var zone: DNSZone

    /// Owner name relative to the zone, or `@` for the apex. Lowercased at
    /// write time; `DNSName.qualified(name:inZone:)` renders the FQDN.
    @Field(key: "name")
    var name: String

    @Enum(key: "type")
    var type: DNSRecordType

    /// The record's RDATA in zone-file text form: an address for A/AAAA, a
    /// target name for CNAME/PTR, the quoted-string contents for TXT, and
    /// `priority weight port target` for SRV.
    @Field(key: "value")
    var value: String

    @Field(key: "ttl")
    var ttl: Int

    @Enum(key: "view")
    var view: DNSRecordView

    @OptionalParent(key: "created_by_id")
    var createdBy: User?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        zoneID: UUID,
        name: String,
        type: DNSRecordType,
        value: String,
        ttl: Int = DNSRecord.defaultTTL,
        view: DNSRecordView = .both,
        createdByID: UUID? = nil
    ) {
        self.id = id
        self.$zone.id = zoneID
        self.name = name
        self.type = type
        self.value = value
        self.ttl = ttl
        self.view = view
        self.$createdBy.id = createdByID
    }
}

extension DNSRecord: Content {}

// MARK: - Request/Response DTOs

struct CreateDNSRecordRequest: Content, ValidatedRequestBody {
    /// Owner name relative to the zone; `@` (or omitted) means the apex.
    let name: String?
    let type: DNSRecordType
    let value: String
    /// Defaults to `DNSRecord.defaultTTL`.
    let ttl: Int?
    /// Defaults to `both`.
    let view: DNSRecordView?

    init(
        name: String? = nil, type: DNSRecordType, value: String, ttl: Int? = nil,
        view: DNSRecordView? = nil
    ) {
        self.name = name
        self.type = type
        self.value = value
        self.ttl = ttl
        self.view = view
    }

    /// Bounded, not normalized (STR-198). Both fields have a parser downstream
    /// and it owns their shape; this is the floor underneath it, applied before
    /// the parser does O(n) work on a value it will refuse anyway.
    ///
    /// `name` takes `Validate.text` rather than `Validate.name` because empty is
    /// meaningful here — `DNSName.normalizedRecordName` reads `""` as the apex,
    /// the same as `@` — so the non-empty rule that comes with a "required name"
    /// would turn a documented spelling into a `400`. Its ceiling is the
    /// grammar's, for the reason given on `CreateDNSZoneRequest.validate()`.
    ///
    /// `value` takes `Validate.textLength`, which is deliberately looser than
    /// anything `DNSZoneService.validatedValue` accepts (255 bytes for TXT, a
    /// domain name for CNAME/PTR/SRV, a parsed address for A/AAAA). A second
    /// content-shaped number would be the drift this whole helper exists to
    /// avoid; what this pins is the same ceiling the `dns_records.value` column
    /// carries, so the API and the backstop agree.
    mutating func validate() throws {
        try Validate.text(name, "name", max: DNSName.maxNameLength)
        try Validate.text(value, "value")
    }
}

struct UpdateDNSRecordRequest: Content, ValidatedRequestBody {
    let value: String?
    let ttl: Int?
    let view: DNSRecordView?

    init(value: String? = nil, ttl: Int? = nil, view: DNSRecordView? = nil) {
        self.value = value
        self.ttl = ttl
        self.view = view
    }

    /// The same ceiling on the same field as the create path — a record's name
    /// and type are its identity and are immutable, so `value` is the only text
    /// an update carries.
    mutating func validate() throws {
        try Validate.text(value, "value")
    }
}

struct DNSRecordResponse: Content {
    let id: UUID
    let zoneId: UUID
    /// The owner name as authored, relative to the zone (`@` for the apex).
    let name: String
    /// The same name fully qualified — what a resolver actually answers on.
    let fqdn: String
    let type: DNSRecordType
    let value: String
    let ttl: Int
    let view: DNSRecordView
    let createdAt: Date?
    let updatedAt: Date?

    init(from record: DNSRecord, zoneName: String) throws {
        self.id = try record.requireID()
        self.zoneId = record.$zone.id
        self.name = record.name
        self.fqdn = DNSName.qualified(name: record.name, inZone: zoneName)
        self.type = record.type
        self.value = record.value
        self.ttl = record.ttl
        self.view = record.view
        self.createdAt = record.createdAt
        self.updatedAt = record.updatedAt
    }
}
