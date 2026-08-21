import AppTestSupport
import Foundation
import PostgresNIO
import StratoShared
import Testing

@testable import ControlPlanePostgres

@Suite("Native storage-device persistence", .serialized)
struct StorageDevicesPersistenceTests {
    @Test("stable identity preserves row and operator intent across disappearance and renumbering")
    func stableIdentityPreservesIntent() async throws {
        try await withStorageDatabase { database, devices, agentID in
            let firstSeen = Date(timeIntervalSince1970: 100)
            let reappearedAt = Date(timeIntervalSince1970: 200)

            try await devices.reconcileInventory(
                [observation(wwn: "0x5000CCA1", serial: "SERIAL-1", path: "/dev/sdb")],
                forAgentID: agentID,
                receivedAt: firstSeen
            )
            let original = try #require(try await devices.devices(forAgentIDs: [agentID]).first)
            #expect(original.identity?.value == "5000cca1")
            #expect(original.createdAt != nil)
            #expect(original.updatedAt != nil)

            let selected = try await devices.setOSDEligibility(
                forDeviceID: original.id,
                eligible: true,
                now: firstSeen
            )
            #expect(selected.device.role == .osd)

            try await devices.reconcileInventory([], forAgentID: agentID, receivedAt: firstSeen)
            let missing = try #require(try await devices.device(id: original.id))
            #expect(!missing.present)
            #expect(missing.lastSeenAt == firstSeen)

            try await devices.reconcileInventory(
                [observation(wwn: "0x5000CCA1", serial: "SERIAL-1", path: "/dev/sdc")],
                forAgentID: agentID,
                receivedAt: reappearedAt
            )
            let rows = try await devices.devices(forAgentIDs: [agentID])
            let restored = try #require(rows.first)
            #expect(rows.count == 1)
            #expect(restored.id == original.id)
            #expect(restored.devicePath == "/dev/sdc")
            #expect(restored.role == .osd)
            #expect(restored.lastSeenAt == reappearedAt)
        }
    }

    @Test("JSONB array encoding preserves device uses exactly")
    func deviceUsesRoundTrip() async throws {
        try await withStorageDatabase { _, devices, agentID in
            let uses: [StorageDeviceUse] = [.mounted, .filesystem, .readOnly]
            try await devices.reconcileInventory(
                [observation(
                    wwn: "0x5000CCA2",
                    serial: nil,
                    path: "/dev/sdb",
                    state: .inUse,
                    uses: uses
                )],
                forAgentID: agentID,
                receivedAt: Date()
            )

            let stored = try #require(try await devices.devices(forAgentIDs: [agentID]).first)
            #expect(stored.uses == [.filesystem, .mounted, .readOnly])
        }
    }

    @Test("anonymous devices never carry intent across reports or paths")
    func anonymousDevicesNeverCarryIntent() async throws {
        try await withStorageDatabase { database, devices, agentID in
            let anonymous = observation(wwn: nil, serial: nil, path: "/dev/sdb")
            try await devices.reconcileInventory(
                [anonymous], forAgentID: agentID, receivedAt: Date(timeIntervalSince1970: 100))
            let original = try #require(try await devices.devices(forAgentIDs: [agentID]).first)

            try await database.withSession(operation: "test.storage_devices.seed_intent") { session in
                _ = try await session.execute(
                    SeedStorageDeviceIntent(id: original.id, role: .osd, osdID: 12),
                    operation: "test.storage_devices.seed_intent.query"
                )
            }
            try await devices.reconcileInventory(
                [anonymous], forAgentID: agentID, receivedAt: Date(timeIntervalSince1970: 110))
            let reset = try #require(try await devices.device(id: original.id))
            #expect(reset.role == .unassigned)
            #expect(reset.osdID == nil)

            try await devices.reconcileInventory(
                [], forAgentID: agentID, receivedAt: Date(timeIntervalSince1970: 120))
            try await devices.reconcileInventory(
                [observation(wwn: nil, serial: nil, path: "/dev/sdc")],
                forAgentID: agentID,
                receivedAt: Date(timeIntervalSince1970: 130)
            )
            let rows = try await devices.devices(forAgentIDs: [agentID])
                .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            #expect(rows.count == 2)
            #expect(rows[0].present == false)
            #expect(rows[1].devicePath == "/dev/sdc")
            #expect(rows[1].role == .unassigned)
        }
    }

    @Test("invalid inventory is rejected before existing rows change")
    func invalidInventoryIsAtomic() async throws {
        try await withStorageDatabase { _, devices, agentID in
            try await devices.reconcileInventory(
                [observation(wwn: "0x5000CCA1", serial: nil, path: "/dev/sdb")],
                forAgentID: agentID,
                receivedAt: Date(timeIntervalSince1970: 100)
            )
            let before = try #require(try await devices.devices(forAgentIDs: [agentID]).first)

            await #expect(throws: StorageDeviceInventoryError.self) {
                try await devices.reconcileInventory(
                    [observation(
                        wwn: "0x5000CCA1",
                        serial: nil,
                        path: "/dev/sdb",
                        state: .available,
                        uses: [.filesystem]
                    )],
                    forAgentID: agentID,
                    receivedAt: Date(timeIntervalSince1970: 200)
                )
            }

            let after = try #require(try await devices.device(id: before.id))
            #expect(after == before)
        }
    }

    @Test("eligibility mutation revalidates safety facts while disabling remains available")
    func eligibilityMutation() async throws {
        try await withStorageDatabase { _, devices, agentID in
            let now = Date(timeIntervalSince1970: 1_000)
            try await devices.reconcileInventory(
                [observation(wwn: "0x5000CCA1", serial: nil, path: "/dev/sdb")],
                forAgentID: agentID,
                receivedAt: now
            )
            let device = try #require(try await devices.devices(forAgentIDs: [agentID]).first)

            let enabled = try await devices.setOSDEligibility(
                forDeviceID: device.id,
                eligible: true,
                now: now
            )
            #expect(enabled.device.role == .osd)

            try await devices.reconcileInventory([], forAgentID: agentID, receivedAt: now)
            let stillSelected = try #require(try await devices.device(id: device.id))
            #expect(stillSelected.role == .osd)
            let disabled = try await devices.setOSDEligibility(
                forDeviceID: device.id,
                eligible: false,
                now: now
            )
            #expect(disabled.device.role == .unassigned)

            await #expect(throws: StorageDevicePersistenceError.self) {
                try await devices.setOSDEligibility(
                    forDeviceID: device.id,
                    eligible: true,
                    now: now
                )
            }
        }
    }

    @Test("stable identities are unique per agent and isolated across agents")
    func identityUniquenessAndAgentIsolation() async throws {
        try await withStorageDatabase { database, devices, firstAgentID in
            let secondAgentID = UUID()
            try await insertAgent(secondAgentID, heartbeat: Date(), using: database)
            let disk = observation(wwn: "0x5000CCA1", serial: nil, path: "/dev/sdb")
            try await devices.reconcileInventory(
                [disk], forAgentID: firstAgentID, receivedAt: Date())
            try await devices.reconcileInventory(
                [disk], forAgentID: secondAgentID, receivedAt: Date())

            try await devices.reconcileInventory([], forAgentID: firstAgentID, receivedAt: Date())
            let secondRows = try await devices.devices(forAgentIDs: [secondAgentID])
            #expect(secondRows.count == 1)
            #expect(secondRows[0].present)
        }
    }

    private func withStorageDatabase(
        _ test: (
            ControlPlanePostgres.PostgresDatabase, StorageDevicesPersistence, UUID
        ) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase { database in
            try await database.withSession(operation: "test.storage_devices.schema") { session in
                try await session.command(
                    """
                    CREATE TABLE agents (
                        id UUID PRIMARY KEY,
                        last_heartbeat TIMESTAMPTZ
                    )
                    """,
                    operation: "test.storage_devices.schema.agents"
                )
                try await session.command(
                    """
                    CREATE TABLE storage_devices (
                        id UUID PRIMARY KEY,
                        agent_id UUID NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
                        identity_kind TEXT,
                        identity_value TEXT,
                        device_path TEXT NOT NULL,
                        size_bytes BIGINT NOT NULL,
                        model TEXT,
                        serial TEXT,
                        wwn TEXT,
                        rotational BOOL NOT NULL,
                        uses JSONB[] NOT NULL DEFAULT '{}',
                        role TEXT NOT NULL,
                        state TEXT NOT NULL,
                        osd_id BIGINT,
                        present BOOL NOT NULL,
                        last_seen_at TIMESTAMPTZ NOT NULL,
                        created_at TIMESTAMPTZ,
                        updated_at TIMESTAMPTZ,
                        CONSTRAINT ck_storage_devices_identity_pair
                            CHECK ((identity_kind IS NULL) = (identity_value IS NULL)),
                        CONSTRAINT ck_storage_devices_identity_kind
                            CHECK (identity_kind IS NULL OR identity_kind IN ('wwn', 'serial')),
                        CONSTRAINT ck_storage_devices_size_bytes CHECK (size_bytes >= 0),
                        CONSTRAINT ck_storage_devices_role
                            CHECK (role IN ('unassigned', 'osd', 'excluded')),
                        CONSTRAINT ck_storage_devices_state
                            CHECK (state IN ('available', 'inUse', 'draining', 'faulted'))
                    )
                    """,
                    operation: "test.storage_devices.schema.devices"
                )
                try await session.command(
                    """
                    CREATE UNIQUE INDEX uq_storage_devices_agent_identity
                    ON storage_devices (agent_id, identity_kind, identity_value)
                    """,
                    operation: "test.storage_devices.schema.identity_index"
                )
            }

            let agentID = UUID()
            try await insertAgent(
                agentID,
                heartbeat: Date(timeIntervalSince1970: 1_000),
                using: database
            )
            try await test(database, ControlPlanePersistence(database: database).storageDevices, agentID)
        }
    }

    private func observation(
        wwn: String?,
        serial: String?,
        path: String,
        state: StorageDeviceState = .available,
        uses: [StorageDeviceUse] = []
    ) -> ObservedStorageDevice {
        ObservedStorageDevice(
            identity: StorageDeviceIdentity.preferred(wwn: wwn, serial: serial),
            devicePath: path,
            sizeBytes: 100,
            model: "Disk",
            serial: serial,
            wwn: wwn,
            rotational: false,
            state: state,
            uses: uses
        )
    }

    private func insertAgent(
        _ id: UUID,
        heartbeat: Date,
        using database: ControlPlanePostgres.PostgresDatabase
    ) async throws {
        try await database.withSession(operation: "test.storage_devices.insert_agent") { session in
            _ = try await session.execute(
                InsertStorageAgent(id: id, heartbeat: heartbeat),
                operation: "test.storage_devices.insert_agent.query"
            )
        }
    }
}

private struct InsertStorageAgent: PostgresPreparedStatement {
    static let sql = "INSERT INTO agents (id, last_heartbeat) VALUES ($1, $2)"
    typealias Row = Void
    let id: UUID
    let heartbeat: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(heartbeat)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws {}
}

private struct SeedStorageDeviceIntent: PostgresPreparedStatement {
    static let sql = "UPDATE storage_devices SET role = $2, osd_id = $3 WHERE id = $1"
    typealias Row = Void
    let id: UUID
    let role: StorageDeviceRole
    let osdID: Int

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(role.rawValue)
        bindings.append(osdID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws {}
}
