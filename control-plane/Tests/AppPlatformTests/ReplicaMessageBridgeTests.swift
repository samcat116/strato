import Foundation
import StratoShared
import Testing
import Vapor

@testable import App

/// Records what the bridge asks its owner to do, standing in for `AgentService`
/// so the bridge can be exercised without any real agent sockets.
private actor FakeBridgeDelegate: ReplicaBridgeDelegate {
    private(set) var deliveredDoorbells: [String] = []
    private(set) var deliveredAgentKeys: [String] = []

    func deliverAgentEnvelope(_ envelope: MessageEnvelope, agentKey: String) async throws {
        deliveredAgentKeys.append(agentKey)
    }

    func deliverDoorbell(agentKey: String) async {
        deliveredDoorbells.append(agentKey)
    }
}

/// Unit tests for `ReplicaMessageBridge` through its own interface with a fake
/// delegate — the cross-replica seam AgentService used to carry inline (issue
/// #261). Everything runs over an in-memory coordination store; no real agent
/// sockets are involved.
///
/// These tests cover both the broadcast doorbell and the narrower one-way
/// delivery RPC used by captured VM commands.
@Suite("Replica Message Bridge Tests", .serialized)
final class ReplicaMessageBridgeTests {

    /// A bridge wired to a shared in-memory coordination store and a fake
    /// delegate. No `AgentService` is created, so the bridge is entirely
    /// isolated from the socket-holding owner.
    private func withBridge(
        _ test: (ReplicaMessageBridge, FakeBridgeDelegate, InMemoryCoordinationStore, String) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        do {
            let store = InMemoryCoordinationStore()
            app.coordination = CoordinationService(store: store, logger: app.logger)

            let bridge = ReplicaMessageBridge(app: app)
            let delegate = FakeBridgeDelegate()
            await bridge.start(delegate: delegate)

            try await test(bridge, delegate, store, app.replicaID)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    // MARK: Doorbell dispatch

    @Test("An agent stream message is forwarded to the replica route and acknowledged")
    func agentMessageForwardsAcrossReplicas() async throws {
        let requesterApp = try await Application.make(.testing)
        let holderApp = try await Application.make(.testing)
        do {
            let store = InMemoryCoordinationStore()
            requesterApp.coordination = CoordinationService(store: store, logger: requesterApp.logger)
            holderApp.coordination = CoordinationService(store: store, logger: holderApp.logger)

            let requester = ReplicaMessageBridge(app: requesterApp)
            let holder = ReplicaMessageBridge(app: holderApp)
            let requesterDelegate = FakeBridgeDelegate()
            let holderDelegate = FakeBridgeDelegate()
            await requester.start(delegate: requesterDelegate)
            await holder.start(delegate: holderDelegate)
            await holder.recordRoute(agentKey: "spiffe://example.test/agent/node-1")

            try await requester.deliver(
                GuestExecCloseMessage(sessionId: "session-1"),
                agentKey: "spiffe://example.test/agent/node-1")

            #expect(await holderDelegate.deliveredAgentKeys == ["spiffe://example.test/agent/node-1"])
            #expect(await requesterDelegate.deliveredAgentKeys.isEmpty)
        } catch {
            try await requesterApp.asyncShutdown()
            try await holderApp.asyncShutdown()
            throw error
        }
        try await requesterApp.asyncShutdown()
        try await holderApp.asyncShutdown()
    }

    @Test("A lost delivery acknowledgement is ambiguous after the holder queues the message")
    func lostAcknowledgementIsAmbiguous() async throws {
        let requesterApp = try await Application.make(.testing)
        let holderApp = try await Application.make(.testing)
        let store = InMemoryCoordinationStore()
        requesterApp.coordination = CoordinationService(store: store, logger: requesterApp.logger)
        holderApp.coordination = CoordinationService(store: store, logger: holderApp.logger)

        // The requester deliberately does not subscribe to its reply channel,
        // modeling a reply lost after the holder queued the envelope.
        let requester = ReplicaMessageBridge(
            app: requesterApp, deliveryAcknowledgementTimeout: .milliseconds(10))
        let holder = ReplicaMessageBridge(app: holderApp)
        let holderDelegate = FakeBridgeDelegate()
        await holder.start(delegate: holderDelegate)
        await holder.recordRoute(agentKey: "spiffe://example.test/agent/node-1")

        let error = await #expect(throws: ReplicaMessageBridge.DeliveryError.self) {
            try await requester.deliver(
                GuestExecCloseMessage(sessionId: "session-1"),
                agentKey: "spiffe://example.test/agent/node-1")
        }

        #expect(error?.isDefinitive == false)
        #expect(await holderDelegate.deliveredAgentKeys == ["spiffe://example.test/agent/node-1"])
        try await requesterApp.asyncShutdown()
        try await holderApp.asyncShutdown()
    }

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
}
