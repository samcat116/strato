import ControlPlanePostgres
import Vapor

struct SCIMTokenController: RouteCollection {
    private let scimTokens: SCIMTokensPersistence

    init(scimTokens: SCIMTokensPersistence) {
        self.scimTokens = scimTokens
    }

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

        let tokens = try await scimTokens.tokens(organizationID: organizationID)

        return tokens.map { SCIMTokenResponse(from: $0) }
    }

    // MARK: - Create Token

    @Sendable
    func createToken(req: Request) async throws -> CreateSCIMTokenResponse {
        let user = try req.auth.require(User.self)
        let organizationID = try getOrganizationID(from: req)

        // Verify user is admin of this organization
        try await requireOrganizationAdmin(organizationID: organizationID, on: req)

        let request = try req.content.decodeValidated(CreateSCIMTokenRequest.self)

        // Generate token
        let fullToken = SCIMTokenCredential.generateToken()
        let tokenHash = SCIMTokenCredential.hashToken(fullToken)
        let tokenPrefix = SCIMTokenCredential.extractPrefix(fullToken)

        // Calculate expiration if specified
        var expiresAt: Date?
        if let days = request.expiresInDays, days > 0 {
            expiresAt = Date().addingTimeInterval(TimeInterval(days) * 24 * 60 * 60)
        }

        guard let userID = user.id else {
            throw Abort(.internalServerError, reason: "User has no ID")
        }

        let scimToken = try await scimTokens.issue(
            SCIMTokenWrite(
                organizationID: organizationID,
                name: request.name,
                tokenHash: tokenHash,
                tokenPrefix: tokenPrefix,
                isActive: true,
                expiresAt: expiresAt,
                createdByID: userID
            ))

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

        guard let token = try await scimTokens.ownedToken(id: tokenID, organizationID: organizationID) else {
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

        guard let existing = try await scimTokens.ownedToken(id: tokenID, organizationID: organizationID) else {
            throw Abort(.notFound, reason: "Token not found")
        }

        let request = try req.content.decodeValidated(UpdateSCIMTokenRequest.self)

        guard request.name != nil || request.isActive != nil else {
            return SCIMTokenResponse(from: existing)
        }

        guard
            let token = try await scimTokens.updateOwnedToken(
                id: tokenID,
                organizationID: organizationID,
                changes: SCIMTokenChanges(name: request.name, isActive: request.isActive)
            )
        else {
            throw Abort(.notFound, reason: "Token not found")
        }

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

        guard try await scimTokens.deleteOwnedToken(id: tokenID, organizationID: organizationID) else {
            throw Abort(.notFound, reason: "Token not found")
        }

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
    /// organization-membership field read invisible to the decision log).
    private func requireOrganizationAdmin(organizationID: UUID, on req: Request) async throws {
        guard try await req.can("org:update", on: IAMNode(type: .organization, id: organizationID)) else {
            throw Abort(.forbidden, reason: "Only organization admins can manage SCIM tokens")
        }
    }
}
