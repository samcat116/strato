import Foundation
import PostgresNIO
import Testing

@testable import ControlPlanePostgres

@Suite("Native service-account persistence", .serialized)
struct ServiceAccountsPersistenceTests {
    @Test("lifecycle keeps creator grants and delete cleanup atomic")
    func lifecycle() async throws {
        try await withServiceAccountDatabase { database, serviceAccounts, projectID in
            let creatorID = UUID()
            let roleID = UUID()
            let write = ServiceAccountWrite(
                name: "build-worker",
                description: "builds images",
                projectID: projectID)
            let created = try await serviceAccounts.create(
                write,
                creatorGrant: ServiceAccountCreatorGrant(
                    principalID: creatorID,
                    roleID: roleID,
                    createdBy: creatorID))

            #expect(created.id == write.id)
            #expect(created.name == "build-worker")
            #expect(created.description == "builds images")
            #expect(created.projectID == projectID)
            #expect(created.createdAt != nil)
            #expect(created.updatedAt != nil)
            #expect(try await serviceAccounts.account(id: created.id) == created)
            #expect(try await serviceAccounts.accounts(projectID: projectID) == [created])
            #expect(try await serviceAccounts.accounts(ids: [created.id]) == [created])

            let initialFacts = try await facts(
                database: database, accountID: created.id, creatorID: creatorID)
            #expect(initialFacts.accountCount == 1)
            #expect(initialFacts.creatorGrantCount == 1)

            let updated = try #require(
                try await serviceAccounts.replaceDescription(
                    id: created.id,
                    description: "builds and publishes images"))
            #expect(updated.description == "builds and publishes images")
            #expect(updated.createdAt == created.createdAt)

            _ = try await database.withSession(operation: "test.service_accounts.seed_cleanup") {
                session in
                try await session.command(
                    """
                    INSERT INTO role_bindings (
                        id, principal_type, principal_id, role_id, node_type, node_id, created_at
                    ) VALUES
                        ('\(UUID())', 'service_account', '\(created.id)', '\(UUID())',
                         'project', '\(projectID)', CURRENT_TIMESTAMP),
                        ('\(UUID())', 'user', '\(UUID())', '\(UUID())',
                         'service_account', '\(created.id)', CURRENT_TIMESTAMP);
                    INSERT INTO workload_registrations (
                        id, spiffe_id, kind, service_account_id, created_at
                    ) VALUES (
                        '\(UUID())', 'spiffe://strato.test/service-account/build-worker',
                        'service_account', '\(created.id)', CURRENT_TIMESTAMP)
                    """,
                    operation: "test.service_accounts.seed_cleanup.query")
            }

            #expect(try await serviceAccounts.delete(id: created.id))
            #expect(try await serviceAccounts.account(id: created.id) == nil)
            let finalFacts = try await facts(
                database: database, accountID: created.id, creatorID: creatorID)
            #expect(finalFacts.accountCount == 0)
            #expect(finalFacts.creatorGrantCount == 0)
            #expect(finalFacts.heldBindingCount == 0)
            #expect(finalFacts.nodeBindingCount == 0)
            #expect(finalFacts.registrationCount == 0)
        }
    }

    @Test("project-local names remain unique under the catalog constraint")
    func duplicateName() async throws {
        try await withServiceAccountDatabase { _, serviceAccounts, projectID in
            _ = try await serviceAccounts.create(
                ServiceAccountWrite(name: "duplicate", projectID: projectID))
            await #expect(
                throws: ServiceAccountsPersistenceError.duplicateName(
                    projectID: projectID, name: "duplicate")
            ) {
                try await serviceAccounts.create(
                    ServiceAccountWrite(name: "duplicate", projectID: projectID))
            }
        }
    }

    private func facts(
        database: ControlPlanePostgres.PostgresDatabase,
        accountID: UUID,
        creatorID: UUID
    ) async throws -> ServiceAccountFactsSnapshot {
        try await database.withSession(operation: "test.service_accounts.facts") { session in
            try #require(
                try await session.execute(
                    ServiceAccountFacts(accountID: accountID, creatorID: creatorID),
                    operation: "test.service_accounts.facts.query").first)
        }
    }

    private func withServiceAccountDatabase(
        _ test: (
            ControlPlanePostgres.PostgresDatabase,
            ServiceAccountsPersistence,
            UUID
        ) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase { database in
            let projectID = UUID()
            _ = try await database.withSession(operation: "test.service_accounts.schema") {
                session in
                try await session.command(
                    """
                    CREATE TABLE projects (id UUID PRIMARY KEY);
                    INSERT INTO projects (id) VALUES ('\(projectID)');
                    CREATE TABLE service_accounts (
                        id UUID PRIMARY KEY,
                        name TEXT NOT NULL,
                        description TEXT NOT NULL,
                        project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                        created_at TIMESTAMPTZ,
                        updated_at TIMESTAMPTZ,
                        CONSTRAINT "uq:service_accounts.project_id+service_accounts.name"
                            UNIQUE (project_id, name)
                    );
                    CREATE TABLE role_bindings (
                        id UUID PRIMARY KEY,
                        principal_type TEXT NOT NULL,
                        principal_id UUID NOT NULL,
                        role_id UUID NOT NULL,
                        node_type TEXT NOT NULL,
                        node_id UUID NOT NULL,
                        condition TEXT,
                        expires_at TIMESTAMPTZ,
                        created_by UUID,
                        created_at TIMESTAMPTZ
                    );
                    CREATE TYPE workload_registration_kind AS ENUM (
                        'agent', 'service_account', 'workload'
                    );
                    CREATE TABLE workload_registrations (
                        id UUID PRIMARY KEY,
                        spiffe_id TEXT NOT NULL UNIQUE,
                        kind workload_registration_kind NOT NULL,
                        service_account_id UUID REFERENCES service_accounts(id) ON DELETE CASCADE,
                        created_at TIMESTAMPTZ
                    )
                    """,
                    operation: "test.service_accounts.schema.create")
            }
            try await test(
                database,
                ControlPlanePersistence(database: database).serviceAccounts,
                projectID)
        }
    }
}

private struct ServiceAccountFactsSnapshot: Sendable {
    let accountCount: Int
    let creatorGrantCount: Int
    let heldBindingCount: Int
    let nodeBindingCount: Int
    let registrationCount: Int
}

private struct ServiceAccountFacts: PostgresPreparedStatement {
    static let sql = """
        SELECT
            (SELECT count(*)::bigint FROM service_accounts WHERE id = $1),
            (SELECT count(*)::bigint FROM role_bindings
             WHERE principal_type = 'user' AND principal_id = $2
               AND node_type = 'service_account' AND node_id = $1),
            (SELECT count(*)::bigint FROM role_bindings
             WHERE principal_type = 'service_account' AND principal_id = $1),
            (SELECT count(*)::bigint FROM role_bindings
             WHERE node_type = 'service_account' AND node_id = $1),
            (SELECT count(*)::bigint FROM workload_registrations WHERE service_account_id = $1)
        """
    typealias Row = ServiceAccountFactsSnapshot
    let accountID: UUID
    let creatorID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(accountID)
        bindings.append(creatorID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> ServiceAccountFactsSnapshot {
        let value = try row.decode((Int, Int, Int, Int, Int).self)
        return ServiceAccountFactsSnapshot(
            accountCount: value.0,
            creatorGrantCount: value.1,
            heldBindingCount: value.2,
            nodeBindingCount: value.3,
            registrationCount: value.4)
    }
}
