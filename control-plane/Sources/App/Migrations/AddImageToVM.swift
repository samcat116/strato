import Fluent

struct AddImageToVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Add optional image_id foreign key to VMs table
        try await database.schema("vms")
            .field("image_id", .uuid, .references("images", "id", onDelete: .setNull))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vms")
            .deleteField("image_id")
            .update()
    }
}
