import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

@Suite("OIDC Controller Tests", .serialized)
final class OIDCControllerTests: BaseTestCase {

    /// Insert a provider directly, bypassing the create endpoint's validation.
    @discardableResult
    private func makeProvider(
        on db: Database,
        organizationID: UUID,
        name: String,
        enabled: Bool = true,
        discoveryURL: String? = nil,
        authorizationEndpoint: String? = "https://idp.example.com/authorize",
        tokenEndpoint: String? = "https://idp.example.com/token",
        jwksURI: String? = "https://idp.example.com/.well-known/jwks.json"
    ) async throws -> OIDCProvider {
        let provider = OIDCProvider(
            organizationID: organizationID,
            name: name,
            clientID: "client-\(name)",
            clientSecret: "secret",
            discoveryURL: discoveryURL,
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint,
            jwksURI: jwksURI,
            enabled: enabled
        )
        try await provider.save(on: db)
        return provider
    }

    // MARK: - Provider management

    @Test("Create OIDC provider as org admin")
    func testCreateProvider() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/oidc-providers") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateOIDCProviderRequest(
                        name: "Okta",
                        clientID: "client-123",
                        clientSecret: "secret-456",
                        discoveryURL: nil,
                        authorizationEndpoint: "https://idp.example.com/authorize",
                        tokenEndpoint: "https://idp.example.com/token",
                        userinfoEndpoint: nil,
                        jwksURI: "https://idp.example.com/.well-known/jwks.json",
                        scopes: nil,
                        enabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(OIDCProviderResponse.self)
                #expect(response.name == "Okta")
                #expect(response.clientID == "client-123")
                #expect(response.scopes == ["openid", "profile", "email"])
                #expect(response.enabled == true)

                // The client secret must never appear in responses.
                let body = res.body.string
                #expect(!body.contains("secret-456"))
            }
        }
    }

    @Test("Create provider requires org admin role")
    func testCreateProviderRequiresAdmin() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            let memberUser = User(
                username: "memberuser",
                email: "member@example.com",
                displayName: "Member User"
            )
            try await memberUser.save(on: app.db)
            let memberOrg = UserOrganization(
                userID: memberUser.id!,
                organizationID: testOrganization.id!,
                role: "member"
            )
            try await memberOrg.save(on: app.db)
            let memberToken = try await memberUser.generateAPIKey(on: app.db)

            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/oidc-providers") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
                try req.content.encode(
                    CreateOIDCProviderRequest(
                        name: "Okta",
                        clientID: "client-123",
                        clientSecret: "secret-456",
                        discoveryURL: "https://idp.example.com/.well-known/openid-configuration",
                        authorizationEndpoint: nil,
                        tokenEndpoint: nil,
                        userinfoEndpoint: nil,
                        jwksURI: nil,
                        scopes: nil,
                        enabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("Create provider without discovery URL or endpoints fails")
    func testCreateProviderRequiresEndpoints() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/oidc-providers") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateOIDCProviderRequest(
                        name: "Broken",
                        clientID: "client-123",
                        clientSecret: "secret-456",
                        discoveryURL: nil,
                        authorizationEndpoint: nil,
                        tokenEndpoint: nil,
                        userinfoEndpoint: nil,
                        jwksURI: nil,
                        scopes: nil,
                        enabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // Authorization + token endpoints alone are not enough: the login
            // callback requires JWKS to validate ID tokens.
            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/oidc-providers") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateOIDCProviderRequest(
                        name: "No JWKS",
                        clientID: "client-123",
                        clientSecret: "secret-456",
                        discoveryURL: nil,
                        authorizationEndpoint: "https://idp.example.com/authorize",
                        tokenEndpoint: "https://idp.example.com/token",
                        userinfoEndpoint: nil,
                        jwksURI: nil,
                        scopes: nil,
                        enabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Update provider changes fields")
    func testUpdateProvider() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let provider = try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "Okta")

            try await app.test(
                .PUT, "/api/organizations/\(testOrganization.id!)/oidc-providers/\(provider.id!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateOIDCProviderRequest(
                        name: "Okta Prod",
                        clientID: nil,
                        clientSecret: nil,
                        discoveryURL: nil,
                        authorizationEndpoint: nil,
                        tokenEndpoint: nil,
                        userinfoEndpoint: nil,
                        jwksURI: nil,
                        scopes: nil,
                        enabled: false
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(OIDCProviderResponse.self)
                #expect(response.name == "Okta Prod")
                #expect(response.enabled == false)
            }
        }
    }

    @Test("Update clears discovery URL when an empty string is sent")
    func testUpdateClearsDiscoveryURL() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let provider = try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "Okta",
                discoveryURL: "https://old-issuer.example.com/.well-known/openid-configuration")

            // Switching to manual config: empty string clears the stored
            // discovery URL; manual endpoints remain and keep the provider valid.
            try await app.test(
                .PUT, "/api/organizations/\(testOrganization.id!)/oidc-providers/\(provider.id!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateOIDCProviderRequest(
                        name: nil,
                        clientID: nil,
                        clientSecret: nil,
                        discoveryURL: "",
                        authorizationEndpoint: nil,
                        tokenEndpoint: nil,
                        userinfoEndpoint: nil,
                        jwksURI: nil,
                        scopes: nil,
                        enabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(OIDCProviderResponse.self)
                #expect(response.discoveryURL == nil)
                #expect(response.authorizationEndpoint == "https://idp.example.com/authorize")
            }

            // Clearing a required manual field without a discovery URL must
            // be rejected — the provider would no longer be loginable.
            try await app.test(
                .PUT, "/api/organizations/\(testOrganization.id!)/oidc-providers/\(provider.id!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateOIDCProviderRequest(
                        name: nil,
                        clientID: nil,
                        clientSecret: nil,
                        discoveryURL: nil,
                        authorizationEndpoint: nil,
                        tokenEndpoint: nil,
                        userinfoEndpoint: nil,
                        jwksURI: "",
                        scopes: nil,
                        enabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Update with unreachable discovery URL still succeeds and keeps stored endpoints")
    func testUpdateWithFailingDiscoveryDoesNotBreak() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let provider = try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "Okta")

            // Not in the discovery allow-list, so the refresh attempt fails
            // before any network I/O; the update must still succeed and the
            // stored endpoints must survive.
            try await app.test(
                .PUT, "/api/organizations/\(testOrganization.id!)/oidc-providers/\(provider.id!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateOIDCProviderRequest(
                        name: nil,
                        clientID: nil,
                        clientSecret: nil,
                        discoveryURL: "https://not-allowlisted.example.com/.well-known/openid-configuration",
                        authorizationEndpoint: nil,
                        tokenEndpoint: nil,
                        userinfoEndpoint: nil,
                        jwksURI: nil,
                        scopes: nil,
                        enabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(OIDCProviderResponse.self)
                #expect(response.authorizationEndpoint == "https://idp.example.com/authorize")
                #expect(response.tokenEndpoint == "https://idp.example.com/token")
            }
        }
    }

    @Test("Delete provider is blocked while users are linked")
    func testDeleteProviderWithLinkedUsers() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let provider = try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "Okta")

            let linkedUser = User(
                username: "ssouser",
                email: "sso@example.com",
                displayName: "SSO User",
                oidcProviderID: provider.id,
                oidcSubject: "subject-1"
            )
            try await linkedUser.save(on: app.db)

            try await app.test(
                .DELETE, "/api/organizations/\(testOrganization.id!)/oidc-providers/\(provider.id!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // Unlink and retry
            linkedUser.$oidcProvider.id = nil
            try await linkedUser.save(on: app.db)

            try await app.test(
                .DELETE, "/api/organizations/\(testOrganization.id!)/oidc-providers/\(provider.id!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
        }
    }

    @Test("Test endpoint reports endpoint configuration as JSON")
    func testTestProviderEndpoint() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let configured = try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "Configured")
            let incomplete = try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "Incomplete",
                authorizationEndpoint: nil, tokenEndpoint: nil, jwksURI: nil)

            try await app.test(
                .POST, "/api/organizations/\(testOrganization.id!)/oidc-providers/\(configured.id!)/test"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let result = try res.content.decode(OIDCProviderTestResponse.self)
                #expect(result.valid == true)
            }

            try await app.test(
                .POST, "/api/organizations/\(testOrganization.id!)/oidc-providers/\(incomplete.id!)/test"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let result = try res.content.decode(OIDCProviderTestResponse.self)
                #expect(result.valid == false)
            }
        }
    }

    // MARK: - Public login-page endpoints (no auth)

    @Test("Public provider listing needs no auth and hides disabled providers")
    func testPublicProviderListing() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            try await makeProvider(on: app.db, organizationID: testOrganization.id!, name: "Enabled")
            try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "Disabled", enabled: false)

            try await app.test(
                .GET, "/api/public/organizations/\(testOrganization.id!)/oidc-providers"
            ) { res async throws in
                #expect(res.status == .ok)
                let providers = try res.content.decode([OIDCProviderPublicResponse].self)
                #expect(providers.count == 1)
                #expect(providers.first?.name == "Enabled")
            }
        }
    }

    @Test("SSO lookup resolves org name case-insensitively without auth")
    func testSSOLookup() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            try await makeProvider(on: app.db, organizationID: testOrganization.id!, name: "Okta")

            // setupCommonTestData names the org "Test Organization"
            try await app.test(.GET, "/api/public/sso/lookup?organization=test%20organization") { res async throws in
                #expect(res.status == .ok)
                let lookup = try res.content.decode(SSOLookupResponse.self)
                #expect(lookup.organizationID == testOrganization.id)
                #expect(lookup.providers.count == 1)
                #expect(lookup.providers.first?.name == "Okta")
            }
        }
    }

    @Test("SSO lookup hides unknown orgs and orgs without enabled providers")
    func testSSOLookupHidesUnknownAndUnconfigured() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            // Only a disabled provider: lookup must look identical to an
            // unknown organization.
            try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "Disabled", enabled: false)

            try await app.test(.GET, "/api/public/sso/lookup?organization=Test%20Organization") { res async throws in
                #expect(res.status == .ok)
                let lookup = try res.content.decode(SSOLookupResponse.self)
                #expect(lookup.organizationID == nil)
                #expect(lookup.providers.isEmpty)
            }

            try await app.test(.GET, "/api/public/sso/lookup?organization=No%20Such%20Org") { res async throws in
                #expect(res.status == .ok)
                let lookup = try res.content.decode(SSOLookupResponse.self)
                #expect(lookup.organizationID == nil)
                #expect(lookup.providers.isEmpty)
            }
        }
    }

    @Test("SSO lookup refuses ambiguous case-only matches but honors exact casing")
    func testSSOLookupAmbiguousCaseMatches() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            try await makeProvider(on: app.db, organizationID: testOrganization.id!, name: "Okta")

            // A second org whose name differs from "Test Organization" only by case
            let shoutyOrg = Organization(name: "TEST ORGANIZATION", description: "case twin")
            try await shoutyOrg.save(on: app.db)
            try await makeProvider(on: app.db, organizationID: shoutyOrg.id!, name: "Entra")

            // A third casing matches both orgs case-insensitively — refusing is
            // the only safe answer, otherwise the user is sent to an arbitrary
            // tenant's IdP.
            try await app.test(.GET, "/api/public/sso/lookup?organization=test%20organization") { res async throws in
                #expect(res.status == .ok)
                let lookup = try res.content.decode(SSOLookupResponse.self)
                #expect(lookup.organizationID == nil)
                #expect(lookup.providers.isEmpty)
            }

            // Exact casing stays unambiguous
            try await app.test(.GET, "/api/public/sso/lookup?organization=Test%20Organization") { res async throws in
                #expect(res.status == .ok)
                let lookup = try res.content.decode(SSOLookupResponse.self)
                #expect(lookup.organizationID == testOrganization.id)
                #expect(lookup.providers.first?.name == "Okta")
            }

            try await app.test(.GET, "/api/public/sso/lookup?organization=TEST%20ORGANIZATION") { res async throws in
                #expect(res.status == .ok)
                let lookup = try res.content.decode(SSOLookupResponse.self)
                #expect(lookup.organizationID == shoutyOrg.id)
                #expect(lookup.providers.first?.name == "Entra")
            }
        }
    }

    @Test("First SSO login provisions current org and SpiceDB membership")
    func testFirstLoginSeedsAuthorization() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let provider = try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "Okta")

            let recorder = SpiceDBMockRecorder()
            app.spicedbMockRecorder = recorder

            let controller = OIDCController()
            let user = try await controller.findOrCreateUser(
                userInfo: OIDCUserInfo(
                    subject: "subject-new",
                    email: "newcomer@example.com",
                    name: "New Comer",
                    preferredUsername: "newcomer"
                ),
                provider: provider,
                organization: testOrganization,
                db: app.db,
                spicedb: app.spicedb
            )

            // The session-issuing path relies on both of these for the user's
            // very first authorized request.
            #expect(user.currentOrganizationId == testOrganization.id)

            let membership = try await UserOrganization.query(on: app.db)
                .filter(\.$user.$id == user.id!)
                .filter(\.$organization.$id == testOrganization.id!)
                .first()
            #expect(membership?.role == "member")

            let writes = await recorder.writes
            let memberTuple = writes.first {
                $0.entity == "organization" && $0.entityId == testOrganization.id!.uuidString
                    && $0.relation == "member" && $0.subjectId == user.id!.uuidString
            }
            #expect(memberTuple != nil)

            // Second login with the same subject reuses the user, no new rows
            let again = try await controller.findOrCreateUser(
                userInfo: OIDCUserInfo(
                    subject: "subject-new", email: nil, name: nil, preferredUsername: nil),
                provider: provider,
                organization: testOrganization,
                db: app.db,
                spicedb: app.spicedb
            )
            #expect(again.id == user.id)
        }
    }

    @Test("Failed SpiceDB write rolls back first-login provisioning")
    func testFirstLoginRollsBackOnSpiceDBFailure() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let provider = try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "Okta")

            app.spicedbMockWritesFail = true

            let controller = OIDCController()
            let userInfo = OIDCUserInfo(
                subject: "subject-rollback",
                email: "rollback@example.com",
                name: "Roll Back",
                preferredUsername: "rollback"
            )

            await #expect(throws: Error.self) {
                _ = try await controller.findOrCreateUser(
                    userInfo: userInfo,
                    provider: provider,
                    organization: self.testOrganization,
                    db: app.db,
                    spicedb: app.spicedb
                )
            }

            // No half-provisioned user may survive: with the rows committed, a
            // retry would take the findOIDCUser early return and never write
            // the missing SpiceDB tuple.
            let orphan = try await User.query(on: app.db)
                .filter(\.$email == "rollback@example.com")
                .first()
            #expect(orphan == nil)

            // With SpiceDB healthy again the same subject provisions cleanly.
            app.spicedbMockWritesFail = false
            let user = try await controller.findOrCreateUser(
                userInfo: userInfo,
                provider: provider,
                organization: testOrganization,
                db: app.db,
                spicedb: app.spicedb
            )
            #expect(user.currentOrganizationId == testOrganization.id)
        }
    }

    @Test("SSO lookup without organization parameter fails")
    func testSSOLookupMissingParameter() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            try await app.test(.GET, "/api/public/sso/lookup") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }
}
