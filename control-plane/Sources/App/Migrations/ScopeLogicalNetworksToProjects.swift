import Fluent
import SQLKit

/// Makes every logical network belong to exactly one project, and scopes name
/// uniqueness to `(project_id, name)` (issue #765).
///
/// Project-less ("global") networks existed only because `CreateLogicalNetwork`
/// seeded one `default` network for every deployment to share. That shared
/// switch was the multi-tenancy hole this issue closes: one L2 domain and one IP
/// pool for all tenants, so exhausting the subnet was a cross-tenant denial of
/// service and the tenant boundary rested entirely on security-group rules.
///
/// With the concept gone, two projects can each own a network named `default`,
/// and a create collision no longer discloses another tenant's network names.
/// The seeded global network — and the role bindings granted on it — are deleted
/// here; `RekeyInterfacesToLogicalNetworkID` has already removed every NIC that
/// could have referenced it.
struct ScopeLogicalNetworksToProjects: AsyncMigration {
    struct UnsupportedDatabase: Error {}

    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { throw UnsupportedDatabase() }

        // Bindings first: `role_bindings` has no FK to the network row (nodes are
        // polymorphic), so deleting the networks would strand them as grants on
        // an id nobody can resolve.
        try await sql.raw(
            """
            DELETE FROM role_bindings
            WHERE node_type = 'network'
              AND node_id IN (SELECT id FROM logical_networks WHERE project_id IS NULL)
            """
        ).run()
        try await sql.raw("DELETE FROM logical_networks WHERE project_id IS NULL").run()

        try await sql.raw("ALTER TABLE logical_networks ALTER COLUMN project_id SET NOT NULL").run()

        try await database.schema("logical_networks")
            .deleteUnique(on: "name")
            .unique(on: "project_id", "name")
            .update()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { throw UnsupportedDatabase() }

        // Restoring global uniqueness fails if two projects took the same name
        // while this migration was applied — which is exactly the state it
        // exists to allow. A revert on such a database errors rather than
        // silently dropping one tenant's network.
        try await database.schema("logical_networks")
            .deleteUnique(on: "project_id", "name")
            .unique(on: "name")
            .update()

        try await sql.raw("ALTER TABLE logical_networks ALTER COLUMN project_id DROP NOT NULL").run()
    }
}
