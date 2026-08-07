import Foundation
import StratoShared
import Testing
import Vapor

import AppTestSupport
@testable import App

/// Records what the bridge asks its owner to do, standing in for `AgentService`
/// so the bridge can be exercised without any real agent sockets.
private actor FakeBridgeDelegate: ReplicaBridgeDelegate {
    private(set) var deliveredDoorbells: [String] = []
    private(set) var localExchanges: [String] = []
    private var localExchangeResult: Result<AgentServiceResponse, Error> = .success(.success(nil))

    func setLocalExchangeResult(_ result: Result<AgentServiceResponse, Error>) {
        localExchangeResult = result
    }

    func runLocalExchange(
        _ envelope: MessageEnvelope,
        requestId: String,
        agentId: String,
        agentKey: String,
        timeout: Duration
    ) async throws -> AgentServiceResponse {
        localExchanges.append(requestId)
        return try localExchangeResult.get()
    }

    func deliverDoorbell(agentKey: String) async {
        deliveredDoorbells.append(agentKey)
    }
}

/// Collects pub/sub deliveries for assertions.
private actor DeliveryCollector {
    private(set) var messages: [String] = []
    func append(_ message: String) { messages.append(message) }

    func waitFor(count: Int, timeoutMilliseconds: Int = 2000) async -> [String] {
        for _ in 0..<(timeoutMilliseconds / 20) {
            if messages.count >= count { return messages }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return messages
    }
}

/// Unit tests for `ReplicaMessageBridge` through its own interface with a fake
/// delegate — the cross-replica seam AgentService used to carry inline (issue
/// #261). Everything runs over an in-memory coordination store; no real agent
/// sockets are involved.
@Suite("Replica Message Bridge Tests", .serialized)
final class ReplicaMessageBridgeTests {

    /// A bridge wired to a shared in-memory coordination store and a fake
    /// delegate. No `AgentService` is created, so the bridge is entirely
    /// isolated from the socket-holding owner.
    private func withBridge(
        _ test: (ReplicaMessageBridge, FakeBridgeDelegate, InMemoryCoordinationStore, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            let store = InMemoryCoordinationStore()
            app.coordination = CoordinationService(store: store, logger: app.logger)

            let bridge = ReplicaMessageBridge(app: app)
            let delegate = FakeBridgeDelegate()
            await bridge.start(delegate: delegate)

            try await test(bridge, delegate, store, app.replicaID)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    // MARK: remoteRoute decision table

    @Test("remoteRoute reports no route when none is recorded")
    func remoteRouteNoRoute() async throws {
        try await withBridge { bridge, _, _, _ in
            #expect(await bridge.remoteRoute(agentKey: "agent-x") == .noRoute)
        }
    }

    @Test("remoteRoute reports our own replica for a self-owned route")
    func remoteRouteOwnReplica() async throws {
        try await withBridge { bridge, _, _, _ in
            await bridge.recordRoute(agentKey: "agent-x")
            #expect(await bridge.remoteRoute(agentKey: "agent-x") == .ownReplica)
        }
    }

    @Test("remoteRoute forwards to the replica that holds the socket")
    func remoteRouteForward() async throws {
        try await withBridge { bridge, _, store, _ in
            // Another replica's claim, written straight to the shared store.
            await store.setValue(
                CoordinationService.routeKey(agentKey: "agent-x"), value: "replica-b", ttlSeconds: 60)
            #expect(await bridge.remoteRoute(agentKey: "agent-x") == .forward(replicaId: "replica-b"))
        }
    }

    // MARK: Doorbell dispatch

    @Test("A doorbell from another replica is handed to the delegate")
    func doorbellDispatchedToDelegate() async throws {
        try await withBridge { bridge, delegate, _, _ in
            await bridge.handleDoorbell(
                CoordinationService.doorbellPayload(agentKey: "agent-x", fromReplica: "replica-b"))
            #expect(await delegate.deliveredDoorbells == ["agent-x"])
        }
    }

    /// The publisher runs the local half inline before broadcasting, so acting
    /// on its own echo would assemble and push the same sync twice.
    @Test("A doorbell this replica published is ignored")
    func ownDoorbellEchoIgnored() async throws {
        try await withBridge { bridge, delegate, _, replicaId in
            await bridge.handleDoorbell(
                CoordinationService.doorbellPayload(agentKey: "agent-x", fromReplica: replicaId))
            #expect(await delegate.deliveredDoorbells.isEmpty)
        }
    }

    @Test("Our own subscription probe is consumed, not delegated")
    func probeSentinelNotDelegated() async throws {
        try await withBridge { bridge, delegate, _, replicaId in
            await bridge.handleDoorbell(
                CoordinationService.doorbellPayload(
                    agentKey: ReplicaMessageBridge.subscriptionProbeMessage, fromReplica: replicaId))
            #expect(await delegate.deliveredDoorbells.isEmpty)
            #expect(await bridge.lastSubscriptionProbeRoundTripped == false)
        }
    }

    /// The doorbell channel is fleet-wide, so every replica sees every other
    /// replica's probes. Counting one would make a dead subscription look alive
    /// on the strength of a neighbor's traffic.
    @Test("Another replica's probe neither counts nor delegates")
    func foreignProbeIgnored() async throws {
        try await withBridge { bridge, delegate, _, _ in
            await bridge.verifySubscriptions()
            await bridge.handleDoorbell(
                CoordinationService.doorbellPayload(
                    agentKey: ReplicaMessageBridge.subscriptionProbeMessage, fromReplica: "replica-b"))
            #expect(await delegate.deliveredDoorbells.isEmpty)
            #expect(await bridge.lastSubscriptionProbeRoundTripped == false)
        }
    }

    @Test("A malformed doorbell payload is dropped rather than delegated")
    func malformedDoorbellIgnored() async throws {
        try await withBridge { bridge, delegate, _, _ in
            await bridge.handleDoorbell("no-separator-here")
            #expect(await delegate.deliveredDoorbells.isEmpty)
        }
    }

    // MARK: Requester-side RPC outcomes

    @Test("call resolves the awaited result on an error reply")
    func callResolvesErrorReply() async throws {
        try await withBridge { bridge, _, store, _ in
            // Stand in for the holder replica: decode the forwarded request and
            // reply straight back through the requester's reply handler.
            await store.subscribe(
                channel: CoordinationService.rpcChannel(replicaId: "replica-b")
            ) { payload in
                Task {
                    guard
                        let request = try? JSONDecoder().decode(
                            ReplicaMessageBridge.AgentRPCRequest.self, from: Data(payload.utf8))
                    else { return }
                    let reply = ReplicaMessageBridge.AgentRPCReply(
                        rpcId: request.rpcId, outcome: .error, data: nil, error: "boom", details: "why")
                    guard let encoded = try? JSONEncoder().encode(reply) else { return }
                    await bridge.handleRPCReply(String(decoding: encoded, as: UTF8.self))
                }
            }

            let envelope = try MessageEnvelope(
                message: ConsoleConnectMessage(vmId: UUID().uuidString, sessionId: "sess-1"))
            let response = try await bridge.call(
                envelope, requestId: "rpc-err", agentId: UUID().uuidString,
                agentKey: "agent-x", toReplica: "replica-b", timeout: .seconds(5))

            guard case .error(let message, let details) = response else {
                Issue.record("Expected error response, got \(response)")
                return
            }
            #expect(message == "boom")
            #expect(details == "why")
        }
    }

    @Test("call throws connectionLost on an unreachable reply")
    func callThrowsOnUnreachable() async throws {
        try await withBridge { bridge, _, store, _ in
            await store.subscribe(
                channel: CoordinationService.rpcChannel(replicaId: "replica-b")
            ) { payload in
                Task {
                    guard
                        let request = try? JSONDecoder().decode(
                            ReplicaMessageBridge.AgentRPCRequest.self, from: Data(payload.utf8))
                    else { return }
                    let reply = ReplicaMessageBridge.AgentRPCReply(
                        rpcId: request.rpcId, outcome: .unreachable, data: nil, error: "gone", details: nil)
                    guard let encoded = try? JSONEncoder().encode(reply) else { return }
                    await bridge.handleRPCReply(String(decoding: encoded, as: UTF8.self))
                }
            }

            let envelope = try MessageEnvelope(
                message: ConsoleConnectMessage(vmId: UUID().uuidString, sessionId: "sess-1"))
            await #expect(throws: AgentServiceError.self) {
                _ = try await bridge.call(
                    envelope, requestId: "rpc-unreach", agentId: UUID().uuidString,
                    agentKey: "agent-x", toReplica: "replica-b", timeout: .seconds(5))
            }
        }
    }

    @Test("A forwarded request for an unheld socket is answered unreachable")
    func handleRPCRequestWithoutSocket() async throws {
        try await withBridge { bridge, _, store, _ in
            let collector = DeliveryCollector()
            let replyChannel = "replica:test-requester:rpc-replies"
            await store.subscribe(channel: replyChannel) { message in
                Task { await collector.append(message) }
            }

            let envelope = try MessageEnvelope(
                message: ConsoleConnectMessage(vmId: UUID().uuidString, sessionId: "sess-1"))
            let request = ReplicaMessageBridge.AgentRPCRequest(
                rpcId: "rpc-nosock",
                replyChannel: replyChannel,
                agentId: UUID().uuidString,
                agentKey: "agent-x",
                envelope: envelope,
                timeoutSeconds: 1
            )
            await bridge.handleRPCRequest(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))

            let replies = await collector.waitFor(count: 1)
            let reply = try JSONDecoder().decode(
                ReplicaMessageBridge.AgentRPCReply.self, from: Data(try #require(replies.first).utf8))
            #expect(reply.outcome == .unreachable)
        }
    }
}
