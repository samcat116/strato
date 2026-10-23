import Fluent
import SQLKit

/// STR-162: retire the unimplemented DRBD pool configuration without making
/// any historical unsupported pool eligible for host-local placement.
struct RemoveReservedStoragePoolConfiguration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            preconditionFailure("RemoveReservedStoragePoolConfiguration requires SQLKit")
        }
        // The baseline uses text columns with CHECK constraints, not native
        // PostgreSQL enums. One statement keeps validation and DDL atomic even
        // when the migration runner does not wrap prepare in a transaction.
        try await sql.raw(
            """
            DO $str162$
            BEGIN
                LOCK TABLE storage_pools IN ACCESS EXCLUSIVE MODE;
                IF EXISTS (
                    SELECT 1 FROM storage_pools
                    WHERE mode NOT IN ('local', 'ceph') OR backing <> 'filesystem'
                ) THEN
                    RAISE EXCEPTION 'Cannot retire reserved storage pool configuration: resolve unsupported mode/backing rows before retrying';
                END IF;
                ALTER TABLE storage_pools
                    DROP CONSTRAINT IF EXISTS ck_storage_pools_mode_enum,
                    DROP CONSTRAINT IF EXISTS ck_storage_pools_backing_enum;
                ALTER TABLE storage_pools
                    ADD CONSTRAINT ck_storage_pools_mode_enum CHECK (mode IN ('local', 'ceph')),
                    ADD CONSTRAINT ck_storage_pools_backing_enum CHECK (backing = 'filesystem'),
                    DROP COLUMN IF EXISTS replication_factor;
            END
            $str162$
            """
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            preconditionFailure("RemoveReservedStoragePoolConfiguration requires SQLKit")
        }
        try await sql.raw(
            """
            DO $str162$
            BEGIN
                LOCK TABLE storage_pools IN ACCESS EXCLUSIVE MODE;
                ALTER TABLE storage_pools
                    DROP CONSTRAINT IF EXISTS ck_storage_pools_mode_enum,
                    DROP CONSTRAINT IF EXISTS ck_storage_pools_backing_enum;
                ALTER TABLE storage_pools
                    ADD CONSTRAINT ck_storage_pools_mode_enum CHECK (mode IN ('local', 'replicated', 'ceph')),
                    ADD CONSTRAINT ck_storage_pools_backing_enum CHECK (backing IN ('filesystem', 'zfs')),
                    ADD COLUMN IF NOT EXISTS replication_factor bigint NOT NULL DEFAULT 1;
                ALTER TABLE storage_pools ALTER COLUMN replication_factor DROP DEFAULT;
            END
            $str162$
            """
        ).run()
    }
}
