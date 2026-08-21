import Foundation
import Testing
import Vapor
import StratoShared
import AppTestSupport
@testable import App

/// Collects pub/sub deliveries for assertions.
private actor MessageCollector {
    private(set) var messages: [String] = []
    func append(_ message: String) { messages.append(message) }

    /// Poll until at least `count` messages arrived or the timeout elapses.
    func waitFor(count: Int, timeoutMilliseconds: Int = 2000) async -> [String] {
        for _ in 0..<(timeoutMilliseconds / 20) {
            if messages.count >= count { return messages }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return messages
    }
}

/// Store-level tests for what is left of the phase-3 primitives (issue #261)
/// once STR-152 removed the socket-route key and the value-carrying store
/// operations that existed to serve it: pub/sub, and the doorbell payloads
/// built on it.
@Suite("Replica Routing Primitive Tests")
struct ReplicaRoutingPrimitiveTests {

    private func makeService() -> (CoordinationService, InMemoryCoordinationStore) {
        let store = InMemoryCoordinationStore()
        return (CoordinationService(store: store, logger: Logger(label: "routing-test")), store)
    }

    @Test("Published messages reach every subscriber of the channel")
    func publishSubscribe() async {
        let (_, store) = makeService()
        let collectorA = MessageCollector()
        let collectorB = MessageCollector()
        let other = MessageCollector()

        await store.subscribe(channel: "chan-1") { message in
            Task { await collectorA.append(message) }
        }
        await store.subscribe(channel: "chan-1") { message in
            Task { await collectorB.append(message) }
        }
        await store.subscribe(channel: "chan-2") { message in
            Task { await other.append(message) }
        }

        await store.publish(channel: "chan-1", message: "hello")

        #expect(await collectorA.waitFor(count: 1) == ["hello"])
        #expect(await collectorB.waitFor(count: 1) == ["hello"])
        #expect(await other.waitFor(count: 1, timeoutMilliseconds: 200).isEmpty)
    }

    @Test("Doorbells land on the one fleet-wide channel, tagged with the publisher")
    func doorbellPublish() async {
        let (service, store) = makeService()
        let collector = MessageCollector()

        await store.subscribe(channel: CoordinationService.doorbellChannel) { message in
            Task { await collector.append(message) }
        }

        await service.publishDoorbell(agentKey: agentKey("agent-a"), fromReplica: "replica-9")

        let received = await collector.waitFor(count: 1)
        #expect(received.count == 1)
        let parsed = received.first.flatMap(CoordinationService.parseDoorbell)
        #expect(parsed?.replicaId == "replica-9")
        #expect(parsed?.agentKey == agentKey("agent-a"))
    }

    /// A SPIFFE ID contains no `|`, so one separator is enough to split the
    /// payload — but a payload that arrives malformed must be recognizable as
    /// such rather than silently splitting somewhere arbitrary.
    @Test("Doorbell payloads round-trip and malformed ones parse to nil")
    func doorbellPayloadRoundTrip() {
        let payload = CoordinationService.doorbellPayload(
            agentKey: agentKey("agent-a"), fromReplica: "replica-9")
        let parsed = CoordinationService.parseDoorbell(payload)
        #expect(parsed?.replicaId == "replica-9")
        #expect(parsed?.agentKey == agentKey("agent-a"))

        #expect(CoordinationService.parseDoorbell("no-separator") == nil)
        #expect(CoordinationService.parseDoorbell("|agent") == nil)
        #expect(CoordinationService.parseDoorbell("replica|") == nil)
    }
}

/// AgentService-level doorbell tests (issue #261, STR-146): a mutation rings
/// the fleet-wide broadcast without consulting any directory, an offline agent
/// is rung anyway, and a socket close marks the agent offline.
///
/// The route-key half of this suite — registration claiming
/// `agent:{name}:replica`, a close deferring to a foreign claim, and the two
/// cross-replica RPC round trips — went with the directory itself in STR-152.
@Suite("Replica Routing AgentService Tests", .serialized)
final class ReplicaRoutingAgentServiceTests {

    /// App harness with a shared coordination store injected before the
    /// AgentService exists, standing in for the store both "replicas" of a
    /// cluster would share.
    private func withApp(
        _ test: (Application, CoordinationService, InMemoryCoordinationStore) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)

            let store = InMemoryCoordinationStore()
            let coordination = CoordinationService(store: store, logger: app.logger)
            app.coordination = coordination

            try await test(app, coordination, store)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    private func registerAgent(
        app: Application,
        named agentName: String = "routed-agent"
    ) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: agentName,
            hostname: "test-host",
            version: "1.0.0",
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            protocolVersion: WireProtocol.currentVersion
        )
        // New agents need an owning org; this harness creates no other data,
        // so mint one on first use.
        let orgID: UUID
        if let existing = try await Organization.all(on: app.testPostgres).first {
            orgID = try existing.requireID()
        } else {
            let org = Organization(name: "Routing Org", description: "org for routing tests")
            try await org.save(on: app.testPostgres)
            orgID = try org.requireID()
        }
        let agentUUID = try await app.agentService.registerAgent(
            message, agentName: agentName, organizationScope: .organization(orgID))
        return agentUUID.uuidString
    }

    /// The point of the broadcast: a mutation publishes without consulting
    /// any routing key, so wherever the agent's poll or socket happens to live
    /// is not this replica's problem.
    @Test("A sync rings the broadcast doorbell regardless of where the agent is")
    func syncRingsBroadcastDoorbell() async throws {
        try await withApp { app, _, store in
            let agentId = try await self.registerAgent(app: app)

            // The agent's socket lives elsewhere — this test holds none — and
            // nothing here says where, which is the point.
            let collector = MessageCollector()
            await store.subscribe(channel: CoordinationService.doorbellChannel) { message in
                Task { await collector.append(message) }
            }

            await app.agentService.syncDesiredState(agentId: agentId)

            let received = await collector.waitFor(count: 1)
            #expect(
                received.compactMap { CoordinationService.parseDoorbell($0)?.agentKey }
                    == [agentKey("routed-agent")])
        }
    }

    /// An offline agent still gets a doorbell — over-ringing is free, and
    /// suppressing it would mean re-introducing the routing lookup the
    /// broadcast exists to remove. What matters is that nothing waits on it.
    @Test("A sync for an offline agent still rings, and nothing blocks on it")
    func syncForOfflineAgentStillRings() async throws {
        try await withApp { app, _, store in
            let agentId = try await self.registerAgent(app: app)

            let collector = MessageCollector()
            await store.subscribe(channel: CoordinationService.doorbellChannel) { message in
                Task { await collector.append(message) }
            }

            await app.agentService.syncDesiredState(agentId: agentId)

            let received = await collector.waitFor(count: 1)
            #expect(
                received.compactMap { CoordinationService.parseDoorbell($0)?.agentKey }
                    == [agentKey("routed-agent")])
        }
    }

    /// Fleet-wide mutations (security groups, networks, sites) have no single
    /// agent to name, so they ring the wildcard rather than enumerating the
    /// fleet from the database.
    @Test("A fleet sync rings the wildcard doorbell")
    func fleetSyncRingsWildcard() async throws {
        try await withApp { app, _, store in
            _ = try await self.registerAgent(app: app)

            let collector = MessageCollector()
            await store.subscribe(channel: CoordinationService.doorbellChannel) { message in
                Task { await collector.append(message) }
            }

            await app.agentService.syncDesiredStateToFleet()

            let received = await collector.waitFor(count: 1)
            #expect(
                received.compactMap { CoordinationService.parseDoorbell($0)?.agentKey }
                    == [CoordinationService.doorbellAllAgents])
        }
    }

    /// Unconditionally, since STR-152: the close used to defer to a route key
    /// naming another replica, and with no directory left it always writes.
    /// A close delayed past a cross-replica reconnect therefore marks the agent
    /// offline until the holding replica's next heartbeat writes `.online`.
    @Test("Socket close marks the agent offline")
    func closeMarksOffline() async throws {
        try await withApp { app, _, _ in
            let agentId = try await self.registerAgent(app: app)

            await app.agentService.removeAgent(agentKey("routed-agent"))

            // The offline write is async; poll for it.
            var status: AgentStatus?
            for _ in 0..<100 {
                status = await app.agentService.getAgentInfo(agentId)?.status
                if status == .offline { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(status == .offline)
        }
    }

    @Test("Subscription probes round-trip through the doorbell channel")
    func subscriptionProbeRoundTrips() async throws {
        try await withApp { app, _, _ in
            // First call arms the subscriptions (idempotent) and publishes a
            // probe; delivery is asynchronous, so poll for the round trip.
            await app.replicaBridge.verifySubscriptions()

            var roundTripped = false
            for _ in 0..<100 {
                roundTripped = await app.replicaBridge.lastSubscriptionProbeRoundTripped
                if roundTripped { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(roundTripped)
        }
    }

    @Test("Schedulable agents are assembled from the shared registry")
    func schedulableAgentsFromDatabase() async throws {
        try await withApp { app, _, _ in
            let agentId = try await self.registerAgent(app: app)

            let schedulable = await app.agentService.schedulableAgentsFromDatabase()
            #expect(schedulable.count == 1)
            let entry = try #require(schedulable.first)
            #expect(entry.id == agentId)
            #expect(entry.name == "routed-agent")
            #expect(entry.availableCPU == 16)
            #expect(entry.runningVMCount == 0)
        }
    }
}
