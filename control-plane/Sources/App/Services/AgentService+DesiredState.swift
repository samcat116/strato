import Foundation
import Vapor
import StratoShared
import NIOWebSocket
import Fluent
import NIOCore
import NIOConcurrencyHelpers
import SQLKit
import Tracing
import Metrics

/// Owns desired-state doorbells and delivery across local and remote replicas.
extension AgentService {
    // MARK: - Desired-state sync (issues #260, #261)

    /// Signal a desired-state change for an agent from any replica.
    ///
    /// This rings the contentless broadcast doorbell (STR-146): the local half
    /// runs inline, and the same signal goes out on `agent:doorbell` so
    /// whichever *other* replica happens to hold the agent's parked poll can
    /// act on it. Nothing here consults a routing directory — that question is
    /// what the doorbell exists to not have to answer.
    ///
    /// Purely a latency optimization: the agent converges on its own
    /// unconditional re-fetch, doorbell or no doorbell.
    ///
    /// A mutation on one agent can change what its site's network controller
    /// must realize (a VM landing on any site node may reference a network
    /// the shared NB doesn't have yet), so the controller is synced alongside
    /// — and *first*: a non-authoritative peer cannot create a missing switch
    /// itself, so giving the controller's topology sync a head start lets the
    /// common case (first VM on a fresh network) converge on the peer's first
    /// attempt instead of waiting out a dependency-pending retry.
    func syncDesiredState(agentId: String) async {
        if let controllerId = await siteNetworkControllerID(forAgentId: agentId), controllerId != agentId {
            await ringDesiredStateDoorbell(agentId: controllerId)
        }
        await ringDesiredStateDoorbell(agentId: agentId)
    }

    /// The agent id of the site network controller responsible for the given
    /// agent's networks, or nil for unconfigured sites.
    /// Best-effort: on lookup failure the controller's own unconditional
    /// refetch still converges it.
    func siteNetworkControllerID(forAgentId agentId: String) async -> String? {
        guard let agentUUID = UUID(uuidString: agentId) else { return nil }
        do {
            guard let agent = try await Agent.find(agentUUID, on: app.db),
                let site = try await Site.find(agent.$site.id, on: app.db)
            else { return nil }
            return site.$networkControllerAgent.id?.uuidString
        } catch {
            app.logger.debug("Site controller lookup failed: \(error)")
            return nil
        }
    }

    /// Ring the doorbell for one agent: act on it locally, then broadcast so
    /// every other replica gets the same chance.
    ///
    /// Both halves always run. The local half is not an optimization that
    /// makes the broadcast redundant — this replica may hold the poll — and
    /// the broadcast is not a substitute for the local half, because Valkey
    /// may be down. Ringing twice is free; the doorbell is contentless and
    /// every recipient re-derives the truth from Postgres.
    func ringDesiredStateDoorbell(agentId: String) async {
        guard let agentKey = await agentKey(forId: agentId) else {
            app.logger.warning(
                "Cannot ring the desired-state doorbell for an unknown agent",
                metadata: ["agentId": .string(agentId)])
            return
        }
        await applyDoorbell(agentKey: agentKey)
        await app.replicaBridge.ringDoorbell(agentKey: agentKey)
    }

    /// The local half of a doorbell, shared by the in-process ring and the
    /// broadcast subscriber. Does whatever this replica can do about the agent
    /// and nothing else — which for most replicas, most of the time, is
    /// nothing at all. That is the design, not a degraded path: "at most one
    /// replica can act" is what removes the need for a routing directory.
    func applyDoorbell(agentKey: String) async {
        guard agentKey != CoordinationService.doorbellAllAgents else {
            await applyFleetDoorbell()
            return
        }

        // Wake a parked long-poll, if this is where it happens to be parked.
        // An agent whose poll is parked elsewhere needs nothing from us: it
        // will fetch wherever it actually lives.
        await app.desiredStatePollRegistry.ring(agentKey: agentKey)
    }

    /// The local half of a fleet-wide doorbell: wake every poll parked here.
    func applyFleetDoorbell() async {
        await app.desiredStatePollRegistry.ringAll()
    }

    /// Ring the fleet-wide doorbell: every agent's desired state may have
    /// changed. The entry point for mutations whose effect is not scoped to a
    /// placement — security groups, networks, site topology, floating IPs.
    ///
    /// Before STR-146 these callers reached only the agents socketed to the
    /// calling replica, so in a multi-replica deployment the rest waited out
    /// the forced periodic pass. Broadcasting fixes that as a side effect of
    /// being the only way to reach a parked poll on another replica.
    func syncDesiredStateToFleet() async {
        await applyFleetDoorbell()
        await app.replicaBridge.ringDoorbell(agentKey: CoordinationService.doorbellAllAgents)
    }

    /// Deliver a broadcast doorbell from another replica (the
    /// `ReplicaBridgeDelegate` hook). Identical to the local ring — the whole
    /// point of a contentless broadcast is that the recipient does not need to
    /// know where it came from.
    func deliverDoorbell(agentKey: String) async {
        await applyDoorbell(agentKey: agentKey)
    }

    func deliverAgentEnvelope(_ envelope: MessageEnvelope, agentKey: String) async throws {
        guard let websocket = app.websocketManager.getConnection(agentKey: agentKey) else {
            throw ReplicaMessageBridge.DeliveryError.agentNotConnected(agentKey)
        }
        websocket.send(try WireProtocol.makeEncoder().encode(envelope))
    }
}
