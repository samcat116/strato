import Fluent
import Foundation
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

@Suite("Storage Pool Tests", .serialized)
struct StoragePoolTests {
    private let resources = AgentResources(
        totalCPU: 8, availableCPU: 8,
        totalMemory: 16_000_000_000, availableMemory: 16_000_000_000,
        totalDisk: 100_000_000_000, availableDisk: 100_000_000_000)

    private func makePool(mode: StoragePoolMode, siteID: UUID? = nil) -> StoragePool {
        StoragePool(
            name: "test", mode: mode, memberAgentIds: [], backing: .filesystem,
            siteID: mode == .ceph ? siteID : nil,
            cephClusterID: mode == .ceph ? UUID() : nil,
            cephProjectAccessID: mode == .ceph ? UUID() : nil,
            cephPoolName: mode == .ceph ? "rbd" : nil,
            cephNamespace: mode == .ceph ? "project" : nil)
    }

    private func makeAgent(
        id: UUID = UUID(), siteID: UUID? = nil, cephState: NodeDependencyFunctionalState? = nil,
        receivedAt: Date = Date(), status: AgentStatus = .online
    ) -> Agent {
        let observations: [NodeDependencyObservation]
        if let cephState {
            observations = [
                NodeDependencyObservation(
                    id: .cephClient, role: .storage, desiredState: .required,
                    ownership: .observeOnly, supervisorState: .notApplicable,
                    compatibility: .compatible, functionalState: cephState,
                    checkedAt: receivedAt, affectedCapabilities: [.cephVolumes])
            ]
        } else {
            observations = []
        }
        return Agent(
            id: id, name: "agent-\(id)", hostname: "agent.example", version: "test",
            siteID: siteID ?? UUID(), status: status, resources: resources,
            dependencyObservations: observations,
            dependencyObservationsReceivedAt: observations.isEmpty ? nil : receivedAt,
            lastHeartbeat: Date())
    }

    @Test("local pool reachability remains replica-local")
    func localPoolRequiresReplicaAgent() {
        let instant = ClusterInstant.testing(Date())
        let pool = makePool(mode: .local)
        let holder = makeAgent()
        let other = makeAgent()
        let holderID = holder.id!.uuidString

        #expect(StoragePool.agentCanReach(agent: holder, pool: pool, replicaAgentIds: [holderID], at: instant))
        #expect(!StoragePool.agentCanReach(agent: other, pool: pool, replicaAgentIds: [holderID], at: instant))
        #expect(StoragePool.agentCanReach(agent: other, pool: pool, replicaAgentIds: [], at: instant))
    }

    @Test("no pool behaves like local")
    func nilPoolBehavesLikeLocal() {
        let instant = ClusterInstant.testing(Date())
        let holder = makeAgent()
        let other = makeAgent()
        let holderID = holder.id!.uuidString
        #expect(StoragePool.agentCanReach(agent: holder, pool: nil, replicaAgentIds: [holderID], at: instant))
        #expect(!StoragePool.agentCanReach(agent: other, pool: nil, replicaAgentIds: [holderID], at: instant))
    }

    @Test("replicated pools remain fail closed")
    func replicatedPoolIsUnreachable() {
        let agent = makeAgent()
        #expect(
            !StoragePool.agentCanReach(
                agent: agent, pool: makePool(mode: .replicated),
                replicaAgentIds: [agent.id!.uuidString], at: .testing(Date())))
    }

    @Test("Ceph requires same site and a fresh healthy client capability")
    func cephReachability() {
        let now = Date()
        let instant = ClusterInstant.testing(now)
        let siteID = UUID()
        let pool = makePool(mode: .ceph, siteID: siteID)
        let eligible = makeAgent(siteID: siteID, cephState: .healthy, receivedAt: now)
        let wrongSite = makeAgent(siteID: UUID(), cephState: .healthy, receivedAt: now)
        let missing = makeAgent(siteID: siteID)
        let unhealthy = makeAgent(siteID: siteID, cephState: .unhealthy, receivedAt: now)
        let stale = makeAgent(
            siteID: siteID, cephState: .healthy,
            receivedAt: now.addingTimeInterval(-Agent.dependencyObservationStaleAfter - 1))

        #expect(StoragePool.agentCanReach(agent: eligible, pool: pool, replicaAgentIds: [], at: instant))
        #expect(!StoragePool.agentCanReach(agent: wrongSite, pool: pool, replicaAgentIds: [], at: instant))
        #expect(!StoragePool.agentCanReach(agent: missing, pool: pool, replicaAgentIds: [], at: instant))
        #expect(!StoragePool.agentCanReach(agent: unhealthy, pool: pool, replicaAgentIds: [], at: instant))
        #expect(!StoragePool.agentCanReach(agent: stale, pool: pool, replicaAgentIds: [], at: instant))
    }

    @Test("the schema baseline seeds the default local pool")
    func defaultPoolExists() async throws {
        try await withTestApp { app in
            let pool = try await StoragePool.defaultPool(on: app.db)
            #expect(pool.name == StoragePool.defaultPoolName)
            #expect(pool.mode == .local)
            #expect(pool.replicationFactor == 1)
            #expect(pool.memberAgentIds.isEmpty)
            #expect(pool.backing == .filesystem)
            #expect(pool.$site.id == nil)
            #expect(pool.$cephCluster.id == nil)
        }
    }
}
