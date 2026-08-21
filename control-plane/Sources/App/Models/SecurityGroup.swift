import ControlPlanePostgres
import Foundation
import Vapor

enum SecurityGroup {
    static let schema = "security_groups"
    static let defaultGroupName = "default"
    static let maxRulesPerGroup = 100
    static let maxGroupsPerNIC = 5
    static let maxGroupsPerProject = 100
}

struct SecurityGroupSnapshot: Equatable, Sendable {
    let id: UUID
    let projectID: UUID
    let name: String
    let groupDescription: String?
    let isDefault: Bool
    let generation: Int64
    let createdByID: UUID?
    let createdAt: Date?
    let updatedAt: Date?
}

enum LegacySecurityGroupStore {
    static func groups(
        ids: [UUID]? = nil, projectIDs: [UUID]? = nil, isDefault: Bool? = nil,
        on db: PostgresStoreContext
    ) async throws -> [SecurityGroupSnapshot] {
        if let ids, ids.isEmpty { return [] }
        if let projectIDs, projectIDs.isEmpty { return [] }
        var query: PostgresSQLQuery = "SELECT \(unsafeRaw: columns) FROM security_groups WHERE TRUE"
        if let ids { query += " AND id = ANY(\(bind: ids))" }
        if let projectIDs { query += " AND project_id = ANY(\(bind: projectIDs))" }
        if let isDefault { query += " AND is_default = \(bind: isDefault)" }
        query += " ORDER BY name, id"
        return try await requireSQL(db).raw(query).all(decoding: Record.self).map(\.snapshot)
    }

    static func group(id: UUID, on db: PostgresStoreContext) async throws -> SecurityGroupSnapshot? {
        try await groups(ids: [id], on: db).first
    }

    static func defaultGroup(projectID: UUID, on db: PostgresStoreContext) async throws
        -> SecurityGroupSnapshot?
    {
        try await groups(projectIDs: [projectID], isDefault: true, on: db).first
    }

    @discardableResult
    static func insert(
        id: UUID = UUID(), projectID: UUID, name: String,
        description: String? = nil, isDefault: Bool = false,
        createdByID: UUID? = nil, on db: PostgresStoreContext
    ) async throws -> SecurityGroupSnapshot {
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO security_groups (
                id, project_id, name, description, is_default, generation,
                created_by_id, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: projectID), \(bind: name), \(bind: description),
                \(bind: isDefault), 0, \(bind: createdByID), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            ) RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not create security group")
        }
        return row.snapshot
    }

    @discardableResult
    static func update(
        id: UUID, name: String, description: String?, on db: PostgresStoreContext
    ) async throws -> SecurityGroupSnapshot? {
        try await requireSQL(db).raw(
            """
            UPDATE security_groups
            SET name = \(bind: name), description = \(bind: description),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = \(bind: id)
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: Record.self)?.snapshot
    }

    static func count(projectID: UUID, on db: PostgresStoreContext) async throws -> Int {
        struct Count: Decodable { let count: Int }
        return try await requireSQL(db).raw(
            "SELECT count(*)::bigint AS count FROM security_groups WHERE project_id = \(bind: projectID)"
        ).first(decoding: Count.self)?.count ?? 0
    }

    static func ids(projectIDs: [UUID], on db: PostgresStoreContext) async throws -> [UUID] {
        struct ID: Decodable { let id: UUID }
        guard !projectIDs.isEmpty else { return [] }
        return try await requireSQL(db).raw(
            "SELECT id FROM security_groups WHERE project_id = ANY(\(bind: projectIDs))"
        ).all(decoding: ID.self).map(\.id)
    }

    @discardableResult
    static func delete(id: UUID, on db: PostgresStoreContext) async throws -> UUID? {
        struct ID: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            "DELETE FROM security_groups WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: ID.self)?.id
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let projectID: UUID
        let name: String
        let groupDescription: String?
        let isDefault: Bool
        let generation: Int64
        let createdByID: UUID?
        let createdAt: Date?
        let updatedAt: Date?

        var snapshot: SecurityGroupSnapshot {
            SecurityGroupSnapshot(
                id: id, projectID: projectID, name: name,
                groupDescription: groupDescription, isDefault: isDefault,
                generation: generation, createdByID: createdByID,
                createdAt: createdAt, updatedAt: updatedAt)
        }
    }

    private static let columns = """
        id, project_id AS "projectID", name, description AS "groupDescription",
        is_default AS "isDefault", generation, created_by_id AS "createdByID",
        created_at AS "createdAt", updated_at AS "updatedAt"
        """

    private static func requireSQL(_ db: PostgresStoreContext) throws -> PostgresStoreContext {
        guard let sql = db as? PostgresStoreContext else {
            throw Abort(.internalServerError, reason: "Security groups require PostgreSQL")
        }
        return sql
    }
}

// MARK: - DTOs

struct CreateSecurityGroupRequest: Content, ValidatedRequestBody {
    var name: String
    let description: String?
    /// Required: there is no default project (issue #1059). Optional here so
    /// the refusal is `Request.projectIsRequired`'s, which names the remedy,
    /// rather than a `Codable` decode failure that names neither.
    let projectId: UUID?

    init(name: String, description: String? = nil, projectId: UUID? = nil) {
        self.name = name
        self.description = description
        self.projectId = projectId
    }

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
    }
}

struct UpdateSecurityGroupRequest: Content, ValidatedRequestBody {
    var name: String?
    let description: String?

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
    }
}

struct CreateSecurityGroupRuleRequest: Content, ValidatedRequestBody {
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
    /// Log the packets this rule matches (STR-34). Omitted means off.
    let log: Bool?
    let description: String?

    init(
        direction: SecurityGroupRule.Direction,
        ethertype: SecurityGroupRule.Ethertype,
        protocolName: String? = nil,
        portRangeMin: Int? = nil,
        portRangeMax: Int? = nil,
        remoteCIDR: String? = nil,
        remoteGroupId: UUID? = nil,
        log: Bool? = nil,
        description: String? = nil
    ) {
        self.direction = direction
        self.ethertype = ethertype
        self.protocolName = protocolName
        self.portRangeMin = portRangeMin
        self.portRangeMax = portRangeMax
        self.remoteCIDR = remoteCIDR
        self.remoteGroupId = remoteGroupId
        self.log = log
        self.description = description
    }

    mutating func validate() throws {
        try Validate.text(description)
    }
}

/// The attach/detach target: exactly one of `vmId` / `sandboxId`, optionally
/// narrowed to a specific NIC. Both ids are optional on the wire so the
/// sandbox arm (STR-34) could be added without breaking clients that send
/// `vmId`; `requireTarget()` is what actually enforces exactly-one, so no
/// handler has to re-derive the rule.
struct AttachSecurityGroupRequest: Content {
    let vmId: UUID?
    /// The sandbox to attach to. Realizes the group's port group and ACLs, but
    /// not yet the membership — see the sandbox NIC membership store for which
    /// half of the sync reaches an agent today.
    let sandboxId: UUID?
    /// The NIC to attach to; defaults to the workload's first interface.
    let interfaceId: UUID?

    init(vmId: UUID? = nil, sandboxId: UUID? = nil, interfaceId: UUID? = nil) {
        self.vmId = vmId
        self.sandboxId = sandboxId
        self.interfaceId = interfaceId
    }

    enum Target {
        case vm(UUID)
        case sandbox(UUID)
    }

    /// Resolves the workload the request names, refusing both "neither" and
    /// "both" — a request naming two workloads has no defensible reading, and
    /// silently preferring one would attach the group to the wrong thing.
    func requireTarget() throws -> Target {
        switch (vmId, sandboxId) {
        case (let vmId?, nil): return .vm(vmId)
        case (nil, let sandboxId?): return .sandbox(sandboxId)
        case (nil, nil):
            throw Abort(.badRequest, reason: "Name the target workload with either vmId or sandboxId")
        case (_?, _?):
            throw Abort(.badRequest, reason: "Name either vmId or sandboxId, not both")
        }
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
    /// Whether the realized OVN ACL logs matching packets (STR-34).
    let log: Bool
    let description: String?
    let createdAt: Date?

    init(from rule: SecurityGroupRuleSnapshot) {
        self.id = rule.id
        self.direction = rule.direction
        self.ethertype = rule.ethertype
        self.protocolName = rule.protocolName
        self.portRangeMin = rule.portRangeMin
        self.portRangeMax = rule.portRangeMax
        self.remoteCIDR = rule.remoteCIDR
        self.remoteGroupId = rule.remoteGroupID
        self.log = rule.log
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

    init(
        from group: SecurityGroupSnapshot,
        rules: [SecurityGroupRuleSnapshot] = [],
        attachmentCount: Int
    ) {
        self.id = group.id
        self.name = group.name
        self.description = group.groupDescription
        self.projectId = group.projectID
        self.isDefault = group.isDefault
        self.rules = rules.map(SecurityGroupRuleResponse.init(from:))
        self.attachmentCount = attachmentCount
        self.createdAt = group.createdAt
        self.updatedAt = group.updatedAt
    }
}
