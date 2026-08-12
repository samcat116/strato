import Fluent
import SQLKit

/// Adds the mutable metadata STR-66 publishes to a running VM.
///
/// Existing single-key rows are copied into the plural key list. The legacy
/// column remains as a rolling-upgrade/rollback projection and is mirrored by
/// every new write; removing it requires its own compatibility window.
struct AddMutableMetadataToVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        let emptyArrayDefault =
            (database as? any SQLDatabase)?.dialect.name == "postgresql"
            ? "DEFAULT '{}'"
            : "DEFAULT '[]'"

        try await database.schema(VM.schema)
            .field("tags", .json, .required, .custom("DEFAULT '{}'"))
            .field(
                "ssh_authorized_keys", .array(of: .string), .required,
                .custom(emptyArrayDefault)
            )
            .update()

        guard let sql = database as? any SQLDatabase else { return }
        if sql.dialect.name == "postgresql" {
            try await sql.raw(
                """
                UPDATE vms
                SET ssh_authorized_keys = ARRAY[ssh_public_key]
                WHERE ssh_public_key IS NOT NULL
                """
            ).run()
        } else {
            try await sql.raw(
                """
                UPDATE vms
                SET ssh_authorized_keys = json_array(ssh_public_key)
                WHERE ssh_public_key IS NOT NULL
                """
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema(VM.schema)
            .deleteField("ssh_authorized_keys")
            .deleteField("tags")
            .update()
    }
}
