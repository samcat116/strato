import Fluent
import SQLKit
import Vapor

/// Seeds DNS resolvers onto the "default" network (issue #518).
///
/// `CreateLogicalNetwork` predates the `dns_servers` column, so the seeded
/// default network came up with no resolvers at all. DHCP is enabled on it, so
/// guests got an address and a gateway but no DNS server option — name
/// resolution silently failed on every fresh install until an operator PUT
/// `dnsServers` themselves. The network already defaults to
/// `external_access = true`, so a public resolver matches the intent.
///
/// Only fills a network that has none: an operator (or an earlier run of this
/// migration on a rolled-back database) who already chose resolvers keeps them.
/// Overrides: `STRATO_DEFAULT_NETWORK_DNS_SERVERS` supplies a comma-separated
/// list; setting it to an empty string opts out of seeding entirely.
///
/// No generation bump — `generation` tracks L3 realization (subnet, gateway,
/// external access), and DHCP/DNS-only edits deliberately leave it alone (see
/// `NetworkController.updateNetwork`). Agents pick the new options up on the
/// next periodic desired-state sync, and guests on their next lease renew.
struct SeedDefaultNetworkDNS: AsyncMigration {
    /// Public resolvers used when the operator didn't configure any. Two
    /// providers rather than two addresses from one, so a single provider
    /// outage doesn't take resolution down.
    static let fallbackResolvers = ["1.1.1.1", "8.8.8.8"]

    func prepare(on database: Database) async throws {
        let configured = Environment.get("STRATO_DEFAULT_NETWORK_DNS_SERVERS")
        if configured?.isEmpty == true {
            return
        }

        let resolvers: [String]
        if let configured {
            // Validate here, where the failure is a clear startup error naming
            // the bad env var (same rationale as CreateLogicalNetwork).
            let parsed = configured.split(separator: ",").map(String.init)
            do {
                resolvers = try NetworkController.validatedDNS(parsed)
            } catch {
                throw Abort(
                    .internalServerError,
                    reason: "STRATO_DEFAULT_NETWORK_DNS_SERVERS is not a comma-separated list of "
                        + "IP addresses: \(configured)")
            }
            guard !resolvers.isEmpty else { return }
        } else {
            resolvers = Self.fallbackResolvers
        }

        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "SeedDefaultNetworkDNS requires an SQL database")
        }
        // Raw SQL keeps this pinned to today's columns (see CreateLogicalNetwork).
        // Read-then-write rather than a NULL-or-empty predicate: the stored form
        // is a comma-separated string, and `LogicalNetwork.splitDNS` is the one
        // definition of "has no resolvers" (it also treats "," and " " as empty).
        guard
            let row = try await sql.select()
                .column("dns_servers")
                .from("logical_networks")
                .where("name", .equal, SQLBind(LogicalNetwork.defaultNetworkName))
                .first(decoding: DNSRow.self),
            LogicalNetwork.splitDNS(row.dnsServers).isEmpty
        else { return }

        try await sql.update("logical_networks")
            .set("dns_servers", to: SQLBind(resolvers.joined(separator: ",")))
            .where("name", .equal, SQLBind(LogicalNetwork.defaultNetworkName))
            .run()
    }

    private struct DNSRow: Decodable {
        let dnsServers: String?

        enum CodingKeys: String, CodingKey {
            case dnsServers = "dns_servers"
        }
    }

    /// The column belongs to `AddDHCPConfigToLogicalNetwork`; this migration
    /// only wrote a value into it, and clearing an operator's resolvers on
    /// revert would be worse than leaving them.
    func revert(on database: Database) async throws {}
}
