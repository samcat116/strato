import Fluent
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

    @Test("replicated pools fail closed until a coherent backend exists")
    func replicatedPoolIsUnreachable() {
        let pool = makePool(mode: .replicated, members: ["agent-a", "agent-b", "agent-c"])

        #expect(!StoragePool.agentCanReach(agentId: "agent-a", pool: pool, replicaAgentIds: ["agent-a"]))
        #expect(!StoragePool.agentCanReach(agentId: "agent-d", pool: pool, replicaAgentIds: ["agent-a", "agent-b"]))
        #expect(!StoragePool.agentCanReach(agentId: "agent-c", pool: pool, replicaAgentIds: ["agent-a", "agent-b"]))
    }

    // MARK: - Default pool (baseline-seeded)

    @Test("the schema baseline seeds the default local pool")
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

}
