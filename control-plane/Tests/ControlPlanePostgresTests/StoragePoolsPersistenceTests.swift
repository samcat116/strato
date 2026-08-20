import Foundation
import Testing

@testable import ControlPlanePostgres

@Suite("Native storage-pool persistence", .serialized)
struct StoragePoolsPersistenceTests {
    @Test("lookups preserve enum values, member arrays, and timestamps")
    func lookupsRoundTrip() async throws {
        try await withStoragePoolDatabase { database, pools in
            let id = UUID()
            let createdAt = Date(timeIntervalSince1970: 40_000)
            try await insert(
                id: id,
                name: StoragePoolsPersistence.defaultPoolName,
                mode: "local",
                members: ["agent-a", "agent-b"],
                backing: "filesystem",
                createdAt: createdAt,
                database: database
            )

            let pool = try await pools.defaultPool()
            #expect(pool.id == id)
            #expect(pool.mode == .local)
            #expect(pool.replicationFactor == 1)
            #expect(pool.memberAgentIDs == ["agent-a", "agent-b"])
            #expect(pool.backing == .filesystem)
            #expect(pool.createdAt == createdAt)
            #expect(try await pools.pool(id: id) == pool)
            #expect(try await pools.all() == [pool])
        }
    }

    @Test("missing defaults and unknown enum values fail explicitly")
    func invalidRowsFailExplicitly() async throws {
        try await withStoragePoolDatabase { database, pools in
            await #expect(throws: StoragePoolPersistenceError.missingDefaultPool) {
                try await pools.defaultPool()
            }

            try await insert(
                id: UUID(),
                name: StoragePoolsPersistence.defaultPoolName,
                mode: "future-mode",
                members: [],
                backing: "filesystem",
                createdAt: Date(),
                database: database
            )
            await #expect(throws: StoragePoolPersistenceError.unknownMode("future-mode")) {
                try await pools.defaultPool()
            }
        }
    }

    private func withStoragePoolDatabase(
        _ test: (PostgresDatabase, StoragePoolsPersistence) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase { database in
            _ = try await database.withSession(operation: "test.storage_pools.schema") { session in
                try await session.command(
                    """
                    CREATE TABLE storage_pools (
                        id UUID PRIMARY KEY,
                        name TEXT NOT NULL UNIQUE,
                        mode TEXT NOT NULL,
                        replication_factor BIGINT NOT NULL,
                        member_agent_ids TEXT[] NOT NULL,
                        backing TEXT NOT NULL,
                        created_at TIMESTAMPTZ,
                        updated_at TIMESTAMPTZ
                    )
                    """,
                    operation: "test.storage_pools.schema.create"
                )
            }
            try await test(database, ControlPlanePersistence(database: database).storagePools)
        }
    }

    private func insert(
        id: UUID,
        name: String,
        mode: String,
        members: [String],
        backing: String,
        createdAt: Date,
        database: PostgresDatabase
    ) async throws {
        _ = try await database.withSession(operation: "test.storage_pools.seed") { session in
            let memberLiteral = members.map { "\"\($0)\"" }.joined(separator: ",")
            let timestamp = createdAt.ISO8601Format(.iso8601(timeZone: .gmt))
            return try await session.command(
                """
                INSERT INTO storage_pools (
                    id, name, mode, replication_factor, member_agent_ids,
                    backing, created_at, updated_at
                ) VALUES (
                    '\(id.uuidString)'::uuid,
                    '\(name)',
                    '\(mode)',
                    1,
                    '{\(memberLiteral)}'::text[],
                    '\(backing)',
                    '\(timestamp)'::timestamptz,
                    '\(timestamp)'::timestamptz
                )
                """,
                operation: "test.storage_pools.seed.insert"
            )
        }
    }
}
