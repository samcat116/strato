import Fluent
import Foundation

/// Adds caller-supplied cloud-init user data to VMs. Nullable: VMs created
/// without user data (or before this migration) get only Strato's built-in
/// provisioning config. `.sql(.text)` because payloads are multi-kilobyte
/// documents, not short strings.
struct AddUserDataToVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("vms")
            .field("user_data", .sql(.text))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vms")
            .deleteField("user_data")
            .update()
    }
}
