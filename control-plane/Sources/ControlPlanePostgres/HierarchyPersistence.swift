import Foundation
import PostgresNIO

public struct OrganizationWrite: Sendable {
    public let id: UUID
    public let name: String
    public let description: String

    public init(id: UUID = UUID(), name: String, description: String) {
        self.id = id
        self.name = name
        self.description = description
    }
}

public struct OrganizationSnapshot: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String
    public let createdAt: Date?
    public let updatedAt: Date?
}

public struct OrganizationProvisioningWrite: Sendable {
    public let organization: OrganizationWrite
    public let creatorID: UUID
    public let administratorRoleID: UUID
    public let projectID: UUID
    public let projectName: String
    public let projectDescription: String
    public let securityGroupID: UUID
    public let siteID: UUID
    public let siteName: String
    public let siteDescription: String
    public let trustDomain: String?

    public init(
        organization: OrganizationWrite,
        creatorID: UUID,
        administratorRoleID: UUID,
        projectID: UUID = UUID(),
        projectName: String = "Default Project",
        projectDescription: String,
        securityGroupID: UUID = UUID(),
        siteID: UUID = UUID(),
        siteName: String,
        siteDescription: String,
        trustDomain: String?
    ) {
        self.organization = organization
        self.creatorID = creatorID
        self.administratorRoleID = administratorRoleID
        self.projectID = projectID
        self.projectName = projectName
        self.projectDescription = projectDescription
        self.securityGroupID = securityGroupID
        self.siteID = siteID
        self.siteName = siteName
        self.siteDescription = siteDescription
        self.trustDomain = trustDomain
    }
}

public struct OrganizationProvisioningSnapshot: Equatable, Sendable {
    public let organization: OrganizationSnapshot
    public let projectID: UUID
    public let securityGroupID: UUID
    public let siteID: UUID
}

public struct OrganizationMembershipSnapshot: Equatable, Sendable {
    public let id: UUID
    public let userID: UUID
    public let organizationID: UUID
    public let roleID: UUID?
    public let createdAt: Date?
}

public struct OrganizationMemberSnapshot: Equatable, Sendable {
    public let membershipID: UUID
    public let userID: UUID
    public let username: String
    public let displayName: String
    public let email: String
    public let roleID: UUID?
    public let joinedAt: Date?
}

public struct UserOrganizationSnapshot: Equatable, Sendable {
    public let organization: OrganizationSnapshot
    public let roleID: UUID?
}

public struct OrganizationalUnitWrite: Sendable {
    public let id: UUID
    public let organizationID: UUID
    public let parentID: UUID?
    public let name: String
    public let description: String

    public init(
        id: UUID = UUID(),
        organizationID: UUID,
        parentID: UUID?,
        name: String,
        description: String
    ) {
        self.id = id
        self.organizationID = organizationID
        self.parentID = parentID
        self.name = name
        self.description = description
    }
}

public struct OrganizationalUnitSnapshot: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String
    public let organizationID: UUID
    public let parentID: UUID?
    public let path: String
    public let depth: Int
    public let createdAt: Date?
    public let updatedAt: Date?
}

public struct OrganizationalUnitOverview: Equatable, Sendable {
    public let organizationalUnit: OrganizationalUnitSnapshot
    public let childCount: Int
    public let projectCount: Int
}

public enum OrganizationalUnitCreateResult: Equatable, Sendable {
    case created(OrganizationalUnitOverview)
    case organizationNotFound
    case parentNotFound
    case parentOutsideOrganization
    case duplicateName
}

public enum OrganizationalUnitUpdateResult: Equatable, Sendable {
    case updated(OrganizationalUnitOverview)
    case notFound
    case outsideOrganization
    case duplicateName
}

public enum OrganizationalUnitDeleteResult: Equatable, Sendable {
    case deleted
    case notFound
    case outsideOrganization
    case hasChildren
    case hasProjects
}

public enum OrganizationalUnitMoveResult: Equatable, Sendable {
    case moved(OrganizationalUnitOverview)
    case notFound
    case outsideOrganization
    case parentNotFound
    case parentOutsideOrganization
    case circularReference
    case duplicateName
}

public enum OrganizationMemberMutationResult: Equatable, Sendable {
    case applied(OrganizationMembershipSnapshot)
    case organizationNotFound
    case membershipNotFound
    case alreadyMember
    case principalAlreadyBound
    case lastAdministrator
}

public enum HierarchyPersistenceError: Error, Equatable, Sendable {
    case duplicateOrganizationName(String)
    case trustDomainCollision(trustDomain: String, existingOrganizationID: UUID)
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Owns hierarchy records and the invariants that cross hierarchy membership
/// and IAM bindings. In particular, membership changes lock the organization
/// row and update the membership pivot, role binding, group memberships, and
/// offboarding sweep on the same physical connection and transaction.
public struct HierarchyPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func allOrganizations() async throws -> [OrganizationSnapshot] {
        try await database.withSession(operation: "hierarchy.organizations.list_all") { session in
            try await session.execute(
                ListOrganizations(),
                operation: "hierarchy.organizations.list_all.query"
            )
        }
    }

    public func organizations(forUser userID: UUID) async throws -> [UserOrganizationSnapshot] {
        try await database.withSession(operation: "hierarchy.organizations.list_for_user") { session in
            try await session.execute(
                ListUserOrganizations(userID: userID),
                operation: "hierarchy.organizations.list_for_user.query"
            )
        }
    }

    public func organization(id: UUID) async throws -> OrganizationSnapshot? {
        try await database.withSession(operation: "hierarchy.organizations.lookup") { session in
            try oneOrNone(
                await session.execute(
                    FindOrganization(id: id),
                    operation: "hierarchy.organizations.lookup.query"
                )
            )
        }
    }

    public func membership(userID: UUID, organizationID: UUID) async throws
        -> OrganizationMembershipSnapshot?
    {
        try await database.withSession(operation: "hierarchy.memberships.lookup") { session in
            try oneOrNone(
                await session.execute(
                    FindOrganizationMembership(userID: userID, organizationID: organizationID),
                    operation: "hierarchy.memberships.lookup.query"
                )
            )
        }
    }

    public func members(organizationID: UUID) async throws -> [OrganizationMemberSnapshot] {
        try await database.withSession(operation: "hierarchy.memberships.list") { session in
            try await session.execute(
                ListOrganizationMembers(organizationID: organizationID),
                operation: "hierarchy.memberships.list.query"
            )
        }
    }

    public func userID(email: String) async throws -> UUID? {
        try await database.withSession(operation: "hierarchy.memberships.user_by_email") { session in
            try oneOrNone(
                await session.execute(
                    FindUserIDByEmail(email: email),
                    operation: "hierarchy.memberships.user_by_email.query"
                )
            )
        }
    }

    public func createOrganization(_ write: OrganizationWrite) async throws -> OrganizationSnapshot {
        do {
            return try await database.withSession(operation: "hierarchy.organizations.create") { session in
                try only(
                    await session.execute(
                        InsertOrganization(write: write),
                        operation: "hierarchy.organizations.create.query"
                    )
                )
            }
        } catch let error as PSQLError
            where error.serverInfo?[.sqlState] == "23505"
                && error.serverInfo?[.constraintName] == "uq:organizations.name"
        {
            throw HierarchyPersistenceError.duplicateOrganizationName(write.name)
        }
    }

    /// Provision the complete first-use hierarchy for a new organization in
    /// one transaction: membership and grants, the default project and
    /// security group, the default site, and the optional SPIFFE claim.
    public func provisionOrganization(
        _ write: OrganizationProvisioningWrite
    ) async throws -> OrganizationProvisioningSnapshot {
        do {
            return try await database.withTransaction(operation: "hierarchy.organizations.provision") {
                session in
                let organization = try only(
                    await session.execute(
                        InsertOrganization(write: write.organization),
                        operation: "hierarchy.organizations.provision.organization"
                    )
                )
                _ = try only(
                    await session.execute(
                        InsertOrganizationMembership(
                            id: UUID(),
                            userID: write.creatorID,
                            organizationID: write.organization.id,
                            roleID: write.administratorRoleID
                        ),
                        operation: "hierarchy.organizations.provision.membership"
                    )
                )
                _ = try only(
                    await session.execute(
                        InsertProvisionedRoleBinding(
                            id: UUID(),
                            principalID: write.creatorID,
                            roleID: write.administratorRoleID,
                            nodeType: "organization",
                            nodeID: write.organization.id,
                            createdBy: write.creatorID
                        ),
                        operation: "hierarchy.organizations.provision.organization_binding"
                    )
                )
                _ = try await session.execute(
                    SelectCurrentOrganizationIfUnset(
                        userID: write.creatorID,
                        organizationID: write.organization.id
                    ),
                    operation: "hierarchy.organizations.provision.current_organization"
                )
                _ = try only(
                    await session.execute(
                        InsertProvisionedProject(write: write),
                        operation: "hierarchy.organizations.provision.project"
                    )
                )
                _ = try only(
                    await session.execute(
                        InsertProvisionedRoleBinding(
                            id: UUID(),
                            principalID: write.creatorID,
                            roleID: write.administratorRoleID,
                            nodeType: "project",
                            nodeID: write.projectID,
                            createdBy: write.creatorID
                        ),
                        operation: "hierarchy.organizations.provision.project_binding"
                    )
                )
                _ = try only(
                    await session.execute(
                        InsertProvisionedSecurityGroup(write: write),
                        operation: "hierarchy.organizations.provision.security_group"
                    )
                )
                for direction in ["ingress", "egress"] {
                    for ethertype in ["ipv4", "ipv6"] {
                        _ = try only(
                            await session.execute(
                                InsertProvisionedSecurityGroupRule(
                                    id: UUID(),
                                    securityGroupID: write.securityGroupID,
                                    direction: direction,
                                    ethertype: ethertype,
                                    remoteGroupID: direction == "ingress" ? write.securityGroupID : nil
                                ),
                                operation: "hierarchy.organizations.provision.security_group_rule"
                            )
                        )
                    }
                }
                _ = try only(
                    await session.execute(
                        InsertProvisionedSite(write: write),
                        operation: "hierarchy.organizations.provision.site"
                    )
                )
                if let trustDomain = write.trustDomain {
                    if let existing = try oneOrNone(
                        await session.execute(
                            FindTrustDomainOwner(trustDomain: trustDomain),
                            operation: "hierarchy.organizations.provision.trust_domain_collision"
                        )
                    ), existing != write.organization.id {
                        throw HierarchyPersistenceError.trustDomainCollision(
                            trustDomain: trustDomain,
                            existingOrganizationID: existing
                        )
                    }
                    _ = try only(
                        await session.execute(
                            InsertOrganizationTrustDomain(
                                id: UUID(),
                                organizationID: write.organization.id,
                                trustDomain: trustDomain
                            ),
                            operation: "hierarchy.organizations.provision.trust_domain"
                        )
                    )
                }
                return OrganizationProvisioningSnapshot(
                    organization: organization,
                    projectID: write.projectID,
                    securityGroupID: write.securityGroupID,
                    siteID: write.siteID
                )
            }
        } catch let error as PSQLError
            where error.serverInfo?[.sqlState] == "23505"
                && error.serverInfo?[.constraintName] == "uq:organizations.name"
        {
            throw HierarchyPersistenceError.duplicateOrganizationName(write.organization.name)
        }
    }

    public func updateOrganization(
        id: UUID,
        name: String?,
        description: String?
    ) async throws -> OrganizationSnapshot? {
        do {
            return try await database.withSession(operation: "hierarchy.organizations.update") { session in
                try oneOrNone(
                    await session.execute(
                        UpdateOrganization(id: id, name: name, description: description),
                        operation: "hierarchy.organizations.update.query"
                    )
                )
            }
        } catch let error as PSQLError
            where error.serverInfo?[.sqlState] == "23505"
                && error.serverInfo?[.constraintName] == "uq:organizations.name"
        {
            throw HierarchyPersistenceError.duplicateOrganizationName(name ?? "")
        }
    }

    public func setCurrentOrganization(userID: UUID, organizationID: UUID) async throws -> Bool {
        try await database.withSession(operation: "hierarchy.organizations.select_current") { session in
            try await session.execute(
                SetCurrentOrganization(userID: userID, organizationID: organizationID),
                operation: "hierarchy.organizations.select_current.query"
            ) == [userID]
        }
    }

    public func addMember(
        userID: UUID,
        organizationID: UUID,
        roleID: UUID?,
        createdBy: UUID?
    ) async throws -> OrganizationMemberMutationResult {
        try await database.withTransaction(operation: "hierarchy.memberships.add") { session in
            guard try await lockOrganization(organizationID, session: session) else {
                return .organizationNotFound
            }
            guard
                try await session.execute(
                    FindOrganizationMembership(userID: userID, organizationID: organizationID),
                    operation: "hierarchy.memberships.add.existing"
                ).isEmpty
            else { return .alreadyMember }

            if roleID != nil {
                let active = try await session.execute(
                    CountActiveOrganizationBindings(userID: userID, organizationID: organizationID),
                    operation: "hierarchy.memberships.add.active_bindings"
                )
                guard try only(active) == 0 else { return .principalAlreadyBound }
            }

            let membership = try only(
                await session.execute(
                    InsertOrganizationMembership(
                        id: UUID(),
                        userID: userID,
                        organizationID: organizationID,
                        roleID: roleID
                    ),
                    operation: "hierarchy.memberships.add.membership"
                )
            )
            if let roleID {
                _ = try await session.execute(
                    UpsertOrganizationBinding(
                        id: UUID(),
                        userID: userID,
                        organizationID: organizationID,
                        roleID: roleID,
                        createdBy: createdBy
                    ),
                    operation: "hierarchy.memberships.add.binding"
                )
            }
            return .applied(membership)
        }
    }

    public func updateMemberRole(
        userID: UUID,
        organizationID: UUID,
        roleID: UUID?,
        administratorRoleID: UUID,
        createdBy: UUID?
    ) async throws -> OrganizationMemberMutationResult {
        try await database.withTransaction(operation: "hierarchy.memberships.update_role") { session in
            guard try await lockOrganization(organizationID, session: session) else {
                return .organizationNotFound
            }
            guard
                let membership = try oneOrNone(
                    await session.execute(
                        FindOrganizationMembership(userID: userID, organizationID: organizationID),
                        operation: "hierarchy.memberships.update_role.lookup"
                    )
                )
            else { return .membershipNotFound }

            if roleID != administratorRoleID {
                let holdsAdmin = try only(
                    await session.execute(
                        HasActiveOrganizationRole(
                            userID: userID,
                            organizationID: organizationID,
                            roleID: administratorRoleID
                        ),
                        operation: "hierarchy.memberships.update_role.has_admin"
                    )
                )
                if holdsAdmin {
                    let count = try only(
                        await session.execute(
                            CountActiveOrganizationRole(
                                organizationID: organizationID,
                                roleID: administratorRoleID
                            ),
                            operation: "hierarchy.memberships.update_role.admin_count"
                        )
                    )
                    guard count > 1 else { return .lastAdministrator }
                }
            }

            _ = try await session.execute(
                DeleteUserOrganizationBindings(userID: userID, organizationID: organizationID),
                operation: "hierarchy.memberships.update_role.revoke"
            )
            if let roleID {
                _ = try await session.execute(
                    UpsertOrganizationBinding(
                        id: UUID(),
                        userID: userID,
                        organizationID: organizationID,
                        roleID: roleID,
                        createdBy: createdBy
                    ),
                    operation: "hierarchy.memberships.update_role.grant"
                )
            }
            let updated = try only(
                await session.execute(
                    UpdateOrganizationMembershipRole(id: membership.id, roleID: roleID),
                    operation: "hierarchy.memberships.update_role.membership"
                )
            )
            return .applied(updated)
        }
    }

    public func removeMember(
        userID: UUID,
        organizationID: UUID,
        administratorRoleID: UUID
    ) async throws -> OrganizationMemberMutationResult {
        try await database.withTransaction(operation: "hierarchy.memberships.remove") { session in
            guard try await lockOrganization(organizationID, session: session) else {
                return .organizationNotFound
            }
            guard
                let membership = try oneOrNone(
                    await session.execute(
                        FindOrganizationMembership(userID: userID, organizationID: organizationID),
                        operation: "hierarchy.memberships.remove.lookup"
                    )
                )
            else { return .membershipNotFound }

            let holdsAdmin = try only(
                await session.execute(
                    HasActiveOrganizationRole(
                        userID: userID,
                        organizationID: organizationID,
                        roleID: administratorRoleID
                    ),
                    operation: "hierarchy.memberships.remove.has_admin"
                )
            )
            if holdsAdmin {
                let count = try only(
                    await session.execute(
                        CountActiveOrganizationRole(
                            organizationID: organizationID,
                            roleID: administratorRoleID
                        ),
                        operation: "hierarchy.memberships.remove.admin_count"
                    )
                )
                guard count > 1 else { return .lastAdministrator }
            }

            _ = try await session.execute(
                DeleteOrganizationMembership(id: membership.id),
                operation: "hierarchy.memberships.remove.membership"
            )
            _ = try await session.execute(
                DeleteUserGroupMembershipsInOrganization(
                    userID: userID,
                    organizationID: organizationID
                ),
                operation: "hierarchy.memberships.remove.groups"
            )
            _ = try await session.execute(
                DeleteUserBindingsRootedInOrganization(
                    userID: userID,
                    organizationID: organizationID
                ),
                operation: "hierarchy.memberships.remove.bindings"
            )
            return .applied(membership)
        }
    }

    public func organizationalUnits(
        organizationID: UUID,
        parentID: UUID?
    ) async throws -> [OrganizationalUnitOverview] {
        try await database.withSession(operation: "hierarchy.folders.list") { session in
            try await session.execute(
                ListOrganizationalUnits(organizationID: organizationID, parentID: parentID),
                operation: "hierarchy.folders.list.query"
            )
        }
    }

    public func organizationalUnitIDs(organizationIDs: [UUID]) async throws -> [UUID] {
        guard !organizationIDs.isEmpty else { return [] }
        return try await database.withSession(operation: "hierarchy.organizational_units.ids") {
            session in
            try await session.execute(
                FindOrganizationalUnitIDs(organizationIDs: Array(Set(organizationIDs))),
                operation: "hierarchy.organizational_units.ids.query"
            )
        }
    }

    public func organizationalUnit(id: UUID) async throws -> OrganizationalUnitOverview? {
        try await database.withSession(operation: "hierarchy.folders.lookup") { session in
            try oneOrNone(
                await session.execute(
                    FindOrganizationalUnitOverview(id: id),
                    operation: "hierarchy.folders.lookup.query"
                )
            )
        }
    }

    /// Returns the folder chain from the organization root down to `id`.
    public func organizationalUnitAncestors(id: UUID) async throws
        -> [OrganizationalUnitSnapshot]
    {
        try await database.withSession(operation: "hierarchy.folders.ancestors") { session in
            guard
                let folder = try oneOrNone(
                    await session.execute(
                        FindOrganizationalUnit(id: id),
                        operation: "hierarchy.folders.ancestors.folder"
                    )
                )
            else { return [] }
            return try await session.execute(
                ListOrganizationalUnitAncestors(path: folder.path),
                operation: "hierarchy.folders.ancestors.query"
            )
        }
    }

    /// Returns the root and all descendants with batched child/project counts.
    public func organizationalUnitSubtree(rootID: UUID) async throws -> [OrganizationalUnitOverview] {
        try await database.withSession(operation: "hierarchy.folders.subtree") { session in
            guard
                let root = try oneOrNone(
                    await session.execute(
                        FindOrganizationalUnit(id: rootID),
                        operation: "hierarchy.folders.subtree.root"
                    )
                )
            else { return [] }
            return try await session.execute(
                ListOrganizationalUnitSubtree(rootPath: root.path),
                operation: "hierarchy.folders.subtree.query"
            )
        }
    }

    public func createOrganizationalUnit(
        _ write: OrganizationalUnitWrite
    ) async throws -> OrganizationalUnitCreateResult {
        do {
            return try await database.withTransaction(operation: "hierarchy.folders.create") { session in
                guard try await lockOrganization(write.organizationID, session: session) else {
                    return .organizationNotFound
                }

                let parent: OrganizationalUnitSnapshot?
                if let parentID = write.parentID {
                    guard
                        let found = try oneOrNone(
                            await session.execute(
                                FindOrganizationalUnit(id: parentID),
                                operation: "hierarchy.folders.create.parent"
                            )
                        )
                    else { return .parentNotFound }
                    guard found.organizationID == write.organizationID else {
                        return .parentOutsideOrganization
                    }
                    parent = found
                } else {
                    parent = nil
                }

                let duplicate = try only(
                    await session.execute(
                        OrganizationalUnitNameExists(
                            organizationID: write.organizationID,
                            parentID: write.parentID,
                            name: write.name,
                            excludingID: nil
                        ),
                        operation: "hierarchy.folders.create.duplicate"
                    )
                )
                guard !duplicate else { return .duplicateName }

                let parentPath = parent?.path ?? "/\(write.organizationID.uuidString)"
                let snapshot = try only(
                    await session.execute(
                        InsertOrganizationalUnit(
                            write: write,
                            path: "\(parentPath)/\(write.id.uuidString)",
                            depth: parent.map { $0.depth + 1 } ?? 0
                        ),
                        operation: "hierarchy.folders.create.insert"
                    )
                )
                return .created(
                    OrganizationalUnitOverview(
                        organizationalUnit: snapshot,
                        childCount: 0,
                        projectCount: 0
                    )
                )
            }
        } catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505" {
            return .duplicateName
        }
    }

    public func updateOrganizationalUnit(
        id: UUID,
        organizationID: UUID,
        name: String?,
        description: String?
    ) async throws -> OrganizationalUnitUpdateResult {
        do {
            return try await database.withTransaction(operation: "hierarchy.folders.update") { session in
                guard
                    let current = try oneOrNone(
                        await session.execute(
                            LockOrganizationalUnit(id: id),
                            operation: "hierarchy.folders.update.lock"
                        )
                    )
                else { return .notFound }
                guard current.organizationID == organizationID else { return .outsideOrganization }

                if let name {
                    let duplicate = try only(
                        await session.execute(
                            OrganizationalUnitNameExists(
                                organizationID: organizationID,
                                parentID: current.parentID,
                                name: name,
                                excludingID: id
                            ),
                            operation: "hierarchy.folders.update.duplicate"
                        )
                    )
                    guard !duplicate else { return .duplicateName }
                }

                _ = try only(
                    await session.execute(
                        UpdateOrganizationalUnit(
                            id: id,
                            name: name,
                            description: description
                        ),
                        operation: "hierarchy.folders.update.row"
                    )
                )
                let overview = try only(
                    await session.execute(
                        FindOrganizationalUnitOverview(id: id),
                        operation: "hierarchy.folders.update.overview"
                    )
                )
                return .updated(overview)
            }
        } catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505" {
            return .duplicateName
        }
    }

    public func deleteOrganizationalUnit(
        id: UUID,
        organizationID: UUID
    ) async throws -> OrganizationalUnitDeleteResult {
        try await database.withTransaction(operation: "hierarchy.folders.delete") { session in
            guard
                let current = try oneOrNone(
                    await session.execute(
                        LockOrganizationalUnit(id: id),
                        operation: "hierarchy.folders.delete.lock"
                    )
                )
            else { return .notFound }
            guard current.organizationID == organizationID else { return .outsideOrganization }

            let counts = try only(
                await session.execute(
                    CountOrganizationalUnitDependents(id: id),
                    operation: "hierarchy.folders.delete.dependents"
                )
            )
            guard counts.children == 0 else { return .hasChildren }
            guard counts.projects == 0 else { return .hasProjects }

            _ = try await session.execute(
                DeleteBindingsAtOrganizationalUnit(id: id),
                operation: "hierarchy.folders.delete.bindings"
            )
            let deleted = try await session.execute(
                DeleteOrganizationalUnit(id: id),
                operation: "hierarchy.folders.delete.row"
            )
            return deleted == [id] ? .deleted : .notFound
        }
    }

    public func moveOrganizationalUnit(
        id: UUID,
        organizationID: UUID,
        newParentID: UUID?
    ) async throws -> OrganizationalUnitMoveResult {
        do {
            return try await database.withTransaction(operation: "hierarchy.folders.move") { session in
                guard try await lockOrganization(organizationID, session: session) else {
                    return .outsideOrganization
                }
                guard
                    let current = try oneOrNone(
                        await session.execute(
                            LockOrganizationalUnit(id: id),
                            operation: "hierarchy.folders.move.lock"
                        )
                    )
                else { return .notFound }
                guard current.organizationID == organizationID else { return .outsideOrganization }

                let parent: OrganizationalUnitSnapshot?
                if let newParentID {
                    guard
                        let found = try oneOrNone(
                            await session.execute(
                                FindOrganizationalUnit(id: newParentID),
                                operation: "hierarchy.folders.move.parent"
                            )
                        )
                    else { return .parentNotFound }
                    guard found.organizationID == organizationID else {
                        return .parentOutsideOrganization
                    }
                    guard found.path != current.path,
                        !found.path.hasPrefix("\(current.path)/")
                    else { return .circularReference }
                    parent = found
                } else {
                    parent = nil
                }

                let duplicate = try only(
                    await session.execute(
                        OrganizationalUnitNameExists(
                            organizationID: organizationID,
                            parentID: newParentID,
                            name: current.name,
                            excludingID: id
                        ),
                        operation: "hierarchy.folders.move.duplicate"
                    )
                )
                guard !duplicate else { return .duplicateName }

                let parentPath = parent?.path ?? "/\(organizationID.uuidString)"
                let newPath = "\(parentPath)/\(id.uuidString)"
                let newDepth = parent.map { $0.depth + 1 } ?? 0
                _ = try only(
                    await session.execute(
                        MoveOrganizationalUnit(
                            id: id,
                            parentID: newParentID,
                            path: newPath,
                            depth: newDepth
                        ),
                        operation: "hierarchy.folders.move.row"
                    )
                )
                _ = try await session.execute(
                    RewriteDescendantOrganizationalUnits(
                        previousPath: current.path,
                        newPath: newPath,
                        depthDelta: newDepth - current.depth
                    ),
                    operation: "hierarchy.folders.move.descendants"
                )
                _ = try await session.execute(
                    RewriteOrganizationalUnitProjectPaths(rootPath: newPath),
                    operation: "hierarchy.folders.move.projects"
                )
                let overview = try only(
                    await session.execute(
                        FindOrganizationalUnitOverview(id: id),
                        operation: "hierarchy.folders.move.overview"
                    )
                )
                return .moved(overview)
            }
        } catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505" {
            return .duplicateName
        }
    }

    private func lockOrganization(_ id: UUID, session: PostgresSession) async throws -> Bool {
        try await session.execute(
            LockOrganization(id: id),
            operation: "hierarchy.memberships.lock_organization"
        ) == [id]
    }

    private func oneOrNone<Value>(_ rows: [Value]) throws -> Value? {
        guard rows.count <= 1 else {
            throw HierarchyPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return rows.first
    }

    private func only<Value>(_ rows: [Value]) throws -> Value {
        guard rows.count == 1, let row = rows.first else {
            throw HierarchyPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return row
    }
}

private let organizationColumns = "id, name, description, created_at, updated_at"

private protocol OrganizationStatement: PostgresPreparedStatement where Row == OrganizationSnapshot {}

private extension OrganizationStatement {
    func decodeRow(_ row: PostgresRow) throws -> OrganizationSnapshot {
        let value = try row.decode((UUID, String, String, Date?, Date?).self)
        return OrganizationSnapshot(
            id: value.0,
            name: value.1,
            description: value.2,
            createdAt: value.3,
            updatedAt: value.4
        )
    }
}

private struct ListOrganizations: OrganizationStatement {
    static let sql = "SELECT \(organizationColumns) FROM organizations ORDER BY name"
    func makeBindings() throws -> PostgresBindings { .init() }
}

private struct FindOrganization: OrganizationStatement {
    static let sql = "SELECT \(organizationColumns) FROM organizations WHERE id = $1"
    let id: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct InsertOrganization: OrganizationStatement {
    static let sql = """
        INSERT INTO organizations (id, name, description, created_at, updated_at)
        VALUES ($1, $2, $3, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING \(organizationColumns)
        """
    let write: OrganizationWrite
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(write.id)
        bindings.append(write.name)
        bindings.append(write.description)
        return bindings
    }
}

private struct UpdateOrganization: OrganizationStatement {
    static let sql = """
        UPDATE organizations
        SET name = COALESCE($2, name),
            description = COALESCE($3, description),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(organizationColumns)
        """
    let id: UUID
    let name: String?
    let description: String?
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(name)
        bindings.append(description)
        return bindings
    }
}

private struct InsertProvisionedRoleBinding: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO role_bindings (
            id, principal_type, principal_id, role_id, node_type, node_id,
            condition, expires_at, created_by, created_at
        )
        VALUES ($1, 'user', $2, $3, $4, $5, NULL, NULL, $6, CURRENT_TIMESTAMP)
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let principalID: UUID
    let roleID: UUID
    let nodeType: String
    let nodeID: UUID
    let createdBy: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 6)
        bindings.append(id)
        bindings.append(principalID)
        bindings.append(roleID)
        bindings.append(nodeType)
        bindings.append(nodeID)
        bindings.append(createdBy)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct SelectCurrentOrganizationIfUnset: PostgresPreparedStatement {
    static let sql = """
        UPDATE users
        SET current_organization_id = $2, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND current_organization_id IS NULL
        RETURNING id
        """
    typealias Row = UUID
    let userID: UUID
    let organizationID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(userID)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertProvisionedProject: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO projects (
            id, name, description, organization_id, organizational_unit_id,
            path, default_environment, environments, created_at, updated_at
        )
        VALUES ($1, $2, $3, $4, NULL, $5, 'development', $6,
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """
    typealias Row = UUID
    let write: OrganizationProvisioningWrite
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 6)
        bindings.append(write.projectID)
        bindings.append(write.projectName)
        bindings.append(write.projectDescription)
        bindings.append(write.organization.id)
        bindings.append("/\(write.organization.id.uuidString)/\(write.projectID.uuidString)")
        bindings.append(["development", "staging", "production"])
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertProvisionedSecurityGroup: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO security_groups (
            id, project_id, name, description, is_default, generation,
            created_by_id, created_at, updated_at
        )
        VALUES ($1, $2, 'default', 'Default security group', TRUE, 0,
                NULL, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """
    typealias Row = UUID
    let write: OrganizationProvisioningWrite
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(write.securityGroupID)
        bindings.append(write.projectID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertProvisionedSecurityGroupRule: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO security_group_rules (
            id, security_group_id, direction, ethertype, protocol,
            port_range_min, port_range_max, remote_cidr, remote_group_id,
            description, log, created_at
        )
        VALUES ($1, $2, $3, $4, NULL, NULL, NULL, NULL, $5,
                NULL, FALSE, CURRENT_TIMESTAMP)
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let securityGroupID: UUID
    let direction: String
    let ethertype: String
    let remoteGroupID: UUID?
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(id)
        bindings.append(securityGroupID)
        bindings.append(direction)
        bindings.append(ethertype)
        bindings.append(remoteGroupID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertProvisionedSite: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO sites (
            id, name, description, organization_id, organizational_unit_id,
            status, labels, created_at, updated_at
        )
        VALUES ($1, $2, $3, $4, NULL, 'active', '{}'::jsonb,
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """
    typealias Row = UUID
    let write: OrganizationProvisioningWrite
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(write.siteID)
        bindings.append(write.siteName)
        bindings.append(write.siteDescription)
        bindings.append(write.organization.id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct FindTrustDomainOwner: PostgresPreparedStatement {
    static let sql = "SELECT organization_id FROM org_trust_domains WHERE trust_domain = $1"
    typealias Row = UUID
    let trustDomain: String
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(trustDomain)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertOrganizationTrustDomain: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO org_trust_domains (
            id, organization_id, trust_domain, phase, generation,
            observed_generation, created_at, updated_at
        )
        VALUES ($1, $2, $3, 'pending', 1, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT (organization_id) DO NOTHING
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let organizationID: UUID
    let trustDomain: String
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(organizationID)
        bindings.append(trustDomain)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct ListUserOrganizations: PostgresPreparedStatement {
    static let sql = """
        SELECT o.\(organizationColumns.replacingOccurrences(of: ", ", with: ", o.")), uo.role_id
        FROM user_organizations AS uo
        JOIN organizations AS o ON o.id = uo.organization_id
        WHERE uo.user_id = $1
        ORDER BY o.name
        """
    typealias Row = UserOrganizationSnapshot
    let userID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(userID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UserOrganizationSnapshot {
        let value = try row.decode((UUID, String, String, Date?, Date?, UUID?).self)
        return UserOrganizationSnapshot(
            organization: OrganizationSnapshot(
                id: value.0,
                name: value.1,
                description: value.2,
                createdAt: value.3,
                updatedAt: value.4
            ),
            roleID: value.5
        )
    }
}

private protocol OrganizationMembershipStatement: PostgresPreparedStatement
    where Row == OrganizationMembershipSnapshot {}

private extension OrganizationMembershipStatement {
    func decodeRow(_ row: PostgresRow) throws -> OrganizationMembershipSnapshot {
        let value = try row.decode((UUID, UUID, UUID, UUID?, Date?).self)
        return OrganizationMembershipSnapshot(
            id: value.0,
            userID: value.1,
            organizationID: value.2,
            roleID: value.3,
            createdAt: value.4
        )
    }
}

private struct FindOrganizationMembership: OrganizationMembershipStatement {
    static let sql = """
        SELECT id, user_id, organization_id, role_id, created_at
        FROM user_organizations
        WHERE user_id = $1 AND organization_id = $2
        """
    let userID: UUID
    let organizationID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(userID)
        bindings.append(organizationID)
        return bindings
    }
}

private struct InsertOrganizationMembership: OrganizationMembershipStatement {
    static let sql = """
        INSERT INTO user_organizations (id, user_id, organization_id, role_id, created_at)
        VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)
        RETURNING id, user_id, organization_id, role_id, created_at
        """
    let id: UUID
    let userID: UUID
    let organizationID: UUID
    let roleID: UUID?
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(id)
        bindings.append(userID)
        bindings.append(organizationID)
        bindings.append(roleID)
        return bindings
    }
}

private struct UpdateOrganizationMembershipRole: OrganizationMembershipStatement {
    static let sql = """
        UPDATE user_organizations
        SET role_id = $2
        WHERE id = $1
        RETURNING id, user_id, organization_id, role_id, created_at
        """
    let id: UUID
    let roleID: UUID?
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(roleID)
        return bindings
    }
}

private struct DeleteOrganizationMembership: PostgresPreparedStatement {
    static let sql = "DELETE FROM user_organizations WHERE id = $1 RETURNING id"
    typealias Row = UUID
    let id: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct ListOrganizationMembers: PostgresPreparedStatement {
    static let sql = """
        SELECT uo.id, u.id, u.username, u.display_name, u.email, uo.role_id, uo.created_at
        FROM user_organizations AS uo
        JOIN users AS u ON u.id = uo.user_id
        WHERE uo.organization_id = $1
        ORDER BY u.username, u.id
        """
    typealias Row = OrganizationMemberSnapshot
    let organizationID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> OrganizationMemberSnapshot {
        let value = try row.decode((UUID, UUID, String, String, String, UUID?, Date?).self)
        return OrganizationMemberSnapshot(
            membershipID: value.0,
            userID: value.1,
            username: value.2,
            displayName: value.3,
            email: value.4,
            roleID: value.5,
            joinedAt: value.6
        )
    }
}

private struct FindUserIDByEmail: PostgresPreparedStatement {
    static let sql = "SELECT id FROM users WHERE email = $1"
    typealias Row = UUID
    let email: String
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(email)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct LockOrganization: PostgresPreparedStatement {
    static let sql = "SELECT id FROM organizations WHERE id = $1 FOR UPDATE"
    typealias Row = UUID
    let id: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct CountActiveOrganizationBindings: PostgresPreparedStatement {
    static let sql = """
        SELECT count(*)::bigint
        FROM role_bindings
        WHERE principal_type = 'user'
          AND principal_id = $1
          AND node_type = 'organization'
          AND node_id = $2
          AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)
        """
    typealias Row = Int
    let userID: UUID
    let organizationID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(userID)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct HasActiveOrganizationRole: PostgresPreparedStatement {
    static let sql = """
        SELECT EXISTS (
            SELECT 1
            FROM role_bindings
            WHERE principal_type = 'user'
              AND principal_id = $1
              AND node_type = 'organization'
              AND node_id = $2
              AND role_id = $3
              AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)
        )
        """
    typealias Row = Bool
    let userID: UUID
    let organizationID: UUID
    let roleID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(userID)
        bindings.append(organizationID)
        bindings.append(roleID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}

private struct CountActiveOrganizationRole: PostgresPreparedStatement {
    static let sql = """
        SELECT count(*)::bigint
        FROM role_bindings AS rb
        JOIN users AS u ON u.id = rb.principal_id
        WHERE rb.principal_type = 'user'
          AND rb.node_type = 'organization'
          AND rb.node_id = $1
          AND rb.role_id = $2
          AND (rb.expires_at IS NULL OR rb.expires_at > CURRENT_TIMESTAMP)
          AND u.disabled_at IS NULL
          AND (NOT u.scim_provisioned OR u.scim_active)
        """
    typealias Row = Int
    let organizationID: UUID
    let roleID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(organizationID)
        bindings.append(roleID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct UpsertOrganizationBinding: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO role_bindings (
            id, principal_type, principal_id, role_id, node_type, node_id,
            condition, expires_at, created_by, created_at
        )
        VALUES ($1, 'user', $2, $3, 'organization', $4, NULL, NULL, $5, CURRENT_TIMESTAMP)
        ON CONFLICT (principal_type, principal_id, role_id, node_type, node_id)
        DO UPDATE SET expires_at = NULL
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let userID: UUID
    let organizationID: UUID
    let roleID: UUID
    let createdBy: UUID?
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(id)
        bindings.append(userID)
        bindings.append(roleID)
        bindings.append(organizationID)
        bindings.append(createdBy)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteUserOrganizationBindings: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM role_bindings
        WHERE principal_type = 'user'
          AND principal_id = $1
          AND node_type = 'organization'
          AND node_id = $2
        RETURNING id
        """
    typealias Row = UUID
    let userID: UUID
    let organizationID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(userID)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteUserGroupMembershipsInOrganization: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM user_groups AS ug
        USING groups AS g
        WHERE ug.group_id = g.id
          AND ug.user_id = $1
          AND g.organization_id = $2
        RETURNING ug.id
        """
    typealias Row = UUID
    let userID: UUID
    let organizationID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(userID)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

/// A fixed, allowlisted ancestry expression for the offboarding sweep. Each
/// branch mirrors ResourceTreePersistence's parent edge for one bindable node.
/// Unknown or already-deleted nodes produce no root and are deliberately kept.
private struct DeleteUserBindingsRootedInOrganization: PostgresPreparedStatement {
    static let sql = """
        WITH RECURSIVE ancestry(binding_id, node_type, node_id) AS (
            SELECT id, node_type, node_id
            FROM role_bindings
            WHERE principal_type = 'user' AND principal_id = $1

            UNION ALL

            SELECT ancestry.binding_id, parent.node_type, parent.node_id
            FROM ancestry
            JOIN LATERAL (
                SELECT
                    CASE WHEN ou.parent_ou_id IS NULL THEN 'organization' ELSE 'organizational_unit' END,
                    COALESCE(ou.parent_ou_id, ou.organization_id)
                FROM organizational_units AS ou
                WHERE ancestry.node_type = 'organizational_unit' AND ou.id = ancestry.node_id

                UNION ALL
                SELECT
                    CASE WHEN p.organizational_unit_id IS NOT NULL THEN 'organizational_unit' ELSE 'organization' END,
                    COALESCE(p.organizational_unit_id, p.organization_id)
                FROM projects AS p
                WHERE ancestry.node_type = 'project' AND p.id = ancestry.node_id

                UNION ALL SELECT 'project', project_id FROM vms
                    WHERE ancestry.node_type = 'virtual_machine' AND id = ancestry.node_id
                UNION ALL SELECT 'project', project_id FROM sandboxes
                    WHERE ancestry.node_type = 'sandbox' AND id = ancestry.node_id
                UNION ALL SELECT 'project', project_id FROM images
                    WHERE ancestry.node_type = 'image' AND id = ancestry.node_id
                UNION ALL SELECT 'project', project_id FROM logical_networks
                    WHERE ancestry.node_type = 'network' AND id = ancestry.node_id
                UNION ALL SELECT 'project', project_id FROM floating_ips
                    WHERE ancestry.node_type = 'floating_ip' AND id = ancestry.node_id
                UNION ALL SELECT 'project', project_id FROM load_balancers
                    WHERE ancestry.node_type = 'load_balancer' AND id = ancestry.node_id
                UNION ALL SELECT 'project', project_id FROM security_groups
                    WHERE ancestry.node_type = 'security_group' AND id = ancestry.node_id
                UNION ALL SELECT 'project', project_id FROM dns_zones
                    WHERE ancestry.node_type = 'dns_zone' AND id = ancestry.node_id
                UNION ALL SELECT 'dns_zone', zone_id FROM dns_records
                    WHERE ancestry.node_type = 'dns_record' AND id = ancestry.node_id
                UNION ALL SELECT 'project', project_id FROM volumes
                    WHERE ancestry.node_type = 'volume' AND id = ancestry.node_id
                UNION ALL SELECT 'project', project_id FROM volume_snapshots
                    WHERE ancestry.node_type = 'volume_snapshot' AND id = ancestry.node_id
                UNION ALL SELECT 'project', project_id FROM sandbox_snapshots
                    WHERE ancestry.node_type = 'sandbox_snapshot' AND id = ancestry.node_id
                UNION ALL SELECT 'project', project_id FROM vm_snapshots
                    WHERE ancestry.node_type = 'vm_snapshot' AND id = ancestry.node_id

                UNION ALL
                SELECT
                    CASE WHEN s.organizational_unit_id IS NOT NULL THEN 'organizational_unit' ELSE 'organization' END,
                    COALESCE(s.organizational_unit_id, s.organization_id)
                FROM sites AS s
                WHERE ancestry.node_type = 'site' AND s.id = ancestry.node_id

                UNION ALL
                SELECT
                    CASE WHEN a.organizational_unit_id IS NOT NULL THEN 'organizational_unit' ELSE 'organization' END,
                    COALESCE(a.organizational_unit_id, a.organization_id)
                FROM agents AS a
                WHERE ancestry.node_type = 'agent' AND a.id = ancestry.node_id

                UNION ALL SELECT 'project', project_id FROM service_accounts
                    WHERE ancestry.node_type = 'service_account' AND id = ancestry.node_id
            ) AS parent(node_type, node_id) ON true
            WHERE ancestry.node_type <> 'organization'
        )
        DELETE FROM role_bindings AS rb
        WHERE rb.id IN (
            SELECT binding_id
            FROM ancestry
            WHERE node_type = 'organization' AND node_id = $2
        )
        RETURNING rb.id
        """
    typealias Row = UUID
    let userID: UUID
    let organizationID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(userID)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct SetCurrentOrganization: PostgresPreparedStatement {
    static let sql = """
        UPDATE users
        SET current_organization_id = $2, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING id
        """
    typealias Row = UUID
    let userID: UUID
    let organizationID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(userID)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private let organizationalUnitColumns = """
    id, name, description, organization_id, parent_ou_id, path, depth, created_at, updated_at
    """

private protocol OrganizationalUnitStatement: PostgresPreparedStatement
    where Row == OrganizationalUnitSnapshot {}

private extension OrganizationalUnitStatement {
    func decodeRow(_ row: PostgresRow) throws -> OrganizationalUnitSnapshot {
        let value = try row.decode((UUID, String, String, UUID, UUID?, String, Int, Date?, Date?).self)
        return OrganizationalUnitSnapshot(
            id: value.0,
            name: value.1,
            description: value.2,
            organizationID: value.3,
            parentID: value.4,
            path: value.5,
            depth: value.6,
            createdAt: value.7,
            updatedAt: value.8
        )
    }
}

private protocol OrganizationalUnitOverviewStatement: PostgresPreparedStatement
    where Row == OrganizationalUnitOverview {}

private extension OrganizationalUnitOverviewStatement {
    func decodeRow(_ row: PostgresRow) throws -> OrganizationalUnitOverview {
        let value = try row.decode(
            (UUID, String, String, UUID, UUID?, String, Int, Date?, Date?, Int, Int).self
        )
        return OrganizationalUnitOverview(
            organizationalUnit: OrganizationalUnitSnapshot(
                id: value.0,
                name: value.1,
                description: value.2,
                organizationID: value.3,
                parentID: value.4,
                path: value.5,
                depth: value.6,
                createdAt: value.7,
                updatedAt: value.8
            ),
            childCount: value.9,
            projectCount: value.10
        )
    }
}

private let organizationalUnitOverviewSelect = """
    SELECT ou.\(organizationalUnitColumns.replacingOccurrences(of: ", ", with: ", ou.")),
           COALESCE(children.entry_count, 0)::bigint AS child_count,
           COALESCE(projects.entry_count, 0)::bigint AS project_count
    FROM organizational_units AS ou
    LEFT JOIN (
        SELECT parent_ou_id, count(*)::bigint AS entry_count
        FROM organizational_units
        WHERE parent_ou_id IS NOT NULL
        GROUP BY parent_ou_id
    ) AS children ON children.parent_ou_id = ou.id
    LEFT JOIN (
        SELECT organizational_unit_id, count(*)::bigint AS entry_count
        FROM projects
        WHERE organizational_unit_id IS NOT NULL
        GROUP BY organizational_unit_id
    ) AS projects ON projects.organizational_unit_id = ou.id
    """

private struct ListOrganizationalUnits: OrganizationalUnitOverviewStatement {
    static let sql = """
        \(organizationalUnitOverviewSelect)
        WHERE ou.organization_id = $1
          AND ou.parent_ou_id IS NOT DISTINCT FROM $2::uuid
        ORDER BY ou.name, ou.id
        """
    let organizationID: UUID
    let parentID: UUID?
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(organizationID)
        bindings.append(parentID)
        return bindings
    }
}

private struct FindOrganizationalUnitOverview: OrganizationalUnitOverviewStatement {
    static let sql = "\(organizationalUnitOverviewSelect) WHERE ou.id = $1"
    let id: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct ListOrganizationalUnitSubtree: OrganizationalUnitOverviewStatement {
    static let sql = """
        \(organizationalUnitOverviewSelect)
        WHERE ou.path = $1 OR ou.path LIKE $1 || '/%'
        ORDER BY ou.depth, ou.name, ou.id
        """
    let rootPath: String
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(rootPath)
        return bindings
    }
}

private struct ListOrganizationalUnitAncestors: OrganizationalUnitStatement {
    static let sql = """
        SELECT \(organizationalUnitColumns)
        FROM organizational_units
        WHERE path = $1 OR $1 LIKE path || '/%'
        ORDER BY depth, id
        """
    let path: String
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(path)
        return bindings
    }
}

private struct FindOrganizationalUnit: OrganizationalUnitStatement {
    static let sql = "SELECT \(organizationalUnitColumns) FROM organizational_units WHERE id = $1"
    let id: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct FindOrganizationalUnitIDs: PostgresPreparedStatement {
    static let sql = """
        SELECT id FROM organizational_units
        WHERE organization_id = ANY($1::uuid[])
        ORDER BY id
        """
    typealias Row = UUID
    let organizationIDs: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(organizationIDs)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct LockOrganizationalUnit: OrganizationalUnitStatement {
    static let sql = "SELECT \(organizationalUnitColumns) FROM organizational_units WHERE id = $1 FOR UPDATE"
    let id: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct OrganizationalUnitNameExists: PostgresPreparedStatement {
    static let sql = """
        SELECT EXISTS (
            SELECT 1
            FROM organizational_units
            WHERE organization_id = $1
              AND parent_ou_id IS NOT DISTINCT FROM $2::uuid
              AND name = $3
              AND ($4::uuid IS NULL OR id <> $4)
        )
        """
    typealias Row = Bool
    let organizationID: UUID
    let parentID: UUID?
    let name: String
    let excludingID: UUID?
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(organizationID)
        bindings.append(parentID)
        bindings.append(name)
        bindings.append(excludingID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}

private struct InsertOrganizationalUnit: OrganizationalUnitStatement {
    static let sql = """
        INSERT INTO organizational_units (
            id, name, description, organization_id, parent_ou_id,
            path, depth, created_at, updated_at
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING \(organizationalUnitColumns)
        """
    let write: OrganizationalUnitWrite
    let path: String
    let depth: Int
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 7)
        bindings.append(write.id)
        bindings.append(write.name)
        bindings.append(write.description)
        bindings.append(write.organizationID)
        bindings.append(write.parentID)
        bindings.append(path)
        bindings.append(depth)
        return bindings
    }
}

private struct UpdateOrganizationalUnit: OrganizationalUnitStatement {
    static let sql = """
        UPDATE organizational_units
        SET name = COALESCE($2, name),
            description = COALESCE($3, description),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(organizationalUnitColumns)
        """
    let id: UUID
    let name: String?
    let description: String?
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(name)
        bindings.append(description)
        return bindings
    }
}

private struct OrganizationalUnitDependentCounts: Equatable, Sendable {
    let children: Int
    let projects: Int
}

private struct CountOrganizationalUnitDependents: PostgresPreparedStatement {
    static let sql = """
        SELECT (SELECT count(*)::bigint FROM organizational_units WHERE parent_ou_id = $1),
               (SELECT count(*)::bigint FROM projects WHERE organizational_unit_id = $1)
        """
    typealias Row = OrganizationalUnitDependentCounts
    let id: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> OrganizationalUnitDependentCounts {
        let value = try row.decode((Int, Int).self)
        return OrganizationalUnitDependentCounts(children: value.0, projects: value.1)
    }
}

private struct DeleteBindingsAtOrganizationalUnit: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM role_bindings
        WHERE node_type = 'organizational_unit' AND node_id = $1
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteOrganizationalUnit: PostgresPreparedStatement {
    static let sql = "DELETE FROM organizational_units WHERE id = $1 RETURNING id"
    typealias Row = UUID
    let id: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct MoveOrganizationalUnit: OrganizationalUnitStatement {
    static let sql = """
        UPDATE organizational_units
        SET parent_ou_id = $2, path = $3, depth = $4, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(organizationalUnitColumns)
        """
    let id: UUID
    let parentID: UUID?
    let path: String
    let depth: Int
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(id)
        bindings.append(parentID)
        bindings.append(path)
        bindings.append(depth)
        return bindings
    }
}

private struct RewriteDescendantOrganizationalUnits: PostgresPreparedStatement {
    static let sql = """
        UPDATE organizational_units
        SET path = $2 || substring(path FROM char_length($1) + 1),
            depth = depth + $3,
            updated_at = CURRENT_TIMESTAMP
        WHERE path LIKE $1 || '/%'
        RETURNING id
        """
    typealias Row = UUID
    let previousPath: String
    let newPath: String
    let depthDelta: Int
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(previousPath)
        bindings.append(newPath)
        bindings.append(depthDelta)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct RewriteOrganizationalUnitProjectPaths: PostgresPreparedStatement {
    static let sql = """
        UPDATE projects AS p
        SET path = ou.path || '/' || p.id::text,
            updated_at = CURRENT_TIMESTAMP
        FROM organizational_units AS ou
        WHERE p.organizational_unit_id = ou.id
          AND (ou.path = $1 OR ou.path LIKE $1 || '/%')
          AND p.path IS DISTINCT FROM ou.path || '/' || p.id::text
        RETURNING p.id
        """
    typealias Row = UUID
    let rootPath: String
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(rootPath)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}
