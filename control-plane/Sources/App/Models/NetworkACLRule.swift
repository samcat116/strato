import Fluent
import Vapor

/// One immutable, ordered rule in a network-level ACL (STR-33).
///
/// Editing is delete and recreate. This keeps concurrent mutations atomic and
/// ensures each change advances the owning ACL's generation.
/// Safety: this mutable Fluent model stays inside one logical operation; child tasks
/// receive IDs or immutable snapshots and reload their own instance.
final class NetworkACLRule: Model, @unchecked Sendable {
    static let schema = "network_acl_rules"

    enum Direction: String, Codable, CaseIterable, Sendable {
        case ingress
        case egress
    }

    enum Ethertype: String, Codable, CaseIterable, Sendable {
        case ipv4
        case ipv6
    }

    enum Action: String, Codable, CaseIterable, Sendable {
        case allow
        case deny
    }

    /// Nil matches any IP protocol.
    static let allowedProtocols: Set<String> = ["tcp", "udp", "icmp"]

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "network_acl_id")
    var networkACL: NetworkACL

    /// Evaluation order within one direction. Valid values are 1...32766.
    @Field(key: "rule_number")
    var ruleNumber: Int

    @Field(key: "direction")
    var direction: Direction

    @Field(key: "ethertype")
    var ethertype: Ethertype

    @Field(key: "action")
    var action: Action

    /// "tcp", "udp", or "icmp"; nil matches any protocol.
    @OptionalField(key: "protocol")
    var protocolName: String?

    /// TCP/UDP destination port, or ICMP type.
    @OptionalField(key: "port_range_min")
    var portRangeMin: Int?

    /// TCP/UDP destination port, or ICMP code.
    @OptionalField(key: "port_range_max")
    var portRangeMax: Int?

    /// Source CIDR for ingress and destination CIDR for egress.
    @Field(key: "remote_cidr")
    var remoteCIDR: String

    @OptionalField(key: "description")
    var ruleDescription: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        networkACLID: UUID,
        ruleNumber: Int,
        direction: Direction,
        ethertype: Ethertype,
        action: Action,
        protocolName: String? = nil,
        portRangeMin: Int? = nil,
        portRangeMax: Int? = nil,
        remoteCIDR: String,
        description: String? = nil
    ) {
        self.id = id
        self.$networkACL.id = networkACLID
        self.ruleNumber = ruleNumber
        self.direction = direction
        self.ethertype = ethertype
        self.action = action
        self.protocolName = protocolName
        self.portRangeMin = portRangeMin
        self.portRangeMax = portRangeMax
        self.remoteCIDR = remoteCIDR
        self.ruleDescription = description
    }
}

extension NetworkACLRule: Content {}

// MARK: - DTOs

struct CreateNetworkACLRuleRequest: Content, ValidatedRequestBody {
    let ruleNumber: Int
    let direction: NetworkACLRule.Direction
    let ethertype: NetworkACLRule.Ethertype
    let action: NetworkACLRule.Action
    let protocolName: String?
    let portRangeMin: Int?
    let portRangeMax: Int?
    let remoteCIDR: String
    let description: String?

    init(
        ruleNumber: Int,
        direction: NetworkACLRule.Direction,
        ethertype: NetworkACLRule.Ethertype,
        action: NetworkACLRule.Action,
        protocolName: String? = nil,
        portRangeMin: Int? = nil,
        portRangeMax: Int? = nil,
        remoteCIDR: String,
        description: String? = nil
    ) {
        self.ruleNumber = ruleNumber
        self.direction = direction
        self.ethertype = ethertype
        self.action = action
        self.protocolName = protocolName
        self.portRangeMin = portRangeMin
        self.portRangeMax = portRangeMax
        self.remoteCIDR = remoteCIDR
        self.description = description
    }

    mutating func validate() throws {
        try Validate.text(description)
    }
}

struct NetworkACLRuleResponse: Content {
    let id: UUID
    let ruleNumber: Int
    let direction: NetworkACLRule.Direction
    let ethertype: NetworkACLRule.Ethertype
    let action: NetworkACLRule.Action
    let protocolName: String?
    let portRangeMin: Int?
    let portRangeMax: Int?
    let remoteCIDR: String
    let description: String?
    let createdAt: Date?

    init(from rule: NetworkACLRule) throws {
        self.id = try rule.requireID()
        self.ruleNumber = rule.ruleNumber
        self.direction = rule.direction
        self.ethertype = rule.ethertype
        self.action = rule.action
        self.protocolName = rule.protocolName
        self.portRangeMin = rule.portRangeMin
        self.portRangeMax = rule.portRangeMax
        self.remoteCIDR = rule.remoteCIDR
        self.description = rule.ruleDescription
        self.createdAt = rule.createdAt
    }
}
