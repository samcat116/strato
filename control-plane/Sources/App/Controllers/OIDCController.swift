import ControlPlanePostgres
import Vapor
import JWT
import Crypto
import Foundation

struct OIDCController: RouteCollection {
    private let providers: OIDCProvidersPersistence
    private let groups: GroupsPersistence
    private let externalIDs: SCIMExternalIDsPersistence
    private let hierarchy: HierarchyPersistence
    private let users: UserDirectoryPersistence
    private let iam: IAMPersistence

    init(
        providers: OIDCProvidersPersistence,
        groups: GroupsPersistence,
        externalIDs: SCIMExternalIDsPersistence,
        hierarchy: HierarchyPersistence,
        users: UserDirectoryPersistence,
        iam: IAMPersistence
    ) {
        self.providers = providers
        self.groups = groups
        self.externalIDs = externalIDs
        self.hierarchy = hierarchy
        self.users = users
        self.iam = iam
    }

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

        let providers = try await providers.providers(organizationID: organizationID)

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
        try await validateProviderConfiguration(createRequest, organizationID: organizationID)

        // Validate URL fields
        try OIDCValidation.validateURLFields(request: createRequest)

        // Validate claim-mapping configuration
        try await validateClaimMappingConfig(
            defaultRoleID: createRequest.defaultRoleID,
            groupMappings: createRequest.groupMappings,
            adminClaimValues: createRequest.adminClaimValues,
            roleMappings: createRequest.roleMappings,
            organizationID: organizationID
        )

        var provider = try await providers.create(OIDCProviderWrite(
            organizationID: organizationID,
            name: createRequest.name,
            clientID: createRequest.clientID,
            encryptedClientSecret: try req.secretsEncryption.encrypt(createRequest.clientSecret),
            discoveryURL: createRequest.discoveryURL,
            authorizationEndpoint: createRequest.authorizationEndpoint,
            tokenEndpoint: createRequest.tokenEndpoint,
            userinfoEndpoint: createRequest.userinfoEndpoint,
            jwksURI: createRequest.jwksURI,
            endSessionEndpoint: createRequest.endSessionEndpoint,
            scopes: createRequest.scopes ?? ["openid", "profile", "email"],
            enabled: createRequest.enabled ?? true,
            useNonce: createRequest.useNonce ?? true,
            groupsClaim: normalizedGroupsClaim(createRequest.groupsClaim),
            groupMappings: (createRequest.groupMappings ?? []).map(\.persistenceValue),
            adminClaimValues: createRequest.adminClaimValues ?? [],
            roleMappings: (createRequest.roleMappings ?? []).map(\.persistenceValue),
            defaultRoleID: createRequest.defaultRoleID
        ))

        // If discovery URL is provided, attempt to fetch configuration.
        // discoveryChanged is false here: omission-clearing exists to purge
        // endpoints left over from a *previous* IdP configuration, and at
        // create time every stored value came from this very request — an
        // explicitly supplied optional endpoint (e.g. a manual logout URL for
        // an IdP whose metadata omits end_session_endpoint) must survive the
        // initial discovery fetch.
        if let discoveryURL = createRequest.discoveryURL, !discoveryURL.isEmpty {
            provider = try await fetchAndUpdateProviderConfiguration(
                provider: provider, discoveryURL: discoveryURL, discoveryChanged: false, on: req)
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

        guard let provider = try await providers.ownedProvider(id: providerID, organizationID: organizationID) else {
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

        guard let existing = try await providers.ownedProvider(id: providerID, organizationID: organizationID) else {
            throw Abort(.notFound, reason: "OIDC provider not found")
        }

        let updateRequest = try req.content.decode(UpdateOIDCProviderRequest.self)
        var provider = OIDCProviderDraft(existing)

        if let name = updateRequest.name { provider.name = name }
        if let clientID = updateRequest.clientID { provider.clientID = clientID }
        if let clientSecret = updateRequest.clientSecret {
            provider.encryptedClientSecret = try req.secretsEncryption.encrypt(clientSecret)
        }
        // Optional URL fields: omitted keeps the stored value, an empty string
        // clears it. Without a clear path, a provider switched from discovery
        // to manual config would keep resending the stale discovery URL and
        // overwrite the manual endpoints on every subsequent edit.
        func applyOptionalURL(_ value: String?, to keyPath: WritableKeyPath<OIDCProviderDraft, String?>) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            provider[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
        }
        // Captured before the update lands so the refresh below can tell a
        // same-value resubmit (the edit form always sends every URL field)
        // from a real change.
        let previousDiscoveryURL = provider.discoveryURL
        let previousUserinfoEndpoint = provider.userinfoEndpoint
        let previousEndSessionEndpoint = provider.endSessionEndpoint
        applyOptionalURL(updateRequest.discoveryURL, to: \.discoveryURL)
        applyOptionalURL(updateRequest.authorizationEndpoint, to: \.authorizationEndpoint)
        applyOptionalURL(updateRequest.tokenEndpoint, to: \.tokenEndpoint)
        applyOptionalURL(updateRequest.userinfoEndpoint, to: \.userinfoEndpoint)
        applyOptionalURL(updateRequest.jwksURI, to: \.jwksURI)
        applyOptionalURL(updateRequest.endSessionEndpoint, to: \.endSessionEndpoint)

        // Clear the stored issuer only when discovery is being *removed* (switching
        // to manual endpoints, possibly a different issuer) — a lingering discovered
        // issuer would reject the new manual issuer's tokens. When a discovery URL
        // is kept or rotated, leave the existing issuer in place: the refresh below
        // overwrites it on success, and on a transient fetch failure the provider
        // keeps its prior endpoints AND issuer (a consistent old-config state)
        // rather than silently disabling the iss check.
        if (provider.discoveryURL ?? "").isEmpty {
            provider.issuer = nil
        }
        if let scopes = updateRequest.scopes { provider.scopes = scopes }
        if let enabled = updateRequest.enabled { provider.enabled = enabled }
        if let useNonce = updateRequest.useNonce { provider.useNonce = useNonce }

        try await validateClaimMappingConfig(
            defaultRoleID: updateRequest.defaultRoleID,
            groupMappings: updateRequest.groupMappings,
            adminClaimValues: updateRequest.adminClaimValues,
            roleMappings: updateRequest.roleMappings,
            organizationID: organizationID
        )
        // An empty string clears the groups claim (disables mapping).
        if let groupsClaim = updateRequest.groupsClaim {
            provider.groupsClaim = normalizedGroupsClaim(groupsClaim)
        }
        if let groupMappings = updateRequest.groupMappings {
            provider.groupMappings = groupMappings.map(\.persistenceValue)
        }
        if let adminClaimValues = updateRequest.adminClaimValues {
            provider.adminClaimValues = adminClaimValues
        }
        if let roleMappings = updateRequest.roleMappings {
            provider.roleMappings = roleMappings.map(\.persistenceValue)
        }
        if updateRequest.updatesDefaultRoleID { provider.defaultRoleID = updateRequest.defaultRoleID }

        // Same HTTPS validation the create path applies — the login flow posts
        // the client secret to the stored token endpoint, so an edit must not
        // be able to point it at an http:// or malformed URL.
        try OIDCValidation.validateURLFields(provider: provider)

        // The resulting configuration must still be loginable: either a
        // discovery URL, or the full manual endpoint set.
        let hasDiscovery = !(provider.discoveryURL ?? "").isEmpty
        guard hasDiscovery || provider.hasRequiredEndpoints else {
            throw Abort(
                .badRequest,
                reason:
                    "Provider must keep either a discovery URL or all of authorization endpoint, token endpoint, and JWKS URI"
            )
        }

        guard var persisted = try await providers.replace(provider.write) else {
            throw Abort(.notFound, reason: "OIDC provider not found")
        }

        // Mirror creation: when a discovery URL is (re)submitted, refresh the
        // stored endpoints from its document. Without this, rotating to a new
        // issuer saves fine but logins keep using the previous issuer's
        // endpoints. Fetch failures are logged, not fatal, same as on create.
        if let discoveryURL = persisted.discoveryURL, updateRequest.discoveryURL != nil, !discoveryURL.isEmpty {
            // A field this request set to a NEW non-empty value is an explicit
            // manual fallback and survives metadata omission; an unchanged
            // resubmitted form value is not explicit, so a discovery change
            // still purges it (it may belong to the previous IdP).
            persisted = try await fetchAndUpdateProviderConfiguration(
                provider: persisted, discoveryURL: discoveryURL,
                discoveryChanged: discoveryURL != previousDiscoveryURL,
                explicitUserinfoEndpoint: persisted.userinfoEndpoint != nil
                    && persisted.userinfoEndpoint != previousUserinfoEndpoint,
                explicitEndSessionEndpoint: persisted.endSessionEndpoint != nil
                    && persisted.endSessionEndpoint != previousEndSessionEndpoint,
                on: req)
        }

        return OIDCProviderResponse(from: persisted)
    }

    func deleteProvider(req: Request) async throws -> HTTPStatus {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let providerID = req.parameters.get("providerID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or provider ID")
        }

        try await verifyOrganizationAdminAccess(req: req, organizationID: organizationID)

        switch try await providers.deleteIfUnused(id: providerID, organizationID: organizationID) {
        case .notFound:
            throw Abort(.notFound, reason: "OIDC provider not found")
        case .inUse(let linkedUserCount):
            throw Abort(
                .badRequest, reason: "Cannot delete provider: \(linkedUserCount) users are linked to this provider")
        case .deleted:
            return .noContent
        }
    }

    // MARK: - Provider Testing

    func testProvider(req: Request) async throws -> OIDCProviderTestResponse {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let providerID = req.parameters.get("providerID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or provider ID")
        }

        try await verifyOrganizationAdminAccess(req: req, organizationID: organizationID)

        guard var provider = try await providers.ownedProvider(id: providerID, organizationID: organizationID) else {
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
                var draft = OIDCProviderDraft(provider)
                applyDiscoveredConfiguration(discovery, to: &draft, discoveryChanged: false)
                guard let refreshed = try await providers.replace(draft.write) else {
                    throw Abort(.notFound, reason: "OIDC provider not found")
                }
                provider = refreshed
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
        if provider.hasRequiredEndpoints {
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

        let providers = try await providers.providers(organizationID: organizationID, enabledOnly: true)

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

        // Case-insensitive name match. Exact match first, then a fallback scan
        // (org counts are small, so the scan is cheap).
        let organizations = try await hierarchy.allOrganizations()
        let exact = organizations.first { $0.name == rawName }
        let folded = organizations.filter {
            $0.name.caseInsensitiveCompare(rawName) == .orderedSame
        }
        guard let organization = exact ?? (folded.count == 1 ? folded[0] : nil) else {
            return SSOLookupResponse(organizationID: nil, providers: [])
        }
        let organizationID = organization.id

        let providers = try await providers.providers(organizationID: organizationID, enabledOnly: true)

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
        guard let provider = try await providers.ownedProvider(id: providerID, organizationID: organizationID),
            provider.enabled
        else {
            throw Abort(.notFound, reason: "OIDC provider not found or disabled")
        }

        // Generate state and nonce for security, and a PKCE verifier (RFC
        // 7636) binding the authorization code to this session. S256 is sent
        // unconditionally: authorization servers ignore unknown parameters,
        // so providers without PKCE support are unaffected, and those with it
        // get code-interception protection.
        let state = UUID().uuidString
        // Only mint a nonce for providers that echo it back. When disabled we
        // send none and store none, so the callback's nonce check is skipped
        // (see the provider's `useNonce`; e.g. Discord never returns the nonce).
        let nonce = provider.useNonce ? UUID().uuidString : nil
        let codeVerifier = OIDCValidation.generateCodeVerifier()

        // Store state, nonce, and PKCE verifier in session for the callback.
        // Assign the nonce unconditionally: a nil nonce (useNonce == false) must
        // CLEAR any stale nonce a prior abandoned nonce-requiring login left in
        // this same session, otherwise the callback would validate this
        // nonce-less flow against it and reject a valid token.
        req.session.data["oidc_state"] = state
        req.session.data["oidc_nonce"] = nonce
        req.session.data["oidc_code_verifier"] = codeVerifier
        req.session.data["oidc_provider_id"] = providerID.uuidString
        req.session.data["oidc_organization_id"] = organizationID.uuidString

        // Build redirect URI
        let redirectURI = try oidcRedirectURI(
            organizationID: organizationID, providerID: providerID, on: req)

        // Generate authorization URL
        guard
            let authURL = provider.getAuthorizationURL(
                redirectURI: redirectURI,
                state: state,
                nonce: nonce,
                codeChallenge: OIDCValidation.codeChallengeS256(for: codeVerifier),
                codeChallengeMethod: "S256"
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
        guard let provider = try await providers.ownedProvider(id: providerID, organizationID: organizationID),
            let organization = try await hierarchy.organization(id: organizationID)
        else {
            throw Abort(.notFound, reason: "OIDC provider not found")
        }

        do {
            // Exchange authorization code for tokens. The PKCE verifier is
            // optional only to tolerate flows initiated before a deploy that
            // introduced PKCE: such flows sent no code_challenge, so sending
            // no code_verifier is the matching (and only valid) behavior.
            let tokenResponse = try await exchangeCodeForTokens(
                provider: provider,
                code: code,
                codeVerifier: req.session.data["oidc_code_verifier"],
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
            let identity = OIDCIdentityService(
                providers: providers,
                groups: groups,
                externalIDs: externalIDs,
                users: users,
                hierarchy: hierarchy,
                iam: iam,
                logger: req.logger
            )

            let user = try await identity.resolveUser(
                userInfo: userInfo,
                provider: provider,
                organization: organization,
                groupValues: userInfo.groupValues
            )

            // Clean up session data
            req.session.data["oidc_state"] = nil
            req.session.data["oidc_nonce"] = nil
            req.session.data["oidc_code_verifier"] = nil
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

            // Retain what RP-initiated logout needs: the provider that issued
            // this session and the raw ID token (sent as id_token_hint so the
            // IdP can end its session without prompting). Distinct keys from
            // the flow-scoped oidc_* values cleared above — these live for
            // the whole login session.
            req.session.data["oidc_login_provider_id"] = providerID.uuidString
            req.session.data["oidc_login_id_token"] = tokenResponse.idToken
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
            req.session.data["oidc_code_verifier"] = nil
            req.session.data["oidc_provider_id"] = nil
            req.session.data["oidc_organization_id"] = nil

            // Redirect to login with error
            return Response(status: .seeOther, headers: HTTPHeaders([("Location", "/login?error=oidc_failed")]))
        }
    }

    // MARK: - Helper Methods

    // Provider management goes through the Cedar evaluator like every other
    // org-scoped surface (issue #482 pre-cutover audit: the inline relational
    // reads here were allow decisions invisible to the decision log). Only the
    // error messages remain OIDC-specific. Managing a provider is org
    // administration — it maps to `org:update` rather than growing an
    // `oidc:*` action family.

    private func verifyOrganizationAccess(req: Request, organizationID: UUID) async throws {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }
        guard try await req.can("org:read", on: IAMNode(type: .organization, id: organizationID)) else {
            throw Abort(.forbidden, reason: "Access denied to organization")
        }
    }

    private func verifyOrganizationAdminAccess(req: Request, organizationID: UUID) async throws {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }
        guard try await req.can("org:update", on: IAMNode(type: .organization, id: organizationID)) else {
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
        _ request: CreateOIDCProviderRequest, organizationID: UUID
    ) async throws {
        // Check for duplicate provider names within the organization
        let existingProvider = try await providers.providerNamed(request.name, organizationID: organizationID)

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

    /// Copies a validated discovery document onto the provider. The required
    /// metadata fields always overwrite; the OPTIONAL ones (userinfo and
    /// end-session endpoints) follow the rules in the body: preserved across a
    /// same-config refresh, cleared when the provider is repointed at a
    /// different IdP. `discoveryChanged` is the caller's knowledge of whether
    /// the discovery URL itself was newly added or changed.
    func applyDiscoveredConfiguration(
        _ discovery: OIDCDiscoveryDocument, to provider: inout OIDCProviderDraft, discoveryChanged: Bool,
        explicitUserinfoEndpoint: Bool = false, explicitEndSessionEndpoint: Bool = false
    ) {
        // Optional endpoints the document omits are cleared when the provider
        // is pointing at a (possibly) different IdP — a stale userinfo or
        // logout URL would receive the new IdP's access token or redirect
        // users to the old provider. That's the case when the discovery URL
        // was newly added or changed (covers manual→discovery switches, where
        // no stored issuer exists to compare) or when the discovered issuer
        // differs from the stored one. Exceptions that preserve a value the
        // metadata omits: a same-URL, same-issuer refresh (the edit form
        // resubmitting an unchanged config), and a field the same request
        // explicitly set to a NEW value (`explicit*` — the admin deliberately
        // supplied a fallback for metadata they know is incomplete; a
        // resubmitted unchanged form value does not count as explicit).
        let issuerChanged = provider.issuer != nil && provider.issuer != discovery.issuer
        let clearOmittedOptionals = discoveryChanged || issuerChanged
        provider.issuer = discovery.issuer
        provider.authorizationEndpoint = discovery.authorizationEndpoint
        provider.tokenEndpoint = discovery.tokenEndpoint
        provider.jwksURI = discovery.jwksURI
        // The allow-listed discovery host vouches for the endpoint hosts it
        // names, so they become fetchable for this provider only (Google serves
        // JWKS from www.googleapis.com, not accounts.google.com). Recorded from
        // the document itself, never from a manually-set endpoint.
        provider.discoveredHosts = [discovery.tokenEndpoint, discovery.userinfoEndpoint, discovery.jwksURI]
            .compactMap { $0 }
            .compactMap { URL(string: $0)?.host?.lowercased() }
        if discovery.userinfoEndpoint != nil {
            provider.userinfoEndpoint = discovery.userinfoEndpoint
        } else if clearOmittedOptionals && !explicitUserinfoEndpoint {
            provider.userinfoEndpoint = nil
        }
        if discovery.endSessionEndpoint != nil {
            provider.endSessionEndpoint = discovery.endSessionEndpoint
        } else if clearOmittedOptionals && !explicitEndSessionEndpoint {
            provider.endSessionEndpoint = nil
        }
    }

    private func fetchAndUpdateProviderConfiguration(
        provider: OIDCProviderSnapshot, discoveryURL: String, discoveryChanged: Bool,
        explicitUserinfoEndpoint: Bool = false, explicitEndSessionEndpoint: Bool = false,
        on req: Request
    ) async throws -> OIDCProviderSnapshot {
        do {
            let discovery = try await fetchDiscoveryDocument(url: discoveryURL, on: req)

            // Same HTTPS validation as manual fields — checked before any
            // assignment so a bad document leaves the provider untouched.
            try OIDCValidation.validateDiscoveredEndpoints(discovery)

            var draft = OIDCProviderDraft(provider)
            applyDiscoveredConfiguration(
                discovery, to: &draft, discoveryChanged: discoveryChanged,
                explicitUserinfoEndpoint: explicitUserinfoEndpoint,
                explicitEndSessionEndpoint: explicitEndSessionEndpoint)

            guard let refreshed = try await providers.replace(draft.write) else {
                throw Abort(.notFound, reason: "OIDC provider not found")
            }
            return refreshed
        } catch {
            req.logger.warning("Failed to fetch OIDC discovery document from discovery URL: \(error)")
            // Don't fail the creation if discovery fails, just log the warning
            return provider
        }
    }

    private func fetchDiscoveryDocument(url: String, on req: Request) async throws -> OIDCDiscoveryDocument {
        // Two gates, not either/or. The allow-list is a name-based root of trust
        // the address classifier cannot express (only these IdPs may be talked
        // to at all); the guarded client then classifies the address the name
        // actually resolves to and pins the connection to it, so an allow-listed
        // host that resolves — or rebinds — to an internal address is refused.
        try OIDCValidation.validateAllowedFetchURL(
            url, label: "Discovery URL", configuration: req.controlPlaneConfiguration)

        let response = try await req.guardedHTTPClient.send(
            ClientRequest(method: .GET, url: URI(string: url)))
        return try response.content.decode(OIDCDiscoveryDocument.self)
    }

    // MARK: - OIDC Authentication Helpers

    /// Builds the OIDC callback URI from the deployment's public base URL.
    /// Throws in production when BASE_URL is unset — see
    /// `OIDCValidation.resolveBaseURL`.
    private func oidcRedirectURI(organizationID: UUID, providerID: UUID, on req: Request) throws -> String {
        let baseURL = try OIDCValidation.resolveBaseURL(
            configured: req.controlPlaneConfiguration.string(.baseURL),
            environment: req.application.environment
        )
        return "\(baseURL)/auth/oidc/\(organizationID)/\(providerID)/callback"
    }

    private func exchangeCodeForTokens(
        provider: OIDCProviderSnapshot,
        code: String,
        codeVerifier: String?,
        organizationID: UUID,
        providerID: UUID,
        on req: Request
    ) async throws -> OIDCTokenResponse {
        guard let tokenEndpoint = provider.tokenEndpoint else {
            throw Abort(.internalServerError, reason: "Token endpoint not configured")
        }

        // Same two gates as the discovery fetch: the stored endpoint may have
        // been set manually or copied from a discovery document. A manually-set
        // host still has to satisfy the global allow-list, and the guarded
        // client below still has to approve the address it resolves to — this
        // request carries the provider's decrypted client secret.
        try OIDCValidation.validateAllowedFetchURL(
            tokenEndpoint,
            label: "Token endpoint",
            perProviderHosts: provider.discoveredHostSet,
            configuration: req.controlPlaneConfiguration)

        let redirectURI = try oidcRedirectURI(
            organizationID: organizationID, providerID: providerID, on: req)

        var body = [
            "grant_type": "authorization_code",
            "client_id": provider.clientID,
            "client_secret": try req.secretsEncryption.decrypt(provider.encryptedClientSecret),
            "code": code,
            "redirect_uri": redirectURI,
        ]
        if let codeVerifier {
            body["code_verifier"] = codeVerifier
        }

        var request = ClientRequest(method: .POST, url: URI(string: tokenEndpoint))
        try request.content.encode(body, as: .urlEncodedForm)
        let response = try await req.guardedHTTPClient.send(request)

        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "Token exchange failed")
        }

        return try response.content.decode(OIDCTokenResponse.self)
    }

    private func extractUserInfo(
        tokenResponse: OIDCTokenResponse,
        provider: OIDCProviderSnapshot,
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

        // Some IdPs return `email` in the ID token but only assert
        // `email_verified` in the UserInfo response, and some (e.g. Discord)
        // put only `sub` in the ID token and return every profile claim from
        // UserInfo. Consult the endpoint whenever the ID token leaves a gap so
        // a legitimate first login isn't blocked or created as an anonymous
        // `oidc_<subject>` user. Only its claims for the same subject are
        // trusted (OIDC 5.3.2).
        var userInfo: OIDCUserInfoResponse?
        let idTokenIncomplete =
            claims.emailVerified != true || claims.email == nil || claims.name == nil
            || claims.preferredUsername == nil
        if idTokenIncomplete, let endpoint = provider.userinfoEndpoint, !endpoint.isEmpty {
            if let info = try? await fetchUserInfo(
                endpoint: endpoint, accessToken: tokenResponse.accessToken, provider: provider, on: req),
                info.sub == claims.sub
            {
                userInfo = info
            }
        }
        let resolvedEmail = OIDCValidation.resolveEmailVerification(
            idTokenEmail: claims.email,
            idTokenEmailVerified: claims.emailVerified,
            userInfoEmail: userInfo?.email,
            userInfoEmailVerified: userInfo?.emailVerified
        )
        let resolvedProfile = OIDCValidation.resolveProfile(
            idTokenName: claims.name,
            idTokenPreferredUsername: claims.preferredUsername,
            userInfoName: userInfo?.name,
            userInfoNickname: userInfo?.nickname,
            userInfoPreferredUsername: userInfo?.preferredUsername
        )

        return OIDCUserInfo(
            subject: claims.sub,
            email: resolvedEmail.email,
            emailVerified: resolvedEmail.verified,
            name: resolvedProfile.name,
            preferredUsername: resolvedProfile.preferredUsername,
            groupValues: groupValues
        )
    }

    /// Fetches the OIDC UserInfo endpoint with the access token. Used to
    /// recover claims the ID token omits; the caller must confirm the returned `sub`
    /// matches the ID token before trusting the response.
    private func fetchUserInfo(
        endpoint: String,
        accessToken: String,
        provider: OIDCProviderSnapshot,
        on req: Request
    ) async throws -> OIDCUserInfoResponse {
        // Same two gates as the discovery fetch: HTTPS + host allow-list here,
        // address classification and connection pinning in the guarded client.
        try OIDCValidation.validateAllowedFetchURL(
            endpoint,
            label: "UserInfo endpoint",
            perProviderHosts: provider.discoveredHostSet,
            configuration: req.controlPlaneConfiguration)
        var request = ClientRequest(method: .GET, url: URI(string: endpoint))
        request.headers.bearerAuthorization = BearerAuthorization(token: accessToken)
        let response = try await req.guardedHTTPClient.send(request)
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "UserInfo request failed")
        }
        return try response.content.decode(OIDCUserInfoResponse.self)
    }

    private func validateIDToken(
        idToken: String,
        provider: OIDCProviderSnapshot,
        expectedNonce: String?,
        on req: Request
    ) async throws -> OIDCIDTokenClaims {
        // Parse JWT header to get key ID
        let tokenParts = idToken.split(separator: ".")
        guard tokenParts.count == 3 else {
            throw Abort(.badRequest, reason: "Invalid ID token format")
        }

        // Decode the JWT header and pin the algorithm to the asymmetric
        // allow-list before any signature work.
        let headerData = try OIDCValidation.decodeBase64URLSafe(String(tokenParts[0]))
        let header = try JSONDecoder().decode(IDTokenHeader.self, from: headerData)
        try OIDCTokenVerification.requireAllowedAlgorithm(header)

        // Get JWKS from provider
        guard let jwksURI = provider.jwksURI else {
            throw Abort(.internalServerError, reason: "JWKS URI not configured for provider")
        }

        let jwksJSON = try await fetchJWKS(uri: jwksURI, provider: provider, on: req)

        // JWTKit selects the key by the header's `kid` and cross-checks the
        // header `alg` against the key's type (RSA/EC/OKP), so a token can't
        // steer verification onto a mismatched algorithm. Unknown `kid`s are
        // rejected rather than falling back to the first key.
        let verifiers = try await OIDCTokenVerification.makeVerifiers(jwksJSON: jwksJSON, logger: req.logger)
        let claims = try await verifiers.verify(idToken, header: header)

        // Additional claim validation
        try validateIDTokenClaims(claims, provider: provider, expectedNonce: expectedNonce)

        req.logger.info(
            "Successfully validated JWT signature for OIDC token",
            metadata: [
                "provider_id": .string(provider.id.uuidString),
                "subject": .string(claims.sub),
                "issuer": .string(claims.iss),
            ])

        return claims
    }

    /// Fetches the provider's JWKS document as raw JSON; decoding happens
    /// per-key in `OIDCTokenVerification.makeSigners` so one unsupported key
    /// can't invalidate the whole set.
    private func fetchJWKS(uri: String, provider: OIDCProviderSnapshot, on req: Request) async throws -> Data {
        // Same two gates as the discovery fetch: HTTPS + host allow-list here,
        // address classification and connection pinning in the guarded client.
        try OIDCValidation.validateAllowedFetchURL(
            uri,
            label: "JWKS URI",
            perProviderHosts: provider.discoveredHostSet,
            configuration: req.controlPlaneConfiguration)

        req.logger.debug("Fetching JWKS from URI", metadata: ["uri": .string(uri)])

        let response = try await req.guardedHTTPClient.send(
            ClientRequest(method: .GET, url: URI(string: uri)))
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "Failed to fetch JWKS from \(uri)")
        }

        guard let body = response.body else {
            throw Abort(.badGateway, reason: "Empty JWKS response from \(uri)")
        }
        return Data(buffer: body)
    }

    private func validateIDTokenClaims(
        _ claims: OIDCIDTokenClaims,
        provider: OIDCProviderSnapshot,
        expectedNonce: String?
    ) throws {
        // Expiration and issued-at time validation is handled by JWTPayload.verify()

        // Validate issuer (iss). The OIDC spec requires the token's issuer to
        // match the provider's known issuer; skipping it lets a token minted by a
        // different issuer that shares the same JWKS/audience (e.g. another tenant
        // on a multi-tenant IdP) be accepted. Templated multi-tenant issuers (e.g.
        // Entra `common`) are matched by pattern — see `OIDCValidation.issuerMatches`.
        if let expectedIssuer = provider.issuer, !expectedIssuer.isEmpty {
            guard OIDCValidation.issuerMatches(expected: expectedIssuer, actual: claims.iss) else {
                throw Abort(
                    .badRequest,
                    reason: "ID token issuer '\(claims.iss)' does not match expected issuer '\(expectedIssuer)'"
                )
            }
        } else if !(provider.discoveryURL ?? "").isEmpty {
            // Discovery-configured but the issuer was never resolved (a failed
            // discovery fetch at create/update, or an un-derivable backfill). Fail
            // closed rather than accept a token whose issuer we can't verify — the
            // stored endpoints alone would otherwise let a different-issuer token
            // sharing the JWKS/audience through. An admin re-test/refresh populates
            // the issuer. Manual-only providers (no discovery URL) legitimately have
            // no issuer and are not affected by this branch.
            throw Abort(
                .badRequest,
                reason:
                    "OIDC provider issuer is not configured. An administrator must re-test the provider to refresh its discovery metadata before logins can proceed."
            )
        }

        // Validate audience (aud). OIDC Core §3.1.3.7: the token MUST list our
        // client ID as an audience, and MUST be rejected if it carries any
        // audience the client does not trust. `aud` may be a single string or
        // an array (RFC 7519 §4.1.3; Discord uses a single-element array). We
        // keep no allow-list of additional trusted audiences, so our client ID
        // must be the only audience — a multi-audience token is rejected rather
        // than honored on the basis of an untrusted co-audience. (To support
        // multi-audience tokens later, add a trusted-audiences list to the
        // provider and permit those values here.)
        let audiences = claims.aud.values
        guard audiences.contains(provider.clientID) else {
            let list = audiences.joined(separator: ", ")
            throw Abort(
                .badRequest,
                reason: "ID token audience '\(list)' does not include client ID '\(provider.clientID)'"
            )
        }
        let untrusted = audiences.filter { $0 != provider.clientID }
        guard untrusted.isEmpty else {
            throw Abort(
                .badRequest,
                reason: "ID token lists untrusted audiences: \(untrusted.joined(separator: ", "))"
            )
        }

        // OIDC Core §3.1.3.7 step 5: if an azp (authorized party) claim is
        // present, it MUST be our client ID.
        if let azp = claims.azp, azp != provider.clientID {
            throw Abort(
                .badRequest,
                reason: "ID token azp '\(azp)' does not match client ID '\(provider.clientID)'"
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
    /// default role and every role mapping must name a role bindable at the
    /// organization, admin claim values must not be blank, and every group
    /// mapping must reference a group in the provider's organization.
    private func validateClaimMappingConfig(
        defaultRoleID: UUID?,
        groupMappings: [OIDCGroupMapping]?,
        adminClaimValues: [String]?,
        roleMappings: [OIDCRoleMapping]?,
        organizationID: UUID
    ) async throws {
        if let defaultRoleID {
            do {
                _ = try await MemberRoleResolver.resolve(
                    defaultRoleID,
                    scopeNode: IAMNode(type: .organization, id: organizationID),
                    using: iam)
            } catch {
                throw Abort(
                    .badRequest,
                    reason:
                        "Default role '\(defaultRoleID)' is not bindable in this organization: \(abortReason(error))")
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

        // Role mappings: a non-blank claim value bound to a role the org can
        // grant. Same scope check as the member endpoints (issue #608/#611).
        if let roleMappings = roleMappings {
            for mapping in roleMappings {
                guard !mapping.claimValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Abort(.badRequest, reason: "Role mapping claim values must not be empty")
                }
                do {
                    _ = try await MemberRoleResolver.resolve(
                        mapping.roleID,
                        scopeNode: IAMNode(type: .organization, id: organizationID),
                        using: iam)
                } catch {
                    throw Abort(
                        .badRequest,
                        reason:
                            "Role mapping for claim value '\(mapping.claimValue)' references a role not bindable in this organization: \(abortReason(error))"
                    )
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
        let orgGroupCount = try await groups.countOwnedGroups(
            ids: Array(groupIDs),
            organizationID: organizationID
        )
        guard orgGroupCount == groupIDs.count else {
            throw Abort(.badRequest, reason: "Group mappings must reference groups in this organization")
        }
    }

    /// The human-readable reason from an error, preferring an `AbortError`'s
    /// own reason so a resolver rejection surfaces its explanation.
    private func abortReason(_ error: any Error) -> String {
        (error as? any AbortError)?.reason ?? String(describing: error)
    }

}

/// Request-local mutable assembly state. Persistence inputs and outputs remain
/// immutable values; this draft never crosses the controller operation.
struct OIDCProviderDraft: OIDCProviderURLConfiguration {
    var id: UUID
    var organizationID: UUID
    var name: String
    var clientID: String
    var encryptedClientSecret: String
    var discoveryURL: String?
    var issuer: String?
    var authorizationEndpoint: String?
    var tokenEndpoint: String?
    var userinfoEndpoint: String?
    var jwksURI: String?
    var endSessionEndpoint: String?
    var discoveredHosts: [String]
    var scopes: [String]
    var enabled: Bool
    var useNonce: Bool
    var groupsClaim: String?
    var groupMappings: [OIDCGroupMappingValue]
    var adminClaimValues: [String]
    var roleMappings: [OIDCRoleMappingValue]
    var defaultRoleID: UUID?

    init(_ provider: OIDCProviderSnapshot) {
        id = provider.id
        organizationID = provider.organizationID
        name = provider.name
        clientID = provider.clientID
        encryptedClientSecret = provider.encryptedClientSecret
        discoveryURL = provider.discoveryURL
        issuer = provider.issuer
        authorizationEndpoint = provider.authorizationEndpoint
        tokenEndpoint = provider.tokenEndpoint
        userinfoEndpoint = provider.userinfoEndpoint
        jwksURI = provider.jwksURI
        endSessionEndpoint = provider.endSessionEndpoint
        discoveredHosts = provider.discoveredHosts
        scopes = provider.scopes
        enabled = provider.enabled
        useNonce = provider.useNonce
        groupsClaim = provider.groupsClaim
        groupMappings = provider.groupMappings
        adminClaimValues = provider.adminClaimValues
        roleMappings = provider.roleMappings
        defaultRoleID = provider.defaultRoleID
    }

    var hasRequiredEndpoints: Bool {
        authorizationEndpoint != nil && tokenEndpoint != nil && jwksURI != nil
    }

    var write: OIDCProviderWrite {
        OIDCProviderWrite(
            id: id,
            organizationID: organizationID,
            name: name,
            clientID: clientID,
            encryptedClientSecret: encryptedClientSecret,
            discoveryURL: discoveryURL,
            issuer: issuer,
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint,
            userinfoEndpoint: userinfoEndpoint,
            jwksURI: jwksURI,
            endSessionEndpoint: endSessionEndpoint,
            discoveredHosts: discoveredHosts,
            scopes: scopes,
            enabled: enabled,
            useNonce: useNonce,
            groupsClaim: groupsClaim,
            groupMappings: groupMappings,
            adminClaimValues: adminClaimValues,
            roleMappings: roleMappings,
            defaultRoleID: defaultRoleID
        )
    }
}
