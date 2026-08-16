import AppTestSupport
import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
import StratoShared
import Testing
import Vapor

@testable import App

@Suite("Storage device inventory reconciliation", .serialized)
struct StorageDeviceInventoryReconcilerTests {
    @Test("an empty snapshot retains rows and marks them missing")
    func emptySnapshotMarksRowsMissing() async throws {
        try await withStorageSchema { database, agent in
            let existing = device(agentID: try agent.requireID(), identityValue: "disk-a")
            try await existing.save(on: database)

            try await StorageDeviceInventoryReconciler(database: database)
                .apply([], for: agent, receivedAt: Date())

            let stored = try #require(try await StorageDevice.find(existing.id, on: database))
            #expect(stored.present == false)
            #expect(stored.lastSeenAt == existing.lastSeenAt)
        }
    }

    @Test("WWN and serial identities survive path renumbering without losing operator intent")
    func stableIdentityPreservesIntentAcrossRenumbering() async throws {
        try await withStorageSchema { database, agent in
            let agentID = try agent.requireID()
            let receivedAt = Date()
            let wwn = device(agentID: agentID, identityKind: .wwn, identityValue: "5000cca1")
            wwn.role = .osd
            wwn.osdId = 7
            let serial = device(
                agentID: agentID,
                identityKind: .serial,
                identityValue: "SERIAL-2",
                path: "/dev/sdc")
            serial.role = .excluded
            try await wwn.save(on: database)
            try await serial.save(on: database)

            try await StorageDeviceInventoryReconciler(database: database).apply(
                [
                    observation(wwn: "0x5000CCA1", serial: "SERIAL-1", path: "/dev/sdd"),
                    observation(wwn: nil, serial: " SERIAL-2 ", path: "/dev/sde"),
                ],
                for: agent,
                receivedAt: receivedAt)

            let storedWWN = try #require(try await StorageDevice.find(wwn.id, on: database))
            let storedSerial = try #require(try await StorageDevice.find(serial.id, on: database))
            #expect(storedWWN.devicePath == "/dev/sdd")
            #expect(storedWWN.role == .osd)
            #expect(storedWWN.osdId == 7)
            #expect(storedWWN.lastSeenAt == receivedAt)
            #expect(storedSerial.devicePath == "/dev/sde")
            #expect(storedSerial.role == .excluded)
        }
    }

    @Test("a stable disk retains its row through disappearance and reappearance")
    func stableDeviceReappears() async throws {
        try await withStorageSchema { database, agent in
            let reconciler = StorageDeviceInventoryReconciler(database: database)
            let firstSeen = Date(timeIntervalSince1970: 100)
            let reappeared = Date(timeIntervalSince1970: 200)

            try await reconciler.apply(
                [observation(wwn: "0x5000CCA1", serial: "SERIAL-1", path: "/dev/sdb")],
                for: agent,
                receivedAt: firstSeen)
            let original = try #require(try await StorageDevice.query(on: database).first())
            original.role = .osd
            original.osdId = 9
            try await original.save(on: database)

            try await reconciler.apply([], for: agent, receivedAt: Date(timeIntervalSince1970: 150))
            try await reconciler.apply(
                [observation(wwn: "0x5000CCA1", serial: "SERIAL-1", path: "/dev/sdc")],
                for: agent,
                receivedAt: reappeared)

            let rows = try await StorageDevice.query(on: database).all()
            let stored = try #require(rows.first)
            #expect(rows.count == 1)
            #expect(stored.id == original.id)
            #expect(stored.present)
            #expect(stored.role == .osd)
            #expect(stored.osdId == 9)
            #expect(stored.devicePath == "/dev/sdc")
            #expect(stored.lastSeenAt == reappeared)
        }
    }

    @Test("anonymous disks correlate only at the same path while continuously present")
    func anonymousIdentityNeverCarriesIntent() async throws {
        try await withStorageSchema { database, agent in
            let reconciler = StorageDeviceInventoryReconciler(database: database)
            let anonymous = observation(wwn: nil, serial: nil, path: "/dev/sdb")

            try await reconciler.apply([anonymous], for: agent, receivedAt: Date())
            let original = try #require(try await StorageDevice.query(on: database).first())
            original.role = .osd
            original.osdId = 12
            try await original.save(on: database)

            try await reconciler.apply([anonymous], for: agent, receivedAt: Date())
            let reset = try #require(try await StorageDevice.find(original.id, on: database))
            #expect(reset.role == .unassigned)
            #expect(reset.osdId == nil)

            try await reconciler.apply([], for: agent, receivedAt: Date())
            try await reconciler.apply(
                [observation(wwn: nil, serial: nil, path: "/dev/sdc")],
                for: agent,
                receivedAt: Date())

            let rows = try await StorageDevice.query(on: database)
                .sort(\.$createdAt)
                .all()
            #expect(rows.count == 2)
            #expect(rows[0].present == false)
            #expect(rows[1].devicePath == "/dev/sdc")
            #expect(rows[1].role == .unassigned)
        }
    }

    @Test("one agent's snapshot never changes another agent's rows")
    func agentsAreIsolated() async throws {
        try await withStorageSchema { database, agent in
            let sql = try #require(database as? any SQLDatabase)
            let otherAgentID = UUID()
            try await sql.raw("INSERT INTO agents (id) VALUES (\(bind: otherAgentID))").run()
            let other = device(agentID: otherAgentID, identityValue: "other")
            try await other.save(on: database)

            try await StorageDeviceInventoryReconciler(database: database)
                .apply([], for: agent, receivedAt: Date())

            let stored = try #require(try await StorageDevice.find(other.id, on: database))
            #expect(stored.present)
        }
    }

    @Test("invalid facts reject the complete snapshot before any row changes")
    func invalidSnapshotsAreAtomicNoOps() async throws {
        try await withStorageSchema { database, agent in
            let existing = device(agentID: try agent.requireID(), identityValue: "existing")
            try await existing.save(on: database)
            let reconciler = StorageDeviceInventoryReconciler(database: database)
            let valid = observation(wwn: "0x5000CCA1", serial: "SERIAL-1", path: "/dev/sdb")
            let invalidSnapshots: [[ObservedStorageDevice]] = [
                [valid, valid],
                [valid, observation(wwn: "0x5000CCA2", serial: nil, path: "/dev/sdb")],
                [observation(wwn: "0x5000CCA1", serial: nil, path: "sdb")],
                [observation(wwn: "0x5000CCA1", serial: nil, path: "/dev/sdb", sizeBytes: -1)],
                [
                    ObservedStorageDevice(
                        identity: .init(kind: .serial, value: "SERIAL-1"),
                        devicePath: "/dev/sdb", sizeBytes: 100, serial: "SERIAL-1",
                        wwn: "0x5000CCA1", rotational: false, state: .available, uses: [])
                ],
                [observation(wwn: "0x5000CCA1", serial: nil, path: "/dev/sdb", state: .draining)],
                [
                    observation(
                        wwn: "0x5000CCA1", serial: nil, path: "/dev/sdb",
                        state: .inUse, uses: [.filesystem, .filesystem])
                ],
                [
                    observation(
                        wwn: "0x5000CCA1", serial: nil, path: "/dev/sdb",
                        state: .available, uses: [.filesystem])
                ],
                [observation(wwn: "0x5000CCA1", serial: nil, path: "/dev/sdb", state: .inUse)],
                [
                    observation(
                        wwn: "0x5000CCA1", serial: nil, path: "/dev/sdb",
                        sizeBytes: 0, state: .available)
                ],
            ]

            for snapshot in invalidSnapshots {
                await #expect(throws: StorageDeviceInventoryError.self) {
                    try await reconciler.apply(snapshot, for: agent, receivedAt: Date())
                }
                let unchanged = try #require(try await StorageDevice.find(existing.id, on: database))
                #expect(unchanged.present)
                #expect(unchanged.devicePath == "/dev/sdb")
            }
        }
    }

    private func withStorageSchema(
        _ test: @escaping @Sendable (any Database, Agent) async throws -> Void
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
        let schemaName = "storage_reconcile_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        do {
            let rootSQL = try #require(app.db as? any SQLDatabase)
            try await rootSQL.raw("CREATE SCHEMA \(ident: schemaName)").run()
            try await app.db.withConnection { database in
                let sql = try #require(database as? any SQLDatabase)
                try await sql.raw("SET search_path TO \(ident: schemaName)").run()
                try await sql.raw("CREATE TABLE agents (id uuid PRIMARY KEY)").run()
                try await CreateStorageDevices().prepare(on: database)
                let agentID = UUID()
                try await sql.raw("INSERT INTO agents (id) VALUES (\(bind: agentID))").run()
                try await test(database, agent(id: agentID))
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

    private func agent(id: UUID) -> Agent {
        Agent(
            id: id,
            name: "storage-agent",
            hostname: "storage-agent.example",
            version: "1.0.0",
            status: .online,
            resources: AgentResources(
                totalCPU: 8, availableCPU: 8,
                totalMemory: 16_000, availableMemory: 16_000,
                totalDisk: 100_000, availableDisk: 100_000))
    }

    private func device(
        agentID: UUID,
        identityKind: StorageDeviceIdentityKind = .wwn,
        identityValue: String,
        path: String = "/dev/sdb"
    ) -> StorageDevice {
        StorageDevice(
            agentID: agentID,
            identityKind: identityKind,
            identityValue: identityValue,
            devicePath: path,
            sizeBytes: 100,
            serial: identityKind == .serial ? identityValue : "SERIAL-1",
            wwn: identityKind == .wwn ? identityValue : nil,
            rotational: false,
            uses: [],
            state: .available,
            present: true,
            lastSeenAt: Date(timeIntervalSince1970: 50))
    }

    private func observation(
        wwn: String?,
        serial: String?,
        path: String,
        sizeBytes: Int64 = 100,
        state: StorageDeviceState = .available,
        uses: [StorageDeviceUse] = []
    ) -> ObservedStorageDevice {
        ObservedStorageDevice(
            identity: StorageDeviceIdentity.preferred(wwn: wwn, serial: serial),
            devicePath: path,
            sizeBytes: sizeBytes,
            model: "Disk",
            serial: serial,
            wwn: wwn,
            rotational: false,
            state: state,
            uses: uses)
    }
}
