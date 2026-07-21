import Fluent
import SQLKit

/// Backfills `user_credentials.device_type`, which was written as the constant
/// `"platform"` for every passkey regardless of what the authenticator actually
/// reported.
///
/// Registration and login now record the credential device type from the
/// verified authenticator flags (`multi_device` for a syncable passkey,
/// `single_device` for one bound to its authenticator). Existing rows are
/// derived from `backup_eligible`, which is the same flag the device type is
/// defined by, so the API stops serving a mix of vocabularies for accounts that
/// have not signed in since.
struct BackfillPasskeyDeviceType: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        try await sql.raw(
            """
            UPDATE user_credentials SET device_type = 'multi_device'
            WHERE device_type = 'platform' AND backup_eligible = \(bind: true)
            """
        ).run()

        try await sql.raw(
            """
            UPDATE user_credentials SET device_type = 'single_device'
            WHERE device_type = 'platform' AND backup_eligible = \(bind: false)
            """
        ).run()
    }

    /// Irreversible by design: the pre-migration value carried no information
    /// (it was the same constant for every row), so there is nothing to restore.
    func revert(on database: Database) async throws {}
}
