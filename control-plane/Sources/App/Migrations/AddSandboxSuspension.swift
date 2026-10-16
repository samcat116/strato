import Fluent
import SQLKit

struct AddSandboxSuspension: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { preconditionFailure("SQL required") }
        try await sql.raw(
            """
            ALTER TABLE sandboxes
            ADD COLUMN suspension_compute_reserved boolean NOT NULL DEFAULT true,
            ADD COLUMN suspension_storage_bytes bigint NOT NULL DEFAULT 0 CHECK (suspension_storage_bytes >= 0),
            ADD COLUMN suspension_storage_estimate_bytes bigint CHECK (suspension_storage_estimate_bytes > 0),
            ADD COLUMN suspension_evidence jsonb,
            ADD COLUMN suspension_after_snapshot_id uuid,
            DROP CONSTRAINT ck_sandboxes_status_enum,
            DROP CONSTRAINT ck_sandboxes_desired_status_enum,
            ADD CONSTRAINT ck_sandboxes_status_enum CHECK (status IN ('Stopped','Suspended','Running','Exited','Starting','Stopping','Error','Unknown')),
            ADD CONSTRAINT ck_sandboxes_desired_status_enum CHECK (desired_status IN ('Running','Stopped','Suspended','Absent'))
            """
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { preconditionFailure("SQL required") }
        // Refuse a downgrade that would lose the only recoverable guest state.
        try await sql.raw(
            """
            DO $$ BEGIN
                IF EXISTS (SELECT 1 FROM sandboxes WHERE suspension_evidence IS NOT NULL
                    OR suspension_storage_bytes > 0 OR NOT suspension_compute_reserved
                    OR status = 'Suspended' OR desired_status = 'Suspended') THEN
                    RAISE EXCEPTION 'Cannot remove retained sandbox suspension state';
                END IF;
            END $$
            """
        ).run()
        try await sql.raw(
            """
            ALTER TABLE sandboxes
            DROP CONSTRAINT ck_sandboxes_status_enum,
            DROP CONSTRAINT ck_sandboxes_desired_status_enum,
            ADD CONSTRAINT ck_sandboxes_status_enum CHECK (status IN ('Stopped','Running','Exited','Starting','Stopping','Error','Unknown')),
            ADD CONSTRAINT ck_sandboxes_desired_status_enum CHECK (desired_status IN ('Running','Stopped','Absent')),
            DROP COLUMN suspension_after_snapshot_id,
            DROP COLUMN suspension_evidence,
            DROP COLUMN suspension_storage_estimate_bytes,
            DROP COLUMN suspension_storage_bytes,
            DROP COLUMN suspension_compute_reserved
            """
        ).run()
    }
}
