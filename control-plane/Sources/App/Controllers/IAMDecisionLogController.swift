import ControlPlanePostgres
import Foundation
import Vapor

/// The decision-log read API (IAM phase 4, issue #481).
/// System-admin only: decision rows span organizations (a check names
/// whatever the caller touched), and this is an operator tool, not a
/// customer surface.
struct IAMDecisionLogController: RouteCollection {
    private let decisionLogs: DecisionLogsPersistence

    init(decisionLogs: DecisionLogsPersistence) {
        self.decisionLogs = decisionLogs
    }

    func boot(routes: RoutesBuilder) throws {
        let logs = routes.grouped("api", "iam", "decision-logs")
        logs.get(use: list)
        logs.get("summary", use: summary)
    }

    // MARK: - DTOs

    struct DecisionLogDTO: Content {
        let id: UUID
        let requestID: String?
        let path: String?
        let method: String?
        let subject: String
        let action: String?
        let nodeType: String?
        let nodeID: UUID?
        let organizationID: UUID?
        let decision: String
        let determiningPolicies: [String]
        let tier: String?
        let cedarErrors: String?
        let policyVersion: Int?
        let skippedConditionedBindings: Int?
        /// The credential the request arrived on (STR-115), so an audit can ask
        /// "everything this token did" of the log directly.
        let credentialType: String?
        let credentialID: UUID?
        let createdAt: Date?

        init(_ entry: DecisionLogSnapshot) {
            self.id = entry.id
            self.requestID = entry.requestID
            self.path = entry.path
            self.method = entry.method
            self.subject = entry.subject
            self.action = entry.action
            self.nodeType = entry.nodeType
            self.nodeID = entry.nodeID
            self.organizationID = entry.organizationID
            self.decision = entry.decision
            self.determiningPolicies = entry.determiningPolicies
            self.tier = entry.tier
            self.cedarErrors = entry.cedarErrors
            self.policyVersion = entry.policyVersion
            self.skippedConditionedBindings = entry.skippedConditionedBindings
            self.credentialType = entry.credentialType
            self.credentialID = entry.credentialID
            self.createdAt = entry.createdAt
        }
    }

    /// One decision bucket, grouped by canonical action, verdict, and tier.
    struct DecisionSummaryDTO: Content {
        let action: String?
        let decision: String
        let tier: String?
        let count: Int
    }

    // MARK: - Handlers

    /// `GET /api/iam/decision-logs?limit=100&before=<iso8601>`
    /// — newest first. `before` is the `createdAt` of the oldest row of the
    /// previous page, verbatim: responses encode dates as ISO8601, so the
    /// cursor a caller reads back is the cursor it can pass in.
    func list(req: Request) async throws -> [DecisionLogDTO] {
        try await requireSystemAdmin(req)

        let limit = try req.intQuery("limit", default: 100, in: 1...500)

        let page = try await decisionLogs.entries(
            matching: DecisionLogFilter(createdBefore: try timestampQuery(req, "before")),
            limit: limit
        )
        return page.entries.map(DecisionLogDTO.init)
    }

    /// `GET /api/iam/decision-logs/summary?sinceHours=24&limit=200` — the
    /// decision counts bucketed by canonical action, verdict, and tier,
    /// largest buckets first.
    ///
    /// Time-bounded on purpose. The log takes a row per authorization check,
    /// so an unbounded `GROUP BY` is a sequential scan over the whole retention
    /// window — the endpoint an operator refreshes most would be the one that
    /// pins the database. The `created_at` index bounds the scan instead.
    func summary(req: Request) async throws -> [DecisionSummaryDTO] {
        try await requireSystemAdmin(req)

        let sinceHours = try req.intQuery("sinceHours", default: 24, in: 1...(24 * 90))
        let limit = try req.intQuery("limit", default: 200, in: 1...1000)
        let since = Date().addingTimeInterval(-Double(sinceHours) * 3600)

        let rows = try await decisionLogs.summary(createdAtOrAfter: since, limit: limit)

        return rows.map {
            DecisionSummaryDTO(
                action: $0.action, decision: $0.decision, tier: $0.tier, count: $0.count
            )
        }
    }

    // MARK: - Query parsing

    /// An ISO8601 timestamp query parameter, or `nil` when absent.
    ///
    /// Parsed explicitly rather than through `req.query.get(Date.self)`:
    /// Vapor's URL-encoded form decoder defaults to `.secondsSince1970`, so an
    /// ISO8601 cursor — which is exactly what the JSON response hands back —
    /// would fail to decode and, under `try?`, silently drop the filter and
    /// return the same page forever.
    ///
    /// `ISO8601FormatStyle` rather than `ISO8601DateFormatter` because the
    /// latter is a non-`Sendable` class. Fractional seconds are tolerated on
    /// input even though responses never emit them.
    private func timestampQuery(_ req: Request, _ name: String) throws -> Date? {
        guard let raw: String = req.query[name], !raw.isEmpty else { return nil }
        if let date = try? Date(raw, strategy: Date.ISO8601FormatStyle()) {
            return date
        }
        if let date = try? Date(
            raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        {
            return date
        }
        throw Abort(
            .badRequest,
            reason: "Query parameter '\(name)' must be an ISO8601 timestamp (e.g. 2026-07-19T12:00:00Z)")
    }

    private func requireSystemAdmin(_ req: Request) async throws {
        // The shared decision-marking gate, so these admin-only reads are
        // flagged for the admin audit trail like every other admin surface.
        _ = try await req.requireSystemAdmin("Decision logs require system administrator access")
    }
}
