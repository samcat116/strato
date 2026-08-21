import Foundation
import Testing

@testable import ControlPlanePostgres

@Suite("Native OIDC-provider persistence", .serialized)
struct OIDCProvidersPersistenceTests {
    @Test("provider configuration round-trips through immutable snapshots")
    func lifecycle() async throws {
        try await withOIDCProviderDatabase { _, providers in
            let organizationID = UUID()
            let groupID = UUID()
            let roleID = UUID()
            let created = try await providers.create(
                OIDCProviderWrite(
                    organizationID: organizationID,
                    name: "Workforce IdP",
                    clientID: "client",
                    encryptedClientSecret: "enc:v1:ciphertext",
                    discoveryURL: "https://idp.example.com/.well-known/openid-configuration",
                    issuer: "https://idp.example.com",
                    authorizationEndpoint: "https://idp.example.com/authorize",
                    tokenEndpoint: "https://idp.example.com/token",
                    userinfoEndpoint: "https://profile.example.com/userinfo",
                    jwksURI: "https://keys.example.com/jwks",
                    endSessionEndpoint: "https://idp.example.com/logout",
                    discoveredHosts: ["KEYS.EXAMPLE.COM", "profile.example.com"],
                    scopes: ["openid", "email"],
                    groupsClaim: "groups",
                    groupMappings: [OIDCGroupMappingValue(claimValue: "engineering", groupID: groupID)],
                    adminClaimValues: ["admins"],
                    roleMappings: [OIDCRoleMappingValue(claimValue: "auditors", roleID: roleID)],
                    defaultRoleID: roleID
                )
            )

            #expect(created.organizationID == organizationID)
            #expect(created.discoveredHosts == ["keys.example.com", "profile.example.com"])
            #expect(created.discoveredHostSet == ["keys.example.com", "profile.example.com"])
            #expect(created.scopes == ["openid", "email"])
            #expect(created.groupMappings.first?.groupID == groupID)
            #expect(created.roleMappings.first?.roleID == roleID)
            #expect(created.hasRequiredEndpoints)
            #expect(created.createdAt != nil)
            #expect(created.updatedAt != nil)
            #expect(try await providers.count(organizationID: organizationID) == 1)
            #expect(try await providers.providerNamed("Workforce IdP", organizationID: organizationID)?.id == created.id)
            #expect(try await providers.ownedProvider(id: created.id, organizationID: UUID()) == nil)
            #expect(try await providers.providers(organizationID: organizationID).map(\.id) == [created.id])
            #expect(try await providers.providers(organizationID: organizationID, enabledOnly: true).count == 1)

            let replaced = try #require(
                try await providers.replace(
                    OIDCProviderWrite(
                        id: created.id,
                        organizationID: organizationID,
                        name: "Disabled IdP",
                        clientID: created.clientID,
                        encryptedClientSecret: created.encryptedClientSecret,
                        scopes: created.scopes,
                        enabled: false,
                        useNonce: false
                    )
                )
            )
            #expect(replaced.name == "Disabled IdP")
            #expect(!replaced.enabled)
            #expect(!replaced.useNonce)
            #expect(try await providers.providers(organizationID: organizationID, enabledOnly: true).isEmpty)
        }
    }

    @Test("secret replacement is compare-and-set and delete refuses linked users")
    func secretAndDeleteInvariants() async throws {
        try await withOIDCProviderDatabase { database, providers in
            let organizationID = UUID()
            let created = try await providers.create(
                OIDCProviderWrite(
                    organizationID: organizationID,
                    name: "Legacy",
                    clientID: "client",
                    encryptedClientSecret: "plaintext"
                )
            )

            #expect(
                !(try await providers.replaceEncryptedClientSecret(
                    id: created.id,
                    expectedCurrentValue: "stale",
                    replacement: "must-not-win"
                ))
            )
            #expect(
                try await providers.replaceEncryptedClientSecret(
                    id: created.id,
                    expectedCurrentValue: "plaintext",
                    replacement: "enc:v1:ciphertext"
                )
            )
            #expect(
                try await providers.provider(id: created.id)?.encryptedClientSecret
                    == "enc:v1:ciphertext"
            )

            try await database.withSession(operation: "test.oidc_providers.link_user") { session in
                _ = try await session.command(
                    "INSERT INTO users (id, oidc_provider_id) VALUES ('\(UUID())', '\(created.id)')",
                    operation: "test.oidc_providers.link_user.insert"
                )
            }
            #expect(
                try await providers.deleteIfUnused(id: created.id, organizationID: organizationID)
                    == .inUse(linkedUsers: 1)
            )

            try await database.withSession(operation: "test.oidc_providers.unlink_user") { session in
                _ = try await session.command(
                    "UPDATE users SET oidc_provider_id = NULL WHERE oidc_provider_id = '\(created.id)'",
                    operation: "test.oidc_providers.unlink_user.update"
                )
            }
            #expect(
                try await providers.deleteIfUnused(id: created.id, organizationID: organizationID)
                    == .deleted(created.id)
            )
            #expect(
                try await providers.deleteIfUnused(id: created.id, organizationID: organizationID)
                    == .notFound
            )
        }
    }

    private func withOIDCProviderDatabase(
        _ test: (PostgresDatabase, OIDCProvidersPersistence) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase { database in
            try await database.withSession(operation: "test.oidc_providers.schema") { session in
                _ = try await session.command(
                    """
                    CREATE TABLE oidc_providers (
                        id UUID PRIMARY KEY,
                        organization_id UUID NOT NULL,
                        name TEXT NOT NULL,
                        client_id TEXT NOT NULL,
                        client_secret TEXT NOT NULL,
                        discovery_url TEXT,
                        issuer TEXT,
                        authorization_endpoint TEXT,
                        token_endpoint TEXT,
                        userinfo_endpoint TEXT,
                        jwks_uri TEXT,
                        end_session_endpoint TEXT,
                        discovered_hosts TEXT NOT NULL DEFAULT '[]',
                        scopes TEXT NOT NULL,
                        enabled BOOLEAN NOT NULL DEFAULT TRUE,
                        use_nonce BOOLEAN NOT NULL DEFAULT TRUE,
                        groups_claim TEXT,
                        group_mappings TEXT NOT NULL DEFAULT '[]',
                        admin_claim_values TEXT NOT NULL DEFAULT '[]',
                        role_mappings TEXT NOT NULL DEFAULT '[]',
                        default_role_id UUID,
                        created_at TIMESTAMPTZ,
                        updated_at TIMESTAMPTZ
                    )
                    """,
                    operation: "test.oidc_providers.schema.create_providers"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE users (
                        id UUID PRIMARY KEY,
                        oidc_provider_id UUID REFERENCES oidc_providers(id) ON DELETE SET NULL
                    )
                    """,
                    operation: "test.oidc_providers.schema.create_users"
                )
            }
            try await test(database, ControlPlanePersistence(database: database).oidcProviders)
        }
    }
}
