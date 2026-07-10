import Fluent
import SQLKit

/// Drops the legacy `vm_templates` table (feature removed).
///
/// VM templates were the original way to define VM configurations with
/// hardcoded kernel/initramfs/disk paths. They were superseded by the `Image`
/// model, and the template creation path has now been removed entirely.
///
/// The original `CreateVMTemplate`/`SeedVMTemplates` migrations are no longer
/// registered, so a fresh database never creates the table — the `IF EXISTS`
/// guard makes this a no-op there. On existing databases it drops the leftover
/// table. No foreign keys reference it, so nothing is orphaned.
struct DropVMTemplate: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS vm_templates").run()
    }

    func revert(on database: Database) async throws {
        // The table is intentionally not recreated on revert; the feature is gone.
    }
}
