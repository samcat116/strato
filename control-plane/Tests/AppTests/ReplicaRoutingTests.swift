import Foundation
import Testing
import Vapor
import StratoShared
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

        #expect(await service.agentRoute(agentName: "agent-a") == nil)

        await service.recordAgentRoute(agentName: "agent-a", replicaId: "replica-1")
        #expect(await service.agentRoute(agentName: "agent-a") == "replica-1")

        // A stale owner (delayed close on another replica) cannot clear a
        // successor's claim.
        await service.clearAgentRoute(agentName: "agent-a", replicaId: "replica-0")
        #expect(await service.agentRoute(agentName: "agent-a") == "replica-1")

        await service.clearAgentRoute(agentName: "agent-a", replicaId: "replica-1")
        #expect(await service.agentRoute(agentName: "agent-a") == nil)
    }

    @Test("Nudges land on the holder replica's channel")
    func nudgePublish() async {
        let (service, store) = makeService()
        let collector = MessageCollector()

        await store.subscribe(channel: CoordinationService.nudgeChannel(replicaId: "replica-9")) { message in
            Task { await collector.append(message) }
        }

        await service.publishNudge(agentName: "agent-a", toReplica: "replica-9")
        #expect(await collector.waitFor(count: 1) == ["agent-a"])
    }
}

/// AgentService-level routing tests (issue #261): registration claims the
/// route, mutations nudge the socket-holding replica, socket close respects a
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

            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            app.cleanupTestDatabase()
            throw error
        }

        try await app.asyncShutdown()
        app.cleanupTestDatabase()
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
        let agentUUID = try await app.agentService.registerAgent(message, agentName: agentName)
        return agentUUID.uuidString
    }

    @Test("Registration claims the socket route and presence for this replica")
    func registrationClaimsRoute() async throws {
        try await withApp { app, coordination, _ in
            _ = try await self.registerAgent(app: app)

            #expect(await coordination.agentRoute(agentName: "routed-agent") == app.replicaID)
            #expect(await coordination.isAgentPresent(agentName: "routed-agent") == true)
        }
    }

    @Test("A sync for an agent socketed elsewhere nudges the holder replica")
    func syncNudgesHolderReplica() async throws {
        try await withApp { app, coordination, store in
            let agentId = try await self.registerAgent(app: app)

            // The agent's socket lives on another replica (no local socket
            // exists in this test, and the route names the other replica).
            await coordination.recordAgentRoute(agentName: "routed-agent", replicaId: "replica-b")

            let collector = MessageCollector()
            await store.subscribe(
                channel: CoordinationService.nudgeChannel(replicaId: "replica-b")
            ) { message in
                Task { await collector.append(message) }
            }

            await app.agentService.syncDesiredState(agentId: agentId)

            #expect(await collector.waitFor(count: 1) == ["routed-agent"])
        }
    }

    @Test("A sync for an offline agent publishes nothing")
    func syncForOfflineAgentIsDeferred() async throws {
        try await withApp { app, coordination, store in
            let agentId = try await self.registerAgent(app: app)
            // No socket anywhere: clear the route registration wrote.
            await coordination.clearAgentRoute(agentName: "routed-agent", replicaId: app.replicaID)

            let collector = MessageCollector()
            await store.subscribe(
                channel: CoordinationService.nudgeChannel(replicaId: "replica-b")
            ) { message in
                Task { await collector.append(message) }
            }

            await app.agentService.syncDesiredState(agentId: agentId)

            #expect(await collector.waitFor(count: 1, timeoutMilliseconds: 200).isEmpty)
        }
    }

    @Test("Socket close does not mark an agent offline when another replica holds its route")
    func closeRespectsForeignRoute() async throws {
        try await withApp { app, coordination, _ in
            let agentId = try await self.registerAgent(app: app)

            // The agent reconnected to another replica before our close ran.
            await coordination.recordAgentRoute(agentName: "routed-agent", replicaId: "replica-b")
            await app.agentService.removeAgent("routed-agent")

            // Give the (would-be) async offline write a moment, then confirm
            // it never happened.
            try await Task.sleep(for: .milliseconds(200))
            let stillOnline = await app.agentService.getAgentInfo(agentId)
            #expect(stillOnline?.status == .online)
            #expect(await coordination.agentRoute(agentName: "routed-agent") == "replica-b")
        }
    }

    @Test("Socket close marks the agent offline when this replica owns the route")
    func closeMarksOfflineWhenRouteIsOurs() async throws {
        try await withApp { app, coordination, _ in
            let agentId = try await self.registerAgent(app: app)

            await app.agentService.removeAgent("routed-agent")

            // The offline write is async; poll for it.
            var status: AgentStatus?
            for _ in 0..<100 {
                status = await app.agentService.getAgentInfo(agentId)?.status
                if status == .offline { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(status == .offline)
            #expect(await coordination.agentRoute(agentName: "routed-agent") == nil)
        }
    }

    @Test("A correlated request for an unrouted agent fails fast")
    func requestForOfflineAgentThrows() async throws {
        try await withApp { app, coordination, _ in
            let agentId = try await self.registerAgent(app: app)
            await coordination.clearAgentRoute(agentName: "routed-agent", replicaId: app.replicaID)

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
            let request = AgentService.AgentRPCRequest(
                rpcId: "rpc-1",
                replyChannel: replyChannel,
                agentId: agentId,
                agentName: "routed-agent",
                envelope: envelope,
                timeoutSeconds: 1
            )
            let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)

            await app.agentService.handleRPCRequest(payload)

            let replies = await collector.waitFor(count: 1)
            let reply = try JSONDecoder().decode(
                AgentService.AgentRPCReply.self, from: Data(try #require(replies.first).utf8))
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
            await coordination.recordAgentRoute(agentName: "routed-agent", replicaId: "replica-b")

            await store.subscribe(
                channel: CoordinationService.rpcChannel(replicaId: "replica-b")
            ) { payload in
                Task {
                    guard
                        let request = try? JSONDecoder().decode(
                            AgentService.AgentRPCRequest.self, from: Data(payload.utf8))
                    else { return }
                    let reply = AgentService.AgentRPCReply(
                        rpcId: request.rpcId, outcome: .success, data: nil, error: nil, details: nil)
                    guard let encodedData = try? JSONEncoder().encode(reply) else { return }
                    // Resolve through the requester's reply handler directly:
                    // deterministic regardless of when the service's own
                    // channel subscription lands.
                    await app.agentService.handleRPCReply(String(decoding: encodedData, as: UTF8.self))
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

    @Test("Subscription probes round-trip through the replica's own nudge channel")
    func subscriptionProbeRoundTrips() async throws {
        try await withApp { app, _, _ in
            // First call arms the subscriptions (idempotent) and publishes a
            // probe; delivery is asynchronous, so poll for the round trip.
            await app.agentService.verifyReplicaSubscriptions()

            var roundTripped = false
            for _ in 0..<100 {
                roundTripped = await app.agentService.lastSubscriptionProbeRoundTripped
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
