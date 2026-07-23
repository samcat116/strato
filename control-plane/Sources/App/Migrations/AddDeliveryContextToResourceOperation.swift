import Fluent

/// Webhook delivery context captured at operation-begin time (issue #559,
/// PR #668 review): `operation.completed`/`operation.failed` events resolve
/// their organization/project/name from these columns, so a delete operation
/// can still be announced after the resource row it removed is gone.
///
/// Plain columns, no foreign keys — like `resource_id`, they must outlive the
/// rows they point at. Nullable because pre-existing operations (and the rare
/// direct-construction sites) lack them; those fall back to resolving from
/// the live resource row.
struct AddDeliveryContextToResourceOperation: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("resource_operations")
            .field("organization_id", .uuid)
            .field("project_id", .uuid)
            .field("resource_name", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("resource_operations")
            .deleteField("organization_id")
            .deleteField("project_id")
            .deleteField("resource_name")
            .update()
    }
}
