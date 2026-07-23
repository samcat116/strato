import Foundation
import StratoShared
import Testing
import Vapor

@testable import App

/// Records what the bridge asks its owner to do, standing in for `AgentService`
/// so the bridge can be exercised without any real agent sockets.
private actor FakeBridgeDelegate: ReplicaBridgeDelegate {
    private(set) var deliveredNudges: [String] = []
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

    func deliverNudge(agentKey: String) async {
        deliveredNudges.append(agentKey)
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

    // MARK: Nudge dispatch

    @Test("A real nudge is handed to the delegate")
    func nudgeDispatchedToDelegate() async throws {
        try await withBridge { bridge, delegate, _, _ in
            await bridge.handleNudge(agentKey: "agent-x")
            #expect(await delegate.deliveredNudges == ["agent-x"])
        }
    }

    @Test("The subscription probe sentinel is consumed, not delegated")
    func probeSentinelNotDelegated() async throws {
        try await withBridge { bridge, delegate, _, _ in
            await bridge.handleNudge(agentKey: ReplicaMessageBridge.subscriptionProbeMessage)
            #expect(await delegate.deliveredNudges.isEmpty)
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
                message: VMOperationMessage(type: .vmReboot, vmId: UUID().uuidString))
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
                message: VMOperationMessage(type: .vmReboot, vmId: UUID().uuidString))
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
                message: VMOperationMessage(type: .vmReboot, vmId: UUID().uuidString))
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
