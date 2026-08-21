import ControlPlanePostgres
import Vapor
import SwiftSCIM

struct UserSCIMHandler: SCIMResourceHandler, Sendable {
    typealias Resource = SCIMUser

    static let endpoint = "Users"
    static let schemaURI = "urn:ietf:params:scim:schemas:core:2.0:User"

    let users: UserDirectoryPersistence
    let externalIDs: SCIMExternalIDsPersistence
    let organizationID: UUID

    // MARK: - Create

    func create(_ resource: SCIMUser, context: SCIMRequestContext) async throws -> SCIMUser {
        // Check for existing user with same username
        if try await users.user(username: resource.userName) != nil {
            throw SCIMServerError.conflict(detail: "User with username '\(resource.userName)' already exists")
        }

        // Extract primary email
        let email =
            resource.emails?.first(where: { $0.primary == true })?.value
            ?? resource.emails?.first?.value
            ?? "\(resource.userName)@scim.local"

        // Create user
        let write = UserDirectoryWrite(
            username: resource.userName,
            email: email,
            displayName: resource.displayName ?? resource.name?.formatted ?? resource.userName,
            source: "scim",
            scimProvisioned: true,
            scimActive: resource.active ?? true
        )
        let user: UserDirectorySnapshot
        switch try await users.createSCIMUser(write, organizationID: organizationID) {
        case .saved(let saved): user = saved
        case .identifierConflict:
            throw SCIMServerError.conflict(
                detail: "User with username '\(resource.userName)' already exists")
        case .notMember:
            throw SCIMServerError.internalError(detail: "Failed to create user")
        }
        let userID = user.id

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

        guard let user = try await users.scimUser(id: uuid, organizationID: organizationID) else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        return try await userToSCIMUser(user, context: context)
    }

    // MARK: - Replace

    func replace(id: String, with resource: SCIMUser, context: SCIMRequestContext) async throws -> SCIMUser {
        guard let uuid = UUID(uuidString: id) else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        guard let current = try await users.scimUser(id: uuid, organizationID: organizationID) else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        // Check if new username is already taken by another user
        let wasActive = current.scimActive
        let active = resource.active ?? true
        var disabledAt = current.disabledAt
        var sessionEpoch = current.sessionEpoch

        // SCIM deactivation is the IdP's offboarding/suspension signal, so it
        // must revoke access immediately — `scimActive` alone is only checked
        // at OIDC login. Mirror the SSF disable path: `disabledAt` makes
        // `UserSecurityMiddleware` and the passkey login path reject the user,
        // and the `sessionEpoch` bump invalidates existing sessions.
        if wasActive && !active {
            disabledAt = disabledAt ?? Date()
            sessionEpoch += 1
        } else if !wasActive && active {
            disabledAt = nil
        }

        let email = resource.emails?.first(where: { $0.primary == true })?.value
            ?? resource.emails?.first?.value ?? current.email
        let write = UserDirectoryWrite(
            id: current.id,
            username: resource.userName,
            email: email,
            displayName: resource.displayName ?? resource.name?.formatted ?? resource.userName,
            currentOrganizationID: current.currentOrganizationID,
            isSystemAdmin: current.isSystemAdmin,
            source: current.source,
            oidcProviderID: current.oidcProviderID,
            oidcSubject: current.oidcSubject,
            scimProvisioned: current.scimProvisioned,
            scimActive: active,
            sessionEpoch: sessionEpoch,
            disabledAt: disabledAt)
        let user: UserDirectorySnapshot
        switch try await users.updateSCIMUser(write, organizationID: organizationID) {
        case .saved(let saved): user = saved
        case .identifierConflict:
            throw SCIMServerError.conflict(
                detail: "User with username '\(resource.userName)' already exists")
        case .notMember:
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

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

        guard try await users.scimUser(id: uuid, organizationID: organizationID) != nil else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        guard try await users.offboardSCIMUser(
            id: uuid,
            organizationID: organizationID) != nil
        else { throw SCIMServerError.notFound(resourceType: "User", id: id) }

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
        var rows = try await users.scimUsers(organizationID: organizationID)
        if let filter = query.filter {
            rows = try rows.filter { try matches(filter, user: $0) }
        }
        let totalCount = rows.count
        rows = Array(rows.dropFirst(query.offset).prefix(query.count))

        // Convert to SCIM resources
        var scimUsers: [SCIMUser] = []
        for user in rows {
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

    private func userToSCIMUser(
        _ user: UserDirectorySnapshot,
        context: SCIMRequestContext
    ) async throws -> SCIMUser {
        let userID = user.id

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

    private func matches(_ filter: SCIMFilterExpression, user: UserDirectorySnapshot) throws -> Bool {
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
        user: UserDirectorySnapshot
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
