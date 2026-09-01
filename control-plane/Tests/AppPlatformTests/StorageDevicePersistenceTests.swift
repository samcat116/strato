import AppTestSupport
import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
import StratoShared
import Testing
import Vapor

@testable import App

@Suite("Storage device persistence", .serialized)
struct StorageDevicePersistenceTests {
    @Test("structured device uses round-trip through PostgreSQL")
    func structuredUsesRoundTrip() async throws {
        try await withStorageSchema { database, sql in
            let agentID = try await insertAgent(using: sql)
            let device = makeDevice(
                agentID: agentID,
                identityValue: "5000cca0",
                uses: [.partitionTable, .filesystem, .mounted])

            try await device.save(on: database)

            let stored = try #require(try await StorageDevice.find(device.id, on: database))
            #expect(stored.uses == [.partitionTable, .filesystem, .mounted])
        }
    }

    @Test("legacy JSON usage arrays migrate without losing values")
    func legacyUsesMigrateToTextArray() async throws {
        try await withStorageSchema { database, sql in
            try await sql.raw(
                """
                ALTER TABLE storage_devices
                    ALTER COLUMN uses DROP DEFAULT,
                    ALTER COLUMN uses TYPE jsonb[] USING '{}'::jsonb[],
                    ALTER COLUMN uses SET DEFAULT '{}'::jsonb[]
                """
            ).run()
            let agentID = try await insertAgent(using: sql)
            let deviceID = UUID()
            try await sql.raw(
                """
                INSERT INTO storage_devices
                    (id, agent_id, identity_kind, identity_value, device_path,
                     size_bytes, rotational, uses, role, state, present, last_seen_at)
                VALUES
                    (
                        \(bind: deviceID), \(bind: agentID), 'wwn', '5000cca9', '/dev/sdz',
                        1000000, false,
                        ARRAY['"partitionTable"'::jsonb, '"filesystem"'::jsonb, '"mounted"'::jsonb],
                        'unassigned', 'inUse', true, NOW()
                    )
                """
            ).run()

            try await FixStorageDeviceUsesArrayType().prepare(on: database)

            let columnType = try #require(
                try await sql.raw(
                    """
                    SELECT udt_name
                    FROM information_schema.columns
                    WHERE table_schema = current_schema()
                      AND table_name = 'storage_devices'
                      AND column_name = 'uses'
                    """
                ).first(decodingColumn: "udt_name", as: String.self))
            #expect(columnType == "_text")
            let stored = try #require(try await StorageDevice.find(deviceID, on: database))
            #expect(stored.uses == [.partitionTable, .filesystem, .mounted])

            let reported = makeDevice(
                agentID: agentID,
                identityValue: "5000ccaa",
                path: "/dev/sdy",
                uses: [.swap])
            try await reported.save(on: database)
            let roundTripped = try #require(
                try await StorageDevice.find(reported.id, on: database))
            #expect(roundTripped.uses == [.swap])
        }
    }

    @Test("stable identities are unique per agent, not across agents")
    func identityUniquenessIsAgentScoped() async throws {
        try await withStorageSchema { database, sql in
            let firstAgent = try await insertAgent(using: sql)
            let secondAgent = try await insertAgent(using: sql)

            try await makeDevice(agentID: firstAgent, identityValue: "5000cca1").save(on: database)
            try await makeDevice(agentID: secondAgent, identityValue: "5000cca1").save(on: database)

            await #expect(throws: (any Error).self) {
                try await makeDevice(agentID: firstAgent, identityValue: "5000cca1")
                    .save(on: database)
            }
        }
    }

    @Test("identity fields are paired while anonymous rows remain valid")
    func identityNullabilityIsPaired() async throws {
        try await withStorageSchema { database, sql in
            let agentID = try await insertAgent(using: sql)

            try await makeDevice(
                agentID: agentID,
                identityKind: nil,
                identityValue: nil,
                path: "/dev/sdz"
            ).save(on: database)

            await #expect(throws: (any Error).self) {
                try await insertRawDevice(
                    using: sql, agentID: agentID,
                    identityKind: "wwn", identityValue: nil)
            }
            await #expect(throws: (any Error).self) {
                try await insertRawDevice(
                    using: sql, agentID: agentID,
                    identityKind: nil, identityValue: "5000cca1")
            }
        }
    }

    @Test("database constraints reject invalid inventory values")
    func rejectsInvalidValues() async throws {
        try await withStorageSchema { _, sql in
            let agentID = try await insertAgent(using: sql)

            await #expect(throws: (any Error).self) {
                try await insertRawDevice(
                    using: sql, agentID: agentID,
                    identityKind: "path", identityValue: "/dev/sdb")
            }
            await #expect(throws: (any Error).self) {
                try await insertRawDevice(
                    using: sql, agentID: agentID,
                    identityKind: "wwn", identityValue: "5000cca2", sizeBytes: -1)
            }
            await #expect(throws: (any Error).self) {
                try await insertRawDevice(
                    using: sql, agentID: agentID,
                    identityKind: "wwn", identityValue: "5000cca3", role: "formatted")
            }
            await #expect(throws: (any Error).self) {
                try await insertRawDevice(
                    using: sql, agentID: agentID,
                    identityKind: "wwn", identityValue: "5000cca4", state: "unknown")
            }
        }
    }

    @Test("deleting an agent cascades to its inventory")
    func agentDeleteCascades() async throws {
        try await withStorageSchema { database, sql in
            let agentID = try await insertAgent(using: sql)
            try await makeDevice(agentID: agentID, identityValue: "5000cca5").save(on: database)

            try await sql.raw("DELETE FROM agents WHERE id = \(bind: agentID)").run()

            #expect(try await StorageDevice.query(on: database).count() == 0)
        }
    }

    private func withStorageSchema(
        _ test: @escaping @Sendable (any Database, any SQLDatabase) async throws -> Void
    ) async throws {
        var environment = Environment.testing
        environment.arguments = ["vapor"]
        let app = try await Application.make(
            environment,
            .shared(PostgresTestDatabases.appEventLoopGroup))
        let databaseName = Environment.get("DATABASE_NAME") ?? "strato_test"
        app.databases.use(
            .postgres(configuration: PostgresTestDatabases.configuration(database: databaseName)),
            as: .psql)

        let schemaName = "storage_devices_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            let rootSQL = try #require(app.db as? any SQLDatabase)
            try await rootSQL.raw("CREATE SCHEMA \(ident: schemaName)").run()
            try await app.db.withConnection { database in
                let sql = try #require(database as? any SQLDatabase)
                try await sql.raw("SET search_path TO \(ident: schemaName)").run()
                try await sql.raw("CREATE TABLE agents (id uuid PRIMARY KEY)").run()
                try await CreateStorageDevices().prepare(on: database)
                try await test(database, sql)
            }
            try await rootSQL.raw("DROP SCHEMA \(ident: schemaName) CASCADE").run()
        } catch {
            if let sql = app.db as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS \(ident: schemaName) CASCADE").run()
            }
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func insertAgent(using sql: any SQLDatabase) async throws -> UUID {
        let id = UUID()
        try await sql.raw("INSERT INTO agents (id) VALUES (\(bind: id))").run()
        return id
    }

    private func makeDevice(
        agentID: UUID,
        identityKind: StorageDeviceIdentityKind? = .wwn,
        identityValue: String?,
        path: String = "/dev/sdb",
        uses: [StorageDeviceUse] = []
    ) -> StorageDevice {
        StorageDevice(
            agentID: agentID,
            identityKind: identityKind,
            identityValue: identityValue,
            devicePath: path,
            sizeBytes: 1_000_000,
            model: "Test Disk",
            serial: "SERIAL-1",
            wwn: "0x5000CCA1",
            rotational: false,
            uses: uses,
            role: .unassigned,
            state: .available,
            present: true,
            lastSeenAt: Date())
    }

    private func insertRawDevice(
        using sql: any SQLDatabase,
        agentID: UUID,
        identityKind: String?,
        identityValue: String?,
        sizeBytes: Int64 = 1_000_000,
        role: String = "unassigned",
        state: String = "available"
    ) async throws {
        try await sql.raw(
            """
            INSERT INTO storage_devices
                (id, agent_id, identity_kind, identity_value, device_path,
                 size_bytes, rotational, role, state, present, last_seen_at)
            VALUES
                (\(bind: UUID()), \(bind: agentID), \(bind: identityKind), \(bind: identityValue),
                 '/dev/sdy', \(bind: sizeBytes), false, \(bind: role), \(bind: state), true, NOW())
            """
        ).run()
    }
}
