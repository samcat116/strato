import Foundation
import PostgresNIO
import Testing

@testable import ControlPlanePostgres

@Suite("Native agent-enrollment persistence", .serialized)
struct AgentEnrollmentsPersistenceTests {
    @Test("create, list, scope, use, and duplicate-name semantics")
    func lifecycle() async throws {
        try await withAgentEnrollmentDatabase { database, enrollments in
            let organizationID = UUID()
            let organizationalUnitID = UUID()
            let first = try await enrollments.create(
                write(
                    suffix: "first",
                    organizationID: organizationID,
                    organizationalUnitID: nil
                )
            )
            let second = try await enrollments.create(
                write(
                    suffix: "second",
                    organizationID: nil,
                    organizationalUnitID: organizationalUnitID
                )
            )

            #expect(first.createdAt != nil)
            #expect(first.hasBootstrapToken)
            #expect(first.isValid())
            #expect(try await enrollments.find(id: first.id) == first)
            #expect(
                try await enrollments.latest(
                    trustDomain: first.trustDomain,
                    agentName: first.agentName
                ) == first
            )
            #expect(try await enrollments.list().map(\.id) == [second.id, first.id])
            #expect(
                try await enrollments.list(
                    filter: AgentEnrollmentListFilter(
                        organizationID: UUID(),
                        organizationalUnitIDs: [organizationalUnitID]
                    )
                ).map(\.id) == [second.id]
            )
            #expect(try await enrollments.markUsed(id: first.id))
            let used = try #require(try await enrollments.find(id: first.id))
            #expect(used.isUsed)
            #expect(!used.hasBootstrapToken)
            #expect(used.usedAt != nil)
            #expect(!(try await enrollments.markUsed(id: first.id)))

            await #expect(
                throws: AgentEnrollmentPersistenceError.duplicateAgentName(
                    trustDomain: first.trustDomain,
                    agentName: first.agentName
                )
            ) {
                _ = try await enrollments.create(
                    write(
                        suffix: "duplicate",
                        trustDomain: first.trustDomain,
                        agentName: first.agentName
                    )
                )
            }

            #expect(try await enrollmentCount(database: database) == 2)
        }
    }

    @Test("concurrent bootstrap replay has exactly one winner")
    func concurrentRedemption() async throws {
        try await withAgentEnrollmentDatabase(maximumConnections: 2) { _, enrollments in
            let enrollment = try await enrollments.create(write(suffix: "redeem"))
            let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        do {
                            let id = try await enrollments.redeemBootstrapToken(
                                tokenHash: "hash-redeem"
                            ) { snapshot in
                                try await Task.sleep(for: .milliseconds(50))
                                return snapshot.id
                            }
                            return id == enrollment.id
                        } catch AgentEnrollmentPersistenceError.invalidBootstrapToken {
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
            let consumed = try #require(try await enrollments.find(id: enrollment.id))
            #expect(!consumed.hasBootstrapToken)
            #expect(!consumed.isUsed)
        }
    }

    @Test("failed external revocation retains the row and a retry deletes it")
    func revocationFailureIsRetryable() async throws {
        struct ExternalFailure: Error {}

        try await withAgentEnrollmentDatabase { _, enrollments in
            let enrollment = try await enrollments.create(write(suffix: "revoke"))

            await #expect(throws: ExternalFailure.self) {
                try await enrollments.revoke(id: enrollment.id) { snapshot, ownsGrant in
                    #expect(snapshot.id == enrollment.id)
                    #expect(ownsGrant)
                    throw ExternalFailure()
                }
            }
            #expect(try await enrollments.find(id: enrollment.id) != nil)

            let result = try await enrollments.revoke(id: enrollment.id) { _, ownsGrant in
                ownsGrant
            }
            #expect(result)
            #expect(try await enrollments.find(id: enrollment.id) == nil)
        }
    }

    @Test("a registered agent owns its external grant instead of the enrollment")
    func registeredAgentChangesRevocationDisposition() async throws {
        try await withAgentEnrollmentDatabase { database, enrollments in
            let enrollment = try await enrollments.create(write(suffix: "registered"))
            try await database.withSession(operation: "test.agent_enrollments.seed_agent") { session in
                _ = try await session.execute(
                    InsertRegisteredAgent(
                        trustDomain: enrollment.trustDomain,
                        name: enrollment.agentName
                    ),
                    operation: "test.agent_enrollments.seed_agent.insert"
                )
            }

            let ownsGrant = try await enrollments.revoke(id: enrollment.id) { _, ownsGrant in
                ownsGrant
            }
            #expect(!ownsGrant)
        }
    }

    private func write(
        suffix: String,
        trustDomain: String = "test.example",
        agentName: String? = nil,
        organizationID: UUID? = nil,
        organizationalUnitID: UUID? = nil
    ) -> AgentEnrollmentWrite {
        AgentEnrollmentWrite(
            agentName: agentName ?? "agent-\(suffix)",
            trustDomain: trustDomain,
            spiffeID: "spiffe://\(trustDomain)/agent/\(agentName ?? "agent-\(suffix)")",
            bootstrapTokenHash: "hash-\(suffix)",
            siteID: UUID(),
            organizationID: organizationID,
            organizationalUnitID: organizationalUnitID,
            expiresAt: Date().addingTimeInterval(3600)
        )
    }

    private func withAgentEnrollmentDatabase(
        maximumConnections: Int = 1,
        _ test: (
            ControlPlanePostgres.PostgresDatabase,
            AgentEnrollmentsPersistence
        ) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase(
            maximumConnections: maximumConnections
        ) { database in
            try await database.withSession(operation: "test.agent_enrollments.schema") { session in
                _ = try await session.command(
                    """
                    CREATE TABLE agent_enrollments (
                        id UUID PRIMARY KEY,
                        agent_name TEXT NOT NULL,
                        trust_domain TEXT NOT NULL,
                        spiffe_id TEXT NOT NULL,
                        bootstrap_token_hash TEXT UNIQUE,
                        is_used BOOLEAN NOT NULL,
                        site_id UUID,
                        organization_id UUID,
                        organizational_unit_id UUID,
                        expires_at TIMESTAMPTZ NOT NULL,
                        created_at TIMESTAMPTZ,
                        used_at TIMESTAMPTZ,
                        CONSTRAINT "uq:agent_enrollments.trust_domain+agent_enrollments.agent_name"
                            UNIQUE (trust_domain, agent_name)
                    )
                    """,
                    operation: "test.agent_enrollments.schema.create_enrollments"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE agents (
                        id UUID PRIMARY KEY,
                        trust_domain TEXT NOT NULL,
                        name TEXT NOT NULL
                    )
                    """,
                    operation: "test.agent_enrollments.schema.create_agents"
                )
            }
            try await test(
                database,
                ControlPlanePersistence(database: database).agentEnrollments
            )
        }
    }
}

private func enrollmentCount(
    database: ControlPlanePostgres.PostgresDatabase
) async throws -> Int64 {
    try await database.withSession(operation: "test.agent_enrollments.count") { session in
        try #require(
            try await session.execute(
                CountAgentEnrollments(),
                operation: "test.agent_enrollments.count.query"
            ).first
        )
    }
}

private struct CountAgentEnrollments: PostgresPreparedStatement {
    static let sql = "SELECT COUNT(*) FROM agent_enrollments"
    typealias Row = Int64

    func makeBindings() -> PostgresBindings { PostgresBindings() }
    func decodeRow(_ row: PostgresRow) throws -> Int64 { try row.decode(Int64.self) }
}

private struct InsertRegisteredAgent: PostgresPreparedStatement {
    static let sql = "INSERT INTO agents (id, trust_domain, name) VALUES ($1, $2, $3) RETURNING id"
    typealias Row = UUID
    let trustDomain: String
    let name: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(UUID())
        bindings.append(trustDomain)
        bindings.append(name)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}
