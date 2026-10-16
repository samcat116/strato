import Fluent
import SQLKit

struct AddSandboxIdleActivity: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { preconditionFailure("SQL required") }
        try await sql.raw("ALTER TABLE sandboxes ADD COLUMN last_active_at timestamptz").run()
        try await sql.raw("UPDATE sandboxes SET last_active_at = created_at").run()
        // Also fence legacy/stale model writers that do not own activity.
        try await sql.raw(
            """
            CREATE FUNCTION preserve_sandbox_activity() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
                NEW.last_active_at := GREATEST(OLD.last_active_at, NEW.last_active_at);
                RETURN NEW;
            END $$
            """
        ).run()
        try await sql.raw(
            """
            CREATE TRIGGER preserve_sandbox_activity BEFORE UPDATE ON sandboxes
            FOR EACH ROW EXECUTE FUNCTION preserve_sandbox_activity()
            """
        ).run()
        try await sql.raw(
            """
            CREATE TABLE sandbox_activity_leases (
                id uuid PRIMARY KEY,
                sandbox_id uuid NOT NULL REFERENCES sandboxes(id) ON DELETE CASCADE,
                agent_key text NOT NULL,
                expires_at timestamptz
            )
            """
        ).run()
        try await sql.raw("CREATE INDEX sandbox_activity_leases_sandbox_idx ON sandbox_activity_leases(sandbox_id)")
            .run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { preconditionFailure("SQL required") }
        try await sql.raw("DROP TABLE sandbox_activity_leases").run()
        try await sql.raw("DROP TRIGGER preserve_sandbox_activity ON sandboxes").run()
        try await sql.raw("DROP FUNCTION preserve_sandbox_activity()").run()
        try await sql.raw("ALTER TABLE sandboxes DROP COLUMN last_active_at").run()
    }
}
