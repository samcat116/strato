import Fluent
import SQLKit

/// Re-keys NIC and address rows from the logical network's *name* to its id
/// (issue #765).
///
/// Names were a global namespace precisely because these four tables referenced
/// them: `vm_network_interfaces.network`, `sandbox_network_interfaces.network`,
/// and the two address tables whose IPAM uniqueness indexes were `(network,
/// address)`. Nothing enforced referential integrity, so deleting a network left
/// NIC rows pointing at a string with no row behind it. With a real FK the
/// reference is checked, and per-project name scoping
/// (`ScopeLogicalNetworksToProjects`) becomes possible.
///
/// **This migration destroys every NIC and every allocated address.** Existing
/// VMs and sandboxes come out with no interfaces and must be recreated. That is
/// deliberate: the alternative — mapping each row through the name that is
/// unique only at this instant in migration history — would leave the rows
/// pointing at the global `default` network that the next migration deletes.
/// Deployments carrying live VMs are not upgradable across this change.
struct RekeyInterfacesToLogicalNetworkID: AsyncMigration {
    struct UnsupportedDatabase: Error {}

    /// Tables whose `network` name column becomes a `logical_network_id` FK.
    private static let rekeyedTables = [
        "vm_network_interfaces",
        "sandbox_network_interfaces",
        "vm_interface_addresses",
        "sandbox_interface_addresses",
    ]

    /// Indexes this migration creates, so `revert` drops exactly what `prepare`
    /// made and a test can assert the migrated schema carries them.
    static let indexes: [(name: String, definition: String)] = [
        // Replaces the `(network, address)` indexes: the only backstop against
        // two concurrent allocations landing on the same address, now that a
        // network's pool is identified by id rather than by name.
        (
            "uq_vm_interface_addresses_network_address",
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_vm_interface_addresses_network_address "
                + "ON vm_interface_addresses (logical_network_id, address)"
        ),
        (
            "uq_sandbox_interface_addresses_network_address",
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_sandbox_interface_addresses_network_address "
                + "ON sandbox_interface_addresses (logical_network_id, address)"
        ),
        // Logical-network delete/rename in-use guards, which now count sandbox
        // NICs too. Replaces `idx_vm_network_interfaces_network`
        // (`AddHotPathIndexes`), whose column is dropped here.
        (
            "idx_vm_network_interfaces_logical_network_id",
            "CREATE INDEX IF NOT EXISTS idx_vm_network_interfaces_logical_network_id "
                + "ON vm_network_interfaces (logical_network_id)"
        ),
        (
            "idx_sandbox_network_interfaces_logical_network_id",
            "CREATE INDEX IF NOT EXISTS idx_sandbox_network_interfaces_logical_network_id "
                + "ON sandbox_network_interfaces (logical_network_id)"
        ),
    ]

    /// The name-keyed indexes this migration removes, with the definitions
    /// `revert` restores them from.
    private static let legacyIndexes: [(name: String, definition: String)] = [
        (
            "idx_vm_interface_addresses_network_address",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_vm_interface_addresses_network_address "
                + "ON vm_interface_addresses (network, address)"
        ),
        (
            "idx_sandbox_interface_addresses_network_address",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_sandbox_interface_addresses_network_address "
                + "ON sandbox_interface_addresses (network, address)"
        ),
        (
            "idx_vm_network_interfaces_network",
            "CREATE INDEX IF NOT EXISTS idx_vm_network_interfaces_network ON vm_network_interfaces (network)"
        ),
    ]

    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { throw UnsupportedDatabase() }

        try await Self.purgeInterfaceRows(on: sql)

        // Indexes before their columns: dropping them explicitly keeps `revert`
        // symmetric rather than relying on Postgres's implicit cleanup.
        for index in Self.legacyIndexes {
            try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: index.name)").run()
        }

        for table in Self.rekeyedTables {
            try await sql.raw("ALTER TABLE \(ident: table) DROP COLUMN \(ident: "network")").run()
            // NOT NULL needs no default: the tables were just emptied.
            try await sql.raw(
                """
                ALTER TABLE \(ident: table) ADD COLUMN \(ident: "logical_network_id") uuid NOT NULL
                REFERENCES logical_networks (id) ON DELETE RESTRICT
                """
            ).run()
        }

        for index in Self.indexes {
            try await sql.raw("\(unsafeRaw: index.definition)").run()
        }
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { throw UnsupportedDatabase() }

        // Same purge as `prepare`: the restored `network` column is NOT NULL and
        // a name cannot be recovered from an id whose network row may be gone.
        try await Self.purgeInterfaceRows(on: sql)

        for index in Self.indexes {
            try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: index.name)").run()
        }

        for table in Self.rekeyedTables {
            try await sql.raw("ALTER TABLE \(ident: table) DROP COLUMN \(ident: "logical_network_id")").run()
            try await sql.raw("ALTER TABLE \(ident: table) ADD COLUMN \(ident: "network") text NOT NULL").run()
        }

        for index in Self.legacyIndexes {
            try await sql.raw("\(unsafeRaw: index.definition)").run()
        }
    }

    /// Empties every table that references a logical network by name, children
    /// first. Floating IPs point at a NIC with `ON DELETE SET NULL`, but the
    /// detach is written explicitly so the intent is visible rather than a side
    /// effect of the cascade.
    private static func purgeInterfaceRows(on sql: SQLDatabase) async throws {
        try await sql.raw("UPDATE floating_ips SET interface_id = NULL").run()
        for table in [
            "vm_interface_addresses",
            "sandbox_interface_addresses",
            "vm_interface_observed_addresses",
            "vm_interface_security_groups",
            "vm_network_interfaces",
            "sandbox_network_interfaces",
        ] {
            try await sql.raw("DELETE FROM \(ident: table)").run()
        }
    }
}
