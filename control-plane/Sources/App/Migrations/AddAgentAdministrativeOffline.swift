import Fluent
import SQLKit
import Vapor

struct AddAgentAdministrativeOffline: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw("ALTER TABLE agents ADD COLUMN administratively_offline boolean NOT NULL DEFAULT false").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Agent.schema).deleteField("administratively_offline").update()
    }
}
