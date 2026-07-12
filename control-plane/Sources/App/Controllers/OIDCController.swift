import Fluent
import SQLKit
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

        // Public SSO discovery for the login page: resolve an organization
        // name to its enabled providers without knowing the org UUID.
        routes.grouped("api", "public", "sso").get("lookup", use: lookupSSOProviders)
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

        // Claim mappings are authorization configuration; only admins see them.
        let isAdmin = await isOrganizationAdmin(req: req, organizationID: organizationID)
        return providers.map { OIDCProviderResponse(from: $0, includeClaimMappings: isAdmin) }
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

        // Validate claim-mapping configuration
        try await validateClaimMappingConfig(
            defaultRole: createRequest.defaultRole,
            groupMappings: createRequest.groupMappings,
            adminClaimValues: createRequest.adminClaimValues,
            organizationID: organizationID,
            on: req.db
        )

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
            enabled: createRequest.enabled ?? true,
            groupsClaim: normalizedGroupsClaim(createRequest.groupsClaim),
            groupMappings: createRequest.groupMappings ?? [],
            adminClaimValues: createRequest.adminClaimValues ?? [],
            defaultRole: createRequest.defaultRole ?? "member"
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
            let providerID = req.parameters.get("providerID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or provider ID")
        }

        try await verifyOrganizationAccess(req: req, organizationID: organizationID)

        guard
            let provider = try await OIDCProvider.query(on: req.db)
                .filter(\.$id == providerID)
                .filter(\.$organization.$id == organizationID)
                .first()
        else {
            throw Abort(.notFound, reason: "OIDC provider not found")
        }

        // Claim mappings are authorization configuration; only admins see them.
        let isAdmin = await isOrganizationAdmin(req: req, organizationID: organizationID)
        return OIDCProviderResponse(from: provider, includeClaimMappings: isAdmin)
    }

    func updateProvider(req: Request) async throws -> OIDCProviderResponse {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let providerID = req.parameters.get("providerID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or provider ID")
        }

        try await verifyOrganizationAdminAccess(req: req, organizationID: organizationID)

        guard
            let provider = try await OIDCProvider.query(on: req.db)
                .filter(\.$id == providerID)
                .filter(\.$organization.$id == organizationID)
                .first()
        else {
            throw Abort(.notFound, reason: "OIDC provider not found")
        }

        let updateRequest = try req.content.decode(UpdateOIDCProviderRequest.self)

        if let name = updateRequest.name { provider.name = name }
        if let clientID = updateRequest.clientID { provider.clientID = clientID }
        if let clientSecret = updateRequest.clientSecret { provider.clientSecret = clientSecret }
        // Optional URL fields: omitted keeps the stored value, an empty string
        // clears it. Without a clear path, a provider switched from discovery
        // to manual config would keep resending the stale discovery URL and
        // overwrite the manual endpoints on every subsequent edit.
        func applyOptionalURL(_ value: String?, to keyPath: ReferenceWritableKeyPath<OIDCProvider, String?>) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            provider[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
        }
        applyOptionalURL(updateRequest.discoveryURL, to: \.discoveryURL)
        applyOptionalURL(updateRequest.authorizationEndpoint, to: \.authorizationEndpoint)
        applyOptionalURL(updateRequest.tokenEndpoint, to: \.tokenEndpoint)
        applyOptionalURL(updateRequest.userinfoEndpoint, to: \.userinfoEndpoint)
        applyOptionalURL(updateRequest.jwksURI, to: \.jwksURI)

        // Any change to the discovery URL invalidates the stored issuer. If the
        // admin cleared discovery (switching to manual endpoints, possibly a
        // different issuer), the old discovered issuer must not linger and reject
        // the new issuer's tokens. If they rotated to a new discovery URL, the
        // refresh below repopulates the issuer — clearing it first means a failed
        // refresh falls back to "skip validation" rather than validating against
        // the previous issuer. A no-op edit (discoveryURL omitted) leaves it as-is.
        if updateRequest.discoveryURL != nil {
            provider.issuer = nil
        }
        if let scopes = updateRequest.scopes { provider.setScopesArray(scopes) }
        if let enabled = updateRequest.enabled { provider.enabled = enabled }

        try await validateClaimMappingConfig(
            defaultRole: updateRequest.defaultRole,
            groupMappings: updateRequest.groupMappings,
            adminClaimValues: updateRequest.adminClaimValues,
            organizationID: organizationID,
            on: req.db
        )
        // An empty string clears the groups claim (disables mapping).
        if let groupsClaim = updateRequest.groupsClaim {
            provider.groupsClaim = normalizedGroupsClaim(groupsClaim)
        }
        if let groupMappings = updateRequest.groupMappings { provider.setGroupMappingsArray(groupMappings) }
        if let adminClaimValues = updateRequest.adminClaimValues {
            provider.setAdminClaimValuesArray(adminClaimValues)
        }
        if let defaultRole = updateRequest.defaultRole { provider.defaultRole = defaultRole }

        // Same HTTPS validation the create path applies — the login flow posts
        // the client secret to the stored token endpoint, so an edit must not
        // be able to point it at an http:// or malformed URL.
        try OIDCValidation.validateURLFields(provider: provider)

        // The resulting configuration must still be loginable: either a
        // discovery URL, or the full manual endpoint set.
        let hasDiscovery = !(provider.discoveryURL ?? "").isEmpty
        guard hasDiscovery || provider.hasRequiredEndpoints() else {
            throw Abort(
                .badRequest,
                reason:
                    "Provider must keep either a discovery URL or all of authorization endpoint, token endpoint, and JWKS URI"
            )
        }

        try await provider.save(on: req.db)

        // Mirror creation: when a discovery URL is (re)submitted, refresh the
        // stored endpoints from its document. Without this, rotating to a new
        // issuer saves fine but logins keep using the previous issuer's
        // endpoints. Fetch failures are logged, not fatal, same as on create.
        if let discoveryURL = provider.discoveryURL, updateRequest.discoveryURL != nil, !discoveryURL.isEmpty {
            try await fetchAndUpdateProviderConfiguration(provider: provider, discoveryURL: discoveryURL, on: req)
        }

        return OIDCProviderResponse(from: provider)
    }

    func deleteProvider(req: Request) async throws -> HTTPStatus {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let providerID = req.parameters.get("providerID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or provider ID")
        }

        try await verifyOrganizationAdminAccess(req: req, organizationID: organizationID)

        guard
            let provider = try await OIDCProvider.query(on: req.db)
                .filter(\.$id == providerID)
                .filter(\.$organization.$id == organizationID)
                .first()
        else {
            throw Abort(.notFound, reason: "OIDC provider not found")
        }

        // Check if any users are linked to this provider
        let linkedUserCount = try await User.query(on: req.db)
            .filter(\.$oidcProvider.$id == providerID)
            .count()

        if linkedUserCount > 0 {
            throw Abort(
                .badRequest, reason: "Cannot delete provider: \(linkedUserCount) users are linked to this provider")
        }

        try await provider.delete(on: req.db)

        return .noContent
    }

    // MARK: - Provider Testing

    func testProvider(req: Request) async throws -> OIDCProviderTestResponse {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let providerID = req.parameters.get("providerID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or provider ID")
        }

        try await verifyOrganizationAdminAccess(req: req, organizationID: organizationID)

        guard
            let provider = try await OIDCProvider.query(on: req.db)
                .filter(\.$id == providerID)
                .filter(\.$organization.$id == organizationID)
                .first()
        else {
            throw Abort(.notFound, reason: "OIDC provider not found")
        }

        // Test the provider configuration by attempting to fetch discovery document
        if let discoveryURL = provider.discoveryURL, !discoveryURL.isEmpty {
            do {
                let discovery = try await fetchDiscoveryDocument(url: discoveryURL, on: req)
                // Discovered values get the same HTTPS validation as manual
                // ones before anything is stored or reported valid.
                try OIDCValidation.validateDiscoveredEndpoints(discovery)
                // Persist the discovered endpoints: the login flow builds its
                // redirect from the STORED fields, so a passing test must
                // leave them usable. This also heals providers whose create-
                // time discovery fetch failed non-fatally and stored nothing.
                provider.issuer = discovery.issuer
                provider.authorizationEndpoint = discovery.authorizationEndpoint
                provider.tokenEndpoint = discovery.tokenEndpoint
                provider.userinfoEndpoint = discovery.userinfoEndpoint
                provider.jwksURI = discovery.jwksURI
                try await provider.save(on: req.db)
                return OIDCProviderTestResponse(valid: true, message: "Provider configuration is valid")
            } catch let abort as AbortError {
                return OIDCProviderTestResponse(
                    valid: false, message: "Provider configuration test failed: \(abort.reason)")
            } catch {
                return OIDCProviderTestResponse(
                    valid: false, message: "Provider configuration test failed: \(error.localizedDescription)")
            }
        }

        // If no discovery URL, check that required endpoints are configured
        if provider.hasRequiredEndpoints() {
            return OIDCProviderTestResponse(valid: true, message: "Provider endpoints are configured")
        }
        return OIDCProviderTestResponse(
            valid: false,
            message:
                "Provider configuration is incomplete: authorization endpoint, token endpoint, and JWKS URI are required"
        )
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

    func lookupSSOProviders(req: Request) async throws -> SSOLookupResponse {
        guard
            let rawName = req.query[String.self, at: "organization"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawName.isEmpty
        else {
            throw Abort(.badRequest, reason: "Missing 'organization' query parameter")
        }

        // Case-insensitive name match. Exact match first; the fallback scan
        // keeps case-insensitivity portable across Postgres and the SQLite
        // test databases (org counts are small, so the scan is cheap).
        var organization = try await Organization.query(on: req.db)
            .filter(\.$name == rawName)
            .first()
        if organization == nil, let sql = req.db as? SQLDatabase {
            // Case-insensitive fallback done in SQL (LOWER works on both
            // Postgres and SQLite) with LIMIT 2 — enough to detect ambiguity
            // without scanning the org table on a public, unauthenticated
            // endpoint. Ambiguous matches (org names differing only by case)
            // must not route the user to an arbitrary tenant's IdP — exact
            // casing is required in that situation.
            let rows = try await sql.select()
                .column("id")
                .from(Organization.schema)
                .where(SQLFunction("LOWER", args: SQLColumn("name")), .equal, SQLBind(rawName.lowercased()))
                .limit(2)
                .all()
            if rows.count == 1 {
                let id = try rows[0].decode(column: "id", as: UUID.self)
                organization = try await Organization.find(id, on: req.db)
            }
        }

        guard let organization, let organizationID = organization.id else {
            return SSOLookupResponse(organizationID: nil, providers: [])
        }

        let providers = try await OIDCProvider.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$enabled == true)
            .all()

        // Indistinguishable from an unknown org so the endpoint doesn't
        // confirm which organization names exist.
        guard !providers.isEmpty else {
            return SSOLookupResponse(organizationID: nil, providers: [])
        }

        return SSOLookupResponse(
            organizationID: organizationID,
            providers: providers.map { OIDCProviderPublicResponse(from: $0) }
        )
    }

    // MARK: - Authentication Flow

    func initiateOIDCAuth(req: Request) async throws -> Response {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let providerID = req.parameters.get("providerID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or provider ID")
        }

        // Fetch the OIDC provider
        guard
            let provider = try await OIDCProvider.query(on: req.db)
                .filter(\.$id == providerID)
                .filter(\.$organization.$id == organizationID)
                .filter(\.$enabled == true)
                .first()
        else {
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
        guard
            let authURL = provider.getAuthorizationURL(
                redirectURI: redirectURI,
                state: state,
                nonce: nonce
            )
        else {
            throw Abort(.internalServerError, reason: "Failed to generate authorization URL")
        }

        return Response(status: .seeOther, headers: HTTPHeaders([("Location", authURL)]))
    }

    func handleOIDCCallback(req: Request) async throws -> Response {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let providerID = req.parameters.get("providerID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or provider ID")
        }

        // Extract query parameters
        let code = try req.query.get(String.self, at: "code")
        let state = try req.query.get(String.self, at: "state")

        // Verify state parameter for CSRF protection
        guard let sessionState = req.session.data["oidc_state"],
            state == sessionState
        else {
            throw Abort(.badRequest, reason: "Invalid state parameter")
        }

        // Verify session provider and organization match
        guard let sessionProviderID = req.session.data["oidc_provider_id"],
            let sessionOrgID = req.session.data["oidc_organization_id"],
            sessionProviderID == providerID.uuidString,
            sessionOrgID == organizationID.uuidString
        else {
            throw Abort(.badRequest, reason: "Session mismatch")
        }

        // Fetch the OIDC provider
        guard
            let provider = try await OIDCProvider.query(on: req.db)
                .filter(\.$id == providerID)
                .filter(\.$organization.$id == organizationID)
                .with(\.$organization)
                .first()
        else {
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

            // Resolve the user and converge identity/authz state with the
            // token's claims (issue #363).
            let identity = OIDCIdentityService(db: req.db, spicedb: try req.spicedb, logger: req.logger)

            let user = try await identity.resolveUser(
                userInfo: userInfo,
                provider: provider,
                organization: provider.organization,
                groupValues: userInfo.groupValues
            )

            // Clean up session data
            req.session.data["oidc_state"] = nil
            req.session.data["oidc_nonce"] = nil
            req.session.data["oidc_provider_id"] = nil
            req.session.data["oidc_organization_id"] = nil

            // Accounts disabled by an SSF signal must not get a session; the
            // middleware only sees authenticated requests, so check here too.
            // Thrown into the catch below, which records the failed login.
            // SCIM-deactivated users are denied the same way.
            try rejectDisabledAccount(user)
            try identity.enforceSCIMActive(user)

            // Sync IdP-managed group memberships and the org role from the
            // token's claims (after the deactivation checks: a denied user
            // must not have authz state written).
            try await identity.syncGroupMemberships(
                user: user,
                provider: provider,
                organizationID: organizationID,
                groupValues: userInfo.groupValues
            )
            try await identity.reconcileOrganizationRole(
                user: user,
                provider: provider,
                organizationID: organizationID,
                groupValues: userInfo.groupValues
            )

            // Authenticate user
            req.auth.login(user)
            req.stampSessionEpoch(for: user)
            await req.recordAuthEvent(.oidcLogin, user: user, organizationID: organizationID)

            // Redirect to dashboard
            return Response(status: .seeOther, headers: HTTPHeaders([("Location", "/")]))

        } catch {
            req.logger.error("OIDC callback error: \(error)")
            await req.recordAuthEvent(
                .oidcLoginFailed, organizationID: organizationID, metadata: ["error": "\(error)"])

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
            return  // System admins can manage all organizations
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

    /// Non-throwing variant of `verifyOrganizationAdminAccess` for read paths
    /// that stay member-accessible but redact admin-only detail.
    private func isOrganizationAdmin(req: Request, organizationID: UUID) async -> Bool {
        do {
            try await verifyOrganizationAdminAccess(req: req, organizationID: organizationID)
            return true
        } catch {
            return false
        }
    }

    private func validateProviderConfiguration(
        _ request: CreateOIDCProviderRequest, on database: Database, organizationID: UUID
    ) async throws {
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

        // If no discovery URL, check for required individual endpoints. JWKS
        // is mandatory for manual configs: the login callback refuses to
        // validate ID tokens without it, so a provider that passes creation
        // without JWKS would fail every SSO login.
        guard let authEndpoint = request.authorizationEndpoint, !authEndpoint.isEmpty,
            let tokenEndpoint = request.tokenEndpoint, !tokenEndpoint.isEmpty,
            let jwksURI = request.jwksURI, !jwksURI.isEmpty
        else {
            throw Abort(
                .badRequest,
                reason:
                    "Either a discovery URL or all of authorization endpoint, token endpoint, and JWKS URI must be provided"
            )
        }
    }

    private func fetchAndUpdateProviderConfiguration(provider: OIDCProvider, discoveryURL: String, on req: Request)
        async throws
    {
        do {
            let discovery = try await fetchDiscoveryDocument(url: discoveryURL, on: req)

            // Same HTTPS validation as manual fields — checked before any
            // assignment so a bad document leaves the provider untouched.
            try OIDCValidation.validateDiscoveredEndpoints(discovery)

            // Update provider with discovered endpoints
            provider.issuer = discovery.issuer
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
            parsedURL.scheme == "https"
        else {
            throw Abort(.badRequest, reason: "Discovery URL must be a valid HTTPS URL")
        }

        // Load allowed hosts and suffixes from environment/config, fallback to defaults
        let allowedHosts = OIDCValidation.allowedHosts()
        let allowedDomainSuffixes = OIDCValidation.allowedDomainSuffixes()

        let isHostAllowed = allowedHosts.contains(host) || allowedDomainSuffixes.contains { host.hasSuffix($0) }

        guard isHostAllowed else {
            throw Abort(
                .badRequest,
                reason:
                    "Discovery URL host is not in the allowed list for security reasons. If you are an administrator, set OIDC_DISCOVERY_ALLOWED_HOSTS or OIDC_DISCOVERY_ALLOWED_SUFFIXES to allow this host."
            )
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
            "redirect_uri": redirectURI,
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

        // The groups claim name is configurable per provider, so it is read
        // from the (already verified) token payload rather than decoded into
        // the fixed claims struct.
        var groupValues: [String] = []
        if let groupsClaim = provider.groupsClaim {
            groupValues = try OIDCIdentityService.extractGroupClaimValues(
                idToken: tokenResponse.idToken,
                claim: groupsClaim
            )
        }

        return OIDCUserInfo(
            subject: claims.sub,
            email: claims.email,
            // Absent claim is treated as unverified (fail closed).
            emailVerified: claims.emailVerified ?? false,
            name: claims.name ?? claims.preferredUsername,
            preferredUsername: claims.preferredUsername,
            groupValues: groupValues
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

        req.logger.info(
            "Successfully validated JWT signature for OIDC token",
            metadata: [
                "provider_id": .string(provider.id?.uuidString ?? "unknown"),
                "subject": .string(claims.sub),
                "issuer": .string(claims.iss),
            ])

        return claims
    }

    private func fetchJWKS(uri: String, on req: Request) async throws -> JWKS {
        // Validate JWKS URI for security
        guard let url = URL(string: uri),
            let scheme = url.scheme,
            scheme == "https"
        else {
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

        // Validate issuer (iss). The OIDC spec requires the token's issuer to
        // match the provider's known issuer; skipping it lets a token minted by a
        // different issuer that shares the same JWKS/audience (e.g. another tenant
        // on a multi-tenant IdP) be accepted. `issuer` is populated from the
        // discovery document; when it's unknown (a provider configured with manual
        // endpoints and no discovery) we can't validate and leave it to the other
        // checks, but a discovery-configured provider always has it.
        if let expectedIssuer = provider.issuer, !expectedIssuer.isEmpty {
            guard claims.iss == expectedIssuer else {
                throw Abort(
                    .badRequest,
                    reason: "ID token issuer '\(claims.iss)' does not match expected issuer '\(expectedIssuer)'"
                )
            }
        }

        // Validate audience (aud) - should match our client ID
        guard claims.aud == provider.clientID else {
            throw Abort(
                .badRequest, reason: "ID token audience '\(claims.aud)' does not match client ID '\(provider.clientID)'"
            )
        }

        // Validate nonce if provided
        if let expectedNonce = expectedNonce, claims.nonce != expectedNonce {
            throw Abort(.badRequest, reason: "Invalid nonce in ID token")
        }
    }

    // MARK: - Claim Mapping Configuration

    /// Treat an empty groups claim as "not configured".
    private func normalizedGroupsClaim(_ claim: String?) -> String? {
        guard let claim = claim?.trimmingCharacters(in: .whitespacesAndNewlines), !claim.isEmpty else {
            return nil
        }
        return claim
    }

    /// Validate the claim-mapping fields of a create/update request: the
    /// default role must be a known org role, admin claim values must not be
    /// blank, and every group mapping must reference a group in the
    /// provider's organization.
    private func validateClaimMappingConfig(
        defaultRole: String?,
        groupMappings: [OIDCGroupMapping]?,
        adminClaimValues: [String]?,
        organizationID: UUID,
        on db: Database
    ) async throws {
        if let defaultRole = defaultRole {
            guard ["member", "admin"].contains(defaultRole) else {
                throw Abort(.badRequest, reason: "Default role must be 'member' or 'admin'")
            }
        }

        // A blank value would flip role reconciliation into authoritative
        // mode ("adminClaimValues is non-empty") while matching no real
        // token, silently demoting every admin on their next login.
        if let adminClaimValues = adminClaimValues {
            for value in adminClaimValues {
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Abort(.badRequest, reason: "Admin claim values must not be empty")
                }
            }
        }

        guard let groupMappings = groupMappings, !groupMappings.isEmpty else { return }

        for mapping in groupMappings {
            guard !mapping.claimValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Abort(.badRequest, reason: "Group mapping claim values must not be empty")
            }
        }

        let groupIDs = Set(groupMappings.map { $0.groupID })
        let orgGroupCount = try await Group.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$id ~~ Array(groupIDs))
            .count()
        guard orgGroupCount == groupIDs.count else {
            throw Abort(.badRequest, reason: "Group mappings must reference groups in this organization")
        }
    }

}
