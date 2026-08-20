import Foundation
import Testing

@testable import ControlPlanePostgres

@Suite("Native audit-event persistence", .serialized)
struct AuditEventsPersistenceTests {
    @Test("batch append preserves nullable fields and metadata")
    func batchAppendRoundTrips() async throws {
        try await withAuditDatabase { events in
            let userID = UUID()
            let organizationID = UUID()
            let writes = [
                AuditEventWrite(
                    eventType: "api.request",
                    userID: userID,
                    username: "neo",
                    organizationID: organizationID,
                    method: "POST",
                    path: "/api/vms",
                    status: 202,
                    resourceType: "vms",
                    resourceID: "vm-1",
                    action: "create",
                    sourceIP: "192.0.2.10",
                    adminBypass: true,
                    metadata: ["request_id": "req-1"]
                ),
                AuditEventWrite(eventType: "auth.logout"),
            ]

            let inserted = try await events.append(writes)
            #expect(inserted.count == 2)
            let request = try #require(inserted.first { $0.eventType == "api.request" })
            #expect(request.userID == userID)
            #expect(request.organizationID == organizationID)
            #expect(request.status == 202)
            #expect(request.adminBypass)
            #expect(request.metadata == ["request_id": "req-1"])
            #expect(request.createdAt != nil)

            let logout = try #require(inserted.first { $0.eventType == "auth.logout" })
            #expect(logout.userID == nil)
            #expect(logout.metadata == nil)
            #expect(logout.createdAt != nil)
        }
    }

    @Test("filters, ordering, total, and pagination match the query contract")
    func filteredPagination() async throws {
        try await withAuditDatabase { events in
            let organizationID = UUID()
            let userID = UUID()
            let base = Date(timeIntervalSince1970: 1_000)
            _ = try await events.append([
                AuditEventWrite(
                    eventType: "test.alpha", userID: userID,
                    organizationID: organizationID, adminBypass: true,
                    createdAt: base),
                AuditEventWrite(
                    eventType: "test.alpha", userID: userID,
                    organizationID: organizationID,
                    createdAt: base.addingTimeInterval(1)),
                AuditEventWrite(
                    eventType: "test.beta", organizationID: UUID(),
                    createdAt: base.addingTimeInterval(2)),
            ])

            let page = try await events.events(
                matching: AuditEventFilter(
                    organizationID: organizationID,
                    eventType: "test.alpha",
                    userID: userID,
                    createdAtOrAfter: base,
                    createdAtOrBefore: base.addingTimeInterval(2)
                ),
                limit: 1,
                offset: 0
            )
            #expect(page.total == 2)
            #expect(page.events.count == 1)
            #expect(page.events[0].createdAt == base.addingTimeInterval(1))

            let admin = try await events.events(
                matching: AuditEventFilter(
                    organizationID: organizationID,
                    eventType: "test.alpha",
                    adminOnly: true
                ),
                limit: 50
            )
            #expect(admin.total == 1)
            #expect(admin.events[0].adminBypass)
        }
    }

    @Test("retention deletion returns the exact affected row count")
    func retentionDelete() async throws {
        try await withAuditDatabase { events in
            let cutoff = Date(timeIntervalSince1970: 10_000)
            _ = try await events.append([
                AuditEventWrite(
                    eventType: "expired.one",
                    createdAt: cutoff.addingTimeInterval(-2)),
                AuditEventWrite(
                    eventType: "expired.two",
                    createdAt: cutoff.addingTimeInterval(-1)),
                AuditEventWrite(
                    eventType: "retained",
                    createdAt: cutoff),
            ])

            #expect(try await events.delete(createdBefore: cutoff) == 2)
            let remaining = try await events.events(limit: 50)
            #expect(remaining.total == 1)
            #expect(remaining.events.map(\.eventType) == ["retained"])
        }
    }

    private func withAuditDatabase(
        _ test: (AuditEventsPersistence) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase { database in
            try await database.withSession(operation: "test.audit_events.schema") { session in
                try await session.command(
                    """
                    CREATE TABLE audit_events (
                        id UUID PRIMARY KEY,
                        event_type TEXT NOT NULL,
                        user_id UUID,
                        username TEXT,
                        api_key_id UUID,
                        organization_id UUID,
                        method TEXT,
                        path TEXT,
                        status BIGINT,
                        resource_type TEXT,
                        resource_id TEXT,
                        action TEXT,
                        source_ip TEXT,
                        admin_bypass BOOLEAN NOT NULL DEFAULT false,
                        metadata TEXT,
                        created_at TIMESTAMPTZ
                    )
                    """,
                    operation: "test.audit_events.schema.create"
                )
            }
            try await test(ControlPlanePersistence(database: database).auditEvents)
        }
    }
}
