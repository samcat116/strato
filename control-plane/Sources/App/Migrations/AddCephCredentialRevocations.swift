import Fluent
import SQLKit

/// Permanent site-scoped cleanup instructions for retired Ceph credentials.
/// Additive and idempotent so databases that saw an earlier STR-155 build are
/// repaired instead of silently lacking the revocation contract.
struct AddCephCredentialRevocations: AsyncMigration {
    var name: String { "App.AddCephCredentialRevocations" }

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw AddCephCredentialRevocationsError.sqlDatabaseRequired
        }
        try await sql.raw(
            """
            CREATE TABLE IF NOT EXISTS ceph_credential_revocations (
                id uuid PRIMARY KEY,
                site_id uuid NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
                cluster_id uuid NOT NULL,
                credential_id uuid NOT NULL,
                created_at timestamptz
            )
            """
        ).run()
        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS uq_ceph_credential_revocations_identity
            ON ceph_credential_revocations (cluster_id, credential_id)
            """
        ).run()
        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_ceph_credential_revocations_site
            ON ceph_credential_revocations (site_id, created_at, id)
            """
        ).run()
    }

    func revert(on database: any Database) async throws {}
}

private enum AddCephCredentialRevocationsError: Error {
    case sqlDatabaseRequired
}
