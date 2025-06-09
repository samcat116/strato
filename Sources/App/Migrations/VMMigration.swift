import Fluent
import Vapor

struct CreateVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("vms")
            .id()
            .field("name", .string)
            .field("description", .string)
            .field("image", .string)
            .field("cpu", .int)
            .field("memory", .int)
            .field("disk", .int)

            .create()
    }

    // Optionally reverts the changes made in the prepare method.
    func revert(on database: Database) async throws {
        try await database.schema("vms").delete()
    }
}
