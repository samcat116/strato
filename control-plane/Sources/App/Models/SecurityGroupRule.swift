import Fluent
import Vapor

/// One rule of a `SecurityGroup`, realized agent-side as one OVN ACL on the
/// group's port group. Rules are immutable — editing is delete + recreate —
/// so concurrent editors can never half-overwrite each other's changes; every
/// mutation bumps the owning group's `generation`.
final class SecurityGroupRule: Model, @unchecked Sendable {
    static let schema = "security_group_rules"

    enum Direction: String, Codable, Sendable {
        /// Traffic to the VM (`to-lport` OVN ACLs).
        case ingress
        /// Traffic from the VM (`from-lport` OVN ACLs).
        case egress
    }

    enum Ethertype: String, Codable, Sendable {
        case ipv4
        case ipv6
    }

    /// The protocols a rule can name; nil on the row means "any".
    static let allowedProtocols: Set<String> = ["tcp", "udp", "icmp"]

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "security_group_id")
    var securityGroup: SecurityGroup

    /// Stored as plain strings (not DB enum types) so adding values never
    /// needs an enum-type migration and stale rows can't trap FluentKit's
    /// persisted-@Enum decoding.
    @Field(key: "direction")
    var direction: Direction

    @Field(key: "ethertype")
    var ethertype: Ethertype

    /// "tcp", "udp", or "icmp"; nil matches any protocol of the ethertype.
    @OptionalField(key: "protocol")
    var protocolName: String?

    /// tcp/udp: destination port range (min == max for a single port).
    /// icmp: `portRangeMin` is the ICMP type and `portRangeMax` the code.
    /// Nil means all ports/types.
    @OptionalField(key: "port_range_min")
    var portRangeMin: Int?

    @OptionalField(key: "port_range_max")
    var portRangeMax: Int?

    /// CIDR peer (source for ingress, destination for egress). Mutually
    /// exclusive with `remoteGroup`; both nil means "any".
    @OptionalField(key: "remote_cidr")
    var remoteCIDR: String?

    /// Security-group peer: matches the current member addresses of the
    /// referenced group (OVN's auto-generated port-group address set). The FK
    /// is RESTRICT — a group cannot be deleted while another group's rule
    /// references it; the API surfaces that as a 409.
    @OptionalParent(key: "remote_group_id")
    var remoteGroup: SecurityGroup?

    @OptionalField(key: "description")
    var ruleDescription: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        securityGroupID: UUID,
        direction: Direction,
        ethertype: Ethertype,
        protocolName: String? = nil,
        portRangeMin: Int? = nil,
        portRangeMax: Int? = nil,
        remoteCIDR: String? = nil,
        remoteGroupID: UUID? = nil,
        description: String? = nil
    ) {
        self.id = id
        self.$securityGroup.id = securityGroupID
        self.direction = direction
        self.ethertype = ethertype
        self.protocolName = protocolName
        self.portRangeMin = portRangeMin
        self.portRangeMax = portRangeMax
        self.remoteCIDR = remoteCIDR
        self.$remoteGroup.id = remoteGroupID
        self.ruleDescription = description
    }
}
