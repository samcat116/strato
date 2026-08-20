import Foundation
import PostgresNIO
import Testing

@testable import ControlPlanePostgres

@Suite("Native bootstrap persistence", .serialized)
struct BootstrapPersistenceTests {
    @Test("bootstrap creates the complete installation graph atomically")
    func createsInstallationGraph() async throws {
        try await withBootstrapDatabase { database, bootstrap in
            let write = makeBootstrapWrite()
            #expect(!(try await bootstrap.hasUsers()))

            let result = try await bootstrap.createInstallation(write)

            #expect(result.userID == write.userID)
            #expect(result.organizationID == write.organizationID)
            #expect(result.projectID == write.projectID)
            #expect(result.siteID == write.siteID)
            #expect(result.claimID == write.claim?.id)
            #expect(result.apiKeyID == write.apiKey?.id)
            #expect(try await bootstrap.hasUsers())
            #expect(try await rowCount("users", database: database) == 1)
            #expect(try await rowCount("organizations", database: database) == 1)
            #expect(try await rowCount("projects", database: database) == 1)
            #expect(try await rowCount("sites", database: database) == 1)
            #expect(try await rowCount("user_organizations", database: database) == 1)
            #expect(try await rowCount("role_bindings", database: database) == 2)
            #expect(try await rowCount("account_claim_tokens", database: database) == 1)
            #expect(try await rowCount("api_keys", database: database) == 1)
            #expect(
                try await projectPath(write.projectID, database: database)
                    == "/\(write.organizationID.uuidString)/\(write.projectID.uuidString)"
            )
        }
    }

    @Test("a late constraint failure rolls the whole bootstrap back")
    func lateFailureRollsBack() async throws {
        try await withBootstrapDatabase { database, bootstrap in
            let write = makeBootstrapWrite(siteName: "duplicate-site")
            try await seedBootstrapSite(name: "duplicate-site", database: database)

            await #expect(throws: (any Error).self) {
                try await bootstrap.createInstallation(write)
            }

            #expect(!(try await bootstrap.hasUsers()))
            #expect(try await rowCount("organizations", database: database) == 0)
            #expect(try await rowCount("projects", database: database) == 0)
            #expect(try await rowCount("role_bindings", database: database) == 0)
            #expect(try await rowCount("account_claim_tokens", database: database) == 0)
            #expect(try await rowCount("api_keys", database: database) == 0)
        }
    }

    @Test("concurrent first-use attempts have exactly one winner")
    func concurrentBootstrapHasOneWinner() async throws {
        try await withBootstrapDatabase(maximumConnections: 2) { database, bootstrap in
            let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                for suffix in ["one", "two"] {
                    group.addTask {
                        do {
                            _ = try await bootstrap.createInstallation(
                                makeBootstrapWrite(suffix: suffix)
                            )
                            return true
                        } catch BootstrapPersistenceError.alreadyInitialized {
                            return false
                        } catch {
                            return false
                        }
                    }
                }
                var values: [Bool] = []
                for await value in group { values.append(value) }
                return values
            }

            #expect(outcomes.filter { $0 }.count == 1)
            #expect(outcomes.filter { !$0 }.count == 1)
            let userCount = try await rowCount("users", database: database)
            let organizationCount = try await rowCount("organizations", database: database)
            #expect(userCount == 1)
            #expect(organizationCount == 1)
        }
    }

    private func withBootstrapDatabase(
        maximumConnections: Int = 1,
        _ test: (
            ControlPlanePostgres.PostgresDatabase,
            BootstrapPersistence
        ) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase(maximumConnections: maximumConnections) { database in
            try await database.withSession(operation: "test.bootstrap.schema") { session in
                for sql in bootstrapSchema {
                    _ = try await session.command(
                        sql,
                        operation: "test.bootstrap.schema"
                    )
                }
            }
            try await test(database, ControlPlanePersistence(database: database).bootstrap)
        }
    }
}

private func makeBootstrapWrite(
    suffix: String = "test",
    siteName: String? = nil
) -> BootstrapInstallationWrite {
    let userID = UUID()
    return BootstrapInstallationWrite(
        userID: userID,
        username: "bootstrap-\(suffix)",
        email: "bootstrap-\(suffix)@example.com",
        organizationName: "Organization \(suffix)",
        projectName: "Project \(suffix)",
        siteName: siteName ?? "Site \(suffix)",
        adminRoleID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        claim: AccountClaimIssue(
            tokenHash: "claim-hash-\(suffix)",
            tokenPrefix: "claim-prefix",
            expiresAt: Date().addingTimeInterval(3600),
            createdByID: userID
        ),
        apiKey: APIKeyWrite(
            userID: userID,
            name: "bootstrap",
            keyHash: "api-hash-\(suffix)",
            keyPrefix: "sk_prefix...",
            restriction: StoredCredentialRestriction(
                actions: ["*"],
                nodeType: nil,
                nodeID: nil
            )
        )
    )
}

private func rowCount(
    _ table: String,
    database: ControlPlanePostgres.PostgresDatabase
) async throws -> Int64 {
    try await database.withSession(operation: "test.bootstrap.row_count") { session in
        let rows: [Int64]
        switch table {
        case "users":
            rows = try await session.execute(
                CountBootstrapUsers(),
                operation: "test.bootstrap.count_users"
            )
        case "organizations":
            rows = try await session.execute(
                CountBootstrapOrganizations(),
                operation: "test.bootstrap.count_organizations"
            )
        case "projects":
            rows = try await session.execute(
                CountBootstrapProjects(),
                operation: "test.bootstrap.count_projects"
            )
        case "sites":
            rows = try await session.execute(
                CountBootstrapSites(),
                operation: "test.bootstrap.count_sites"
            )
        case "user_organizations":
            rows = try await session.execute(
                CountBootstrapMemberships(),
                operation: "test.bootstrap.count_memberships"
            )
        case "role_bindings":
            rows = try await session.execute(
                CountBootstrapBindings(),
                operation: "test.bootstrap.count_bindings"
            )
        case "account_claim_tokens":
            rows = try await session.execute(
                CountBootstrapClaims(),
                operation: "test.bootstrap.count_claims"
            )
        case "api_keys":
            rows = try await session.execute(
                CountBootstrapAPIKeys(),
                operation: "test.bootstrap.count_api_keys"
            )
        default: Issue.record("Unsupported bootstrap count table \(table)"); return -1
        }
        return try #require(rows.first)
    }
}

private func projectPath(
    _ id: UUID,
    database: ControlPlanePostgres.PostgresDatabase
) async throws -> String? {
    try await database.withSession(operation: "test.bootstrap.project_path") { session in
        try await session.execute(
            FindBootstrapProjectPath(id: id),
            operation: "test.bootstrap.project_path.query"
        ).first
    }
}

private func seedBootstrapSite(
    name: String,
    database: ControlPlanePostgres.PostgresDatabase
) async throws {
    try await database.withSession(operation: "test.bootstrap.seed_site") { session in
        _ = try await session.execute(
            InsertBootstrapTestSite(id: UUID(), name: name),
            operation: "test.bootstrap.seed_site.query"
        )
    }
}

private let bootstrapSchema = [
    """
    CREATE TABLE users (
        id UUID PRIMARY KEY, username TEXT NOT NULL UNIQUE, email TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL, current_organization_id UUID,
        is_system_admin BOOLEAN NOT NULL DEFAULT FALSE, source TEXT NOT NULL DEFAULT 'local',
        scim_provisioned BOOLEAN NOT NULL DEFAULT FALSE,
        scim_active BOOLEAN NOT NULL DEFAULT TRUE, session_epoch BIGINT NOT NULL DEFAULT 0,
        created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ
    )
    """,
    """
    CREATE TABLE organizations (
        id UUID PRIMARY KEY, name TEXT NOT NULL UNIQUE, description TEXT NOT NULL,
        created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ
    )
    """,
    """
    CREATE TABLE account_claim_tokens (
        id UUID PRIMARY KEY, user_id UUID NOT NULL, token_hash TEXT NOT NULL UNIQUE,
        token_prefix TEXT NOT NULL, expires_at TIMESTAMPTZ, claimed_at TIMESTAMPTZ,
        created_by_id UUID, created_at TIMESTAMPTZ
    )
    """,
    """
    CREATE TABLE user_organizations (
        id UUID PRIMARY KEY, user_id UUID NOT NULL, organization_id UUID NOT NULL,
        role_id UUID, created_at TIMESTAMPTZ,
        UNIQUE(user_id, organization_id)
    )
    """,
    """
    CREATE TABLE role_bindings (
        id UUID PRIMARY KEY, principal_type TEXT NOT NULL, principal_id UUID NOT NULL,
        role_id UUID NOT NULL, node_type TEXT NOT NULL, node_id UUID NOT NULL,
        condition TEXT, expires_at TIMESTAMPTZ, created_by UUID, created_at TIMESTAMPTZ,
        UNIQUE(principal_type, principal_id, role_id, node_type, node_id)
    )
    """,
    """
    CREATE TABLE projects (
        id UUID PRIMARY KEY, name TEXT NOT NULL, description TEXT NOT NULL,
        organization_id UUID, organizational_unit_id UUID, path TEXT NOT NULL,
        default_environment TEXT NOT NULL, environments TEXT[] NOT NULL,
        created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ
    )
    """,
    """
    CREATE TABLE sites (
        id UUID PRIMARY KEY, name TEXT NOT NULL UNIQUE, description TEXT,
        organization_id UUID, organizational_unit_id UUID, status TEXT NOT NULL,
        labels JSONB NOT NULL, created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ
    )
    """,
    """
    CREATE TABLE api_keys (
        id UUID PRIMARY KEY, user_id UUID NOT NULL, name TEXT NOT NULL,
        key_hash TEXT NOT NULL UNIQUE, key_prefix TEXT NOT NULL,
        restriction_actions TEXT[] NOT NULL, restriction_node_type TEXT,
        restriction_node_id UUID, is_active BOOLEAN NOT NULL, expires_at TIMESTAMPTZ,
        created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ
    )
    """,
]

private protocol BootstrapCountStatement: PostgresPreparedStatement where Row == Int64 {}
private extension BootstrapCountStatement {
    func makeBindings() -> PostgresBindings { PostgresBindings() }
    func decodeRow(_ row: PostgresRow) throws -> Int64 { try row.decode(Int64.self) }
}

private struct CountBootstrapUsers: BootstrapCountStatement { static let sql = "SELECT COUNT(*) FROM users" }
private struct CountBootstrapOrganizations: BootstrapCountStatement {
    static let sql = "SELECT COUNT(*) FROM organizations"
}
private struct CountBootstrapProjects: BootstrapCountStatement { static let sql = "SELECT COUNT(*) FROM projects" }
private struct CountBootstrapSites: BootstrapCountStatement { static let sql = "SELECT COUNT(*) FROM sites" }
private struct CountBootstrapMemberships: BootstrapCountStatement {
    static let sql = "SELECT COUNT(*) FROM user_organizations"
}
private struct CountBootstrapBindings: BootstrapCountStatement { static let sql = "SELECT COUNT(*) FROM role_bindings" }
private struct CountBootstrapClaims: BootstrapCountStatement {
    static let sql = "SELECT COUNT(*) FROM account_claim_tokens"
}
private struct CountBootstrapAPIKeys: BootstrapCountStatement { static let sql = "SELECT COUNT(*) FROM api_keys" }

private struct FindBootstrapProjectPath: PostgresPreparedStatement {
    typealias Row = String
    static let sql = "SELECT path FROM projects WHERE id = $1"
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> String { try row.decode(String.self) }
}

private struct InsertBootstrapTestSite: PostgresPreparedStatement {
    typealias Row = Void
    static let sql = "INSERT INTO sites (id, name, status, labels) VALUES ($1, $2, 'active', '{}'::jsonb)"
    let id: UUID
    let name: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(name)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws {}
}
