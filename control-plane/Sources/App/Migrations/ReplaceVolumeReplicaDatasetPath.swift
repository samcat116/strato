import Fluent
import SQLKit

/// Replaces the file-only replica location with the complete attachment value
/// reported by the owning agent (STR-154).
struct ReplaceVolumeReplicaDatasetPath: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            preconditionFailure("ReplaceVolumeReplicaDatasetPath requires SQLKit")
        }
        try await sql.raw(
            """
            DO $$
            BEGIN
              IF EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = 'volume_replicas'
                  AND column_name = 'dataset_path'
              ) THEN
                ALTER TABLE volume_replicas
                  ADD COLUMN IF NOT EXISTS disk_attachment jsonb;
                UPDATE volume_replicas
                SET disk_attachment = jsonb_build_object(
                  'file', jsonb_build_object(
                    'path', dataset_path,
                    'format', CASE
                      WHEN lower(dataset_path) LIKE '%.raw' THEN 'raw'
                      ELSE 'qcow2'
                    END
                  )
                )
                WHERE dataset_path IS NOT NULL AND disk_attachment IS NULL;
                ALTER TABLE volume_replicas DROP COLUMN dataset_path;
              END IF;
            END
            $$
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            preconditionFailure("ReplaceVolumeReplicaDatasetPath requires SQLKit")
        }
        try await sql.raw(
            """
            DO $$
            BEGIN
              IF EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = 'volume_replicas'
                  AND column_name = 'disk_attachment'
              ) THEN
                IF EXISTS (
                  SELECT 1 FROM volume_replicas
                  WHERE disk_attachment IS NOT NULL
                    AND NOT (disk_attachment ? 'file')
                ) THEN
                  RAISE EXCEPTION
                    'cannot revert typed disk attachments while non-file replicas exist';
                END IF;
                ALTER TABLE volume_replicas ADD COLUMN IF NOT EXISTS dataset_path text;
                UPDATE volume_replicas
                SET dataset_path = disk_attachment -> 'file' ->> 'path'
                WHERE dataset_path IS NULL AND disk_attachment ? 'file';
                ALTER TABLE volume_replicas DROP COLUMN disk_attachment;
              END IF;
            END
            $$
            """
        ).run()
    }
}
