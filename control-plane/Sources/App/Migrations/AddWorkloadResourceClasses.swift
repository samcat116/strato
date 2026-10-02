import Fluent

/// Optional snapshots preserve existing guaranteed behavior without repricing rows.
struct AddWorkloadResourceClasses: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agents").field("resource_class_enforcement", .json).update()
        try await database.schema("agents").field("available_cpu_micro_units", .int64).update()
        try await database.schema("sites").field("burstable_resource_class", .json).update()
        try await database.schema("vms").field("admitted_reservation", .json).update()
        try await database.schema("sandboxes").field("admitted_reservation", .json).update()
        try await database.schema("vms").field("resource_class", .json).update()
        try await database.schema("sandboxes").field("resource_class", .json).update()
    }
    func revert(on database: Database) async throws {
        try await database.schema("agents").deleteField("resource_class_enforcement").update()
        try await database.schema("agents").deleteField("available_cpu_micro_units").update()
        try await database.schema("vms").deleteField("admitted_reservation").update()
        try await database.schema("sandboxes").deleteField("admitted_reservation").update()
        try await database.schema("sandboxes").deleteField("resource_class").update()
        try await database.schema("vms").deleteField("resource_class").update()
        try await database.schema("sites").deleteField("burstable_resource_class").update()
    }
}
