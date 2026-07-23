import Fluent
import Vapor

/// A stateful, NIC-level firewall: a named set of ingress/egress rules that
/// VM NICs attach to, realized agent-side as OVN ACLs on an OVN port group.
/// The model is AWS-shaped: groups are project-scoped, every NIC must belong
/// to at least one group, and each project has an auto-created, undeletable
/// `default` group that NICs fall back to when the caller picks none.
///
/// `generation` is bumped on every rule mutation and travels with the group
/// on the desired-state sync, so a replayed or reordered sync can never
/// resurrect a deleted rule (the `LogicalNetwork.generation` pattern).
final class SecurityGroup: Model, @unchecked Sendable {
    static let schema = "security_groups"

    /// Name of the auto-created per-project group.
    static let defaultGroupName = "default"

    /// Hard cap on rules per group — a guard against unbounded ACL growth on
    /// the agents, not a quota (quotas cap the group count).
    static let maxRulesPerGroup = 100

    /// Hard cap on groups per NIC. OVN evaluates every attached group's ACLs
    /// for every packet, so this bounds per-port match complexity.
    static let maxGroupsPerNIC = 5

    /// Hard cap on groups per project. Deliberately a constant, not a
    /// `ResourceQuota` column: the quota model's network columns are
    /// bookkeeping-only today, and dead quota plumbing would be worse than an
    /// honest cap. Promote to a real quota when networks get one.
    static let maxGroupsPerProject = 100

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "project_id")
    var project: Project

    /// Unique per project (schema-enforced).
    @Field(key: "name")
    var name: String

    @OptionalField(key: "description")
    var groupDescription: String?

    /// The project's auto-created fallback group: undeletable and
    /// un-renamable, though its rules are editable (AWS semantics). At most
    /// one per project (schema-enforced via partial unique index).
    @Field(key: "is_default")
    var isDefault: Bool

    /// Monotonic counter bumped on every rule mutation; see the type doc.
    @Field(key: "generation")
    var generation: Int64

    @OptionalParent(key: "created_by_id")
    var createdBy: User?

    @Children(for: \.$securityGroup)
    var rules: [SecurityGroupRule]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        projectID: UUID,
        name: String,
        description: String? = nil,
        isDefault: Bool = false,
        createdByID: UUID? = nil
    ) {
        self.id = id
        self.$project.id = projectID
        self.name = name
        self.groupDescription = description
        self.isDefault = isDefault
        self.generation = 0
        self.$createdBy.id = createdByID
    }
}

extension SecurityGroup: Content {}

// MARK: - DTOs

struct CreateSecurityGroupRequest: Content {
    let name: String
    let description: String?
    /// Defaults to the caller's default project when omitted, matching VM and
    /// network creation.
    let projectId: UUID?

    init(name: String, description: String? = nil, projectId: UUID? = nil) {
        self.name = name
        self.description = description
        self.projectId = projectId
    }
}

struct UpdateSecurityGroupRequest: Content {
    let name: String?
    let description: String?
}

struct CreateSecurityGroupRuleRequest: Content {
    let direction: SecurityGroupRule.Direction
    let ethertype: SecurityGroupRule.Ethertype
    /// "tcp", "udp", or "icmp"; nil matches any protocol.
    let protocolName: String?
    /// tcp/udp: destination port range (min == max for one port).
    /// icmp: min is the ICMP type, max the code. Nil means all.
    let portRangeMin: Int?
    let portRangeMax: Int?
    /// At most one of `remoteCIDR`/`remoteGroupId`; both nil means "any".
    let remoteCIDR: String?
    let remoteGroupId: UUID?
    let description: String?

    init(
        direction: SecurityGroupRule.Direction,
        ethertype: SecurityGroupRule.Ethertype,
        protocolName: String? = nil,
        portRangeMin: Int? = nil,
        portRangeMax: Int? = nil,
        remoteCIDR: String? = nil,
        remoteGroupId: UUID? = nil,
        description: String? = nil
    ) {
        self.direction = direction
        self.ethertype = ethertype
        self.protocolName = protocolName
        self.portRangeMin = portRangeMin
        self.portRangeMax = portRangeMax
        self.remoteCIDR = remoteCIDR
        self.remoteGroupId = remoteGroupId
        self.description = description
    }
}

struct AttachSecurityGroupRequest: Content {
    let vmId: UUID
    /// The VM NIC to attach to; defaults to the VM's first interface.
    let interfaceId: UUID?

    init(vmId: UUID, interfaceId: UUID? = nil) {
        self.vmId = vmId
        self.interfaceId = interfaceId
    }
}

struct SecurityGroupRuleResponse: Content {
    let id: UUID
    let direction: SecurityGroupRule.Direction
    let ethertype: SecurityGroupRule.Ethertype
    let protocolName: String?
    let portRangeMin: Int?
    let portRangeMax: Int?
    let remoteCIDR: String?
    let remoteGroupId: UUID?
    let description: String?
    let createdAt: Date?

    init(from rule: SecurityGroupRule) throws {
        self.id = try rule.requireID()
        self.direction = rule.direction
        self.ethertype = rule.ethertype
        self.protocolName = rule.protocolName
        self.portRangeMin = rule.portRangeMin
        self.portRangeMax = rule.portRangeMax
        self.remoteCIDR = rule.remoteCIDR
        self.remoteGroupId = rule.$remoteGroup.id
        self.description = rule.ruleDescription
        self.createdAt = rule.createdAt
    }
}

struct SecurityGroupResponse: Content {
    let id: UUID
    let name: String
    let description: String?
    let projectId: UUID
    let isDefault: Bool
    let rules: [SecurityGroupRuleResponse]
    /// How many NICs currently attach this group (drives "in use" UI and
    /// delete affordances).
    let attachmentCount: Int
    let createdAt: Date?
    let updatedAt: Date?

    init(from group: SecurityGroup, attachmentCount: Int) throws {
        self.id = try group.requireID()
        self.name = group.name
        self.description = group.groupDescription
        self.projectId = group.$project.id
        self.isDefault = group.isDefault
        self.rules = try group.rules.map(SecurityGroupRuleResponse.init(from:))
        self.attachmentCount = attachmentCount
        self.createdAt = group.createdAt
        self.updatedAt = group.updatedAt
    }
}
