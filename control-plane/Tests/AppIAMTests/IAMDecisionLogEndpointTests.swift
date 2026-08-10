import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

import AppTestSupport
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
    @discardableResult
    private func insert(
        _ app: Application,
        action: String? = "vm:read",
        nodeType: IAMNodeType? = .virtualMachine,
        decision: String = "allow",
        tier: String? = "grant",
        age: TimeInterval = 0
    ) async throws -> IAMDecisionLog {
        let entry = IAMDecisionLog()
        entry.subject = UUID().uuidString
        entry.action = action
        entry.nodeType = nodeType?.rawValue
        entry.nodeID = nodeType == nil ? nil : UUID()
        entry.decision = decision
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
            try await insert(app, action: "vm:read", age: 3600)
            try await insert(app, action: "vm:update")

            try await app.test(
                .GET, "/api/iam/decision-logs",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let rows = try res.content.decode([IAMDecisionLogController.DecisionLogDTO].self)
                    #expect(rows.count == 2)
                    #expect(rows.first?.action == "vm:update")
                    #expect(rows.last?.action == "vm:read")
                    #expect(rows.first?.nodeType == IAMNodeType.virtualMachine.rawValue)
                    #expect(rows.first?.decision == "allow")
                })
        }
    }

    @Test("The API returns canonical decisions, including node-less credential refusals")
    func canonicalDecisionShapes() async throws {
        try await withApp { app, fixture in
            try await insert(app, action: "vm:delete", decision: "deny", tier: "default-deny")
            try await insert(
                app, action: nil, nodeType: nil, decision: "credential_restricted",
                tier: "credential")

            try await app.test(
                .GET, "/api/iam/decision-logs",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let rows = try res.content.decode([IAMDecisionLogController.DecisionLogDTO].self)
                    #expect(rows.count == 2)
                    let denied = try #require(rows.first { $0.action == "vm:delete" })
                    #expect(denied.decision == "deny")
                    #expect(denied.nodeType == IAMNodeType.virtualMachine.rawValue)
                    let restricted = try #require(rows.first { $0.decision == "credential_restricted" })
                    #expect(restricted.action == nil)
                    #expect(restricted.nodeType == nil)
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
            try await insert(app, action: "vm:read", age: 7200)
            try await insert(app, action: "vm:update")

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
                    #expect(rows.first?.action == "vm:read")
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

    @Test("The summary buckets decisions by canonical action, verdict, and tier")
    func summaryBuckets() async throws {
        try await withApp { app, fixture in
            try await insert(app, action: "vm:read")
            try await insert(app, action: "vm:read")
            try await insert(
                app, action: "vm:start", decision: "deny", tier: "guardrail")

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
                    #expect(buckets.first?.action == "vm:read")
                    #expect(buckets.first?.count == 2)
                    let guardrail = buckets.first { $0.action == "vm:start" }
                    #expect(guardrail?.count == 1)
                    #expect(guardrail?.decision == "deny")
                    #expect(guardrail?.tier == "guardrail")
                })
        }
    }

    /// The summary is time-bounded so it rides the `created_at` index instead
    /// of scanning the whole retention window.
    @Test("The summary window excludes rows older than sinceHours")
    func summaryRespectsWindow() async throws {
        try await withApp { app, fixture in
            try await insert(app, action: "vm:read")
            try await insert(app, action: "vm:update", age: 60 * 60 * 72)

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
                    #expect(buckets.first?.action == "vm:read")
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
