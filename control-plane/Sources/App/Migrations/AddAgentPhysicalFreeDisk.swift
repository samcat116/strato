import Fluent
import SQLKit

struct AddAgentPhysicalFreeDisk: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            preconditionFailure("AddAgentPhysicalFreeDisk requires SQLKit")
        }
        try await sql.raw(
            """
            ALTER TABLE agents
            ADD COLUMN physical_free_disk bigint
            """
        ).run()
        try await sql.raw(
            """
            UPDATE agents
            SET physical_free_disk = available_disk
            WHERE physical_free_disk IS NULL
            """
        ).run()
        try await sql.raw(
            """
            ALTER TABLE agents
            ALTER COLUMN physical_free_disk SET NOT NULL
            """
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            preconditionFailure("AddAgentPhysicalFreeDisk requires SQLKit")
        }
        try await sql.raw(
            """
            ALTER TABLE agents
            DROP COLUMN physical_free_disk
            """
        ).run()
    }
}
