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

        let protocolName: String?
        if let requested = request.protocolName {
            let normalized = requested.lowercased()
            guard NetworkACLRule.allowedProtocols.contains(normalized) else {
                throw Abort(
                    .badRequest,
                    reason: "Unsupported protocol '\(requested)': expected tcp, udp, or icmp")
            }
            protocolName = normalized
        } else {
            protocolName = nil
        }

        switch protocolName {
        case "tcp", "udp":
            if let min = request.portRangeMin, let max = request.portRangeMax {
                guard (0...65_535).contains(min), (0...65_535).contains(max), min <= max else {
                    throw Abort(.badRequest, reason: "Port range must satisfy 0 ≤ min ≤ max ≤ 65535")
                }
            } else if request.portRangeMin != nil || request.portRangeMax != nil {
                throw Abort(.badRequest, reason: "Port ranges need both portRangeMin and portRangeMax")
            }
        case "icmp":
            if let type = request.portRangeMin {
                guard (0...255).contains(type) else {
                    throw Abort(.badRequest, reason: "ICMP type must be 0–255")
                }
                if let code = request.portRangeMax {
                    guard (0...255).contains(code) else {
                        throw Abort(.badRequest, reason: "ICMP code must be 0–255")
                    }
                }
            } else if request.portRangeMax != nil {
                throw Abort(.badRequest, reason: "An ICMP code (portRangeMax) needs a type (portRangeMin)")
            }
        default:
            if request.portRangeMin != nil || request.portRangeMax != nil {
                throw Abort(.badRequest, reason: "Port ranges require a protocol of tcp, udp, or icmp")
            }
        }

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
