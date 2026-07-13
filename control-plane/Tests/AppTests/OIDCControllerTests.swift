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
        jwksURI: String? = "https://idp.example.com/.well-known/jwks.json",
        endSessionEndpoint: String? = nil
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
            endSessionEndpoint: endSessionEndpoint,
            enabled: enabled
        )
        try await provider.save(on: db)
        return provider
    }

    // MARK: - Provider management

    @Test("Create provider with blank admin claim values fails")
    func testCreateProviderRejectsBlankAdminClaimValues() async throws {
        // A saved blank value would make adminClaimValuesArray non-empty,
        // flipping role reconciliation into authoritative mode while matching
        // no real token — demoting every admin on their next login.
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            for blank in ["  ", "\n", "\t\n "] {
                try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/oidc-providers") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                    try req.content.encode(
                        CreateOIDCProviderRequest(
                            name: "Okta",
                            clientID: "client-123",
                            clientSecret: "secret-456",
                            authorizationEndpoint: "https://idp.example.com/authorize",
                            tokenEndpoint: "https://idp.example.com/token",
                            jwksURI: "https://idp.example.com/.well-known/jwks.json",
                            groupsClaim: "groups",
                            adminClaimValues: [blank]
                        ))
                } afterResponse: { res in
                    #expect(res.status == .badRequest)
                }
            }
        }
    }

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

    @Test("Claim mapping config is redacted for non-admin members")
    func testClaimMappingRedactedForMembers() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            let provider = try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "Okta")
            provider.groupsClaim = "groups"
            provider.setAdminClaimValuesArray(["strato-admins"])
            provider.defaultRole = "member"
            try await provider.save(on: app.db)

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

            // A plain member can list providers but must not see which IdP
            // claims map groups or grant admin.
            try await app.test(.GET, "/api/organizations/\(testOrganization.id!)/oidc-providers") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let providers = try res.content.decode([OIDCProviderResponse].self)
                #expect(providers.first?.groupsClaim == nil)
                #expect(providers.first?.adminClaimValues == nil)
                #expect(providers.first?.groupMappings == nil)
                #expect(providers.first?.defaultRole == nil)
            }

            // Admins see the full configuration.
            try await app.test(.GET, "/api/organizations/\(testOrganization.id!)/oidc-providers") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let providers = try res.content.decode([OIDCProviderResponse].self)
                #expect(providers.first?.groupsClaim == "groups")
                #expect(providers.first?.adminClaimValues == ["strato-admins"])
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

    @Test("Client secrets are stored encrypted at rest and re-encrypted on update")
    func testClientSecretEncryptedAtRest() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let key = try SecretsEncryptionService.parseKey(String(repeating: "ef", count: 32))
            app.secretsEncryption = SecretsEncryptionService(key: key)

            var providerID: UUID?
            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/oidc-providers") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateOIDCProviderRequest(
                        name: "Okta",
                        clientID: "client-123",
                        clientSecret: "top-secret-original",
                        authorizationEndpoint: "https://idp.example.com/authorize",
                        tokenEndpoint: "https://idp.example.com/token",
                        jwksURI: "https://idp.example.com/.well-known/jwks.json"
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)
                providerID = try res.content.decode(OIDCProviderResponse.self).id
            }

            let created = try await OIDCProvider.find(providerID, on: app.db)
            let storedSecret = try #require(created?.clientSecret)
            #expect(storedSecret.hasPrefix(SecretsEncryptionService.encryptedPrefix))
            #expect(!storedSecret.contains("top-secret-original"))
            let decrypted = try app.secretsEncryption.decrypt(storedSecret)
            #expect(decrypted == "top-secret-original")

            // Rotating the secret through the update path re-encrypts it.
            try await app.test(
                .PUT, "/api/organizations/\(testOrganization.id!)/oidc-providers/\(providerID!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(UpdateOIDCProviderRequest(clientSecret: "rotated-secret"))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let updated = try await OIDCProvider.find(providerID, on: app.db)
            let rotatedStored = try #require(updated?.clientSecret)
            #expect(rotatedStored.hasPrefix(SecretsEncryptionService.encryptedPrefix))
            let rotatedDecrypted = try app.secretsEncryption.decrypt(rotatedStored)
            #expect(rotatedDecrypted == "rotated-secret")
        }
    }

    @Test("Clearing the discovery URL clears the stored issuer")
    func testUpdateClearingDiscoveryClearsIssuer() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let provider = try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "Okta")
            // Simulate a provider that previously discovered an issuer.
            provider.issuer = "https://old-issuer.example.com"
            try await provider.save(on: app.db)

            // Switch to manual endpoints by clearing discovery. The stale issuer
            // must be dropped, otherwise it would reject a new manual issuer's tokens.
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
                        authorizationEndpoint: "https://new-idp.example.com/authorize",
                        tokenEndpoint: "https://new-idp.example.com/token",
                        userinfoEndpoint: nil,
                        jwksURI: "https://new-idp.example.com/.well-known/jwks.json",
                        scopes: nil,
                        enabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(OIDCProviderResponse.self)
                #expect(response.issuer == nil)
            }

            let reloaded = try await OIDCProvider.find(provider.id!, on: app.db)
            #expect(reloaded?.issuer == nil)
        }
    }

    @Test("Issuer backfill derives exact and templated issuers, skips unresolvable")
    func testIssuerBackfill() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let org = testOrganization.id!
            func mk(_ name: String, _ url: String) async throws -> OIDCProvider {
                try await makeProvider(on: app.db, organizationID: org, name: name, discoveryURL: url)
            }
            // Providers created after startup have issuer NULL; run the real
            // backfill SQL against them (exercises it on SQLite).
            let google = try await mk("g", "https://accounts.google.com/.well-known/openid-configuration")
            let common = try await mk(
                "c", "https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration")
            let orgs = try await mk(
                "o", "https://login.microsoftonline.com/organizations/v2.0/.well-known/openid-configuration")
            let single = try await mk(
                "s",
                "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0/.well-known/openid-configuration"
            )
            // Non-Microsoft host with a literal `common` path segment: the exact
            // stripped URL is its real issuer and must be backfilled, not skipped.
            let nonMS = try await mk("n", "https://idp.example.com/common/.well-known/openid-configuration")
            // Microsoft v1.0 `common` (no /v2.0): the real issuer is on the
            // sts.windows.net host, templated per tenant.
            let msV1 = try await mk("v1", "https://login.microsoftonline.com/common/.well-known/openid-configuration")

            try await AddIssuerToOIDCProvider.backfillIssuers(on: app.db)

            // Standard IdP: exact issuer (discovery URL minus the well-known suffix).
            let googleIssuer = try await OIDCProvider.find(google.id!, on: app.db)?.issuer
            #expect(googleIssuer == "https://accounts.google.com")
            // Entra multi-tenant aliases: templated so issuerMatches accepts the
            // concrete-tenant token.
            let commonIssuer = try await OIDCProvider.find(common.id!, on: app.db)?.issuer
            #expect(commonIssuer == "https://login.microsoftonline.com/{tenantid}/v2.0")
            let orgsIssuer = try await OIDCProvider.find(orgs.id!, on: app.db)?.issuer
            #expect(orgsIssuer == "https://login.microsoftonline.com/{tenantid}/v2.0")
            // Entra single-tenant (concrete GUID): exact, not templated.
            let singleIssuer = try await OIDCProvider.find(single.id!, on: app.db)?.issuer
            #expect(singleIssuer == "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0")
            // A `/common/` segment on a non-Microsoft host is a literal path, not a
            // multi-tenant alias: backfill the exact issuer.
            let nonMSIssuer = try await OIDCProvider.find(nonMS.id!, on: app.db)?.issuer
            #expect(nonMSIssuer == "https://idp.example.com/common")
            // Microsoft v1.0 multi-tenant `common`: issuer is on sts.windows.net,
            // templated per tenant.
            let msV1Issuer = try await OIDCProvider.find(msV1.id!, on: app.db)?.issuer
            #expect(msV1Issuer == "https://sts.windows.net/{tenantid}/")
        }
    }

    @Test("Update rejects non-HTTPS endpoint URLs")
    func testUpdateRejectsInsecureURLs() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let provider = try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "Okta")

            // An http:// token endpoint would receive the client secret on the
            // next login — the same HTTPS validation as create must apply.
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
                        tokenEndpoint: "http://insecure.example.com/token",
                        userinfoEndpoint: nil,
                        jwksURI: nil,
                        scopes: nil,
                        enabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // The stored endpoint must be untouched after the rejected edit.
            let reloaded = try await OIDCProvider.find(provider.id, on: app.db)
            #expect(reloaded?.tokenEndpoint == "https://idp.example.com/token")
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

            let identity = OIDCIdentityService(db: app.db, spicedb: try app.spicedb, logger: app.logger)
            let user = try await identity.resolveUser(
                userInfo: OIDCUserInfo(
                    subject: "subject-new",
                    email: "newcomer@example.com",
                    emailVerified: true,
                    name: "New Comer",
                    preferredUsername: "newcomer"
                ),
                provider: provider,
                organization: testOrganization,
                groupValues: []
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
            let again = try await identity.resolveUser(
                userInfo: OIDCUserInfo(
                    subject: "subject-new", email: nil, emailVerified: false, name: nil, preferredUsername: nil),
                provider: provider,
                organization: testOrganization,
                groupValues: []
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

            let identity = OIDCIdentityService(db: app.db, spicedb: try app.spicedb, logger: app.logger)
            let userInfo = OIDCUserInfo(
                subject: "subject-rollback",
                email: "rollback@example.com",
                emailVerified: true,
                name: "Roll Back",
                preferredUsername: "rollback"
            )

            await #expect(throws: Error.self) {
                _ = try await identity.resolveUser(
                    userInfo: userInfo,
                    provider: provider,
                    organization: self.testOrganization,
                    groupValues: []
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
            let healthyIdentity = OIDCIdentityService(db: app.db, spicedb: try app.spicedb, logger: app.logger)
            let user = try await healthyIdentity.resolveUser(
                userInfo: userInfo,
                provider: provider,
                organization: testOrganization,
                groupValues: []
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

    // MARK: - PKCE

    @Test("Authorize redirect carries S256 PKCE parameters")
    func testAuthorizeRedirectIncludesPKCE() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let provider = try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "Okta")

            try await app.test(
                .GET, "/auth/oidc/\(testOrganization.id!)/\(provider.id!)/authorize"
            ) { res async throws in
                #expect(res.status == .seeOther)
                let location = try #require(res.headers.first(name: .location))
                let components = try #require(URLComponents(string: location))
                let query = Dictionary(
                    uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

                #expect(query["code_challenge_method"] == "S256")
                // The challenge is base64url(SHA256): 43 chars, no padding.
                let challenge = try #require(query["code_challenge"])
                #expect(challenge.count == 43)
                #expect(query["response_type"] == "code")
                #expect(query["state"]?.isEmpty == false)
                #expect(query["nonce"]?.isEmpty == false)
            }
        }
    }

    // MARK: - RP-initiated logout

    @Test("End-session URL includes client_id, id_token_hint, and post-logout redirect")
    func testEndSessionURL() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let provider = try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "Okta",
                endSessionEndpoint: "https://idp.example.com/logout")

            let url = try #require(
                provider.getEndSessionURL(
                    idTokenHint: "id-token-abc",
                    postLogoutRedirectURI: "https://cloud.example.com/login"))
            let components = try #require(URLComponents(string: url))
            #expect(components.host == "idp.example.com")
            #expect(components.path == "/logout")
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(query["client_id"] == "client-Okta")
            #expect(query["id_token_hint"] == "id-token-abc")
            #expect(query["post_logout_redirect_uri"] == "https://cloud.example.com/login")

            // No end-session endpoint → no SLO URL.
            let plain = try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "Plain")
            #expect(plain.getEndSessionURL(idTokenHint: nil, postLogoutRedirectURI: nil) == nil)
        }
    }

    @Test("Endpoint URLs keep their own query parameters (e.g. B2C policy selectors)")
    func testEndpointQueryParametersPreserved() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let provider = try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "B2C",
                authorizationEndpoint: "https://idp.example.com/authorize?p=b2c_1_signin",
                endSessionEndpoint: "https://idp.example.com/logout?p=b2c_1_signin")

            let authURL = try #require(
                provider.getAuthorizationURL(
                    redirectURI: "https://cloud.example.com/cb", state: "s", nonce: "n"))
            let authQuery = Dictionary(
                uniqueKeysWithValues: (URLComponents(string: authURL)?.queryItems ?? [])
                    .map { ($0.name, $0.value ?? "") })
            #expect(authQuery["p"] == "b2c_1_signin")
            #expect(authQuery["client_id"] == "client-B2C")

            let sloURL = try #require(
                provider.getEndSessionURL(idTokenHint: "t", postLogoutRedirectURI: nil))
            let sloQuery = Dictionary(
                uniqueKeysWithValues: (URLComponents(string: sloURL)?.queryItems ?? [])
                    .map { ($0.name, $0.value ?? "") })
            #expect(sloQuery["p"] == "b2c_1_signin")
            #expect(sloQuery["id_token_hint"] == "t")
        }
    }

    @Test("Provider CRUD stores, updates, and validates the end-session endpoint")
    func testEndSessionEndpointCRUD() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            // Non-HTTPS end-session endpoint is rejected on create.
            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/oidc-providers") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateOIDCProviderRequest(
                        name: "Bad",
                        clientID: "client-123",
                        clientSecret: "secret-456",
                        authorizationEndpoint: "https://idp.example.com/authorize",
                        tokenEndpoint: "https://idp.example.com/token",
                        jwksURI: "https://idp.example.com/.well-known/jwks.json",
                        endSessionEndpoint: "http://idp.example.com/logout"
                    ))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // Valid endpoint round-trips through create and the response.
            var providerID: UUID?
            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/oidc-providers") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateOIDCProviderRequest(
                        name: "Okta",
                        clientID: "client-123",
                        clientSecret: "secret-456",
                        authorizationEndpoint: "https://idp.example.com/authorize",
                        tokenEndpoint: "https://idp.example.com/token",
                        jwksURI: "https://idp.example.com/.well-known/jwks.json",
                        endSessionEndpoint: "https://idp.example.com/logout"
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let created = try res.content.decode(OIDCProviderResponse.self)
                #expect(created.endSessionEndpoint == "https://idp.example.com/logout")
                providerID = created.id
            }

            // An empty string clears it (same contract as the other URL fields).
            try await app.test(
                .PUT, "/api/organizations/\(testOrganization.id!)/oidc-providers/\(providerID!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(UpdateOIDCProviderRequest(endSessionEndpoint: ""))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let updated = try res.content.decode(OIDCProviderResponse.self)
                #expect(updated.endSessionEndpoint == nil)
            }
        }
    }

    @Test("Discovery refresh preserves manual optional endpoints, rotation clears them")
    func testDiscoveryOptionalEndpointSemantics() async throws {
        func doc(issuer: String, userinfo: String? = nil, endSession: String? = nil) -> OIDCDiscoveryDocument {
            OIDCDiscoveryDocument(
                issuer: issuer,
                authorizationEndpoint: "\(issuer)/authorize",
                tokenEndpoint: "\(issuer)/token",
                userinfoEndpoint: userinfo,
                endSessionEndpoint: endSession,
                jwksURI: "\(issuer)/jwks",
                responseTypesSupported: ["code"],
                subjectTypesSupported: ["public"],
                idTokenSigningAlgValuesSupported: ["RS256"]
            )
        }
        let controller = OIDCController()
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let provider = try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "Okta",
                endSessionEndpoint: "https://manual.example.com/logout")

            // Same-URL, same-issuer refresh with metadata omitting the
            // optional endpoints: the manual logout URL must survive.
            controller.applyDiscoveredConfiguration(
                doc(issuer: "https://idp.example.com"), to: provider, discoveryChanged: false)
            #expect(provider.endSessionEndpoint == "https://manual.example.com/logout")

            // Rotating the discovery document to a different issuer clears
            // the previous IdP's optional endpoints — a stale logout URL
            // would redirect users to the old provider.
            controller.applyDiscoveredConfiguration(
                doc(issuer: "https://other.example.com"), to: provider, discoveryChanged: false)
            #expect(provider.endSessionEndpoint == nil)
            #expect(provider.issuer == "https://other.example.com")

            // And when the new metadata supplies them, they're adopted.
            controller.applyDiscoveredConfiguration(
                doc(
                    issuer: "https://third.example.com",
                    userinfo: "https://third.example.com/userinfo",
                    endSession: "https://third.example.com/logout"),
                to: provider, discoveryChanged: false)
            #expect(provider.userinfoEndpoint == "https://third.example.com/userinfo")
            #expect(provider.endSessionEndpoint == "https://third.example.com/logout")

            // A manual→discovery switch has no stored issuer to compare, so
            // a newly added/changed discovery URL alone must clear manual
            // optional endpoints the document omits.
            let manual = try await makeProvider(
                on: app.db, organizationID: testOrganization.id!, name: "Manual",
                endSessionEndpoint: "https://manual.example.com/logout")
            controller.applyDiscoveredConfiguration(
                doc(issuer: "https://new-idp.example.com"), to: manual, discoveryChanged: true)
            #expect(manual.endSessionEndpoint == nil)
            #expect(manual.userinfoEndpoint == nil)
        }
    }

    @Test("Logout without an OIDC session returns no SLO URL")
    func testLogoutWithoutOIDCSession() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            try await app.test(.POST, "/auth/logout") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(LogoutResponse.self)
                #expect(body.sloUrl == nil)
            }
        }
    }
}
