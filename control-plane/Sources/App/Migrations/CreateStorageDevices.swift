import Fluent
import SQLKit

struct CreateStorageDevices: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(StorageDevice.schema)
            .id()
            .field(
                "agent_id", .uuid, .required,
                .references(Agent.schema, "id", onDelete: .cascade)
            )
            .field("identity_kind", .string)
            .field("identity_value", .string)
            .field("device_path", .string, .required)
            .field("size_bytes", .int64, .required)
            .field("model", .string)
            .field("serial", .string)
            .field("wwn", .string)
            .field("rotational", .bool, .required)
            .field("uses", .array(of: .string), .required, .custom("DEFAULT '{}'"))
            .field("role", .string, .required)
            .field("state", .string, .required)
            .field("osd_id", .int)
            .field("present", .bool, .required)
            .field("last_seen_at", .datetime, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            """
            ALTER TABLE storage_devices
            ADD CONSTRAINT ck_storage_devices_identity_pair
            CHECK ((identity_kind IS NULL) = (identity_value IS NULL))
            """
        ).run()
        try await sql.raw(
            """
            ALTER TABLE storage_devices
            ADD CONSTRAINT ck_storage_devices_identity_kind
            CHECK (identity_kind IS NULL OR identity_kind IN ('wwn', 'serial'))
            """
        ).run()
        try await sql.raw(
            """
            ALTER TABLE storage_devices
            ADD CONSTRAINT ck_storage_devices_size_bytes CHECK (size_bytes >= 0)
            """
        ).run()
        try await sql.raw(
            """
            ALTER TABLE storage_devices
            ADD CONSTRAINT ck_storage_devices_role
            CHECK (role IN ('unassigned', 'osd', 'excluded'))
            """
        ).run()
        try await sql.raw(
            """
            ALTER TABLE storage_devices
            ADD CONSTRAINT ck_storage_devices_state
            CHECK (state IN ('available', 'inUse', 'draining', 'faulted'))
            """
        ).run()
        try await sql.raw(
            """
            CREATE UNIQUE INDEX uq_storage_devices_agent_identity
            ON storage_devices (agent_id, identity_kind, identity_value)
            """
        ).run()
        try await sql.raw(
            """
            CREATE INDEX idx_storage_devices_agent_present
            ON storage_devices (agent_id, present)
            """
        ).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(StorageDevice.schema).delete()
    }
}
