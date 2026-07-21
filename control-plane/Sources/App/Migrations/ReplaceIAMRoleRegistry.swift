import Fluent
import Foundation
import SQLKit

/// IAM roles/policies authoring, phase 1 (issue #604): one role machinery.
///
/// Replaces the boot-reconciled `iam_roles`/`iam_role_actions` registry
/// mirror (write-only tables, no readers) with the unified role-definition
/// store: every role — seeded defaults and user-created — is a row whose
/// Cedar permit text is the source of truth. The four defaults are seeded
/// here with their fixed well-known ids and `role_bindings.role` is
/// backfilled from role names to those ids (role identity is the row UUID
/// everywhere from this migration on).
///
/// The backfill is data-only on purpose: `role_bindings.role` stays a string
/// column that now holds UUID strings. Swapping it for a typed uuid column
/// would mean dropping the table's five-column unique constraint, which
/// SQLite cannot do without a full table rebuild.
///
/// Seeded rows get empty `cedar_text`: `RoleRegistrySync` runs right after
/// migrations on every boot and writes the canonical text before the first
/// policy-set compile.
struct ReplaceIAMRoleRegistry: AsyncMigration {

    /// Column snapshot of the seeded role rows — migrations never touch live
    /// models (they drift; see MigrateVMDisksToVolumes).
    private final class SeededRole: Model, @unchecked Sendable {
        static let schema = "iam_roles"

        @ID(key: .id)
        var id: UUID?

        @Field(key: "name")
        var name: String

        @Field(key: "owner_type")
        var ownerType: String

        @Field(key: "owner_id")
        var ownerID: UUID

        @Field(key: "cedar_text")
        var cedarText: String

        @Field(key: "actions")
        var actions: [String]

        @Field(key: "managed")
        var managed: Bool

        init() {}

        init(id: UUID, name: String) {
            self.id = id
            self.name = name
            self.ownerType = "platform"
            self.ownerID = IAMRoleDefinition.platformOwnerID
            self.cedarText = ""
            self.actions = []
            self.managed = true
        }
    }

    func prepare(on database: Database) async throws {
        // The old mirror tables have no readers; RoleRegistrySync was their
        // only writer and is rewritten against the new shape.
        try await database.schema("iam_role_actions").delete()
        try await database.schema("iam_roles").delete()

        try await database.schema("iam_roles")
            .id()
            .field("name", .string, .required)
            .field("description", .string)
            .field("owner_type", .string, .required)
            .field("owner_id", .uuid, .required)
            .field("cedar_text", .string, .required)
            .field("actions", .array(of: .string), .required)
            .field("managed", .bool, .required)
            .field("created_by", .uuid)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            // The name identifies the role in bindings UI and API errors, so
            // it has to be unambiguous within its owner. Platform rows use the
            // zero-UUID owner sentinel to keep this enforceable (NULLs are
            // distinct in unique indexes on both engines).
            .unique(on: "owner_type", "owner_id", "name")
            .create()

        for role in IAMRole.allCases {
            try await SeededRole(id: role.seededID, name: role.rawValue).create(on: database)
        }

        if let sql = database as? SQLDatabase {
            // The listing every roles/bindable query does: rows by owner.
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_iam_roles_owner ON iam_roles (owner_type, owner_id)"
            ).run()

            // Delete-block counts and who-can filter bindings by role id;
            // CreateRoleBinding only indexed node and principal.
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_role_bindings_role ON role_bindings (role)"
            ).run()

            // `uuidString` is uppercase; every writer/reader of
            // `role_bindings.role` uses it verbatim so string equality holds.
            for role in IAMRole.allCases {
                try await sql.raw(
                    """
                    UPDATE role_bindings SET role = \(bind: role.seededID.uuidString)
                    WHERE role = \(bind: role.rawValue)
                    """
                ).run()
            }
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            for role in IAMRole.allCases {
                try await sql.raw(
                    """
                    UPDATE role_bindings SET role = \(bind: role.rawValue)
                    WHERE role = \(bind: role.seededID.uuidString)
                    """
                ).run()
            }
            try await sql.raw("DROP INDEX IF EXISTS idx_role_bindings_role").run()
        }

        try await database.schema("iam_roles").delete()

        // Recreate the old registry-mirror shapes empty; on a rollback the
        // old code's RoleRegistrySync refills them at boot.
        try await database.schema("iam_roles")
            .id()
            .field("name", .string, .required)
            .field("implies", .string)
            .unique(on: "name")
            .create()
        try await database.schema("iam_role_actions")
            .id()
            .field("role", .string, .required)
            .field("action", .string, .required)
            .unique(on: "role", "action")
            .create()
    }
}
