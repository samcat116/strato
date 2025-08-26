import Fluent
import Vapor

struct OIDCController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let organizations = routes.grouped("api", "organizations", ":organizationID")
        let oidcRoutes = organizations.grouped("oidc-providers")
        
        // OIDC Provider management
        oidcRoutes.get(use: listProviders)
        oidcRoutes.post(use: createProvider)
        oidcRoutes.get(":providerID", use: getProvider)
        oidcRoutes.put(":providerID", use: updateProvider)
        oidcRoutes.delete(":providerID", use: deleteProvider)
        
        // OIDC Provider testing
        oidcRoutes.post(":providerID", "test", use: testProvider)
        
        // OIDC Authentication endpoints
        let authRoutes = routes.grouped("auth", "oidc", ":organizationID", ":providerID")
        authRoutes.get("authorize", use: initiateOIDCAuth)
        authRoutes.get("callback", use: handleOIDCCallback)
        
        // Public OIDC provider listing for login page
        let publicRoutes = routes.grouped("api", "public", "organizations", ":organizationID")
        publicRoutes.get("oidc-providers", use: listPublicProviders)
    }
    
    // MARK: - Provider Management
    
    func listProviders(req: Request) async throws -> [OIDCProviderResponse] {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }
        
        // Verify user has access to this organization
        try await verifyOrganizationAccess(req: req, organizationID: organizationID)
        
        let providers = try await OIDCProvider.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .all()
        
        return providers.map { OIDCProviderResponse(from: $0) }
    }
    
    func createProvider(req: Request) async throws -> OIDCProviderResponse {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }
        
        // Verify user has admin access to this organization
        try await verifyOrganizationAdminAccess(req: req, organizationID: organizationID)
        
        let createRequest = try req.content.decode(CreateOIDCProviderRequest.self)
        
        // Validate the provider configuration
        try await validateProviderConfiguration(createRequest, on: req.db, organizationID: organizationID)
        
        let provider = OIDCProvider(
            organizationID: organizationID,
            name: createRequest.name,
            clientID: createRequest.clientID,
            clientSecret: createRequest.clientSecret,
            discoveryURL: createRequest.discoveryURL,
            authorizationEndpoint: createRequest.authorizationEndpoint,
            tokenEndpoint: createRequest.tokenEndpoint,
            userinfoEndpoint: createRequest.userinfoEndpoint,
            jwksURI: createRequest.jwksURI,
            scopes: createRequest.scopes ?? ["openid", "profile", "email"],
            enabled: createRequest.enabled ?? true
        )
        
        try await provider.save(on: req.db)
        
        // If discovery URL is provided, attempt to fetch configuration
        if let discoveryURL = createRequest.discoveryURL, !discoveryURL.isEmpty {
            try await fetchAndUpdateProviderConfiguration(provider: provider, discoveryURL: discoveryURL, on: req)
        }
        
        return OIDCProviderResponse(from: provider)
    }
    
    func getProvider(req: Request) async throws -> OIDCProviderResponse {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
              let providerID = req.parameters.get("providerID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or provider ID")
        }
        
        try await verifyOrganizationAccess(req: req, organizationID: organizationID)
        
        guard let provider = try await OIDCProvider.query(on: req.db)
            .filter(\.$id == providerID)
            .filter(\.$organization.$id == organizationID)
            .first() else {
            throw Abort(.notFound, reason: "OIDC provider not found")
        }
        
        return OIDCProviderResponse(from: provider)
    }
    
    func updateProvider(req: Request) async throws -> OIDCProviderResponse {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
              let providerID = req.parameters.get("providerID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or provider ID")
        }
        
        try await verifyOrganizationAdminAccess(req: req, organizationID: organizationID)
        
        guard let provider = try await OIDCProvider.query(on: req.db)
            .filter(\.$id == providerID)
            .filter(\.$organization.$id == organizationID)
            .first() else {
            throw Abort(.notFound, reason: "OIDC provider not found")
        }
        
        let updateRequest = try req.content.decode(UpdateOIDCProviderRequest.self)
        
        if let name = updateRequest.name { provider.name = name }
        if let clientID = updateRequest.clientID { provider.clientID = clientID }
        if let clientSecret = updateRequest.clientSecret { provider.clientSecret = clientSecret }
        if let discoveryURL = updateRequest.discoveryURL { provider.discoveryURL = discoveryURL }
        if let authorizationEndpoint = updateRequest.authorizationEndpoint { provider.authorizationEndpoint = authorizationEndpoint }
        if let tokenEndpoint = updateRequest.tokenEndpoint { provider.tokenEndpoint = tokenEndpoint }
        if let userinfoEndpoint = updateRequest.userinfoEndpoint { provider.userinfoEndpoint = userinfoEndpoint }
        if let jwksURI = updateRequest.jwksURI { provider.jwksURI = jwksURI }
        if let scopes = updateRequest.scopes { provider.setScopesArray(scopes) }
        if let enabled = updateRequest.enabled { provider.enabled = enabled }
        
        try await provider.save(on: req.db)
        
        return OIDCProviderResponse(from: provider)
    }
    
    func deleteProvider(req: Request) async throws -> HTTPStatus {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
              let providerID = req.parameters.get("providerID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or provider ID")
        }
        
        try await verifyOrganizationAdminAccess(req: req, organizationID: organizationID)
        
        guard let provider = try await OIDCProvider.query(on: req.db)
            .filter(\.$id == providerID)
            .filter(\.$organization.$id == organizationID)
            .first() else {
            throw Abort(.notFound, reason: "OIDC provider not found")
        }
        
        // Check if any users are linked to this provider
        let linkedUserCount = try await User.query(on: req.db)
            .filter(\.$oidcProvider.$id == providerID)
            .count()
        
        if linkedUserCount > 0 {
            throw Abort(.badRequest, reason: "Cannot delete provider: \(linkedUserCount) users are linked to this provider")
        }
        
        try await provider.delete(on: req.db)
        
        return .noContent
    }
    
    // MARK: - Provider Testing
    
    func testProvider(req: Request) async throws -> Response {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
              let providerID = req.parameters.get("providerID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or provider ID")
        }
        
        try await verifyOrganizationAdminAccess(req: req, organizationID: organizationID)
        
        guard let provider = try await OIDCProvider.query(on: req.db)
            .filter(\.$id == providerID)
            .filter(\.$organization.$id == organizationID)
            .first() else {
            throw Abort(.notFound, reason: "OIDC provider not found")
        }
        
        // Test the provider configuration by attempting to fetch discovery document
        if let discoveryURL = provider.discoveryURL {
            do {
                _ = try await fetchDiscoveryDocument(url: discoveryURL, on: req)
                return Response(status: .ok, body: .init(string: "Provider configuration is valid"))
            } catch {
                return Response(status: .badRequest, body: .init(string: "Provider configuration test failed: \(error.localizedDescription)"))
            }
        } else {
            // If no discovery URL, check that required endpoints are configured
            if provider.authorizationEndpoint != nil && provider.tokenEndpoint != nil {
                return Response(status: .ok, body: .init(string: "Provider endpoints are configured"))
            } else {
                return Response(status: .badRequest, body: .init(string: "Provider configuration is incomplete: missing required endpoints"))
            }
        }
    }
    
    // MARK: - Public Provider Listing
    
    func listPublicProviders(req: Request) async throws -> [OIDCProviderPublicResponse] {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }
        
        let providers = try await OIDCProvider.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$enabled == true)
            .all()
        
        return providers.map { OIDCProviderPublicResponse(from: $0) }
    }
    
    // MARK: - Authentication Flow
    
    func initiateOIDCAuth(req: Request) async throws -> Response {
        // TODO: Implement OIDC authentication initiation
        // This will be implemented when we integrate with Pactum or custom OIDC implementation
        throw Abort(.notImplemented, reason: "OIDC authentication not yet implemented")
    }
    
    func handleOIDCCallback(req: Request) async throws -> Response {
        // TODO: Implement OIDC callback handling
        // This will be implemented when we integrate with Pactum or custom OIDC implementation
        throw Abort(.notImplemented, reason: "OIDC callback handling not yet implemented")
    }
    
    // MARK: - Helper Methods
    
    private func verifyOrganizationAccess(req: Request, organizationID: UUID) async throws {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        
        // Check if user belongs to this organization
        try await user.$organizations.load(on: req.db)
        let hasAccess = user.organizations.contains { $0.id == organizationID }
        
        if !hasAccess && !user.isSystemAdmin {
            throw Abort(.forbidden, reason: "Access denied to organization")
        }
    }
    
    private func verifyOrganizationAdminAccess(req: Request, organizationID: UUID) async throws {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        
        if user.isSystemAdmin {
            return // System admins can manage all organizations
        }
        
        // Check if user is an admin of this organization
        let membership = try await UserOrganization.query(on: req.db)
            .filter(\.$user.$id == user.id!)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$role == "admin")
            .first()
        
        guard membership != nil else {
            throw Abort(.forbidden, reason: "Admin access required")
        }
    }
    
    private func validateProviderConfiguration(_ request: CreateOIDCProviderRequest, on database: Database, organizationID: UUID) async throws {
        // Check for duplicate provider names within the organization
        let existingProvider = try await OIDCProvider.query(on: database)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$name == request.name)
            .first()
        
        if existingProvider != nil {
            throw Abort(.badRequest, reason: "A provider with this name already exists in the organization")
        }
        
        // Validate that either discovery URL or required endpoints are provided
        if let discoveryURL = request.discoveryURL, !discoveryURL.isEmpty {
            // Discovery URL provided, that's sufficient
            return
        }
        
        // If no discovery URL, check for required individual endpoints
        guard let authEndpoint = request.authorizationEndpoint, !authEndpoint.isEmpty,
              let tokenEndpoint = request.tokenEndpoint, !tokenEndpoint.isEmpty else {
            throw Abort(.badRequest, reason: "Either discovery URL or both authorization and token endpoints must be provided")
        }
    }
    
    private func fetchAndUpdateProviderConfiguration(provider: OIDCProvider, discoveryURL: String, on req: Request) async throws {
        do {
            let discovery = try await fetchDiscoveryDocument(url: discoveryURL, on: req)
            
            // Update provider with discovered endpoints
            provider.authorizationEndpoint = discovery.authorizationEndpoint
            provider.tokenEndpoint = discovery.tokenEndpoint
            provider.userinfoEndpoint = discovery.userinfoEndpoint
            provider.jwksURI = discovery.jwksURI
            
            try await provider.save(on: req.db)
        } catch {
            req.logger.warning("Failed to fetch OIDC discovery document from \(discoveryURL): \(error)")
            // Don't fail the creation if discovery fails, just log the warning
        }
    }
    
    private func fetchDiscoveryDocument(url: String, on req: Request) async throws -> OIDCDiscoveryDocument {
        let response = try await req.client.get(URI(string: url))
        return try response.content.decode(OIDCDiscoveryDocument.self)
    }
}

// MARK: - OIDC Discovery Document

struct OIDCDiscoveryDocument: Content {
    let issuer: String
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let userinfoEndpoint: String?
    let jwksURI: String
    let responseTypesSupported: [String]
    let subjectTypesSupported: [String]
    let idTokenSigningAlgValuesSupported: [String]
    
    private enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case userinfoEndpoint = "userinfo_endpoint"
        case jwksURI = "jwks_uri"
        case responseTypesSupported = "response_types_supported"
        case subjectTypesSupported = "subject_types_supported"
        case idTokenSigningAlgValuesSupported = "id_token_signing_alg_values_supported"
    }
}