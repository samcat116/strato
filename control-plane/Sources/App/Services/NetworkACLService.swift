import Fluent
import StratoShared
import Vapor

/// Validation and generation serialization shared by the network-ACL routes.
///
/// A network ACL is a network-owned, stateless policy. Mutations lock the
/// logical-network row first and the ACL row second so concurrent rule edits,
/// ACL deletion, and network deletion have one stable lock order.
enum NetworkACLService {
    /// Validate a rule and return the normalized values stored on the row and
    /// sent to agents.
    static func validateRule(_ request: CreateNetworkACLRuleRequest) throws -> (
        protocolName: String?, remoteCIDR: String
    ) {
        guard (1...32_766).contains(request.ruleNumber) else {
            throw Abort(.badRequest, reason: "ruleNumber must be between 1 and 32766")
        }

        let protocolName = try NetworkRuleValidation.validate(
            protocolName: request.protocolName, portRangeMin: request.portRangeMin, portRangeMax: request.portRangeMax)

        let remoteCIDR: String
        switch request.ethertype {
        case .ipv4:
            guard let cidr = IPv4CIDR(request.remoteCIDR) else {
                throw Abort(
                    .badRequest,
                    reason: "remoteCIDR is not a valid IPv4 CIDR: \(request.remoteCIDR)")
            }
            remoteCIDR = "\(cidr.networkAddress)/\(cidr.prefix)"
        case .ipv6:
            guard let cidr = IPv6CIDR(request.remoteCIDR) else {
                throw Abort(
                    .badRequest,
                    reason: "remoteCIDR is not a valid IPv6 CIDR: \(request.remoteCIDR)")
            }
            remoteCIDR = cidr.description
        }

        return (protocolName, remoteCIDR)
    }

    /// Lock the owning network for the enclosing transaction. Every mutation
    /// takes this lock before the ACL lock so creation, deletion, and rule
    /// edits serialize across control-plane replicas.
    static func lockNetwork(_ networkID: UUID, on db: any Database) async throws {
        switch try await DesiredStateGenerationWriter.lockCurrent(
            schema: LogicalNetwork.schema, id: networkID, on: db)
        {
        case .applied:
            return
        case .missing:
            throw Abort(.notFound, reason: "Network no longer exists")
        case .superseded:
            // No expected generation was supplied, so an existing row always
            // locks successfully.
            throw Abort(.internalServerError, reason: "Network row could not be locked")
        }
    }

    static func lockACL(_ aclID: UUID, on db: any Database) async throws {
        switch try await DesiredStateGenerationWriter.lockCurrent(
            schema: NetworkACL.schema, id: aclID, on: db)
        {
        case .applied:
            return
        case .missing:
            throw Abort(.notFound, reason: "Network ACL no longer exists")
        case .superseded:
            throw Abort(.internalServerError, reason: "Network ACL row could not be locked")
        }
    }

    static func bumpACLGeneration(_ aclID: UUID, on db: any Database) async throws {
        switch try await DesiredStateGenerationWriter.advance(
            schema: NetworkACL.schema, id: aclID, on: db)
        {
        case .applied:
            return
        case .missing:
            throw Abort(.notFound, reason: "Network ACL no longer exists")
        case .superseded:
            throw Abort(.internalServerError, reason: "Network ACL generation did not advance")
        }
    }

    /// The network generation is the outer replay guard for switch topology.
    /// Bump it with every ACL mutation, especially ACL deletion, so a stale
    /// sync carrying the removed policy cannot win after teardown.
    static func bumpNetworkGeneration(_ networkID: UUID, on db: any Database) async throws {
        switch try await DesiredStateGenerationWriter.advance(
            schema: LogicalNetwork.schema, id: networkID, on: db)
        {
        case .applied:
            return
        case .missing:
            throw Abort(.notFound, reason: "Network no longer exists")
        case .superseded:
            throw Abort(.internalServerError, reason: "Network generation did not advance")
        }
    }
}
