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
        let allowedHosts = Self.getAllowedOIDCHosts(from: req.application.environment)
        let allowedDomainSuffixes = Self.getAllowedOIDCDomainSuffixes(from: req.application.environment)

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
        // For now, we'll extract basic info from the ID token
        // In a full implementation, we would validate the JWT signature
        let idTokenParts = tokenResponse.idToken.split(separator: ".")
        guard idTokenParts.count >= 2 else {
            throw Abort(.badRequest, reason: "Invalid ID token format")
        }

        let payload = String(idTokenParts[1])
        let paddedPayload = payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard let data = Data(base64Encoded: paddedPayload) else {
            throw Abort(.badRequest, reason: "Invalid ID token payload")
        }

        let claims = try JSONDecoder().decode(OIDCIDTokenClaims.self, from: data)

        // Validate nonce if provided
        if let expectedNonce = nonce, claims.nonce != expectedNonce {
            throw Abort(.badRequest, reason: "Invalid nonce in ID token")
        }

        return OIDCUserInfo(
            subject: claims.sub,
            email: claims.email,
            name: claims.name ?? claims.preferredUsername,
            preferredUsername: claims.preferredUsername
        )
    }

    private func findOrCreateUser(
        userInfo: OIDCUserInfo,
        provider: OIDCProvider,
        organization: Organization,
        on db: Database
    ) async throws -> User {
        // Try to find existing user by OIDC subject and provider
        if let existingUser = try await User.findOIDCUser(subject: userInfo.subject, providerID: provider.id!, on: db) {
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
                if userOrgIDs.contains(organization.id!) {
                    // Link existing user to OIDC provider
                    user.linkToOIDCProvider(provider.id!, subject: userInfo.subject)
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
            oidcProviderID: provider.id!,
            oidcSubject: userInfo.subject
        )

        try await user.save(on: db)

        // Add user to organization as a member
        let membership = UserOrganization(
            userID: user.id!,
            organizationID: organization.id!,
            role: "member"
        )
        try await membership.save(on: db)

        return user
    }

    // MARK: - OIDC Allowlist Helpers
    private static func getAllowedOIDCHosts(from env: Environment) -> Set<String> {
        if let hostsString = Environment.get("OIDC_DISCOVERY_ALLOWED_HOSTS") {
            // Comma or semicolon separated
            let hosts = hostsString
                .split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Set(hosts)
        } else {
            // Default hosts
            return [
                "accounts.google.com",
                "login.microsoftonline.com",
                "login.salesforce.com",
                "auth0.com",
                "okta.com",
                "oauth.reddit.com",
                "github.com",
                "gitlab.com"
            ]
        }
    }

    private static func getAllowedOIDCDomainSuffixes(from env: Environment) -> [String] {
        if let suffixesString = Environment.get("OIDC_DISCOVERY_ALLOWED_SUFFIXES") {
            // Comma or semicolon separated
            let suffixes = suffixesString
                .split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return suffixes
        } else {
            // Default suffixes
            return [
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
        }
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

// MARK: - OIDC Authentication Data Structures

struct OIDCTokenResponse: Content {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int?
    let refreshToken: String?
    let idToken: String

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
    }
}

struct OIDCIDTokenClaims: Content {
    let iss: String // Issuer
    let sub: String // Subject
    let aud: String // Audience
    let exp: Int    // Expiration time
    let iat: Int    // Issued at
    let nonce: String?
    let email: String?
    let name: String?
    let preferredUsername: String?

    private enum CodingKeys: String, CodingKey {
        case iss, sub, aud, exp, iat, nonce, email, name
        case preferredUsername = "preferred_username"
    }
}

struct OIDCUserInfo {
    let subject: String
    let email: String?
    let name: String?
    let preferredUsername: String?
}
