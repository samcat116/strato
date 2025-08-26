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
        
        // Validate URL fields
        try validateURLFields(request: createRequest)
        
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
            if provider.hasRequiredEndpoints() {
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
    
    /**
     * Initiates the OIDC authentication flow for a user.
     *
     * Intended implementation:
     * - Extract the organization and OIDC provider information from the request.
     * - Generate a state and nonce for CSRF protection and replay attack prevention.
     * - Construct the OIDC authorization URL with required parameters (client_id, redirect_uri, scope, state, nonce, etc.).
     * - Store the state and nonce in the user's session or a secure cookie for later verification.
     * - Redirect the user to the OIDC provider's authorization endpoint.
     *
     * Integration plan:
     * - This method will be implemented when we integrate with Pactum or a custom OIDC implementation.
     * - The implementation should be compatible with the OIDC providers configured for the organization.
     * - Proper error handling and logging should be added for failed or invalid requests.
     */
    func initiateOIDCAuth(req: Request) async throws -> Response {
        throw Abort(.notImplemented, reason: "OIDC authentication not yet implemented")
    }
    
    /**
     * Handles the OIDC callback after user authentication.
     *
     * Intended implementation:
     * - Validate the authorization code and state parameters from the callback.
     * - Verify the state parameter matches what was stored in the session for CSRF protection.
     * - Exchange the authorization code for an access token and ID token via the token endpoint.
     * - Validate the ID token signature and claims (issuer, audience, expiration, nonce).
     * - Extract user information from the ID token or by calling the userinfo endpoint.
     * - Create or update the user account in the local database.
     * - Establish an authenticated session for the user.
     * - Redirect the user to their intended destination or the dashboard.
     *
     * Integration plan:
     * - This method will be implemented when we integrate with Pactum or a custom OIDC implementation.
     * - The implementation should handle various OIDC providers and their specific requirements.
     * - Proper error handling for invalid tokens, expired sessions, and authentication failures.
     */
    func handleOIDCCallback(req: Request) async throws -> Response {
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
    
    private func validateURLFields(request: CreateOIDCProviderRequest) throws {
        // Validate discovery URL
        if let discoveryURL = request.discoveryURL, !discoveryURL.isEmpty {
            guard isValidHTTPSURL(discoveryURL) else {
                throw Abort(.badRequest, reason: "Discovery URL must be a valid HTTPS URL")
            }
        }
        
        // Validate authorization endpoint
        if let authEndpoint = request.authorizationEndpoint, !authEndpoint.isEmpty {
            guard isValidHTTPSURL(authEndpoint) else {
                throw Abort(.badRequest, reason: "Authorization endpoint must be a valid HTTPS URL")
            }
        }
        
        // Validate token endpoint
        if let tokenEndpoint = request.tokenEndpoint, !tokenEndpoint.isEmpty {
            guard isValidHTTPSURL(tokenEndpoint) else {
                throw Abort(.badRequest, reason: "Token endpoint must be a valid HTTPS URL")
            }
        }
        
        // Validate userinfo endpoint
        if let userinfoEndpoint = request.userinfoEndpoint, !userinfoEndpoint.isEmpty {
            guard isValidHTTPSURL(userinfoEndpoint) else {
                throw Abort(.badRequest, reason: "Userinfo endpoint must be a valid HTTPS URL")
            }
        }
        
        // Validate JWKS URI
        if let jwksURI = request.jwksURI, !jwksURI.isEmpty {
            guard isValidHTTPSURL(jwksURI) else {
                throw Abort(.badRequest, reason: "JWKS URI must be a valid HTTPS URL")
            }
        }
    }
    
    private func isValidHTTPSURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme,
              scheme == "https",
              url.host != nil else {
            return false
        }
        return true
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
            req.logger.warning("Failed to fetch OIDC discovery document from discovery URL.")
            // Don't fail the creation if discovery fails, just log the warning
        }
    }
    
    private func fetchDiscoveryDocument(url: String, on req: Request) async throws -> OIDCDiscoveryDocument {
        // Validate URL to prevent SSRF attacks
        guard let parsedURL = URL(string: url),
              let host = parsedURL.host,
              parsedURL.scheme == "https" else {
            throw Abort(.badRequest, reason: "Discovery URL must be a valid HTTPS URL")
        }
        
        // Define allowed hosts for OIDC discovery (common providers)
        let allowedHosts: Set<String> = [
            "accounts.google.com",
            "login.microsoftonline.com",
            "login.salesforce.com",
            "auth0.com",
            "okta.com",
            "oauth.reddit.com",
            "github.com",
            "gitlab.com"
        ]
        
        // Allow subdomains for major OIDC providers
        let allowedDomainSuffixes = [
            ".auth0.com",
            ".okta.com",
            ".oktapreview.com",
            ".okta-emea.com",
            ".salesforce.com",
            ".force.com",
            ".herokuapp.com",
            ".amazonaws.com",
            ".azure.com",
            ".azurewebsites.net"
        ]
        
        let isHostAllowed = allowedHosts.contains(host) || 
                           allowedDomainSuffixes.contains { host.hasSuffix($0) }
        
        guard isHostAllowed else {
            throw Abort(.badRequest, reason: "Discovery URL host is not in the allowed list for security reasons")
        }
        
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