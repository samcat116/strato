import Foundation
import PostgresNIO

public struct GroupWrite: Sendable {
    public let id: UUID
    public let organizationID: UUID
    public let name: String
    public let description: String
    public let scimProvisioned: Bool

    public init(
        id: UUID = UUID(),
        organizationID: UUID,
        name: String,
        description: String,
        scimProvisioned: Bool = false
    ) {
        self.id = id
        self.organizationID = organizationID
        self.name = name
        self.description = description
        self.scimProvisioned = scimProvisioned
    }
}

public struct GroupSnapshot: Equatable, Sendable {
    public let id: UUID
    public let organizationID: UUID
    public let name: String
    public let description: String
    public let scimProvisioned: Bool
    public let createdAt: Date?
    public let updatedAt: Date?
}

public struct GroupOverview: Equatable, Sendable {
    public let group: GroupSnapshot
    public let memberCount: Int
}

public struct GroupMemberSnapshot: Equatable, Sendable {
    public let userID: UUID
    public let username: String
    public let displayName: String
    public let email: String
    public let joinedAt: Date?
}

public struct GroupMembershipSnapshot: Equatable, Sendable {
    public let id: UUID
    public let userID: UUID
    public let groupID: UUID
    public let createdAt: Date?
}

public enum GroupNameFilter: Equatable, Sendable {
    case all
    case present
    case equal(String)
    case notEqual(String)
    case contains(String)
    case startsWith(String)
    case endsWith(String)

    fileprivate var queryValues: (mode: String, value: String) {
        switch self {
        case .all: return ("all", "")
        case .present: return ("present", "")
        case .equal(let value): return ("equal", value)
        case .notEqual(let value): return ("not_equal", value)
        case .contains(let value): return ("contains", "%\(value)%")
        case .startsWith(let value): return ("starts_with", "\(value)%")
        case .endsWith(let value): return ("ends_with", "%\(value)")
        }
    }
}

public struct GroupPage: Equatable, Sendable {
    public let items: [GroupSnapshot]
    public let total: Int
}

public struct GroupMemberMutationResult: Equatable, Sendable {
    public let groupFound: Bool
    public let addedUserIDs: [UUID]
    public let removedUserIDs: [UUID]
    public let ineligibleUserIDs: [UUID]

    fileprivate static let groupNotFound = GroupMemberMutationResult(
        groupFound: false,
        addedUserIDs: [],
        removedUserIDs: [],
        ineligibleUserIDs: []
    )
}

public enum GroupMembershipSetResult: Equatable, Sendable {
    case applied
    case unchanged
    case groupNotFound
    case userNotOrganizationMember
}

public enum GroupPersistenceError: Error, Equatable, Sendable {
    case duplicateName(organizationID: UUID, name: String)
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Owns organization groups, membership convergence, and the group-principal
/// cleanup invariant. Callers receive immutable facts and express membership
/// intent; they never orchestrate join-table reads or duplicate-key recovery.
public struct GroupsPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func groups(organizationID: UUID) async throws -> [GroupOverview] {
        try await database.withSession(operation: "groups.list") { session in
            try await session.execute(
                ListGroups(organizationID: organizationID),
                operation: "groups.list.query"
            )
        }
    }

    public func groups(ids: [UUID]) async throws -> [GroupSnapshot] {
        guard !ids.isEmpty else { return [] }
        return try await database.withSession(operation: "groups.lookup_many") { session in
            try await session.execute(
                FindGroups(ids: ids),
                operation: "groups.lookup_many.query"
            )
        }
    }

    public func group(id: UUID) async throws -> GroupSnapshot? {
        try await database.withSession(operation: "groups.lookup") { session in
            try oneOrNone(
                await session.execute(
                    FindGroup(id: id),
                    operation: "groups.lookup.query"
                )
            )
        }
    }

    public func ownedGroup(id: UUID, organizationID: UUID) async throws -> GroupSnapshot? {
        try await database.withSession(operation: "groups.lookup_owned") { session in
            try oneOrNone(
                await session.execute(
                    FindOwnedGroup(id: id, organizationID: organizationID),
                    operation: "groups.lookup_owned.query"
                )
            )
        }
    }

    public func countOwnedGroups(ids: [UUID], organizationID: UUID) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try await database.withSession(operation: "groups.count_owned") { session in
            try only(
                await session.execute(
                    CountOwnedGroups(ids: ids, organizationID: organizationID),
                    operation: "groups.count_owned.query"
                )
            )
        }
    }

    public func groupIDs(organizationID: UUID) async throws -> [UUID] {
        try await database.withSession(operation: "groups.ids_for_organization") { session in
            try await session.execute(
                FindGroupIDs(organizationID: organizationID),
                operation: "groups.ids_for_organization.query"
            )
        }
    }

    public func create(_ write: GroupWrite) async throws -> GroupSnapshot {
        do {
            return try await database.withSession(operation: "groups.create") { session in
                try only(
                    await session.execute(
                        InsertGroup(write: write),
                        operation: "groups.create.query"
                    )
                )
            }
        } catch let error as PSQLError
            where error.serverInfo?[.sqlState] == "23505"
                && error.serverInfo?[.constraintName] == "uq:groups.name+groups.organization_id"
        {
            throw GroupPersistenceError.duplicateName(
                organizationID: write.organizationID,
                name: write.name
            )
        }
    }

    public func replace(_ write: GroupWrite) async throws -> GroupSnapshot? {
        do {
            return try await database.withSession(operation: "groups.replace") { session in
                try oneOrNone(
                    await session.execute(
                        ReplaceGroup(write: write),
                        operation: "groups.replace.query"
                    )
                )
            }
        } catch let error as PSQLError
            where error.serverInfo?[.sqlState] == "23505"
                && error.serverInfo?[.constraintName] == "uq:groups.name+groups.organization_id"
        {
            throw GroupPersistenceError.duplicateName(
                organizationID: write.organizationID,
                name: write.name
            )
        }
    }

    /// Deletes the group and every binding held by its principal in one
    /// transaction. Membership and group-owned rows retain their FK cascades.
    public func delete(id: UUID, organizationID: UUID) async throws -> Bool {
        try await database.withTransaction(operation: "groups.delete") { session in
            guard
                try await session.execute(
                    LockOwnedGroup(id: id, organizationID: organizationID),
                    operation: "groups.delete.lock"
                ).count == 1
            else { return false }

            _ = try await session.execute(
                DeleteGroupPrincipalBindings(groupID: id),
                operation: "groups.delete.bindings"
            )
            let deleted = try await session.execute(
                DeleteOwnedGroup(id: id, organizationID: organizationID),
                operation: "groups.delete.group"
            )
            return deleted == [id]
        }
    }

    public func members(groupID: UUID) async throws -> [GroupMemberSnapshot] {
        try await database.withSession(operation: "groups.members") { session in
            try await session.execute(
                FindGroupMembers(groupID: groupID),
                operation: "groups.members.query"
            )
        }
    }

    public func memberCount(groupID: UUID) async throws -> Int {
        try await database.withSession(operation: "groups.member_count") { session in
            try only(
                await session.execute(
                    CountGroupMembers(groupID: groupID),
                    operation: "groups.member_count.query"
                )
            )
        }
    }

    public func memberships(userIDs: [UUID]) async throws -> [GroupMembershipSnapshot] {
        guard !userIDs.isEmpty else { return [] }
        return try await database.withSession(operation: "groups.memberships_for_users") { session in
            try await session.execute(
                FindMembershipsByUsers(userIDs: userIDs),
                operation: "groups.memberships_for_users.query"
            )
        }
    }

    public func memberships(groupIDs: [UUID]) async throws -> [GroupMembershipSnapshot] {
        guard !groupIDs.isEmpty else { return [] }
        return try await database.withSession(operation: "groups.memberships_for_groups") { session in
            try await session.execute(
                FindMembershipsByGroups(groupIDs: groupIDs),
                operation: "groups.memberships_for_groups.query"
            )
        }
    }

    public func hasMember(userID: UUID, groupID: UUID) async throws -> Bool {
        try await database.withSession(operation: "groups.has_member") { session in
            try only(
                await session.execute(
                    GroupHasMember(userID: userID, groupID: groupID),
                    operation: "groups.has_member.query"
                )
            )
        }
    }

    public func groupsShareMember(_ firstGroupID: UUID, _ secondGroupID: UUID) async throws -> Bool {
        try await database.withSession(operation: "groups.share_member") { session in
            try only(
                await session.execute(
                    GroupsShareMember(firstGroupID: firstGroupID, secondGroupID: secondGroupID),
                    operation: "groups.share_member.query"
                )
            )
        }
    }

    public func hasMemberOutsideOrganization(groupID: UUID, organizationID: UUID) async throws -> Bool {
        try await database.withSession(operation: "groups.has_external_member") { session in
            try only(
                await session.execute(
                    GroupHasMemberOutsideOrganization(
                        groupID: groupID,
                        organizationID: organizationID
                    ),
                    operation: "groups.has_external_member.query"
                )
            )
        }
    }

    public func addMembers(
        _ userIDs: [UUID],
        to groupID: UUID,
        organizationID: UUID
    ) async throws -> GroupMemberMutationResult {
        try await mutateMembers(
            groupID: groupID,
            organizationID: organizationID,
            add: userIDs,
            remove: [],
            replaceAll: false
        )
    }

    public func removeMembers(
        _ userIDs: [UUID],
        from groupID: UUID,
        organizationID: UUID
    ) async throws -> GroupMemberMutationResult {
        try await mutateMembers(
            groupID: groupID,
            organizationID: organizationID,
            add: [],
            remove: userIDs,
            replaceAll: false
        )
    }

    public func replaceMembers(
        _ userIDs: [UUID],
        in groupID: UUID,
        organizationID: UUID
    ) async throws -> GroupMemberMutationResult {
        try await mutateMembers(
            groupID: groupID,
            organizationID: organizationID,
            add: userIDs,
            remove: [],
            replaceAll: true
        )
    }

    public func setMembership(
        userID: UUID,
        groupID: UUID,
        organizationID: UUID,
        desired: Bool
    ) async throws -> GroupMembershipSetResult {
        if desired {
            let result = try await addMembers([userID], to: groupID, organizationID: organizationID)
            guard result.groupFound else { return .groupNotFound }
            if result.ineligibleUserIDs.contains(userID) { return .userNotOrganizationMember }
            return result.addedUserIDs.contains(userID) ? .applied : .unchanged
        }

        let result = try await removeMembers([userID], from: groupID, organizationID: organizationID)
        guard result.groupFound else { return .groupNotFound }
        return result.removedUserIDs.contains(userID) ? .applied : .unchanged
    }

    public func search(
        organizationID: UUID,
        filters: [GroupNameFilter] = [],
        offset: Int,
        limit: Int
    ) async throws -> GroupPage {
        let values = (filters.isEmpty ? [.all] : filters).map(\.queryValues)
        return try await database.withSession(operation: "groups.search") { session in
            let items = try await session.execute(
                SearchGroups(
                    organizationID: organizationID,
                    modes: values.map(\.mode),
                    values: values.map(\.value),
                    offset: offset,
                    limit: limit
                ),
                operation: "groups.search.items"
            )
            let total = try await session.execute(
                CountSearchedGroups(
                    organizationID: organizationID,
                    modes: values.map(\.mode),
                    values: values.map(\.value)
                ),
                operation: "groups.search.count"
            )
            return try GroupPage(items: items, total: only(total))
        }
    }

    private func mutateMembers(
        groupID: UUID,
        organizationID: UUID,
        add requestedAdds: [UUID],
        remove requestedRemovals: [UUID],
        replaceAll: Bool
    ) async throws -> GroupMemberMutationResult {
        let adds = Array(Set(requestedAdds))
        let removals = Array(Set(requestedRemovals))
        return try await database.withTransaction(operation: "groups.mutate_members") { session in
            guard
                try await session.execute(
                    LockOwnedGroup(id: groupID, organizationID: organizationID),
                    operation: "groups.mutate_members.lock"
                ).count == 1
            else { return .groupNotFound }

            var removed: [UUID] = []
            if replaceAll {
                removed = try await session.execute(
                    DeleteAllGroupMemberships(groupID: groupID),
                    operation: "groups.mutate_members.remove_all"
                )
            } else if !removals.isEmpty {
                removed = try await session.execute(
                    DeleteGroupMemberships(groupID: groupID, userIDs: removals),
                    operation: "groups.mutate_members.remove"
                )
            }

            guard !adds.isEmpty else {
                return GroupMemberMutationResult(
                    groupFound: true,
                    addedUserIDs: [],
                    removedUserIDs: removed,
                    ineligibleUserIDs: []
                )
            }

            let eligible = try await session.execute(
                FindEligibleOrganizationMembers(
                    organizationID: organizationID,
                    userIDs: adds
                ),
                operation: "groups.mutate_members.eligible"
            )
            let eligibleSet = Set(eligible)
            let ineligible = adds.filter { !eligibleSet.contains($0) }
            let added: [UUID]
            if eligible.isEmpty {
                added = []
            } else {
                added = try await session.execute(
                    InsertGroupMemberships(
                        ids: eligible.map { _ in UUID() },
                        userIDs: eligible,
                        groupID: groupID
                    ),
                    operation: "groups.mutate_members.add"
                )
            }
            return GroupMemberMutationResult(
                groupFound: true,
                addedUserIDs: added,
                removedUserIDs: removed,
                ineligibleUserIDs: ineligible
            )
        }
    }

    private func oneOrNone(_ rows: [GroupSnapshot]) throws -> GroupSnapshot? {
        guard rows.count <= 1 else {
            throw GroupPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return rows.first
    }

    private func only<Value>(_ rows: [Value]) throws -> Value {
        guard rows.count == 1, let row = rows.first else {
            throw GroupPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return row
    }
}

private let groupColumns = "id, organization_id, name, description, scim_provisioned, created_at, updated_at"

private protocol GroupStatement: PostgresPreparedStatement where Row == GroupSnapshot {}

private extension GroupStatement {
    func decodeRow(_ row: PostgresRow) throws -> GroupSnapshot {
        let (id, organizationID, name, description, scimProvisioned, createdAt, updatedAt) =
            try row.decode((UUID, UUID, String, String, Bool, Date?, Date?).self)
        return GroupSnapshot(
            id: id,
            organizationID: organizationID,
            name: name,
            description: description,
            scimProvisioned: scimProvisioned,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private struct ListGroups: PostgresPreparedStatement {
    static let sql = """
        SELECT g.\(groupColumns.replacingOccurrences(of: ", ", with: ", g.")),
               count(ug.id)::bigint AS member_count
        FROM groups AS g
        LEFT JOIN user_groups AS ug ON ug.group_id = g.id
        WHERE g.organization_id = $1
        GROUP BY g.id
        ORDER BY g.name, g.id
        """
    typealias Row = GroupOverview

    let organizationID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(organizationID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> GroupOverview {
        let (id, organizationID, name, description, scimProvisioned, createdAt, updatedAt, memberCount) =
            try row.decode((UUID, UUID, String, String, Bool, Date?, Date?, Int).self)
        return GroupOverview(
            group: GroupSnapshot(
                id: id,
                organizationID: organizationID,
                name: name,
                description: description,
                scimProvisioned: scimProvisioned,
                createdAt: createdAt,
                updatedAt: updatedAt
            ),
            memberCount: memberCount
        )
    }
}

private struct FindGroup: GroupStatement {
    static let sql = "SELECT \(groupColumns) FROM groups WHERE id = $1 LIMIT 1"
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct FindOwnedGroup: GroupStatement {
    static let sql = "SELECT \(groupColumns) FROM groups WHERE id = $1 AND organization_id = $2 LIMIT 1"
    let id: UUID
    let organizationID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(organizationID)
        return bindings
    }
}

private struct FindGroups: GroupStatement {
    static let sql = "SELECT \(groupColumns) FROM groups WHERE id = ANY($1) ORDER BY id"
    let ids: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(ids)
        return bindings
    }
}

private struct CountOwnedGroups: PostgresPreparedStatement {
    static let sql = "SELECT count(*)::bigint FROM groups WHERE organization_id = $1 AND id = ANY($2)"
    typealias Row = Int
    let ids: [UUID]
    let organizationID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(organizationID)
        bindings.append(ids)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct FindGroupIDs: PostgresPreparedStatement {
    static let sql = "SELECT id FROM groups WHERE organization_id = $1 ORDER BY id"
    typealias Row = UUID
    let organizationID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertGroup: GroupStatement {
    static let sql = """
        INSERT INTO groups (
            id, organization_id, name, description, scim_provisioned, created_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING \(groupColumns)
        """
    let write: GroupWrite
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(write.id)
        bindings.append(write.organizationID)
        bindings.append(write.name)
        bindings.append(write.description)
        bindings.append(write.scimProvisioned)
        return bindings
    }
}

private struct ReplaceGroup: GroupStatement {
    static let sql = """
        UPDATE groups
        SET name = $3,
            description = $4,
            scim_provisioned = $5,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND organization_id = $2
        RETURNING \(groupColumns)
        """
    let write: GroupWrite
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(write.id)
        bindings.append(write.organizationID)
        bindings.append(write.name)
        bindings.append(write.description)
        bindings.append(write.scimProvisioned)
        return bindings
    }
}

private struct LockOwnedGroup: PostgresPreparedStatement {
    static let sql = "SELECT id FROM groups WHERE id = $1 AND organization_id = $2 FOR UPDATE"
    typealias Row = UUID
    let id: UUID
    let organizationID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteGroupPrincipalBindings: PostgresPreparedStatement {
    static let sql = "DELETE FROM role_bindings WHERE principal_type = 'group' AND principal_id = $1"
    typealias Row = Void
    let groupID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(groupID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws {}
}

private struct DeleteOwnedGroup: PostgresPreparedStatement {
    static let sql = "DELETE FROM groups WHERE id = $1 AND organization_id = $2 RETURNING id"
    typealias Row = UUID
    let id: UUID
    let organizationID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct FindGroupMembers: PostgresPreparedStatement {
    static let sql = """
        SELECT u.id, u.username, u.display_name, u.email, ug.created_at
        FROM user_groups AS ug
        JOIN users AS u ON u.id = ug.user_id
        WHERE ug.group_id = $1
        ORDER BY ug.created_at, u.id
        """
    typealias Row = GroupMemberSnapshot
    let groupID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(groupID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> GroupMemberSnapshot {
        let (userID, username, displayName, email, joinedAt) =
            try row.decode((UUID, String, String, String, Date?).self)
        return GroupMemberSnapshot(
            userID: userID,
            username: username,
            displayName: displayName,
            email: email,
            joinedAt: joinedAt
        )
    }
}

private struct CountGroupMembers: PostgresPreparedStatement {
    static let sql = "SELECT count(*)::bigint FROM user_groups WHERE group_id = $1"
    typealias Row = Int
    let groupID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(groupID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private protocol GroupMembershipStatement: PostgresPreparedStatement
where Row == GroupMembershipSnapshot {}

private extension GroupMembershipStatement {
    func decodeRow(_ row: PostgresRow) throws -> GroupMembershipSnapshot {
        let (id, userID, groupID, createdAt) = try row.decode((UUID, UUID, UUID, Date?).self)
        return GroupMembershipSnapshot(id: id, userID: userID, groupID: groupID, createdAt: createdAt)
    }
}

private struct FindMembershipsByUsers: GroupMembershipStatement {
    static let sql = "SELECT id, user_id, group_id, created_at FROM user_groups WHERE user_id = ANY($1) ORDER BY user_id, group_id"
    let userIDs: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(userIDs)
        return bindings
    }
}

private struct FindMembershipsByGroups: GroupMembershipStatement {
    static let sql = "SELECT id, user_id, group_id, created_at FROM user_groups WHERE group_id = ANY($1) ORDER BY group_id, user_id"
    let groupIDs: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(groupIDs)
        return bindings
    }
}

private struct GroupHasMember: PostgresPreparedStatement {
    static let sql = "SELECT EXISTS (SELECT 1 FROM user_groups WHERE user_id = $1 AND group_id = $2)"
    typealias Row = Bool
    let userID: UUID
    let groupID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(userID)
        bindings.append(groupID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}

private struct GroupsShareMember: PostgresPreparedStatement {
    static let sql = """
        SELECT EXISTS (
            SELECT 1
            FROM user_groups AS first_membership
            JOIN user_groups AS second_membership
              ON second_membership.user_id = first_membership.user_id
            WHERE first_membership.group_id = $1
              AND second_membership.group_id = $2
        )
        """
    typealias Row = Bool
    let firstGroupID: UUID
    let secondGroupID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(firstGroupID)
        bindings.append(secondGroupID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}

private struct GroupHasMemberOutsideOrganization: PostgresPreparedStatement {
    static let sql = """
        SELECT EXISTS (
            SELECT 1
            FROM user_groups AS membership
            WHERE membership.group_id = $1
              AND NOT EXISTS (
                  SELECT 1
                  FROM user_organizations AS organization_membership
                  WHERE organization_membership.user_id = membership.user_id
                    AND organization_membership.organization_id = $2
              )
        )
        """
    typealias Row = Bool
    let groupID: UUID
    let organizationID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(groupID)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}

private struct FindEligibleOrganizationMembers: PostgresPreparedStatement {
    static let sql = """
        SELECT DISTINCT user_id
        FROM user_organizations
        WHERE organization_id = $1 AND user_id = ANY($2)
        ORDER BY user_id
        """
    typealias Row = UUID
    let organizationID: UUID
    let userIDs: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(organizationID)
        bindings.append(userIDs)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertGroupMemberships: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO user_groups (id, user_id, group_id, created_at)
        SELECT input.id, input.user_id, $3, CURRENT_TIMESTAMP
        FROM unnest($1::uuid[], $2::uuid[]) AS input(id, user_id)
        ON CONFLICT (user_id, group_id) DO NOTHING
        RETURNING user_id
        """
    typealias Row = UUID
    let ids: [UUID]
    let userIDs: [UUID]
    let groupID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(ids)
        bindings.append(userIDs)
        bindings.append(groupID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteGroupMemberships: PostgresPreparedStatement {
    static let sql = "DELETE FROM user_groups WHERE group_id = $1 AND user_id = ANY($2) RETURNING user_id"
    typealias Row = UUID
    let groupID: UUID
    let userIDs: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(groupID)
        bindings.append(userIDs)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteAllGroupMemberships: PostgresPreparedStatement {
    static let sql = "DELETE FROM user_groups WHERE group_id = $1 RETURNING user_id"
    typealias Row = UUID
    let groupID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(groupID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private let groupSearchPredicate = """
    organization_id = $1
    AND NOT EXISTS (
        SELECT 1
        FROM unnest($2::text[], $3::text[]) AS requested_filter(mode, value)
        WHERE NOT (
            requested_filter.mode = 'all'
            OR (requested_filter.mode = 'present' AND name <> '')
            OR (requested_filter.mode = 'equal' AND name = requested_filter.value)
            OR (requested_filter.mode = 'not_equal' AND name <> requested_filter.value)
            OR (requested_filter.mode = 'contains' AND name ILIKE requested_filter.value)
            OR (requested_filter.mode = 'starts_with' AND name ILIKE requested_filter.value)
            OR (requested_filter.mode = 'ends_with' AND name ILIKE requested_filter.value)
        )
    )
    """

private struct SearchGroups: GroupStatement {
    static let sql = """
        SELECT \(groupColumns)
        FROM groups
        WHERE \(groupSearchPredicate)
        ORDER BY id
        OFFSET $4 LIMIT $5
        """
    let organizationID: UUID
    let modes: [String]
    let values: [String]
    let offset: Int
    let limit: Int
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(organizationID)
        bindings.append(modes)
        bindings.append(values)
        bindings.append(offset)
        bindings.append(limit)
        return bindings
    }
}

private struct CountSearchedGroups: PostgresPreparedStatement {
    static let sql = "SELECT count(*)::bigint FROM groups WHERE \(groupSearchPredicate)"
    typealias Row = Int
    let organizationID: UUID
    let modes: [String]
    let values: [String]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(organizationID)
        bindings.append(modes)
        bindings.append(values)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}
