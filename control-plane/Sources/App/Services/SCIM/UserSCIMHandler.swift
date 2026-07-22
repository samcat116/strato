import Fluent
import Vapor
import SwiftSCIM

struct UserSCIMHandler: SCIMResourceHandler, @unchecked Sendable {
    typealias Resource = SCIMUser

    static let endpoint = "Users"
    static let schemaURI = "urn:ietf:params:scim:schemas:core:2.0:User"

    let db: Database
    let organizationID: UUID

    // MARK: - Create

    func create(_ resource: SCIMUser, context: SCIMRequestContext) async throws -> SCIMUser {
        // Check for existing user with same username
        if let _ = try await User.query(on: db)
            .filter(\.$username == resource.userName)
            .first()
        {
            throw SCIMServerError.conflict(detail: "User with username '\(resource.userName)' already exists")
        }

        // Extract primary email
        let email =
            resource.emails?.first(where: { $0.primary == true })?.value
            ?? resource.emails?.first?.value
            ?? "\(resource.userName)@scim.local"

        // Create user
        let user = User(
            username: resource.userName,
            email: email,
            displayName: resource.displayName ?? resource.name?.formatted ?? resource.userName,
            source: .scim,
            scimProvisioned: true,
            scimActive: resource.active ?? true
        )
        try await user.save(on: db)

        guard let userID = user.id else {
            throw SCIMServerError.internalError(detail: "Failed to create user")
        }

        // Add user to organization as member
        let membership = UserOrganization(
            userID: userID,
            organizationID: organizationID,
            role: "member"
        )
        try await membership.save(on: db)

        // Store external ID mapping if provided
        if let externalId = resource.externalId {
            try await SCIMExternalID.upsert(
                organizationID: organizationID,
                resourceType: .user,
                externalId: externalId,
                internalId: userID,
                on: db
            )
        }

        return try await userToSCIMUser(user, context: context)
    }

    // MARK: - Get

    func get(id: String, context: SCIMRequestContext) async throws -> SCIMUser {
        guard let uuid = UUID(uuidString: id) else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        guard
            let user = try await User.query(on: db)
                .filter(\.$id == uuid)
                .first()
        else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        // Verify user is in this organization
        let isMember =
            try await UserOrganization.query(on: db)
            .filter(\.$user.$id == uuid)
            .filter(\.$organization.$id == organizationID)
            .first() != nil

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

        guard
            let user = try await User.query(on: db)
                .filter(\.$id == uuid)
                .first()
        else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        // Verify user is in this organization
        let isMember =
            try await UserOrganization.query(on: db)
            .filter(\.$user.$id == uuid)
            .filter(\.$organization.$id == organizationID)
            .first() != nil

        guard isMember else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        // Check if new username is already taken by another user
        if user.username != resource.userName {
            let existingUser = try await User.query(on: db)
                .filter(\.$username == resource.userName)
                .filter(\.$id != uuid)
                .first()
            if existingUser != nil {
                throw SCIMServerError.conflict(detail: "User with username '\(resource.userName)' already exists")
            }
        }

        // Update user fields
        user.username = resource.userName
        user.displayName = resource.displayName ?? resource.name?.formatted ?? resource.userName
        let wasActive = user.scimActive
        user.scimActive = resource.active ?? true

        // SCIM deactivation is the IdP's offboarding/suspension signal, so it
        // must revoke access immediately — `scimActive` alone is only checked
        // at OIDC login. Mirror the SSF disable path: `disabledAt` makes
        // `UserSecurityMiddleware` and the passkey login path reject the user,
        // and the `sessionEpoch` bump invalidates existing sessions.
        if wasActive && !user.scimActive {
            if user.disabledAt == nil {
                user.disabledAt = Date()
            }
            user.sessionEpoch += 1
        } else if !wasActive && user.scimActive {
            user.disabledAt = nil
        }

        if let email = resource.emails?.first(where: { $0.primary == true })?.value
            ?? resource.emails?.first?.value
        {
            user.email = email
        }

        try await user.save(on: db)

        // Update external ID mapping if provided
        if let externalId = resource.externalId {
            try await SCIMExternalID.upsert(
                organizationID: organizationID,
                resourceType: .user,
                externalId: externalId,
                internalId: uuid,
                on: db
            )
        }

        return try await userToSCIMUser(user, context: context)
    }

    // MARK: - Delete

    func delete(id: String, context: SCIMRequestContext) async throws {
        guard let uuid = UUID(uuidString: id) else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        guard
            let user = try await User.query(on: db)
                .filter(\.$id == uuid)
                .first()
        else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        // Verify user is in this organization
        guard
            let membership = try await UserOrganization.query(on: db)
                .filter(\.$user.$id == uuid)
                .filter(\.$organization.$id == organizationID)
                .first()
        else {
            throw SCIMServerError.notFound(resourceType: "User", id: id)
        }

        // Soft delete - set scimActive to false, and revoke access immediately
        // (mirrors the SSF disable path): `disabledAt` makes the security
        // middleware and passkey login reject the user, and the epoch bump
        // invalidates existing sessions.
        user.scimActive = false
        if user.disabledAt == nil {
            user.disabledAt = Date()
        }
        user.sessionEpoch += 1
        try await user.save(on: db)

        // Remove the organization membership and everything held inside the
        // org — group memberships, project mirror rows, and role bindings
        // across the org's whole subtree (issue #485). Bindings the user
        // holds in other orgs are those orgs' grants and stay.
        try await db.transaction { transaction in
            try await membership.delete(on: transaction)
            try await OffboardingSweep.userLeftOrganization(
                userID: uuid, organizationID: organizationID, on: transaction)
        }

        // Delete external ID mapping
        try await SCIMExternalID.deleteMapping(
            internalId: uuid,
            resourceType: .user,
            organizationID: organizationID,
            on: db
        )
    }

    // MARK: - Search

    func search(query: SCIMServerQuery, context: SCIMRequestContext) async throws -> SCIMListResponse<SCIMUser> {
        // Get all users in this organization
        var userQuery = User.query(on: db)
            .join(UserOrganization.self, on: \User.$id == \UserOrganization.$user.$id)
            .filter(UserOrganization.self, \.$organization.$id == organizationID)

        // Apply filter if present
        if let filter = query.filter {
            userQuery = try applyFilter(filter, to: userQuery)
        }

        // Get total count before pagination
        let totalCount = try await userQuery.count()

        // Apply pagination
        let users =
            try await userQuery
            .offset(query.offset)
            .limit(query.count)
            .all()

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
        let externalId = try await SCIMExternalID.findExternalID(
            internalId: userID,
            resourceType: .user,
            organizationID: organizationID,
            on: db
        )

        // Note: Groups field is omitted from user responses to avoid Swift type naming
        // conflicts between App.UserGroup and SwiftSCIM.UserGroup. IdPs typically
        // track group membership through the Groups endpoint, not the Users endpoint.

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

    private func applyFilter(_ filter: SCIMFilterExpression, to query: QueryBuilder<User>) throws -> QueryBuilder<User>
    {
        switch filter {
        case .attribute(let path, let op, let value):
            return try applyAttributeFilter(path: path, op: op, value: value, to: query)

        case .logical(let logicalOp, let left, let right):
            switch logicalOp {
            case .and:
                var result = try applyFilter(left, to: query)
                result = try applyFilter(right, to: result)
                return result
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
            // Check if attribute is present (not null)
            if path.lowercased() == "username" {
                return query.filter(\.$username != "")
            }
            return query

        case .group(let inner):
            return try applyFilter(inner, to: query)

        case .empty:
            return query
        }
    }

    private func applyAttributeFilter(
        path: String,
        op: SCIMFilterOperator,
        value: String,
        to query: QueryBuilder<User>
    ) throws -> QueryBuilder<User> {
        let lowercasePath = path.lowercased()

        switch lowercasePath {
        case "username":
            return applyStringFilter(keyPath: \User.$username, column: "username", op: op, value: value, to: query)

        case "displayname":
            return applyStringFilter(
                keyPath: \User.$displayName, column: "display_name", op: op, value: value, to: query)

        case "emails.value", "emails[type eq \"work\"].value":
            return applyStringFilter(keyPath: \User.$email, column: "email", op: op, value: value, to: query)

        case "active":
            if let boolValue = Bool(value.lowercased()) {
                return query.filter(\.$scimActive == boolValue)
            }
            return query

        case "externalid":
            // Need to join with scim_external_ids table
            // For now, return unfiltered - this would need a more complex query
            return query

        default:
            return query
        }
    }

    private func applyStringFilter(
        keyPath: KeyPath<User, FieldProperty<User, String>>,
        column: String,
        op: SCIMFilterOperator,
        value: String,
        to query: QueryBuilder<User>
    ) -> QueryBuilder<User> {
        switch op {
        case .equal:
            return query.filter(keyPath == value)
        case .notEqual:
            return query.filter(keyPath != value)
        case .contains:
            return query.filter(.caseInsensitiveContains(schema: User.schema, column: column, value: value))
        case .startsWith:
            return query.filter(.caseInsensitiveStartsWith(schema: User.schema, column: column, value: value))
        case .endsWith:
            return query.filter(.caseInsensitiveEndsWith(schema: User.schema, column: column, value: value))
        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual, .present:
            // These don't make sense for strings, just return unchanged
            return query
        }
    }
}
