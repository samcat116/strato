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
        authorizationEndpoint: String? = "https://idp.example.com/authorize",
        tokenEndpoint: String? = "https://idp.example.com/token"
    ) async throws -> OIDCProvider {
        let provider = OIDCProvider(
            organizationID: organizationID,
            name: name,
            clientID: "client-\(name)",
            clientSecret: "secret",
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint,
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
                        jwksURI: nil,
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
                authorizationEndpoint: nil, tokenEndpoint: nil)

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
