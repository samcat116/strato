import Fluent
import SQLKit

/// External Ceph registration and project-scoped RBD pools (STR-155).
///
/// Fresh databases already contain these objects in `CurrentSchema.sql`; every
/// statement is therefore idempotent so the same migration safely upgrades a
/// preserved database without changing any existing local pool or volume row.
struct AddExternalCephStorage: AsyncMigration {
    var name: String { "App.AddExternalCephStorage" }

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw AddExternalCephStorageError.sqlDatabaseRequired
        }

        try await sql.raw(
            """
            CREATE TABLE IF NOT EXISTS stored_secrets (
                id uuid PRIMARY KEY,
                purpose text NOT NULL,
                encrypted_value text NOT NULL,
                created_at timestamptz,
                updated_at timestamptz,
                CONSTRAINT ck_stored_secrets_purpose CHECK (
                    purpose IN ('ceph_cluster_observer_keyring', 'ceph_project_keyring')
                )
            )
            """
        ).run()
        try await sql.raw(
            """
            CREATE TABLE IF NOT EXISTS ceph_clusters (
                id uuid PRIMARY KEY,
                site_id uuid NOT NULL REFERENCES sites(id) ON DELETE RESTRICT,
                fsid text NOT NULL,
                managed boolean NOT NULL,
                mon_endpoints text[] NOT NULL,
                client_name text NOT NULL,
                keyring_secret_ref uuid NOT NULL REFERENCES stored_secrets(id) ON DELETE RESTRICT,
                health text NOT NULL,
                capacity_bytes bigint,
                used_bytes bigint,
                observed_at timestamptz,
                created_at timestamptz,
                updated_at timestamptz,
                CONSTRAINT ck_ceph_clusters_external CHECK (managed = FALSE),
                CONSTRAINT ck_ceph_clusters_health CHECK (health IN ('unknown', 'ok', 'warning', 'error')),
                CONSTRAINT ck_ceph_clusters_mon_endpoints CHECK (cardinality(mon_endpoints) > 0),
                CONSTRAINT ck_ceph_clusters_capacity CHECK (
                    (capacity_bytes IS NULL OR capacity_bytes >= 0)
                    AND (used_bytes IS NULL OR used_bytes >= 0)
                    AND (capacity_bytes IS NULL OR used_bytes IS NULL OR used_bytes <= capacity_bytes)
                )
            )
            """
        ).run()
        try await sql.raw(
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_ceph_clusters_site ON ceph_clusters (site_id)"
        ).run()
        try await sql.raw(
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_ceph_clusters_fsid ON ceph_clusters (fsid)"
        ).run()
        try await sql.raw(
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_ceph_clusters_secret ON ceph_clusters (keyring_secret_ref)"
        ).run()

        try await sql.raw(
            """
            CREATE TABLE IF NOT EXISTS ceph_project_accesses (
                id uuid PRIMARY KEY,
                cluster_id uuid NOT NULL REFERENCES ceph_clusters(id) ON DELETE RESTRICT,
                project_id uuid NOT NULL REFERENCES projects(id) ON DELETE RESTRICT,
                client_name text NOT NULL,
                keyring_secret_ref uuid NOT NULL REFERENCES stored_secrets(id) ON DELETE RESTRICT,
                created_at timestamptz,
                updated_at timestamptz
            )
            """
        ).run()
        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS uq_ceph_project_accesses_cluster_project
            ON ceph_project_accesses (cluster_id, project_id)
            """
        ).run()
        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS uq_ceph_project_accesses_secret
            ON ceph_project_accesses (keyring_secret_ref)
            """
        ).run()
        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS uq_ceph_project_accesses_cluster_client
            ON ceph_project_accesses (cluster_id, client_name)
            """
        ).run()

        try await sql.raw(
            "ALTER TABLE storage_pools ADD COLUMN IF NOT EXISTS site_id uuid REFERENCES sites(id) ON DELETE RESTRICT"
        ).run()
        try await sql.raw(
            """
            ALTER TABLE storage_pools
            ADD COLUMN IF NOT EXISTS ceph_cluster_id uuid REFERENCES ceph_clusters(id) ON DELETE RESTRICT
            """
        ).run()
        try await sql.raw(
            """
            ALTER TABLE storage_pools
            ADD COLUMN IF NOT EXISTS ceph_project_access_id uuid REFERENCES ceph_project_accesses(id) ON DELETE RESTRICT
            """
        ).run()
        try await sql.raw("ALTER TABLE storage_pools ADD COLUMN IF NOT EXISTS ceph_pool_name text").run()
        try await sql.raw("ALTER TABLE storage_pools ADD COLUMN IF NOT EXISTS ceph_namespace text").run()
        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS uq_storage_pools_ceph_project_access
            ON storage_pools (ceph_project_access_id)
            WHERE ceph_project_access_id IS NOT NULL
            """
        ).run()
        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS uq_storage_pools_ceph_namespace
            ON storage_pools (ceph_cluster_id, ceph_namespace)
            WHERE mode = 'ceph'
            """
        ).run()
        try await sql.raw(
            "ALTER TABLE storage_pools DROP CONSTRAINT IF EXISTS ck_storage_pools_mode_enum"
        ).run()
        try await sql.raw(
            "ALTER TABLE storage_pools DROP CONSTRAINT IF EXISTS ck_storage_pools_ceph_shape"
        ).run()
        try await sql.raw(
            """
            ALTER TABLE storage_pools
            ADD CONSTRAINT ck_storage_pools_mode_enum
                CHECK (mode IN ('local', 'replicated', 'ceph')),
            ADD CONSTRAINT ck_storage_pools_ceph_shape
                CHECK (
                    (
                        mode = 'ceph'
                        AND site_id IS NOT NULL
                        AND ceph_cluster_id IS NOT NULL
                        AND ceph_project_access_id IS NOT NULL
                        AND ceph_pool_name IS NOT NULL
                        AND ceph_namespace IS NOT NULL
                    ) OR (
                        mode <> 'ceph'
                        AND site_id IS NULL
                        AND ceph_cluster_id IS NULL
                        AND ceph_project_access_id IS NULL
                        AND ceph_pool_name IS NULL
                        AND ceph_namespace IS NULL
                    )
                )
            """
        ).run()

        try await sql.raw("ALTER TABLE volumes ADD COLUMN IF NOT EXISTS disk_attachment jsonb").run()
        try await sql.raw("ALTER TABLE volumes ADD COLUMN IF NOT EXISTS reconciler_agent_id text").run()
        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_volumes_reconciler_agent_id
            ON volumes (reconciler_agent_id)
            WHERE reconciler_agent_id IS NOT NULL
            """
        ).run()
    }

    /// Fresh-schema ownership makes destructive reversion ambiguous. Keeping
    /// compatible nullable columns is safer than dropping objects the baseline
    /// may have created before this migration was logged.
    func revert(on database: any Database) async throws {}
}

private enum AddExternalCephStorageError: Error {
    case sqlDatabaseRequired
}
