import Fluent
import Foundation
import SQLKit

/// Durable per-NIC convergence state for STR-202.
struct AddVMNetworkInterfaceLifecycle: AsyncMigration {
    static let orderIndex = "uniq_vm_network_interfaces_vm_id_order_index"

    struct Row: Decodable {
        let id: UUID
        let vmID: UUID
        let orderIndex: Int
        let deviceName: String

        enum CodingKeys: String, CodingKey {
            case id
            case vmID = "vm_id"
            case orderIndex = "order_index"
            case deviceName = "device_name"
        }
    }

    struct Repair: Equatable {
        let id: UUID
        let orderIndex: Int
        let deviceName: String
    }

    static func repairs(for rows: [Row]) -> [Repair] {
        var used: [UUID: Set<Int>] = [:]
        var repairs: [Repair] = []
        for row in rows {
            var indexes = used[row.vmID] ?? []
            var resolved = max(0, row.orderIndex)
            if indexes.contains(resolved) {
                resolved = 0
                while indexes.contains(resolved) { resolved += 1 }
            }
            indexes.insert(resolved)
            used[row.vmID] = indexes
            let deviceName = "net\(resolved)"
            guard resolved != row.orderIndex || row.deviceName != deviceName else { continue }
            repairs.append(Repair(id: row.id, orderIndex: resolved, deviceName: deviceName))
        }
        return repairs
    }

    func prepare(on database: any Database) async throws {
        try await database.schema(VMNetworkInterface.schema)
            .field("attach_generation", .int64)
            .field("detach_generation", .int64)
            .update()

        guard let sql = database as? any SQLDatabase else { return }
        let rows = try await sql.raw(
            """
            SELECT id, vm_id, order_index, device_name
            FROM vm_network_interfaces
            ORDER BY vm_id, order_index, device_name, id
            """
        ).all(decoding: Row.self)

        let repairs = Self.repairs(for: rows)

        // `(vm_id, device_name)` is already unique. Move every row that needs
        // repair to a per-row temporary name first, so a swapped or shifted
        // legacy layout cannot collide halfway through normalization.
        for repair in repairs {
            try await sql.raw(
                "UPDATE vm_network_interfaces SET device_name = \(bind: "__str202_\(repair.id.uuidString)") WHERE id = \(bind: repair.id)"
            ).run()
        }
        for repair in repairs {
            try await sql.raw(
                "UPDATE vm_network_interfaces SET order_index = \(bind: repair.orderIndex), device_name = \(bind: repair.deviceName) WHERE id = \(bind: repair.id)"
            ).run()
        }

        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS \(unsafeRaw: Self.orderIndex)
            ON vm_network_interfaces (vm_id, order_index)
            """
        ).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: Self.orderIndex)").run()
        }
        try await database.schema(VMNetworkInterface.schema)
            .deleteField("detach_generation")
            .deleteField("attach_generation")
            .update()
    }
}
