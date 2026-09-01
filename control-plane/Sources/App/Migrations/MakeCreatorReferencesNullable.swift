import Fluent
import SQLKit

/// Makes every creator reference attribution instead of ownership (STR-297).
///
/// `created_by_id` (and `images.uploaded_by_id`) records who asked for a
/// resource. The nullable half of the schema already treats a deleted creator
/// as nulled attribution (`logical_networks`, `dns_zones`, ...); the NOT NULL
/// half either CASCADEd — deleting a user silently deleted their volumes,
/// volume snapshots and images, and the agent was then told the surviving
/// bytes were strays and destroyed them — or had no delete rule at all, which
/// turned the same request into an unhandled constraint violation. This
/// migration lands the invariant everywhere: a creator reference can never
/// delete or block what it points at. Durable attribution is unaffected — it
/// lives in `resource_events`, which is append-only and never swept.
///
/// `scim_tokens.created_by_id` deliberately stays RESTRICT: a token is a
/// credential its creator is accountable for, so `UserController.delete`
/// refuses with a checked `409` instead.
struct MakeCreatorReferencesNullable: AsyncMigration {
    private struct CreatorReference {
        let table: String
        let column: String
        let constraint: String
        /// The delete rule the baseline declared, restored on revert. NO ACTION
        /// is spelled explicitly so the revert DDL round-trips every case.
        let previousRule: String
    }

    private static let references: [CreatorReference] = [
        .init(
            table: "volumes", column: "created_by_id",
            constraint: "volumes_created_by_id_fkey", previousRule: "CASCADE"),
        .init(
            table: "volume_snapshots", column: "created_by_id",
            constraint: "volume_snapshots_created_by_id_fkey", previousRule: "CASCADE"),
        .init(
            table: "images", column: "uploaded_by_id",
            constraint: "images_uploaded_by_id_fkey", previousRule: "CASCADE"),
        .init(
            table: "vm_snapshots", column: "created_by_id",
            constraint: "vm_snapshots_created_by_id_fkey", previousRule: "NO ACTION"),
        .init(
            table: "sandbox_snapshots", column: "created_by_id",
            constraint: "sandbox_snapshots_created_by_id_fkey", previousRule: "NO ACTION"),
        .init(
            table: "webhook_subscriptions", column: "created_by_id",
            constraint: "webhook_subscriptions_created_by_id_fkey", previousRule: "NO ACTION"),
        .init(
            table: "ssf_streams", column: "created_by_id",
            constraint: "ssf_streams_created_by_id_fkey", previousRule: "NO ACTION"),
    ]

    func prepare(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            preconditionFailure("MakeCreatorReferencesNullable requires SQLKit")
        }
        for reference in Self.references {
            try await sql.raw(
                """
                ALTER TABLE \(unsafeRaw: reference.table)
                  ALTER COLUMN \(unsafeRaw: reference.column) DROP NOT NULL
                """
            ).run()
            // Plain DROP, not IF EXISTS: if the baseline name ever drifts this
            // must fail loudly rather than leave the destructive rule in place
            // beside a second, weaker constraint.
            try await sql.raw(
                """
                ALTER TABLE \(unsafeRaw: reference.table)
                  DROP CONSTRAINT \(unsafeRaw: reference.constraint),
                  ADD CONSTRAINT \(unsafeRaw: reference.constraint)
                    FOREIGN KEY (\(unsafeRaw: reference.column))
                    REFERENCES users (id) ON DELETE SET NULL
                """
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            preconditionFailure("MakeCreatorReferencesNullable requires SQLKit")
        }
        for reference in Self.references.reversed() {
            // A row whose creator is already gone cannot be given its NOT NULL
            // back; refuse rather than invent an owner.
            try await sql.raw(
                """
                DO $$
                BEGIN
                  IF EXISTS (
                    SELECT 1 FROM \(unsafeRaw: reference.table)
                    WHERE \(unsafeRaw: reference.column) IS NULL
                  ) THEN
                    RAISE EXCEPTION
                      'cannot revert: \(unsafeRaw: reference.table) rows with null \(unsafeRaw: reference.column) exist';
                  END IF;
                END
                $$
                """
            ).run()
            try await sql.raw(
                """
                ALTER TABLE \(unsafeRaw: reference.table)
                  ALTER COLUMN \(unsafeRaw: reference.column) SET NOT NULL
                """
            ).run()
            let action = reference.previousRule == "NO ACTION" ? "" : " ON DELETE \(reference.previousRule)"
            try await sql.raw(
                """
                ALTER TABLE \(unsafeRaw: reference.table)
                  DROP CONSTRAINT \(unsafeRaw: reference.constraint),
                  ADD CONSTRAINT \(unsafeRaw: reference.constraint)
                    FOREIGN KEY (\(unsafeRaw: reference.column))
                    REFERENCES users (id)\(unsafeRaw: action)
                """
            ).run()
        }
    }
}
