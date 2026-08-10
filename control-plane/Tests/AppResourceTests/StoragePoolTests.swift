import Fluent
import Foundation
import SQLKit
import Testing
import Vapor
import VaporTesting
import StratoShared

import AppTestSupport
@testable import App

/// Storage phase 1 (issue #349): the pool/replica data model. Covers the
/// pool-aware reachability guard, the migration-seeded default pool, and the
/// backfill that adopts legacy volumes (hypervisor_id + storage_path) into the
/// default pool with a replica row.
@Suite("Storage Pool Tests", .serialized)
struct StoragePoolTests {

    // MARK: - Reachability (pure logic)

    private func makePool(mode: StoragePoolMode, members: [String] = []) -> StoragePool {
        StoragePool(name: "test", mode: mode, memberAgentIds: members, backing: .filesystem)
    }

    @Test("local pool: only the agent holding the replica reaches the volume")
    func localPoolRequiresReplicaAgent() {
        let pool = makePool(mode: .local)

        #expect(StoragePool.agentCanReach(agentId: "agent-a", pool: pool, replicaAgentIds: ["agent-a"]))
        #expect(!StoragePool.agentCanReach(agentId: "agent-b", pool: pool, replicaAgentIds: ["agent-a"]))
    }

    @Test("local pool: a volume with no replicas yet is reachable from anywhere")
    func localPoolUnprovisionedVolumeIsUnrestricted() {
        // Matches the old guard's behavior when no hypervisor was recorded.
        let pool = makePool(mode: .local)

        #expect(StoragePool.agentCanReach(agentId: "agent-a", pool: pool, replicaAgentIds: []))
    }

    @Test("no pool behaves like a local pool")
    func nilPoolBehavesLikeLocal() {
        #expect(StoragePool.agentCanReach(agentId: "agent-a", pool: nil, replicaAgentIds: ["agent-a"]))
        #expect(!StoragePool.agentCanReach(agentId: "agent-b", pool: nil, replicaAgentIds: ["agent-a"]))
        #expect(StoragePool.agentCanReach(agentId: "agent-b", pool: nil, replicaAgentIds: []))
    }

    @Test("replicated pool: membership decides, independent of replica placement")
    func replicatedPoolUsesMembership() {
        let pool = makePool(mode: .replicated, members: ["agent-a", "agent-b", "agent-c"])

        // A member reaches the replica set over the network even when it
        // holds no replica itself.
        #expect(StoragePool.agentCanReach(agentId: "agent-c", pool: pool, replicaAgentIds: ["agent-a", "agent-b"]))
        #expect(!StoragePool.agentCanReach(agentId: "agent-d", pool: pool, replicaAgentIds: ["agent-a", "agent-b"]))
    }

    @Test("replicated pool with no member restriction accepts any agent")
    func replicatedPoolEmptyMembersIsUnrestricted() {
        let pool = makePool(mode: .replicated)

        #expect(StoragePool.agentCanReach(agentId: "anyone", pool: pool, replicaAgentIds: ["agent-a"]))
    }

    // MARK: - Default pool (migration-seeded)

    @Test("migrations seed the default local pool")
    func defaultPoolExists() async throws {
        try await withTestApp { app in
            let pool = try await StoragePool.defaultPool(on: app.db)

            #expect(pool.name == StoragePool.defaultPoolName)
            #expect(pool.mode == .local)
            #expect(pool.replicationFactor == 1)
            #expect(pool.memberAgentIds.isEmpty)
            #expect(pool.backing == .filesystem)
        }
    }

    // MARK: - Backfill

    private func registerAgent(on app: Application, named name: String) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: name,
            hostname: "\(name).test",
            version: "1.0.0",
            capabilities: ["qemu"],
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            protocolVersion: WireProtocol.currentVersion
        )
        let org = try await TestDataBuilder(db: app.db).createOrganization(
            name: "Cutover Agent Org \(name)")
        let id = try await app.agentService.registerAgent(
            message, agentName: name,
            organizationScope: .organization(try org.requireID()))
        return id.uuidString
    }

    /// A volume shaped like a pre-pool row: legacy placement columns set, no
    /// pool, no replicas.
    private func createLegacyVolume(
        on db: Database,
        name: String,
        hypervisorId: String?,
        storagePath: String?,
        vm: VM? = nil
    ) async throws -> Volume {
        let builder = TestDataBuilder(db: db)
        let user = try await builder.createUser(username: "pooluser-\(name)", email: "\(name)@example.com")
        let org = try await builder.createOrganization(name: "Pool Org \(name)")
        let project = try await builder.createProject(name: "pool-project-\(name)", description: "", organization: org)

        let volume = Volume(
            name: name,
            description: "",
            projectID: project.id!, environment: "development",
            size: 1024 * 1024 * 1024,
            status: hypervisorId == nil ? .creating : .available,
            createdByID: user.id!
        )
        if let vm {
            volume.$vm.id = vm.id
            // An attached row names its device: `NormalizeVolumeAttachments`
            // makes that a check constraint (STR-129).
            volume.deviceName = "disk0"
            volume.status = .attached
        }
        try await volume.save(on: db)
        let sql = try #require(db as? any SQLDatabase)
        try await sql.raw(
            "ALTER TABLE volumes ADD COLUMN IF NOT EXISTS hypervisor_id text"
        ).run()
        try await sql.raw(
            "ALTER TABLE volumes ADD COLUMN IF NOT EXISTS storage_path text"
        ).run()
        try await sql.raw(
            """
            UPDATE volumes
            SET hypervisor_id = \(bind: hypervisorId),
                storage_path = \(bind: storagePath)
            WHERE id = \(bind: try volume.requireID())
            """
        ).run()
        return volume
    }

    @Test("backfill adopts a legacy volume into the default pool with one healthy replica")
    func backfillCreatesPoolAndReplica() async throws {
        try await withTestApp { app in
            let volume = try await createLegacyVolume(
                on: app.db,
                name: "legacy",
                hypervisorId: "agent-1",
                storagePath: "/var/lib/strato/volumes/legacy.qcow2"
            )

            try await BackfillVolumePools().prepare(on: app.db)

            let found = try await Volume.find(volume.id, on: app.db)
            let migrated = try #require(found)
            let defaultPool = try await StoragePool.defaultPool(on: app.db)
            #expect(migrated.$pool.id == defaultPool.id)

            let replicas = try await VolumeReplica.query(on: app.db)
                .filter(\.$volume.$id == volume.id!)
                .all()
            #expect(replicas.count == 1)
            let replica = try #require(replicas.first)
            #expect(replica.agentId == "agent-1")
            #expect(replica.datasetPath == "/var/lib/strato/volumes/legacy.qcow2")
            #expect(replica.state == .healthy)
            #expect(replica.generation == 0)

            // Unattached volume: no attachment agent to record.
            #expect(migrated.attachedAgentId == nil)
        }
    }

    @Test("backfill records the attachment agent for an attached volume")
    func backfillSetsAttachedAgentId() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Attach Backfill Org")
            let project = try await builder.createProject(
                name: "attach-backfill", description: "", organization: org)
            let vm = try await builder.createVM(name: "attach-backfill-vm", project: project)

            let volume = try await createLegacyVolume(
                on: app.db,
                name: "attached-legacy",
                hypervisorId: "agent-2",
                storagePath: "/var/lib/strato/volumes/attached.qcow2",
                vm: vm
            )

            try await BackfillVolumePools().prepare(on: app.db)

            let found = try await Volume.find(volume.id, on: app.db)
            let migrated = try #require(found)
            #expect(migrated.attachedAgentId == "agent-2")
        }
    }

    @Test("backfill skips never-provisioned volumes and is idempotent")
    func backfillIsGuardedAndIdempotent() async throws {
        try await withTestApp { app in
            let unprovisioned = try await createLegacyVolume(
                on: app.db, name: "unprovisioned", hypervisorId: nil, storagePath: nil)
            let placed = try await createLegacyVolume(
                on: app.db, name: "placed", hypervisorId: "agent-3", storagePath: "/vols/placed.qcow2")

            try await BackfillVolumePools().prepare(on: app.db)
            try await BackfillVolumePools().prepare(on: app.db)

            // Both volumes join the pool; only the placed one gets a replica,
            // and re-running doesn't duplicate it.
            let defaultPool = try await StoragePool.defaultPool(on: app.db)
            let foundUnprovisioned = try await Volume.find(unprovisioned.id, on: app.db)
            let migratedUnprovisioned = try #require(foundUnprovisioned)
            #expect(migratedUnprovisioned.$pool.id == defaultPool.id)
            let unprovisionedReplicas = try await VolumeReplica.query(on: app.db)
                .filter(\.$volume.$id == unprovisioned.id!)
                .count()
            #expect(unprovisionedReplicas == 0)

            let placedReplicas = try await VolumeReplica.query(on: app.db)
                .filter(\.$volume.$id == placed.id!)
                .count()
            #expect(placedReplicas == 1)
        }
    }

    @Test("replica rows are deleted with their volume")
    func replicaCascadesOnVolumeDelete() async throws {
        try await withTestApp { app in
            let volume = try await createLegacyVolume(
                on: app.db, name: "cascade", hypervisorId: "agent-4", storagePath: "/vols/cascade.qcow2")
            try await BackfillVolumePools().prepare(on: app.db)

            try await volume.delete(on: app.db)

            let orphaned = try await VolumeReplica.query(on: app.db)
                .filter(\.$volume.$id == volume.id!)
                .count()
            #expect(orphaned == 0)
        }
    }

    // MARK: - Authoritative cutover

    @Test("authoritative cutover backfills a valid live volume before dropping legacy columns")
    func authoritativeCutoverBackfillsAndDropsLegacyColumns() async throws {
        try await withTestApp { app in
            let agentID = try await registerAgent(on: app, named: "cutover-agent")
            let volume = try await createLegacyVolume(
                on: app.db,
                name: "cutover-valid",
                hypervisorId: agentID,
                storagePath: "/volumes/cutover-valid.qcow2")

            try await MakeVolumeReplicasAuthoritative().prepare(on: app.db)

            let replica = try #require(
                try await VolumeReplica.query(on: app.db)
                    .filter(\.$volume.$id == volume.id!)
                    .first())
            #expect(replica.agentId == agentID)
            #expect(replica.datasetPath == "/volumes/cutover-valid.qcow2")

            let sql = try #require(app.db as? any SQLDatabase)
            struct ColumnCount: Decodable { let count: Int }
            let remaining = try await sql.raw(
                """
                SELECT COUNT(*)::int AS count
                FROM information_schema.columns
                WHERE table_schema = current_schema()
                  AND table_name = 'volumes'
                  AND column_name IN ('hypervisor_id', 'storage_path')
                """
            ).first(decoding: ColumnCount.self)
            #expect(remaining?.count == 0)
        }
    }

    @Test("authoritative cutover refuses to discard the only legacy placement")
    func authoritativeCutoverRejectsMissingReplica() async throws {
        try await withTestApp { app in
            _ = try await createLegacyVolume(
                on: app.db,
                name: "cutover-invalid",
                hypervisorId: nil,
                storagePath: "/volumes/unplaced.qcow2")

            await #expect(throws: MakeVolumeReplicasAuthoritative.InvalidReplicaInventory.self) {
                try await MakeVolumeReplicasAuthoritative().prepare(on: app.db)
            }

            let sql = try #require(app.db as? any SQLDatabase)
            struct ColumnCount: Decodable { let count: Int }
            let remaining = try await sql.raw(
                """
                SELECT COUNT(*)::int AS count
                FROM information_schema.columns
                WHERE table_schema = current_schema()
                  AND table_name = 'volumes'
                  AND column_name IN ('hypervisor_id', 'storage_path')
                """
            ).first(decoding: ColumnCount.self)
            #expect(remaining?.count == 2)
        }
    }
}
