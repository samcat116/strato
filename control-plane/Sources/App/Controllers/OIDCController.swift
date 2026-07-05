import Fluent
import Vapor
@preconcurrency import JWT
import Crypto
import Foundation

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
        try OIDCValidation.validateURLFields(request: createRequest)

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

    func initiateOIDCAuth(req: Request) async throws -> Response {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
              let providerID = req.parameters.get("providerID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or provider ID")
        }

        // Fetch the OIDC provider
        guard let provider = try await OIDCProvider.query(on: req.db)
            .filter(\.$id == providerID)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$enabled == true)
            .first() else {
            throw Abort(.notFound, reason: "OIDC provider not found or disabled")
        }

        // Generate state and nonce for security
        let state = UUID().uuidString
        let nonce = UUID().uuidString

        // Store state and nonce in session for verification
        req.session.data["oidc_state"] = state
        req.session.data["oidc_nonce"] = nonce
        req.session.data["oidc_provider_id"] = providerID.uuidString
        req.session.data["oidc_organization_id"] = organizationID.uuidString

        // Build redirect URI
        let baseURL = Environment.get("BASE_URL") ?? "http://localhost:8080"
        let redirectURI = "\(baseURL)/auth/oidc/\(organizationID)/\(providerID)/callback"

        // Generate authorization URL
        guard let authURL = provider.getAuthorizationURL(
            redirectURI: redirectURI,
            state: state,
            nonce: nonce
        ) else {
            throw Abort(.internalServerError, reason: "Failed to generate authorization URL")
        }

        return Response(status: .seeOther, headers: HTTPHeaders([("Location", authURL)]))
    }

    func handleOIDCCallback(req: Request) async throws -> Response {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
              let providerID = req.parameters.get("providerID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or provider ID")
        }

        // Extract query parameters
        let code = try req.query.get(String.self, at: "code")
        let state = try req.query.get(String.self, at: "state")

        // Verify state parameter for CSRF protection
        guard let sessionState = req.session.data["oidc_state"],
              state == sessionState else {
            throw Abort(.badRequest, reason: "Invalid state parameter")
        }

        // Verify session provider and organization match
        guard let sessionProviderID = req.session.data["oidc_provider_id"],
              let sessionOrgID = req.session.data["oidc_organization_id"],
              sessionProviderID == providerID.uuidString,
              sessionOrgID == organizationID.uuidString else {
            throw Abort(.badRequest, reason: "Session mismatch")
        }

        // Fetch the OIDC provider
        guard let provider = try await OIDCProvider.query(on: req.db)
            .filter(\.$id == providerID)
            .filter(\.$organization.$id == organizationID)
            .with(\.$organization)
            .first() else {
            throw Abort(.notFound, reason: "OIDC provider not found")
        }

        do {
            // Exchange authorization code for tokens
            let tokenResponse = try await exchangeCodeForTokens(
                provider: provider,
                code: code,
                organizationID: organizationID,
                providerID: providerID,
                on: req
            )

            // Extract user information from ID token or userinfo endpoint
            let userInfo = try await extractUserInfo(
                tokenResponse: tokenResponse,
                provider: provider,
                nonce: req.session.data["oidc_nonce"],
                on: req
            )

            // Find or create user
            let user = try await findOrCreateUser(
                userInfo: userInfo,
                provider: provider,
                organization: provider.organization,
                on: req.db
            )

            // Clean up session data
            req.session.data["oidc_state"] = nil
            req.session.data["oidc_nonce"] = nil
            req.session.data["oidc_provider_id"] = nil
            req.session.data["oidc_organization_id"] = nil

            // Authenticate user
            req.auth.login(user)

            // Redirect to dashboard
            return Response(status: .seeOther, headers: HTTPHeaders([("Location", "/")]))

        } catch {
            req.logger.error("OIDC callback error: \(error)")

            // Clean up session data on error
            req.session.data["oidc_state"] = nil
            req.session.data["oidc_nonce"] = nil
            req.session.data["oidc_provider_id"] = nil
            req.session.data["oidc_organization_id"] = nil

            // Redirect to login with error
            return Response(status: .seeOther, headers: HTTPHeaders([("Location", "/login?error=oidc_failed")]))
        }
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
            req.logger.warning("Failed to fetch OIDC discovery document from discovery URL: \(error)")
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

        // Load allowed hosts and suffixes from environment/config, fallback to defaults
        let allowedHosts = OIDCValidation.allowedHosts()
        let allowedDomainSuffixes = OIDCValidation.allowedDomainSuffixes()

        let isHostAllowed = allowedHosts.contains(host) ||
                           allowedDomainSuffixes.contains { host.hasSuffix($0) }

        guard isHostAllowed else {
            throw Abort(.badRequest, reason: "Discovery URL host is not in the allowed list for security reasons. If you are an administrator, set OIDC_DISCOVERY_ALLOWED_HOSTS or OIDC_DISCOVERY_ALLOWED_SUFFIXES to allow this host.")
        }

        let response = try await req.client.get(URI(string: url))
        return try response.content.decode(OIDCDiscoveryDocument.self)
    }

    // MARK: - OIDC Authentication Helpers

    private func exchangeCodeForTokens(
        provider: OIDCProvider,
        code: String,
        organizationID: UUID,
        providerID: UUID,
        on req: Request
    ) async throws -> OIDCTokenResponse {
        guard let tokenEndpoint = provider.tokenEndpoint else {
            throw Abort(.internalServerError, reason: "Token endpoint not configured")
        }

        let baseURL = Environment.get("BASE_URL") ?? "http://localhost:8080"
        let redirectURI = "\(baseURL)/auth/oidc/\(organizationID)/\(providerID)/callback"

        let body = [
            "grant_type": "authorization_code",
            "client_id": provider.clientID,
            "client_secret": provider.clientSecret,
            "code": code,
            "redirect_uri": redirectURI
        ]

        let response = try await req.client.post(URI(string: tokenEndpoint)) { clientReq in
            try clientReq.content.encode(body, as: .urlEncodedForm)
        }

        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "Token exchange failed")
        }

        return try response.content.decode(OIDCTokenResponse.self)
    }

    private func extractUserInfo(
        tokenResponse: OIDCTokenResponse,
        provider: OIDCProvider,
        nonce: String?,
        on req: Request
    ) async throws -> OIDCUserInfo {
        // Validate ID token signature and claims
        let claims = try await validateIDToken(
            idToken: tokenResponse.idToken,
            provider: provider,
            expectedNonce: nonce,
            on: req
        )

        return OIDCUserInfo(
            subject: claims.sub,
            email: claims.email,
            name: claims.name ?? claims.preferredUsername,
            preferredUsername: claims.preferredUsername
        )
    }

    private func validateIDToken(
        idToken: String,
        provider: OIDCProvider,
        expectedNonce: String?,
        on req: Request
    ) async throws -> OIDCIDTokenClaims {
        // Parse JWT header to get key ID
        let tokenParts = idToken.split(separator: ".")
        guard tokenParts.count == 3 else {
            throw Abort(.badRequest, reason: "Invalid ID token format")
        }

        // Decode JWT header
        let headerData = try OIDCValidation.decodeBase64URLSafe(String(tokenParts[0]))
        let header = try JSONDecoder().decode(JWTHeader.self, from: headerData)

        // Get JWKS from provider
        guard let jwksURI = provider.jwksURI else {
            throw Abort(.internalServerError, reason: "JWKS URI not configured for provider")
        }

        let jwks = try await fetchJWKS(uri: jwksURI, on: req)
        
        // Find the matching key
        guard let jwk = jwks.keys.first(where: { $0.kid == header.kid && $0.kty == "RSA" }) else {
            throw Abort(.badRequest, reason: "Unable to find matching RSA key for ID token")
        }

        // Create RSA key for verification
        let rsaKey = try jwk.createRSAPublicKey()

        // Configure JWT signers and verify signature
        let signers = JWTSigners()
        signers.use(.rs256(key: rsaKey))
        
        // Verify JWT signature and decode claims
        let claims = try signers.verify(idToken, as: OIDCIDTokenClaims.self)

        // Additional claim validation
        try validateIDTokenClaims(claims, provider: provider, expectedNonce: expectedNonce)

        req.logger.info("Successfully validated JWT signature for OIDC token", metadata: [
            "provider_id": .string(provider.id?.uuidString ?? "unknown"),
            "subject": .string(claims.sub),
            "issuer": .string(claims.iss)
        ])

        return claims
    }

    private func fetchJWKS(uri: String, on req: Request) async throws -> JWKS {
        // Validate JWKS URI for security
        guard let url = URL(string: uri),
              let scheme = url.scheme,
              scheme == "https" else {
            throw Abort(.badRequest, reason: "JWKS URI must be HTTPS")
        }

        req.logger.debug("Fetching JWKS from URI", metadata: ["uri": .string(uri)])

        let response = try await req.client.get(URI(string: uri))
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "Failed to fetch JWKS from \(uri)")
        }

        return try response.content.decode(JWKS.self)
    }

    private func validateIDTokenClaims(
        _ claims: OIDCIDTokenClaims,
        provider: OIDCProvider,
        expectedNonce: String?
    ) throws {
        // Expiration and issued-at time validation is handled by JWTPayload.verify()
        
        // Validate audience (aud) - should match our client ID
        guard claims.aud == provider.clientID else {
            throw Abort(.badRequest, reason: "ID token audience '\(claims.aud)' does not match client ID '\(provider.clientID)'")
        }

        // Validate nonce if provided
        if let expectedNonce = expectedNonce, claims.nonce != expectedNonce {
            throw Abort(.badRequest, reason: "Invalid nonce in ID token")
        }

        // Additional issuer validation could be added here
        // For production, consider validating the issuer (iss) claim matches expected values
    }


    private func findOrCreateUser(
        userInfo: OIDCUserInfo,
        provider: OIDCProvider,
        organization: Organization,
        on db: Database
    ) async throws -> User {
        // Try to find existing user by OIDC subject and provider
        guard let providerID = provider.id else {
            throw Abort(.internalServerError, reason: "Provider ID is required")
        }
        if let existingUser = try await User.findOIDCUser(subject: userInfo.subject, providerID: providerID, on: db) {
            return existingUser
        }

        // Try to find user by email within the same organization
        if let email = userInfo.email {
            let usersWithEmail = try await User.query(on: db)
                .filter(\.$email == email)
                .with(\.$organizations)
                .all()

            for user in usersWithEmail {
                let userOrgIDs = user.organizations.compactMap { $0.id }
                guard let organizationID = organization.id else {
                    continue
                }
                if userOrgIDs.contains(organizationID) {
                    // Link existing user to OIDC provider
                    user.linkToOIDCProvider(providerID, subject: userInfo.subject)
                    try await user.save(on: db)
                    return user
                }
            }
        }

        // Create new user
        let username = userInfo.preferredUsername ?? userInfo.email ?? "oidc_\(userInfo.subject.prefix(8))"
        let displayName = userInfo.name ?? username
        let email = userInfo.email ?? ""

        let user = User(
            username: username,
            email: email,
            displayName: displayName,
            isSystemAdmin: false,
            oidcProviderID: providerID,
            oidcSubject: userInfo.subject
        )

        try await user.save(on: db)

        // Add user to organization as a member
        guard let userID = user.id,
              let organizationID = organization.id else {
            throw Abort(.internalServerError, reason: "User and organization IDs are required")
        }
        let membership = UserOrganization(
            userID: userID,
            organizationID: organizationID,
            role: "member"
        )
        try await membership.save(on: db)

        return user
    }

}
