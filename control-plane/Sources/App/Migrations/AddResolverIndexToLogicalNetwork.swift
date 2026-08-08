import Fluent
import SQLKit

/// Gives each resolver-enabled network its own link-local address pair, by
/// storing the index both addresses derive from (STR-40).
///
/// This is what moves the resolver out of the network's chassis namespace and
/// into the host's. A namespace-terminated resolver could share one well-known
/// address across every network, because the namespace said which network was
/// asking — but it had no egress the OVN router would SNAT, so it could answer
/// for its own zones and forward nothing, which is the bug the phase exists to
/// fix. In the host namespace forwarding is the hypervisor's own, and the
/// distinct address is what replaces the namespace as the thing that identifies
/// the network.
///
/// Nullable rather than backfilled: an index is allocated the first time a
/// network's resolver is enabled, and the column stays null for every network
/// that never wants one. The unique index is what makes the allocator's
/// read-then-write safe against a racing transaction the advisory lock did not
/// cover — a partial index, so the many nulls do not contend.
struct AddResolverIndexToLogicalNetwork: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("logical_networks")
            .field("resolver_index", .int)
            .update()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS logical_networks_resolver_index_key
            ON logical_networks (resolver_index)
            WHERE resolver_index IS NOT NULL
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS logical_networks_resolver_index_key").run()
        }
        try await database.schema("logical_networks").deleteField("resolver_index").update()
    }
}
