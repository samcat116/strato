import Fluent
import SQLKit

/// Allows failed recorded commands to retain bounded partial output even
/// though no authoritative guest exit code exists (STR-260). A monotonic
/// result revision prevents an older replica from replacing a newer snapshot;
/// every captured result still has both streams, a truncation marker, and the
/// same one-MiB combined ceiling.
struct AllowPartialVMCommandResults: AsyncMigration {
    var name: String { "App.AllowPartialVMCommandResults" }

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw AllowPartialVMCommandResultsError.sqlDatabaseRequired
        }
        try await sql.raw(
            """
            ALTER TABLE vm_command_payloads
            ADD COLUMN result_revision BIGINT,
            DROP CONSTRAINT ck_vm_command_payloads_result,
            ADD CONSTRAINT ck_vm_command_payloads_result
            CHECK (
                (result_revision IS NULL OR result_revision >= 0)
                AND (
                    (stdout IS NULL AND stderr IS NULL AND exit_code IS NULL AND truncated IS NULL)
                    OR
                    (stdout IS NOT NULL AND stderr IS NOT NULL AND truncated IS NOT NULL
                     AND octet_length(stdout) + octet_length(stderr) <= 1048576)
                )
            )
            """
        ).run()
    }

    /// Partial rows become valid durable evidence as soon as this migration
    /// lands. Re-adding the old exit-code requirement would either fail on
    /// those rows or require deleting evidence, so the migration cannot be
    /// reverted safely.
    func revert(on database: any Database) async throws {
        throw AllowPartialVMCommandResultsError.irreversible
    }
}

private enum AllowPartialVMCommandResultsError: Error {
    case sqlDatabaseRequired
    case irreversible
}
