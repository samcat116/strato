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

/// Store- and service-level tests for the phase-3 primitives (issue #261):
/// value-carrying keys, compare-and-delete, pub/sub, and the agent route keys
/// built on them.
@Suite("Replica Routing Primitive Tests")
struct ReplicaRoutingPrimitiveTests {

    private func makeService() -> (CoordinationService, InMemoryCoordinationStore) {
        let store = InMemoryCoordinationStore()
        return (CoordinationService(store: store, logger: Logger(label: "routing-test")), store)
    }

    @Test("Values round-trip and expire by TTL")
    func valueRoundTripAndTTL() async throws {
        let (_, store) = makeService()

        #expect(await store.getValue("k") == nil)
        await store.setValue("k", value: "v1", ttlSeconds: 60)
        #expect(await store.getValue("k") == "v1")

        // Overwrite replaces value and TTL.
        await store.setValue("k", value: "v2", ttlSeconds: 1)
        #expect(await store.getValue("k") == "v2")
        try await Task.sleep(for: .milliseconds(1200))
        #expect(await store.getValue("k") == nil)
    }

    @Test("Compare-and-delete removes only a matching value")
    func compareAndDelete() async {
        let (_, store) = makeService()

        await store.setValue("k", value: "mine", ttlSeconds: 60)
        await store.deleteValue("k", ifEquals: "theirs")
        #expect(await store.getValue("k") == "mine")

        await store.deleteValue("k", ifEquals: "mine")
        #expect(await store.getValue("k") == nil)
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

    @Test("Agent routes record, read back, and clear only for their owner")
    func agentRouteLifecycle() async {
        let (service, _) = makeService()

        #expect(await service.agentRoute(agentKey: agentKey("agent-a")) == nil)

        await service.recordAgentRoute(agentKey: agentKey("agent-a"), replicaId: "replica-1")
        #expect(await service.agentRoute(agentKey: agentKey("agent-a")) == "replica-1")

        // A stale owner (delayed close on another replica) cannot clear a
        // successor's claim.
        await service.clearAgentRoute(agentKey: agentKey("agent-a"), replicaId: "replica-0")
        #expect(await service.agentRoute(agentKey: agentKey("agent-a")) == "replica-1")

        await service.clearAgentRoute(agentKey: agentKey("agent-a"), replicaId: "replica-1")
        #expect(await service.agentRoute(agentKey: agentKey("agent-a")) == nil)
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

/// AgentService-level routing tests (issue #261): registration claims the
/// route, mutations ring the broadcast doorbell, socket close respects a
/// foreign route, and the RPC bridge forwards correlated exchanges.
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
            try await app.autoMigrate()

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
            capabilities: ["qemu"],
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            protocolVersion: 2
        )
        // New agents need an owning org; this harness creates no other data,
        // so mint one on first use.
        let orgID: UUID
        if let existing = try await Organization.query(on: app.db).sort(\.$createdAt).first() {
            orgID = try existing.requireID()
        } else {
            let org = Organization(name: "Routing Org", description: "org for routing tests")
            try await org.save(on: app.db)
            orgID = try org.requireID()
        }
        let agentUUID = try await app.agentService.registerAgent(
            message, agentName: agentName, organizationScope: .organization(orgID))
        return agentUUID.uuidString
    }

    @Test("Registration claims the socket route and presence for this replica")
    func registrationClaimsRoute() async throws {
        try await withApp { app, coordination, _ in
            _ = try await self.registerAgent(app: app)

            #expect(await coordination.agentRoute(agentKey: agentKey("routed-agent")) == app.replicaID)
            #expect(await coordination.isAgentPresent(agentKey: agentKey("routed-agent")) == true)
        }
    }

    /// The point of the broadcast: a mutation publishes without consulting
    /// any routing key, so wherever the agent's poll or socket happens to live
    /// is not this replica's problem.
    @Test("A sync rings the broadcast doorbell regardless of where the agent is")
    func syncRingsBroadcastDoorbell() async throws {
        try await withApp { app, coordination, store in
            let agentId = try await self.registerAgent(app: app)

            // The agent's socket lives on another replica (no local socket
            // exists in this test, and the route names the other replica).
            await coordination.recordAgentRoute(agentKey: agentKey("routed-agent"), replicaId: "replica-b")

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
        try await withApp { app, coordination, store in
            let agentId = try await self.registerAgent(app: app)
            // No socket anywhere: clear the route registration wrote.
            await coordination.clearAgentRoute(agentKey: agentKey("routed-agent"), replicaId: app.replicaID)

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

    @Test("Socket close does not mark an agent offline when another replica holds its route")
    func closeRespectsForeignRoute() async throws {
        try await withApp { app, coordination, _ in
            let agentId = try await self.registerAgent(app: app)

            // The agent reconnected to another replica before our close ran.
            await coordination.recordAgentRoute(agentKey: agentKey("routed-agent"), replicaId: "replica-b")
            await app.agentService.removeAgent(agentKey("routed-agent"))

            // Give the (would-be) async offline write a moment, then confirm
            // it never happened.
            try await Task.sleep(for: .milliseconds(200))
            let stillOnline = await app.agentService.getAgentInfo(agentId)
            #expect(stillOnline?.status == .online)
            #expect(await coordination.agentRoute(agentKey: agentKey("routed-agent")) == "replica-b")
        }
    }

    @Test("Socket close marks the agent offline when this replica owns the route")
    func closeMarksOfflineWhenRouteIsOurs() async throws {
        try await withApp { app, coordination, _ in
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
            #expect(await coordination.agentRoute(agentKey: agentKey("routed-agent")) == nil)
        }
    }

    @Test("A correlated request for an unrouted agent fails fast")
    func requestForOfflineAgentThrows() async throws {
        try await withApp { app, coordination, _ in
            let agentId = try await self.registerAgent(app: app)
            await coordination.clearAgentRoute(agentKey: agentKey("routed-agent"), replicaId: app.replicaID)

            await #expect(throws: AgentServiceError.self) {
                _ = try await app.agentService.sendMessageToAgentWithResponse(
                    VMOperationMessage(type: .vmReboot, vmId: UUID().uuidString),
                    agentId: agentId,
                    timeout: .seconds(1)
                )
            }
        }
    }

    @Test("An RPC forwarded to a replica without the socket is answered unreachable")
    func rpcWithoutSocketRepliesUnreachable() async throws {
        try await withApp { app, _, store in
            let agentId = try await self.registerAgent(app: app)

            let collector = MessageCollector()
            let replyChannel = "replica:test-requester:rpc-replies"
            await store.subscribe(channel: replyChannel) { message in
                Task { await collector.append(message) }
            }

            let envelope = try MessageEnvelope(
                message: VMOperationMessage(type: .vmReboot, vmId: UUID().uuidString))
            let request = ReplicaMessageBridge.AgentRPCRequest(
                rpcId: "rpc-1",
                replyChannel: replyChannel,
                agentId: agentId,
                agentKey: agentKey("routed-agent"),
                envelope: envelope,
                timeoutSeconds: 1
            )
            let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)

            await app.replicaBridge.handleRPCRequest(payload)

            let replies = await collector.waitFor(count: 1)
            let reply = try JSONDecoder().decode(
                ReplicaMessageBridge.AgentRPCReply.self, from: Data(try #require(replies.first).utf8))
            #expect(reply.rpcId == "rpc-1")
            #expect(reply.outcome == .unreachable)
        }
    }

    @Test("An RPC to the holder replica resolves the requester's await")
    func rpcRoundTrip() async throws {
        try await withApp { app, coordination, store in
            let agentId = try await self.registerAgent(app: app)

            // Route the agent to a fictitious second replica whose RPC channel
            // the test itself services, standing in for the holder process.
            await coordination.recordAgentRoute(agentKey: agentKey("routed-agent"), replicaId: "replica-b")

            await store.subscribe(
                channel: CoordinationService.rpcChannel(replicaId: "replica-b")
            ) { payload in
                Task {
                    guard
                        let request = try? JSONDecoder().decode(
                            ReplicaMessageBridge.AgentRPCRequest.self, from: Data(payload.utf8))
                    else { return }
                    let reply = ReplicaMessageBridge.AgentRPCReply(
                        rpcId: request.rpcId, outcome: .success, data: nil, error: nil, details: nil)
                    guard let encodedData = try? JSONEncoder().encode(reply) else { return }
                    // Resolve through the requester's reply handler directly:
                    // deterministic regardless of when the service's own
                    // channel subscription lands.
                    await app.replicaBridge.handleRPCReply(String(decoding: encodedData, as: UTF8.self))
                }
            }

            let response = try await app.agentService.sendMessageToAgentWithResponse(
                VMOperationMessage(type: .vmReboot, vmId: UUID().uuidString),
                agentId: agentId,
                timeout: .seconds(5)
            )

            if case .success = response {
                // expected
            } else {
                Issue.record("Expected success response, got \(response)")
            }
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
