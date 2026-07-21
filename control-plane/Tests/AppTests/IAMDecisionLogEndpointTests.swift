import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import App

/// The decision-log burn-down API (`/api/iam/decision-logs`, issue #481).
///
/// These rows span organizations — a decision names whatever the caller
/// touched — so the system-admin gate is the only thing between a normal user
/// and a cross-tenant record of who checked what. `/api/iam` is not one of
/// `AuthorizationMiddleware`'s guarded prefixes, which makes the controller's
/// own `requireSystemAdmin` the sole gate and worth pinning here.
@Suite("IAM Decision Log Endpoint Tests", .serialized)
final class IAMDecisionLogEndpointTests {

    private struct Fixture {
        let user: User
        let token: String
    }

    private func withApp(
        systemAdmin: Bool = true,
        _ test: (Application, Fixture) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: systemAdmin ? "decisionadmin" : "decisionuser",
                email: systemAdmin ? "decision-admin@example.com" : "decision-user@example.com",
                displayName: "Decision User",
                isSystemAdmin: systemAdmin
            )
            let org = try await builder.createOrganization(name: "Decision Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let token = try await user.generateAPIKey(on: app.db)
            try await test(app, Fixture(user: user, token: token))
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    /// Insert one row, optionally backdated. `@Timestamp(on: .create)` stamps
    /// `createdAt` on insert, so an explicit age is a second save.
    /// The `spicedb*`-named fields are historical column names kept on the
    /// model; the API filters on them regardless of who wrote the row.
    @discardableResult
    private func insert(
        _ app: Application,
        permission: String = "read",
        action: String? = "vm:read",
        spicedb: String = "allow",
        cedar: String = "allow",
        match: Bool? = true,
        tier: String? = "grant",
        age: TimeInterval = 0
    ) async throws -> IAMDecisionLog {
        let entry = IAMDecisionLog()
        entry.subject = UUID().uuidString
        entry.spicedbPermission = permission
        entry.resourceType = "virtual_machine"
        entry.resourceID = UUID().uuidString
        entry.iamAction = action
        entry.spicedbDecision = spicedb
        entry.cedarDecision = cedar
        entry.decisionsMatch = match
        entry.tier = tier
        entry.path = "/api/vms"
        entry.method = "GET"
        try await entry.save(on: app.db)
        if age > 0 {
            entry.createdAt = Date().addingTimeInterval(-age)
            try await entry.save(on: app.db)
        }
        return entry
    }

    /// Matches how the JSON response encodes `createdAt`, so the cursor under
    /// test is the cursor a caller actually reads back.
    private func iso8601(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }

    // MARK: - The gate

    @Test("A non-admin cannot read decision logs")
    func nonAdminForbidden() async throws {
        try await withApp(systemAdmin: false) { app, fixture in
            for path in ["/api/iam/decision-logs", "/api/iam/decision-logs/summary"] {
                try await app.test(
                    .GET, path,
                    beforeRequest: { req in
                        req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    },
                    afterResponse: { res in
                        #expect(res.status == .forbidden, "\(path)")
                    })
            }
        }
    }

    @Test("An anonymous caller cannot read decision logs")
    func anonymousUnauthorized() async throws {
        try await withApp { app, _ in
            try await app.test(
                .GET, "/api/iam/decision-logs",
                afterResponse: { res in
                    #expect(res.status == .unauthorized)
                })
        }
    }

    // MARK: - Listing

    @Test("A system admin lists decision rows newest first")
    func listsNewestFirst() async throws {
        try await withApp { app, fixture in
            try await insert(app, permission: "old", age: 3600)
            try await insert(app, permission: "new")

            try await app.test(
                .GET, "/api/iam/decision-logs",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let rows = try res.content.decode([IAMDecisionLogController.DecisionLogDTO].self)
                    #expect(rows.count == 2)
                    #expect(rows.first?.spicedbPermission == "new")
                    #expect(rows.last?.spicedbPermission == "old")
                })
        }
    }

    @Test("mismatchesOnly returns disagreements and excludes verdict-less rows")
    func mismatchesOnlyFilters() async throws {
        try await withApp { app, fixture in
            try await insert(app, permission: "agreed", match: true)
            try await insert(
                app, permission: "disagreed", spicedb: "allow", cedar: "deny", match: false,
                tier: "default-deny")
            // No Cedar verdict at all: decisions_match is NULL, which must not
            // read as a mismatch.
            try await insert(
                app, permission: "untranslated", action: nil, cedar: "untranslated", match: nil,
                tier: nil)

            try await app.test(
                .GET, "/api/iam/decision-logs?mismatchesOnly=true",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let rows = try res.content.decode([IAMDecisionLogController.DecisionLogDTO].self)
                    #expect(rows.count == 1)
                    #expect(rows.first?.spicedbPermission == "disagreed")
                })
        }
    }

    /// The regression this file exists for. `req.query.get(Date.self)` decodes
    /// `.secondsSince1970`, so an ISO8601 cursor — which is exactly what the
    /// JSON response hands back — used to fail to decode and, under `try?`,
    /// silently drop the filter: every page returned the newest rows forever.
    @Test("An ISO8601 before-cursor actually pages")
    func beforeCursorPages() async throws {
        try await withApp { app, fixture in
            try await insert(app, permission: "older", age: 7200)
            try await insert(app, permission: "newer")

            let cursor = iso8601(Date().addingTimeInterval(-3600))
            let encoded =
                cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cursor

            try await app.test(
                .GET, "/api/iam/decision-logs?before=\(encoded)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let rows = try res.content.decode([IAMDecisionLogController.DecisionLogDTO].self)
                    #expect(rows.count == 1)
                    #expect(rows.first?.spicedbPermission == "older")
                })
        }
    }

    @Test("Malformed pagination parameters are rejected, not silently ignored")
    func malformedParametersRejected() async throws {
        try await withApp { app, fixture in
            for path in [
                "/api/iam/decision-logs?before=yesterday",
                "/api/iam/decision-logs?limit=abc",
                "/api/iam/decision-logs/summary?sinceHours=lots",
            ] {
                try await app.test(
                    .GET, path,
                    beforeRequest: { req in
                        req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    },
                    afterResponse: { res in
                        #expect(res.status == .badRequest, "\(path)")
                    })
            }
        }
    }

    // MARK: - Summary

    @Test("The summary buckets decisions by permission, verdicts, and tier")
    func summaryBuckets() async throws {
        try await withApp { app, fixture in
            try await insert(app, permission: "read", match: true)
            try await insert(app, permission: "read", match: true)
            try await insert(
                app, permission: "start", spicedb: "allow", cedar: "deny", match: false,
                tier: "guardrail")

            try await app.test(
                .GET, "/api/iam/decision-logs/summary",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let buckets = try res.content.decode(
                        [IAMDecisionLogController.DecisionSummaryDTO].self)
                    #expect(buckets.count == 2)
                    // Largest bucket first.
                    #expect(buckets.first?.spicedbPermission == "read")
                    #expect(buckets.first?.count == 2)
                    let guardrail = buckets.first { $0.spicedbPermission == "start" }
                    #expect(guardrail?.count == 1)
                    #expect(guardrail?.cedarDecision == "deny")
                    #expect(guardrail?.tier == "guardrail")
                })
        }
    }

    /// The summary is time-bounded so it rides the `created_at` index instead
    /// of scanning the whole retention window.
    @Test("The summary window excludes rows older than sinceHours")
    func summaryRespectsWindow() async throws {
        try await withApp { app, fixture in
            try await insert(app, permission: "recent")
            try await insert(app, permission: "ancient", age: 60 * 60 * 72)

            try await app.test(
                .GET, "/api/iam/decision-logs/summary?sinceHours=24",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let buckets = try res.content.decode(
                        [IAMDecisionLogController.DecisionSummaryDTO].self)
                    #expect(buckets.count == 1)
                    #expect(buckets.first?.spicedbPermission == "recent")
                })

            // Widen the window and the old row comes back — proving the
            // exclusion above was the window, not a lost row.
            try await app.test(
                .GET, "/api/iam/decision-logs/summary?sinceHours=96",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    let buckets = try res.content.decode(
                        [IAMDecisionLogController.DecisionSummaryDTO].self)
                    #expect(buckets.count == 2)
                })
        }
    }
}
