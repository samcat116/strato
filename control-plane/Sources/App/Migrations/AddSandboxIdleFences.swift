import Fluent
import SQLKit

struct AddSandboxIdleFences: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { preconditionFailure("SQL required") }
        try await sql.raw("ALTER TABLE sandbox_activity_leases ADD COLUMN guest_started_at timestamptz").run()
        try await sql.raw(
            """
            CREATE TABLE sandbox_idle_fences (
                sandbox_id uuid PRIMARY KEY REFERENCES sandboxes(id) ON DELETE CASCADE,
                activity_revision bigint NOT NULL DEFAULT 0 CHECK (activity_revision >= 0),
                agent_key text NOT NULL,
                inventory_session_id uuid,
                report jsonb,
                received_at timestamptz,
                fence jsonb,
                valid boolean NOT NULL DEFAULT false,
                expires_at timestamptz
            )
            """
        ).run()
        try await sql.raw(
            """
            CREATE FUNCTION invalidate_sandbox_idle_fence() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
                IF TG_TABLE_NAME = 'agents' THEN
                    IF NEW.inventory_session_id IS DISTINCT FROM OLD.inventory_session_id THEN
                        UPDATE sandbox_idle_fences SET activity_revision = activity_revision + 1,
                            valid = false, report = NULL, received_at = NULL
                        WHERE lower(agent_key) = NEW.id::text;
                    END IF;
                    RETURN NEW;
                END IF;
                IF NEW.last_active_at IS DISTINCT FROM OLD.last_active_at
                    OR NEW.generation IS DISTINCT FROM OLD.generation
                    OR NEW.hypervisor_id IS DISTINCT FROM OLD.hypervisor_id THEN
                    UPDATE sandbox_idle_fences SET activity_revision = activity_revision + 1,
                        valid = false WHERE sandbox_id = NEW.id;
                END IF;
                RETURN NEW;
            END $$
            """
        ).run()
        try await sql.raw(
            """
            CREATE TRIGGER invalidate_sandbox_idle_fence AFTER UPDATE ON sandboxes
            FOR EACH ROW EXECUTE FUNCTION invalidate_sandbox_idle_fence()
            """
        ).run()
        try await sql.raw(
            """
            CREATE TRIGGER invalidate_agent_sandbox_idle_fences AFTER UPDATE OF inventory_session_id ON agents
            FOR EACH ROW EXECUTE FUNCTION invalidate_sandbox_idle_fence()
            """
        ).run()
    }
    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { preconditionFailure("SQL required") }
        try await sql.raw("DROP TRIGGER invalidate_agent_sandbox_idle_fences ON agents").run()
        try await sql.raw("DROP TRIGGER invalidate_sandbox_idle_fence ON sandboxes").run()
        try await sql.raw("DROP FUNCTION invalidate_sandbox_idle_fence()").run()
        try await sql.raw("DROP TABLE sandbox_idle_fences").run()
        try await sql.raw("ALTER TABLE sandbox_activity_leases DROP COLUMN guest_started_at").run()
    }
}
