import Fluent
import Foundation
import Logging
import SQLKit
import StratoShared

/// Read-only inspection of the two workload-interface tables.
///
/// A MAC collision is fleet-scoped rather than logical-network-scoped: two
/// networks may meet on the same localnet uplink, so the audit deliberately
/// unions every VM and sandbox interface in the deployment.
enum MACAddressAudit {
    struct Assignment: Equatable, Sendable {
        let interfaceKind: String
        let interfaceID: UUID
        let storedMACAddress: String

        var canonicalMACAddress: String? {
            MACAddress(storedMACAddress)?.description
        }

        var label: String {
            "\(interfaceKind):\(interfaceID.uuidString)"
        }
    }

    struct Duplicate: Equatable, Sendable {
        let macAddress: String
        let assignments: [Assignment]
    }

    static func assignments(on database: any Database) async throws -> [Assignment] {
        guard let sql = database as? any SQLDatabase else {
            throw MACAddressAuditError.sqlDatabaseRequired
        }
        let rows = try await sql.raw(
            """
            SELECT 'vm' AS interface_kind, id AS interface_id, mac_address
            FROM vm_network_interfaces
            UNION ALL
            SELECT 'sandbox' AS interface_kind, id AS interface_id, mac_address
            FROM sandbox_network_interfaces
            ORDER BY interface_kind, interface_id
            """
        ).all()
        return try rows.map { row in
            Assignment(
                interfaceKind: try row.decode(column: "interface_kind", as: String.self),
                interfaceID: try row.decode(column: "interface_id", as: UUID.self),
                storedMACAddress: try row.decode(column: "mac_address", as: String.self)
            )
        }
    }

    /// Returns only assignments whose normalized address occurs more than once.
    /// PostgreSQL performs the fleet-wide grouping so the recurring startup
    /// audit does not transfer or retain the ordinary unique-address inventory.
    static func duplicateAssignments(on database: any Database) async throws -> [Assignment] {
        guard let sql = database as? any SQLDatabase else {
            throw MACAddressAuditError.sqlDatabaseRequired
        }
        let rows = try await sql.raw(
            """
            WITH assignments AS (
                SELECT 'vm' AS interface_kind, id AS interface_id,
                       mac_address, lower(mac_address) AS normalized_mac_address
                FROM vm_network_interfaces
                UNION ALL
                SELECT 'sandbox' AS interface_kind, id AS interface_id,
                       mac_address, lower(mac_address) AS normalized_mac_address
                FROM sandbox_network_interfaces
            ), duplicate_addresses AS (
                SELECT normalized_mac_address
                FROM assignments
                GROUP BY normalized_mac_address
                HAVING count(*) > 1
            )
            SELECT assignments.interface_kind, assignments.interface_id,
                   assignments.mac_address
            FROM assignments
            INNER JOIN duplicate_addresses USING (normalized_mac_address)
            ORDER BY assignments.interface_kind, assignments.interface_id
            """
        ).all()
        return try rows.map { row in
            Assignment(
                interfaceKind: try row.decode(column: "interface_kind", as: String.self),
                interfaceID: try row.decode(column: "interface_id", as: UUID.self),
                storedMACAddress: try row.decode(column: "mac_address", as: String.self)
            )
        }
    }

    static func duplicates(in assignments: [Assignment]) -> [Duplicate] {
        Dictionary(
            grouping: assignments.compactMap { assignment in
                assignment.canonicalMACAddress.map { ($0, assignment) }
            }, by: { $0.0 }
        )
        .compactMap { macAddress, entries in
            let assignments = entries.map(\.1)
            guard assignments.count > 1 else { return nil }
            return Duplicate(
                macAddress: macAddress,
                assignments: assignments.sorted { $0.label < $1.label })
        }
        .sorted { $0.macAddress < $1.macAddress }
    }

    static func invalidAssignments(in assignments: [Assignment]) -> [Assignment] {
        assignments.filter { $0.canonicalMACAddress == nil }
    }

    /// Runs after migrations on every normal boot. It also runs in the
    /// migration-error path: a legacy duplicate makes the ledger migration
    /// fail closed, but still gets a named warning and metric before startup
    /// exits instead of surfacing only as an opaque unique-index error.
    static func warnAboutDuplicates(on database: any Database, logger: Logger) async throws {
        let duplicates = duplicates(in: try await duplicateAssignments(on: database))
        Telemetry.recordDuplicateMACAddressGroups(duplicates.count)
        for duplicate in duplicates {
            logger.warning(
                "Duplicate workload NIC MAC address detected; affected guests may silently lose L2 traffic",
                metadata: [
                    "macAddress": .string(duplicate.macAddress),
                    "interfaces": .array(duplicate.assignments.map { .string($0.label) }),
                    "remediation": .string("renumber one interface during a planned guest reconfiguration"),
                ]
            )
        }
    }
}

private enum MACAddressAuditError: Error {
    case sqlDatabaseRequired
}
