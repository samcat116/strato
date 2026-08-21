import Foundation
import PostgresNIO
import Testing

@testable import ControlPlanePostgres

@Suite("Native user-security persistence", .serialized)
struct UserSecurityPersistenceTests {
    @Test("subject resolution is organization scoped")
    func organizationScopedResolution() async throws {
        try await withUserSecurityDatabase { database, security in
            let organizationID = UUID()
            let otherOrganizationID = UUID()
            let providerID = UUID()
            let userID = UUID()

            try await database.withSession(operation: "test.user_security.seed") { session in
                _ = try await session.execute(
                    InsertOIDCProvider(
                        id: providerID,
                        discoveryURL: "https://idp.example.com/.well-known/openid-configuration",
                        authorizationEndpoint: "https://idp.example.com/authorize",
                        tokenEndpoint: "https://idp.example.com/token",
                        jwksURI: "https://idp.example.com/jwks"
                    ),
                    operation: "test.user_security.seed.provider"
                )
                _ = try await session.execute(
                    InsertSecurityUser(
                        id: userID,
                        username: "native-user",
                        email: "native@example.com",
                        oidcProviderID: providerID,
                        oidcSubject: "subject-1"
                    ),
                    operation: "test.user_security.seed.user"
                )
                _ = try await session.execute(
                    InsertUserOrganization(
                        userID: userID,
                        organizationID: organizationID
                    ),
                    operation: "test.user_security.seed.membership"
                )
            }

            #expect(
                try await security.organizationMember(
                    email: "native@example.com",
                    organizationID: organizationID
                )?.id == userID
            )
            #expect(
                try await security.organizationMember(
                    id: userID,
                    organizationID: organizationID
                )?.email == "native@example.com"
            )
            #expect(
                try await security.organizationMember(
                    id: userID,
                    organizationID: otherOrganizationID
                ) == nil
            )

            let oidc = try await security.oidcOrganizationMembers(
                subject: "subject-1",
                organizationID: organizationID
            )
            #expect(oidc.map(\.user.id) == [userID])
            #expect(oidc.first?.tokenEndpoint == "https://idp.example.com/token")
            #expect(
                try await security.oidcOrganizationMembers(
                    subject: "subject-1",
                    organizationID: otherOrganizationID
                ).isEmpty
            )
        }
    }

    @Test("security transitions preserve every concurrent revocation")
    func atomicSecurityTransitions() async throws {
        try await withUserSecurityDatabase(maximumConnections: 4) { database, security in
            let userID = UUID()
            try await database.withSession(operation: "test.user_security.seed") { session in
                _ = try await session.execute(
                    InsertSecurityUser(
                        id: userID,
                        username: "signal-target",
                        email: "signal@example.com",
                        oidcProviderID: nil,
                        oidcSubject: nil
                    ),
                    operation: "test.user_security.seed.user"
                )
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<10 {
                    group.addTask {
                        _ = try await security.revokeSessions(userID: userID)
                    }
                }
                try await group.waitForAll()
            }
            #expect(try await security.revokeSessions(userID: UUID()) == nil)

            let firstDisabledAt = Date()
            let disabled = try #require(
                try await security.disable(
                    userID: userID,
                    disabledAt: firstDisabledAt
                )
            )
            #expect(disabled.sessionEpoch == 11)
            #expect(disabled.disabledAt != nil)

            let disabledAgain = try #require(
                try await security.disable(
                    userID: userID,
                    disabledAt: firstDisabledAt.addingTimeInterval(60)
                )
            )
            #expect(disabledAgain.sessionEpoch == 12)
            #expect(disabledAgain.disabledAt == disabled.disabledAt)

            let enabled = try #require(try await security.enable(userID: userID))
            #expect(enabled.sessionEpoch == 12)
            #expect(enabled.disabledAt == nil)
            #expect(try await security.enable(userID: userID) == nil)
        }
    }

    private func withUserSecurityDatabase(
        maximumConnections: Int = 1,
        _ test: (ControlPlanePostgres.PostgresDatabase, UserSecurityPersistence) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase(maximumConnections: maximumConnections) { database in
            try await database.withSession(operation: "test.user_security.schema") { session in
                _ = try await session.command(
                    """
                    CREATE TABLE oidc_providers (
                        id UUID PRIMARY KEY,
                        discovery_url TEXT,
                        authorization_endpoint TEXT,
                        token_endpoint TEXT,
                        jwks_uri TEXT
                    )
                    """,
                    operation: "test.user_security.schema.providers"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE users (
                        id UUID PRIMARY KEY,
                        username TEXT NOT NULL,
                        email TEXT NOT NULL UNIQUE,
                        session_epoch BIGINT NOT NULL DEFAULT 0,
                        disabled_at TIMESTAMPTZ,
                        updated_at TIMESTAMPTZ,
                        oidc_provider_id UUID,
                        oidc_subject TEXT
                    )
                    """,
                    operation: "test.user_security.schema.users"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE user_organizations (
                        user_id UUID NOT NULL,
                        organization_id UUID NOT NULL,
                        UNIQUE (user_id, organization_id)
                    )
                    """,
                    operation: "test.user_security.schema.memberships"
                )
            }
            try await test(
                database,
                ControlPlanePersistence(database: database).userSecurity
            )
        }
    }
}

private struct InsertOIDCProvider: PostgresPreparedStatement {
    typealias Row = Void
    static let sql = """
        INSERT INTO oidc_providers (
            id, discovery_url, authorization_endpoint, token_endpoint, jwks_uri
        ) VALUES ($1, $2, $3, $4, $5)
        """

    let id: UUID
    let discoveryURL: String?
    let authorizationEndpoint: String?
    let tokenEndpoint: String?
    let jwksURI: String?

    static let bindingDataTypes: [PostgresDataType] = [.uuid, .text, .text, .text, .text]

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(id)
        bindings.append(discoveryURL)
        bindings.append(authorizationEndpoint)
        bindings.append(tokenEndpoint)
        bindings.append(jwksURI)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws {}
}

private struct InsertSecurityUser: PostgresPreparedStatement {
    typealias Row = Void
    static let sql = """
        INSERT INTO users (
            id, username, email, session_epoch, disabled_at, updated_at,
            oidc_provider_id, oidc_subject
        ) VALUES ($1, $2, $3, 0, NULL, NULL, $4, $5)
        """

    let id: UUID
    let username: String
    let email: String
    let oidcProviderID: UUID?
    let oidcSubject: String?

    static let bindingDataTypes: [PostgresDataType] = [.uuid, .text, .text, .uuid, .text]

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(id)
        bindings.append(username)
        bindings.append(email)
        bindings.append(oidcProviderID)
        bindings.append(oidcSubject)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws {}
}

private struct InsertUserOrganization: PostgresPreparedStatement {
    typealias Row = Void
    static let sql = "INSERT INTO user_organizations (user_id, organization_id) VALUES ($1, $2)"

    let userID: UUID
    let organizationID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(userID)
        bindings.append(organizationID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws {}
}
