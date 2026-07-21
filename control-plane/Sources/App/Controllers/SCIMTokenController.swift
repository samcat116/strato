import Fluent
import Vapor

struct SCIMTokenController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // SCIM token management routes: /organizations/:organizationID/settings/scim-tokens
        let tokens = routes.grouped("organizations", ":organizationID", "settings", "scim-tokens")

        tokens.get(use: listTokens)
        tokens.post(use: createToken)

        tokens.group(":tokenID") { token in
            token.get(use: getToken)
            token.patch(use: updateToken)
            token.delete(use: deleteToken)
        }
    }

    // MARK: - List Tokens

    @Sendable
    func listTokens(req: Request) async throws -> [SCIMTokenResponse] {
        _ = try req.auth.require(User.self)
        let organizationID = try getOrganizationID(from: req)

        // Verify user is admin of this organization
        try await requireOrganizationAdmin(organizationID: organizationID, on: req)

        let tokens = try await SCIMToken.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .sort(\.$createdAt, .descending)
            .all()

        return tokens.map { SCIMTokenResponse(from: $0) }
    }

    // MARK: - Create Token

    @Sendable
    func createToken(req: Request) async throws -> CreateSCIMTokenResponse {
        let user = try req.auth.require(User.self)
        let organizationID = try getOrganizationID(from: req)

        // Verify user is admin of this organization
        try await requireOrganizationAdmin(organizationID: organizationID, on: req)

        let request = try req.content.decode(CreateSCIMTokenRequest.self)

        // Generate token
        let fullToken = SCIMToken.generateToken()
        let tokenHash = SCIMToken.hashToken(fullToken)
        let tokenPrefix = SCIMToken.extractPrefix(fullToken)

        // Calculate expiration if specified
        var expiresAt: Date?
        if let days = request.expiresInDays, days > 0 {
            expiresAt = Date().addingTimeInterval(TimeInterval(days) * 24 * 60 * 60)
        }

        guard let userID = user.id else {
            throw Abort(.internalServerError, reason: "User has no ID")
        }

        let scimToken = SCIMToken(
            organizationID: organizationID,
            name: request.name,
            tokenHash: tokenHash,
            tokenPrefix: tokenPrefix,
            isActive: true,
            expiresAt: expiresAt,
            createdByID: userID
        )

        try await scimToken.save(on: req.db)

        return CreateSCIMTokenResponse(scimToken: scimToken, fullToken: fullToken)
    }

    // MARK: - Get Token

    @Sendable
    func getToken(req: Request) async throws -> SCIMTokenResponse {
        _ = try req.auth.require(User.self)
        let organizationID = try getOrganizationID(from: req)

        // Verify user is admin of this organization
        try await requireOrganizationAdmin(organizationID: organizationID, on: req)

        guard let tokenIDString = req.parameters.get("tokenID"),
            let tokenID = UUID(uuidString: tokenIDString)
        else {
            throw Abort(.badRequest, reason: "Invalid token ID")
        }

        guard
            let token = try await SCIMToken.query(on: req.db)
                .filter(\.$id == tokenID)
                .filter(\.$organization.$id == organizationID)
                .first()
        else {
            throw Abort(.notFound, reason: "Token not found")
        }

        return SCIMTokenResponse(from: token)
    }

    // MARK: - Update Token

    @Sendable
    func updateToken(req: Request) async throws -> SCIMTokenResponse {
        _ = try req.auth.require(User.self)
        let organizationID = try getOrganizationID(from: req)

        // Verify user is admin of this organization
        try await requireOrganizationAdmin(organizationID: organizationID, on: req)

        guard let tokenIDString = req.parameters.get("tokenID"),
            let tokenID = UUID(uuidString: tokenIDString)
        else {
            throw Abort(.badRequest, reason: "Invalid token ID")
        }

        guard
            let token = try await SCIMToken.query(on: req.db)
                .filter(\.$id == tokenID)
                .filter(\.$organization.$id == organizationID)
                .first()
        else {
            throw Abort(.notFound, reason: "Token not found")
        }

        let request = try req.content.decode(UpdateSCIMTokenRequest.self)

        if let name = request.name {
            token.name = name
        }

        if let isActive = request.isActive {
            token.isActive = isActive
        }

        try await token.save(on: req.db)

        return SCIMTokenResponse(from: token)
    }

    // MARK: - Delete Token

    @Sendable
    func deleteToken(req: Request) async throws -> HTTPStatus {
        _ = try req.auth.require(User.self)
        let organizationID = try getOrganizationID(from: req)

        // Verify user is admin of this organization
        try await requireOrganizationAdmin(organizationID: organizationID, on: req)

        guard let tokenIDString = req.parameters.get("tokenID"),
            let tokenID = UUID(uuidString: tokenIDString)
        else {
            throw Abort(.badRequest, reason: "Invalid token ID")
        }

        guard
            let token = try await SCIMToken.query(on: req.db)
                .filter(\.$id == tokenID)
                .filter(\.$organization.$id == organizationID)
                .first()
        else {
            throw Abort(.notFound, reason: "Token not found")
        }

        try await token.delete(on: req.db)

        return .noContent
    }

    // MARK: - Helpers

    private func getOrganizationID(from req: Request) throws -> UUID {
        guard let organizationIDString = req.parameters.get("organizationID"),
            let organizationID = UUID(uuidString: organizationIDString)
        else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }
        return organizationID
    }

    /// Managing SCIM tokens is org administration, gated through the
    /// evaluator like the rest of the org-admin surface (the issue #482
    /// pre-cutover audit's conversion pattern — previously an inline
    /// `UserOrganization.role` read invisible to the decision log).
    private func requireOrganizationAdmin(organizationID: UUID, on req: Request) async throws {
        guard try await req.can("manage_members", on: "organization", id: organizationID.uuidString) else {
            throw Abort(.forbidden, reason: "Only organization admins can manage SCIM tokens")
        }
    }
}
