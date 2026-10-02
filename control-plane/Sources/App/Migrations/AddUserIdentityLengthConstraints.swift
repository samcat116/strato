import Fluent
import SQLKit
import Vapor

/// STR-324: protect the identity indexes even when a writer bypasses model validation.
/// Refuse incompatible existing data rather than silently truncating login identifiers.
struct AddUserIdentityLengthConstraints: AsyncMigration {
    var name: String { "App.AddUserIdentityLengthConstraints" }

    func prepare(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            throw Abort(.internalServerError, reason: "User identity constraints require PostgreSQL")
        }
        let invalid = try await sql.raw(
            """
            SELECT id FROM users
            WHERE char_length(username) NOT BETWEEN 3 AND 64
               OR char_length(email) NOT BETWEEN 1 AND 254
               OR char_length(display_name) NOT BETWEEN 1 AND 128
            LIMIT 1
            """
        ).all()
        guard invalid.isEmpty else {
            throw Abort(
                .internalServerError,
                reason:
                    "Cannot add user identity constraints: existing users violate identity length limits; repair those rows before retrying"
            )
        }
        for (column, minimum, maximum) in [("username", 3, 64), ("email", 1, 254), ("display_name", 1, 128)] {
            let constraint = "ck_users_\(column)_length"
            try await sql.raw(
                """
                DO $str324$
                BEGIN
                    IF NOT EXISTS (
                        SELECT 1 FROM pg_constraint
                        WHERE conname = '\(unsafeRaw: constraint)' AND conrelid = 'public.users'::regclass
                    ) THEN
                        ALTER TABLE public.users ADD CONSTRAINT \(unsafeRaw: constraint)
                            CHECK (char_length(\(unsafeRaw: column)) BETWEEN \(unsafeRaw: String(minimum)) AND \(unsafeRaw: String(maximum)));
                    END IF;
                END
                $str324$
                """
            ).run()
        }
    }

    // Retain the safety invariant, matching AddAdministrativeTextLengthConstraints.
    func revert(on database: Database) async throws {}
}
