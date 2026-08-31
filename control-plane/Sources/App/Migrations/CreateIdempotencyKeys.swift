import Fluent
import SQLKit

/// Adds the expiring client-to-control-plane mutation replay ledger (STR-289).
struct CreateIdempotencyKeys: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(IdempotencyKey.schema)
            .id()
            .field("principal_type", .string, .required)
            .field("principal_id", .uuid)
            .field("key", .string, .required)
            .field("request_digest", .data, .required)
            .field("resource_kind", .string)
            .field("resource_id", .uuid)
            .field("mutation_id", .uuid)
            .field("target_generation", .int64)
            .field("response_status", .int16)
            .field("response_body", .data)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            """
            ALTER TABLE idempotency_keys
            ADD CONSTRAINT ck_idempotency_keys_principal
              CHECK (
                (principal_type = 'system' AND principal_id IS NULL)
                OR
                (principal_type IN ('user', 'service_account', 'workload') AND principal_id IS NOT NULL)
              ),
            ADD CONSTRAINT ck_idempotency_keys_key_length
              CHECK (char_length(key) BETWEEN 1 AND 255),
            ADD CONSTRAINT ck_idempotency_keys_digest_length
              CHECK (octet_length(request_digest) = 32),
            ADD CONSTRAINT ck_idempotency_keys_expiry
              CHECK (expires_at > created_at),
            ADD CONSTRAINT ck_idempotency_keys_response_status
              CHECK (response_status IS NULL OR response_status BETWEEN 100 AND 599)
            """
        ).run()
        try await sql.raw(
            """
            CREATE UNIQUE INDEX uq_idempotency_keys_principal_key
            ON idempotency_keys (principal_type, principal_id, key)
            WHERE principal_id IS NOT NULL
            """
        ).run()
        try await sql.raw(
            """
            CREATE UNIQUE INDEX uq_idempotency_keys_system_key
            ON idempotency_keys (principal_type, key)
            WHERE principal_id IS NULL
            """
        ).run()
        try await sql.raw(
            "CREATE INDEX idx_idempotency_keys_expires_at ON idempotency_keys (expires_at)"
        ).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(IdempotencyKey.schema).delete()
    }
}
