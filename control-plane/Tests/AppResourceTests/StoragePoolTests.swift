import ControlPlanePostgres
import Foundation
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Storage phase 1 (issue #349): the pool/replica data model. Covers the
/// pool-aware reachability guard and the baseline-seeded default pool.
@Suite("Storage Pool Tests", .serialized)
struct StoragePoolTests {

    // MARK: - Reachability (pure logic)

    private func makePool(mode: StoragePoolMode, members: [String] = []) -> StoragePoolSnapshot {
        StoragePoolSnapshot(
            id: UUID(), name: "test", mode: mode,
            memberAgentIDs: members, backing: .filesystem)
    }

    @Test("local pool: only the agent holding the replica reaches the volume")
    func localPoolRequiresReplicaAgent() {
        let pool = makePool(mode: .local)

        #expect(StoragePoolsPersistence.agentCanReach(agentID: "agent-a", pool: pool, replicaAgentIDs: ["agent-a"]))
        #expect(!StoragePoolsPersistence.agentCanReach(agentID: "agent-b", pool: pool, replicaAgentIDs: ["agent-a"]))
    }

    @Test("local pool: a volume with no replicas yet is reachable from anywhere")
    func localPoolUnprovisionedVolumeIsUnrestricted() {
        // Matches the old guard's behavior when no hypervisor was recorded.
        let pool = makePool(mode: .local)

        #expect(StoragePoolsPersistence.agentCanReach(agentID: "agent-a", pool: pool, replicaAgentIDs: []))
    }

    @Test("no pool behaves like a local pool")
    func nilPoolBehavesLikeLocal() {
        #expect(StoragePoolsPersistence.agentCanReach(agentID: "agent-a", pool: nil, replicaAgentIDs: ["agent-a"]))
        #expect(!StoragePoolsPersistence.agentCanReach(agentID: "agent-b", pool: nil, replicaAgentIDs: ["agent-a"]))
        #expect(StoragePoolsPersistence.agentCanReach(agentID: "agent-b", pool: nil, replicaAgentIDs: []))
    }

    @Test("replicated pools fail closed until a coherent backend exists")
    func replicatedPoolIsUnreachable() {
        let pool = makePool(mode: .replicated, members: ["agent-a", "agent-b", "agent-c"])

        #expect(!StoragePoolsPersistence.agentCanReach(agentID: "agent-a", pool: pool, replicaAgentIDs: ["agent-a"]))
        #expect(!StoragePoolsPersistence.agentCanReach(agentID: "agent-d", pool: pool, replicaAgentIDs: ["agent-a", "agent-b"]))
        #expect(!StoragePoolsPersistence.agentCanReach(agentID: "agent-c", pool: pool, replicaAgentIDs: ["agent-a", "agent-b"]))
    }

    // MARK: - Default pool (baseline-seeded)

    @Test("the schema baseline seeds the default local pool")
    func defaultPoolExists() async throws {
        try await withTestApp { app in
            let pool = try await app.storagePoolsPersistence.defaultPool()

            #expect(pool.name == StoragePoolsPersistence.defaultPoolName)
            #expect(pool.mode == .local)
            #expect(pool.replicationFactor == 1)
            #expect(pool.memberAgentIDs.isEmpty)
            #expect(pool.backing == .filesystem)
        }
    }

}
