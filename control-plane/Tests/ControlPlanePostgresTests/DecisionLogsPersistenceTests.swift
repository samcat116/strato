import Foundation
import Testing

@testable import ControlPlanePostgres

@Suite("Native IAM decision-log persistence", .serialized)
struct DecisionLogsPersistenceTests {
    @Test("batch append preserves decision provenance and nullable fields")
    func batchAppendRoundTrips() async throws {
        try await withDecisionLogDatabase { logs in
            let nodeID = UUID()
            let credentialID = UUID()
            let rows = try await logs.append([
                DecisionLogWrite(
                    requestID: "request-1",
                    path: "/api/vms",
                    method: "GET",
                    subject: UUID().uuidString,
                    action: "vm:read",
                    nodeType: "virtual_machine",
                    nodeID: nodeID,
                    organizationID: UUID(),
                    decision: "deny",
                    determiningPolicies: ["guardrail-1", "role-viewer"],
                    tier: "guardrail",
                    cedarErrors: "evaluation detail",
                    policyVersion: 7,
                    skippedConditionedBindings: 2,
                    credentialType: "api_key",
                    credentialID: credentialID
                ),
                DecisionLogWrite(subject: "workload", decision: "credential_restricted"),
            ])

            #expect(rows.count == 2)
            let denied = try #require(rows.first { $0.action == "vm:read" })
            #expect(denied.nodeID == nodeID)
            #expect(denied.determiningPolicies == ["guardrail-1", "role-viewer"])
            #expect(denied.policyVersion == 7)
            #expect(denied.skippedConditionedBindings == 2)
            #expect(denied.credentialID == credentialID)
            #expect(denied.createdAt != nil)

            let restricted = try #require(rows.first { $0.decision == "credential_restricted" })
            #expect(restricted.action == nil)
            #expect(restricted.determiningPolicies.isEmpty)
        }
    }

    @Test("filters, pagination, and newest-first ordering share one contract")
    func filtersAndPagination() async throws {
        try await withDecisionLogDatabase { logs in
            let nodeID = UUID()
            let base = Date(timeIntervalSince1970: 20_000)
            _ = try await logs.append([
                DecisionLogWrite(
                    subject: "subject-a", action: "vm:read", nodeID: nodeID,
                    decision: "allow", createdAt: base),
                DecisionLogWrite(
                    subject: "subject-a", action: "vm:read", nodeID: nodeID,
                    decision: "deny", createdAt: base.addingTimeInterval(1)),
                DecisionLogWrite(
                    subject: "subject-b", action: "vm:update", decision: "allow",
                    createdAt: base.addingTimeInterval(2)),
            ])

            let page = try await logs.entries(
                matching: DecisionLogFilter(
                    nodeID: nodeID,
                    action: "vm:read",
                    subject: "subject-a"
                ),
                limit: 1
            )
            #expect(page.total == 2)
            #expect(page.entries.count == 1)
            #expect(page.entries[0].decision == "deny")

            let before = try await logs.entries(
                matching: DecisionLogFilter(createdBefore: base.addingTimeInterval(0.5)),
                limit: 50
            )
            #expect(before.entries.map(\.decision) == ["allow"])
        }
    }

    @Test("summary and retention use database timestamps")
    func summaryAndRetention() async throws {
        try await withDecisionLogDatabase { logs in
            let cutoff = Date(timeIntervalSince1970: 30_000)
            _ = try await logs.append([
                DecisionLogWrite(
                    subject: "old", action: "vm:update", decision: "deny",
                    tier: "guardrail", createdAt: cutoff.addingTimeInterval(-1)),
                DecisionLogWrite(
                    subject: "new-1", action: "vm:read", decision: "allow",
                    tier: "grant", createdAt: cutoff),
                DecisionLogWrite(
                    subject: "new-2", action: "vm:read", decision: "allow",
                    tier: "grant", createdAt: cutoff.addingTimeInterval(1)),
            ])

            let summary = try await logs.summary(
                createdAtOrAfter: cutoff,
                limit: 20
            )
            #expect(summary == [
                DecisionLogSummary(action: "vm:read", decision: "allow", tier: "grant", count: 2)
            ])

            #expect(try await logs.delete(createdBefore: cutoff) == 1)
            #expect(try await logs.entries(limit: 50).total == 2)
        }
    }

    private func withDecisionLogDatabase(
        _ test: (DecisionLogsPersistence) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase { database in
            _ = try await database.withSession(operation: "test.decision_logs.schema") { session in
                try await session.command(
                    """
                    CREATE TABLE iam_decision_logs (
                        id UUID PRIMARY KEY,
                        request_id TEXT,
                        path TEXT,
                        method TEXT,
                        subject TEXT NOT NULL,
                        action TEXT,
                        node_type TEXT,
                        node_id UUID,
                        organization_id UUID,
                        decision TEXT NOT NULL,
                        determining_policies TEXT,
                        tier TEXT,
                        cedar_errors TEXT,
                        policy_version BIGINT,
                        skipped_conditioned_bindings BIGINT,
                        created_at TIMESTAMPTZ,
                        credential_type TEXT,
                        credential_id UUID
                    )
                    """,
                    operation: "test.decision_logs.schema.create"
                )
            }
            try await test(ControlPlanePersistence(database: database).decisionLogs)
        }
    }
}
