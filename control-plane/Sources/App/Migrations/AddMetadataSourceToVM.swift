import Fluent
import SQLKit
import StratoShared

/// Adds the per-VM guest-bootstrap source (STR-64).
///
/// Existing rows become `.iso`, preserving the complete NoCloud seed they were
/// created with. The later default-flip phase can change what new requests omit;
/// it must never reinterpret an already-created VM as IMDS-backed.
struct AddMetadataSourceToVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(VM.schema)
            .field("metadata_source", .string, .required, .sql(.default(MetadataSource.iso.rawValue)))
            .update()

        if let sql = database as? any SQLDatabase {
            // One stable, unguessable capability per VM. The database default
            // covers both the existing rows this migration upgrades and any
            // insert path that does not construct the Fluent model directly.
            try await sql.raw(
                "ALTER TABLE vms ADD COLUMN metadata_seed_token UUID NOT NULL DEFAULT gen_random_uuid()"
            ).run()
            try await sql.raw(
                "ALTER TABLE vms ADD CONSTRAINT \"uq:vms.metadata_seed_token\" UNIQUE (metadata_seed_token)"
            ).run()
            try await sql.raw(
                "ALTER TABLE vms ADD CONSTRAINT ck_vms_metadata_source_enum CHECK (metadata_source IN ('iso', 'imds'))"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw(
                "ALTER TABLE vms DROP CONSTRAINT IF EXISTS ck_vms_metadata_source_enum"
            ).run()
        }
        try await database.schema(VM.schema).deleteField("metadata_seed_token").update()
        try await database.schema(VM.schema).deleteField("metadata_source").update()
    }
}
