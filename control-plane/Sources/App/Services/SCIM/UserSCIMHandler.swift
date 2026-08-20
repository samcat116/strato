import ControlPlanePostgres
import Fluent
import Vapor
import SwiftSCIM

/// Fluent's database handle predates checked sendability. It is immutable here;
/// every mutable model is created or reloaded inside one method and never sent
/// to a child task or retained by the handler.
struct UserSCIMHandler: SCIMResourceHandler, Sendable {
    typealias Resource = SCIMUser

    static let endpoint = "Users"
    static let schemaURI = "urn:ietf:params:scim:schemas:core:2.0:User"

    let db: Database
    let externalIDs: SCIMExternalIDsPersistence
    let organizationID: UUID

    // MARK: - Create

    func create(_ resource: SCIMUser, context: SCIMRequestContext) async throws -> SCIMUser {
        // Check for existing user with same username
        if try await LegacyUserStore.users(username: resource.userName, on: db).first != nil {
            throw SCIMServerError.conflict(detail: "User with username '\(resource.userName)' already exists")
        }

        // Extract primary email
        let email =
            resource.emails?.first(where: { $0.primary == true })?.value
            ?? resource.emails?.first?.value
            ?? "\(resource.userName)@scim.local"

        // Create user
        let user = try await User(
            username: resource.userName,
            email: email,
            displayName: resource.displayName ?? resource.name?.formatted ?? resource.userName,
            source: .scim,
            scimProvisioned: true,
            scimActive: resource.active ?? true
        ).persisted(on: db)

        guard let userID = user.id else {
            throw SCIMServerError.internalError(detail: "Failed to create user")
        }

        // Add user to organization as member
        _ = try await OrganizationMembershipStore.insert(
            userID: userID,
            organizationID: organizationID,
            on: db
        )

        // Store external ID mapping if provided
        if let externalId = resource.externalId {
            try await externalIDs.assign(
                externalID: externalId,
                to: userID,
                resourceType: .user,
                organizationID: organizationID
            )
        }

        return try await userToSCIMUser(user, context: context)
    }

    // MARK: - Get

    func get(id: String, context: SCIMRequestContext) async throws -> SCIMUser {
        guard let uuid = UUID(uuidString: id) else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        guard let user = try await User.find(uuid, on: db) else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        // Verify user is in this organization
        let isMember = try await OrganizationMembershipStore.membership(
            userID: uuid, organizationID: organizationID, on: db) != nil

        guard isMember else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        return try await userToSCIMUser(user, context: context)
    }

    // MARK: - Replace

    func replace(id: String, with resource: SCIMUser, context: SCIMRequestContext) async throws -> SCIMUser {
        guard let uuid = UUID(uuidString: id) else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        guard var user = try await User.find(uuid, on: db) else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        // Verify user is in this organization
        let isMember = try await OrganizationMembershipStore.membership(
            userID: uuid, organizationID: organizationID, on: db) != nil

        guard isMember else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        // Check if new username is already taken by another user
        if user.username != resource.userName {
            let existingUser = try await LegacyUserStore.users(
                username: resource.userName,
                excludingID: uuid,
                on: db
            ).first
            if existingUser != nil {
                throw SCIMServerError.conflict(detail: "User with username '\(resource.userName)' already exists")
            }
        }

        // Update user fields
        user = user.replacing(
            username: resource.userName,
            displayName: resource.displayName ?? resource.name?.formatted ?? resource.userName
        )
        let wasActive = user.scimActive
        user = user.replacing(scimActive: resource.active ?? true)

        // SCIM deactivation is the IdP's offboarding/suspension signal, so it
        // must revoke access immediately — `scimActive` alone is only checked
        // at OIDC login. Mirror the SSF disable path: `disabledAt` makes
        // `UserSecurityMiddleware` and the passkey login path reject the user,
        // and the `sessionEpoch` bump invalidates existing sessions.
        if wasActive && !user.scimActive {
            if user.disabledAt == nil {
                user = user.replacing(disabledAt: .some(Date()))
            }
            user = user.replacing(sessionEpoch: user.sessionEpoch + 1)
        } else if !wasActive && user.scimActive {
            user = user.replacing(disabledAt: .some(nil))
        }

        if let email = resource.emails?.first(where: { $0.primary == true })?.value
            ?? resource.emails?.first?.value
        {
            user = user.replacing(email: email)
        }

        user = try await user.persisted(on: db)

        // Update external ID mapping if provided
        if let externalId = resource.externalId {
            try await externalIDs.assign(
                externalID: externalId,
                to: uuid,
                resourceType: .user,
                organizationID: organizationID
            )
        }

        return try await userToSCIMUser(user, context: context)
    }

    // MARK: - Delete

    func delete(id: String, context: SCIMRequestContext) async throws {
        guard let uuid = UUID(uuidString: id) else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        guard var user = try await User.find(uuid, on: db) else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        // Verify user is in this organization
        guard
            let membership = try await OrganizationMembershipStore.membership(
                userID: uuid, organizationID: organizationID, on: db)
        else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        // Soft delete - set scimActive to false, and revoke access immediately
        // (mirrors the SSF disable path): `disabledAt` makes the security
        // middleware and passkey login reject the user, and the epoch bump
        // invalidates existing sessions.
        user = user.replacing(scimActive: false)
        if user.disabledAt == nil {
            user = user.replacing(disabledAt: .some(Date()))
        }
        user = user.replacing(sessionEpoch: user.sessionEpoch + 1)
        try await user.save(on: db)

        // Remove the organization membership and everything held inside the
        // org — group memberships and role bindings
        // across the org's whole subtree (issue #485). Bindings the user
        // holds in other orgs are those orgs' grants and stay.
        try await db.transaction { transaction in
            _ = try await OrganizationMembershipStore.delete(id: membership.id, on: transaction)
            try await OffboardingSweep.userLeftOrganization(
                userID: uuid, organizationID: organizationID, on: transaction)
        }

        // Delete external ID mapping
        _ = try await externalIDs.remove(
            internalID: uuid,
            resourceType: .user,
            organizationID: organizationID
        )
    }

    // MARK: - Search

    func search(query: SCIMServerQuery, context: SCIMRequestContext) async throws -> SCIMListResponse<SCIMUser> {
        // Get all users in this organization
        let memberIDs = try await OrganizationMembershipStore.memberships(
            organizationID: organizationID, on: db
        ).map(\.userID)
        var users = try await LegacyUserStore.users(ids: memberIDs, on: db)
        if let filter = query.filter {
            users = try users.filter { try matches(filter, user: $0) }
        }
        let totalCount = users.count
        users = Array(users.dropFirst(query.offset).prefix(query.count))

        // Convert to SCIM resources
        var scimUsers: [SCIMUser] = []
        for user in users {
            let scimUser = try await userToSCIMUser(user, context: context)
            scimUsers.append(scimUser)
        }

        return SCIMListResponse(
            totalResults: totalCount,
            resources: scimUsers,
            startIndex: query.startIndex,
            itemsPerPage: query.count
        )
    }

    // MARK: - Helpers

    private func userToSCIMUser(_ user: User, context: SCIMRequestContext) async throws -> SCIMUser {
        guard let userID = user.id else {
            throw SCIMServerError.internalError(detail: "User has no ID")
        }

        let location = context.resourceLocation(endpoint: Self.endpoint, id: userID.uuidString)

        // Get external ID if exists
        let externalId = try await externalIDs.externalID(
            internalID: userID,
            resourceType: .user,
            organizationID: organizationID
        )

        // Groups are omitted because IdPs track membership through the Groups
        // endpoint and the existing wire contract does not embed them here.

        let meta = SCIMResourceMeta(
            resourceType: "User",
            created: user.createdAt,
            lastModified: user.updatedAt,
            location: location,
            version: user.updatedAt.map { "W/\"\($0.timeIntervalSince1970)\"" }
        )

        return SCIMUser(
            id: userID.uuidString,
            externalId: externalId,
            meta: meta,
            userName: user.username,
            name: UserName(formatted: user.displayName),
            displayName: user.displayName,
            active: user.scimActive,
            emails: [
                SCIMMultiValuedAttribute(
                    value: user.email,
                    type: "work",
                    primary: true
                )
            ]
        )
    }

    private func matches(_ filter: SCIMFilterExpression, user: User) throws -> Bool {
        switch filter {
        case .attribute(let path, let op, let value):
            return try matchesAttribute(path: path, op: op, value: value, user: user)

        case .logical(let logicalOp, let left, let right):
            switch logicalOp {
            case .and:
                return try matches(left, user: user) && matches(right, user: user)
            case .or, .not:
                throw SCIMServerError.invalidFilter(
                    detail: "SCIM logical filter operator '\(logicalOp)' is not supported"
                )
            }

        case .not:
            throw SCIMServerError.invalidFilter(
                detail: "SCIM NOT filter is not supported"
            )

        case .present(let path):
            if path.lowercased() == "username" {
                return !user.username.isEmpty
            }
            return true

        case .group(let inner):
            return try matches(inner, user: user)

        case .empty:
            return true
        }
    }

    private func matchesAttribute(
        path: String,
        op: SCIMFilterOperator,
        value: SCIMComparisonValue,
        user: User
    ) throws -> Bool {
        let lowercasePath = path.lowercased()

        switch lowercasePath {
        case "username":
            return matchesString(user.username, op: op, value: try value.requireText(path: path))

        case "displayname":
            return matchesString(user.displayName, op: op, value: try value.requireText(path: path))

        case "emails.value", "emails[type eq \"work\"].value":
            return matchesString(user.email, op: op, value: try value.requireText(path: path))

        case "active":
            if let boolValue = Bool(try value.requireText(path: path).lowercased()) {
                return user.scimActive == boolValue
            }
            return true

        case "externalid":
            // Preserve the previous behavior until external-ID search is added.
            return true

        default:
            return true
        }
    }

    private func matchesString(
        _ candidate: String,
        op: SCIMFilterOperator,
        value: String
    ) -> Bool {
        switch op {
        case .equal:
            return candidate == value
        case .notEqual:
            return candidate != value
        case .contains:
            return candidate.localizedCaseInsensitiveContains(value)
        case .startsWith:
            return candidate.lowercased().hasPrefix(value.lowercased())
        case .endsWith:
            return candidate.lowercased().hasSuffix(value.lowercased())
        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual, .present:
            return true
        }
    }
}
