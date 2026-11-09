import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

/// Durable protocol support belonging to one registration. Any serving replica
/// intersects the agent's offer with its own support, rather than trusting the
/// feature set of the replica that accepted the WebSocket.
struct AgentProtocolSession: Sendable {
    let id: UUID
    let offer: Strato_Agent_V1_ProtocolOffer
    let agreement: Strato_Agent_V1_ProtocolAgreement

    static func load(
        agentID: UUID, sessionID: UUID? = nil,
        localOffer: Strato_Agent_V1_ProtocolOffer = AgentProtocolCompatibility.localOffer,
        on database: any Database
    ) async throws -> Self {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        guard
            let row = try await sql.raw(
                """
                SELECT inventory_session_id, protocol_major, protocol_capabilities::text AS capabilities,
                    protocol_agreed_capabilities::text AS agreed_capabilities
                FROM agents WHERE id = \(bind: agentID) AND administratively_offline = FALSE
                """
            ).first(),
            let id = try row.decode(column: "inventory_session_id", as: UUID?.self),
            sessionID == nil || sessionID == id,
            let major = try row.decode(column: "protocol_major", as: Int?.self),
            let majorValue = UInt32(exactly: major),
            let capabilities = try row.decode(column: "capabilities", as: String?.self),
            let acceptedCapabilities = try row.decode(column: "agreed_capabilities", as: String?.self)
        else { throw Abort(.conflict, reason: "Agent registration session is unavailable or superseded") }
        var offer = Strato_Agent_V1_ProtocolOffer()
        offer.major = majorValue
        offer.capabilities = try JSONDecoder().decode([String].self, from: Data(capabilities.utf8))
        var agreement = try AgentProtocolCompatibility.negotiate(
            local: localOffer, remote: offer, inventorySessionID: id)
        let ceiling = try JSONDecoder().decode([String].self, from: Data(acceptedCapabilities.utf8))
        var registeredAgreement = agreement
        registeredAgreement.capabilities = ceiling
        try AgentProtocolCompatibility.validate(registeredAgreement, offered: offer)
        agreement.capabilities = agreement.capabilities.filter(Set(ceiling).contains)
        return Self(id: id, offer: offer, agreement: agreement)
    }

    /// Called inside the same transaction that replaces inventory_session_id.
    static func persist(
        _ offer: Strato_Agent_V1_ProtocolOffer, agentID: UUID, sessionID: UUID, on database: any Database
    ) async throws {
        let agreement = try AgentProtocolCompatibility.negotiate(
            local: AgentProtocolCompatibility.localOffer, remote: offer, inventorySessionID: sessionID)
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        let capabilities = String(decoding: try JSONEncoder().encode(offer.capabilities), as: UTF8.self)
        let agreedCapabilities = String(decoding: try JSONEncoder().encode(agreement.capabilities), as: UTF8.self)
        let updated = try await sql.raw(
            """
            UPDATE agents SET protocol_major = \(bind: Int(offer.major)),
                protocol_capabilities = \(bind: capabilities)::jsonb,
                protocol_agreed_capabilities = \(bind: agreedCapabilities)::jsonb
            WHERE id = \(bind: agentID) AND inventory_session_id = \(bind: sessionID)
            RETURNING id
            """
        ).first()
        guard updated != nil else { throw Abort(.conflict, reason: "Agent registration was superseded") }
    }
}
