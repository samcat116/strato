import Fluent
import Foundation
import SQLKit

/// Adds the gateway denormalized onto each NIC row at allocation time (so spec
/// building needs no network lookup), and a unique index guarding control-plane
/// IPAM against two concurrent creates allocating the same address on one
/// network. NULL ip_address rows are exempt on both PostgreSQL and SQLite.
struct AddGatewayToVMNetworkInterface: AsyncMigration {
    /// Point-in-time mapping of `vm_network_interfaces` with only the columns
    /// this migration touches, so later model changes cannot break it (see
    /// `MigrateVMNetworkConfigToInterfaces` for the same pattern).
    private final class InterfaceRow: Model, @unchecked Sendable {
        static let schema = "vm_network_interfaces"

        @ID(key: .id)
        var id: UUID?

        @Field(key: "network")
        var network: String

        @OptionalField(key: "ip_address")
        var ipAddress: String?

        @Timestamp(key: "created_at", on: .none)
        var createdAt: Date?

        init() {}
    }

    func prepare(on database: Database) async throws {
        // Single action per update() call: SQLite cannot combine multiple
        // ALTER TABLE actions in one statement.
        try await database.schema("vm_network_interfaces")
            .field("gateway", .string)
            .update()

        // Legacy data can violate the uniqueness this migration introduces:
        // `MigrateVMNetworkConfigToInterfaces` copied each VM's legacy
        // ip_address verbatim onto a NIC on the "default" network, and nothing
        // ever enforced that those per-VM values were distinct. Building the
        // unique index over such duplicates would throw and crash-loop startup,
        // so clear the duplicates first (oldest row keeps its address; the
        // others fall back to address-less NICs, exactly what pre-IPAM agents
        // handled anyway).
        let rows = try await InterfaceRow.query(on: database)
            .filter(\.$ipAddress != nil)
            .all()
            .sorted {
                ($0.createdAt ?? .distantPast, $0.id?.uuidString ?? "")
                    < ($1.createdAt ?? .distantPast, $1.id?.uuidString ?? "")
            }

        var seen: Set<String> = []
        var cleared = 0
        for row in rows {
            guard let ipAddress = row.ipAddress else { continue }
            let key = "\(row.network)|\(ipAddress)"
            if seen.insert(key).inserted { continue }
            row.ipAddress = nil
            try await row.save(on: database)
            cleared += 1
        }
        if cleared > 0 {
            database.logger.warning(
                "Cleared duplicate NIC IP addresses before enforcing per-network uniqueness",
                metadata: ["cleared": .stringConvertible(cleared)])
        }

        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_vm_network_interfaces_network_ip "
                    + "ON vm_network_interfaces (network, ip_address)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_vm_network_interfaces_network_ip").run()
        }
        try await database.schema("vm_network_interfaces")
            .deleteField("gateway")
            .update()
    }
}
