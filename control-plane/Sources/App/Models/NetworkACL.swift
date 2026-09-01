import Fluent
import Vapor

/// The optional, stateless firewall attached to one logical network (STR-33).
///
/// Rules are evaluated independently for ingress and egress in ascending rule
/// number. Every rule mutation bumps `generation`, allowing agents to replace
/// the complete realized ACL without replaying stale rules.
/// Safety: this mutable Fluent model stays inside one logical operation; child tasks
/// receive IDs or immutable snapshots and reload their own instance.
final class NetworkACL: Model, @unchecked Sendable {
    static let schema = "network_acls"

    /// Bounds the amount of ordered policy an agent must realize per network.
    static let maxRules = 100

    @ID(key: .id)
    var id: UUID?

    /// At most one ACL may be attached to a logical network (schema-enforced).
    @Parent(key: "logical_network_id")
    var logicalNetwork: LogicalNetwork

    /// Monotonic counter bumped on every rule mutation.
    @Field(key: "generation")
    var generation: Int64

    @Children(for: \.$networkACL)
    var rules: [NetworkACLRule]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, logicalNetworkID: UUID) {
        self.id = id
        self.$logicalNetwork.id = logicalNetworkID
        self.generation = 1
    }
}

extension NetworkACL: Content {}

// MARK: - DTOs

struct NetworkACLResponse: Content {
    let id: UUID
    let networkId: UUID
    let generation: Int64
    let rules: [NetworkACLRuleResponse]
    let createdAt: Date?
    let updatedAt: Date?

    init(from acl: NetworkACL) throws {
        self.id = try acl.requireID()
        self.networkId = acl.$logicalNetwork.id
        self.generation = acl.generation
        self.rules = try acl.rules.map(NetworkACLRuleResponse.init(from:)).sorted { lhs, rhs in
            if lhs.direction != rhs.direction {
                return lhs.direction.rawValue < rhs.direction.rawValue
            }
            if lhs.ruleNumber != rhs.ruleNumber {
                return lhs.ruleNumber < rhs.ruleNumber
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        self.createdAt = acl.createdAt
        self.updatedAt = acl.updatedAt
    }
}
