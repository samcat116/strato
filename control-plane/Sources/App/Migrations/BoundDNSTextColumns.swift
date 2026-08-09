import Fluent
import Foundation

/// STR-198: the same storage-layer backstop `BoundResourceTextColumns` gave the
/// workload and hierarchy tables, for the four DNS columns the STR-195 cut left
/// out.
///
/// A follow-on migration rather than four more entries in that one's list,
/// because it has already run: a deployment upgrading into this build has the
/// constraint set it installed, and Fluent will not re-run a migration whose
/// name it has recorded. Adding columns there would bound them on a fresh
/// database and silently not on an existing one — the one place a backstop
/// cannot be conditional. The mechanism is shared (`BoundResourceTextColumns.bound`),
/// so this is a list of columns and nothing else.
///
/// These are the DNS model's text columns, and the reason they are worth
/// bounding is that none of them stays in the database. `DNSZoneAssembler`
/// unions authored records with derived ones; the topology authority realizes
/// the A/AAAA/PTR subset into the OVN `DNS` table referenced from
/// `Logical_Switch.dns_records`, comparing a `recordsHash` in `external_ids` on
/// every reconcile; and since STR-40 a per-network CoreDNS serves the rest.
///
/// The limits come from the same two places the request boundary takes them:
/// `DNSName.maxNameLength` for the two names, which is RFC 1035's 253 and the
/// ceiling `DNSName` has always enforced, and `Validate.textLength` for the
/// zone description and the record value. The latter is deliberately looser
/// than any RDATA `DNSZoneService.validatedValue` accepts — a backstop that
/// refused something the API allows would turn a caller's success into a `500`,
/// which is the failure mode this arrangement exists to avoid.
struct BoundDNSTextColumns: AsyncMigration {
    static let columns: [BoundResourceTextColumns.BoundedColumn] = [
        .init(table: "dns_zones", column: "name", limit: DNSName.maxNameLength),
        .init(table: "dns_zones", column: "description", limit: Validate.textLength),
        .init(table: "dns_records", column: "name", limit: DNSName.maxNameLength),
        .init(table: "dns_records", column: "value", limit: Validate.textLength),
    ]

    func prepare(on database: Database) async throws {
        try await BoundResourceTextColumns.bound(Self.columns, on: database)
    }

    func revert(on database: Database) async throws {
        try await BoundResourceTextColumns.unbound(Self.columns, on: database)
    }
}
