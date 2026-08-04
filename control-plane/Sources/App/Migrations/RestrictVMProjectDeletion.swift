import Fluent
import SQLKit

/// Stop a project delete from hard-deleting live VM rows (STR-98 trigger 3).
///
/// `vms.project_id` was created `ON DELETE CASCADE`. `deleteProject` guards
/// against it by counting VMs first and refusing when any exist — but a count
/// and a delete in read-committed Postgres do not exclude a concurrent insert,
/// so a VM created inside that window was removed *by the database*: no
/// `desiredStatus = .absent`, no `ResourceOperation`, no audit trail. Its agent
/// then learned about it only as an absence from the next sync, which used to
/// mean "destroy" — a running guest killed by a race nobody could see.
///
/// RESTRICT makes the database enforce what the guard already intends. The
/// pre-checks stay for the friendly 409; this is what makes the answer correct
/// when the check and the delete disagree, and `ProjectsAPIService.deleteProject`
/// maps the resulting FK violation onto the same 409.
struct RestrictVMProjectDeletion: AsyncMigration {
    static let constraintName = "fk_vms_project_id_restrict"

    func prepare(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await Self.replaceForeignKey(action: "RESTRICT", on: sql)
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await Self.replaceForeignKey(action: "CASCADE", on: sql)
    }

    /// Drop whatever foreign key currently governs `vms.project_id` — Fluent's
    /// generated name is not stable enough to hardcode — and install one with
    /// the given delete action.
    static func replaceForeignKey(action: String, on sql: any SQLDatabase) async throws {
        let rows = try await sql.raw(
            """
            SELECT con.conname AS name
            FROM pg_constraint con
            JOIN pg_class rel ON rel.oid = con.conrelid
            JOIN pg_attribute att ON att.attrelid = rel.oid AND att.attnum = ANY (con.conkey)
            WHERE rel.relname = 'vms' AND con.contype = 'f' AND att.attname = 'project_id'
            """
        ).all()

        for row in rows {
            let name = try row.decode(column: "name", as: String.self)
            let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            try await sql.raw("ALTER TABLE vms DROP CONSTRAINT \(unsafeRaw: quoted)").run()
        }

        try await sql.raw(
            """
            ALTER TABLE vms ADD CONSTRAINT \(unsafeRaw: constraintName)
            FOREIGN KEY (project_id) REFERENCES projects (id) ON DELETE \(unsafeRaw: action)
            """
        ).run()
    }
}
