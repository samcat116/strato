import Fluent
import Foundation
import SQLKit
import Vapor

/// The decision-log read API (IAM phase 4, issue #481) — what the mismatch
/// burn-down works from. System-admin only: decision rows span organizations
/// (a check names whatever the caller touched), and pre-cutover this is an
/// operator tool, not a customer surface.
struct IAMDecisionLogController: RouteCollection {
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
        let spicedbPermission: String
        let resourceType: String
        let resourceID: String
        let iamAction: String?
        let nodeType: String?
        let nodeID: UUID?
        let organizationID: UUID?
        let spicedbDecision: String
        let cedarDecision: String
        let decisionsMatch: Bool?
        let determiningPolicies: [String]
        let tier: String?
        let cedarErrors: String?
        let policyVersion: Int?
        let skippedConditionedBindings: Int?
        let createdAt: Date?

        init(_ entry: IAMDecisionLog) throws {
            self.id = try entry.requireID()
            self.requestID = entry.requestID
            self.path = entry.path
            self.method = entry.method
            self.subject = entry.subject
            self.spicedbPermission = entry.spicedbPermission
            self.resourceType = entry.resourceType
            self.resourceID = entry.resourceID
            self.iamAction = entry.iamAction
            self.nodeType = entry.nodeType
            self.nodeID = entry.nodeID
            self.organizationID = entry.organizationID
            self.spicedbDecision = entry.spicedbDecision
            self.cedarDecision = entry.cedarDecision
            self.decisionsMatch = entry.decisionsMatch
            self.determiningPolicies = entry.determiningPolicies
            self.tier = entry.tier
            self.cedarErrors = entry.cedarErrors
            self.policyVersion = entry.policyVersion
            self.skippedConditionedBindings = entry.skippedConditionedBindings
            self.createdAt = entry.createdAt
        }
    }

    /// One burn-down bucket: every distinct way a (permission, action) pair
    /// has decided, with how often.
    struct DecisionSummaryDTO: Content {
        let spicedbPermission: String
        let iamAction: String?
        let spicedbDecision: String
        let cedarDecision: String
        let tier: String?
        let count: Int
    }

    // MARK: - Handlers

    /// `GET /api/iam/decision-logs?mismatchesOnly=true&limit=100&before=<iso8601>`
    /// — newest first. `before` is the `createdAt` of the oldest row of the
    /// previous page, verbatim: responses encode dates as ISO8601, so the
    /// cursor a caller reads back is the cursor it can pass in.
    func list(req: Request) async throws -> [DecisionLogDTO] {
        try requireSystemAdmin(req)

        let limit = min(max(try intQuery(req, "limit") ?? 100, 1), 500)
        let mismatchesOnly = (try? req.query.get(Bool.self, at: "mismatchesOnly")) ?? false

        let query = IAMDecisionLog.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .limit(limit)
        if mismatchesOnly {
            query.filter(\.$decisionsMatch == false)
        }
        if let before = try timestampQuery(req, "before") {
            query.filter(\.$createdAt < before)
        }

        return try await query.all().map { try DecisionLogDTO($0) }
    }

    /// `GET /api/iam/decision-logs/summary?sinceHours=24&limit=200` — the
    /// burn-down view: decision counts bucketed by permission, action, both
    /// verdicts, and tier, largest buckets first. One glance says which
    /// mismatch classes remain and how big each is.
    ///
    /// Time-bounded on purpose. The log takes a row per authorization check,
    /// so an unbounded `GROUP BY` is a sequential scan over the whole retention
    /// window — the endpoint an operator refreshes most would be the one that
    /// pins the database. The `created_at` index bounds the scan instead.
    func summary(req: Request) async throws -> [DecisionSummaryDTO] {
        try requireSystemAdmin(req)

        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "Decision-log summary requires an SQL database")
        }

        let sinceHours = min(max(try intQuery(req, "sinceHours") ?? 24, 1), 24 * 90)
        let limit = min(max(try intQuery(req, "limit") ?? 200, 1), 1000)
        let since = Date().addingTimeInterval(-Double(sinceHours) * 3600)

        struct Row: Decodable {
            let spicedb_permission: String
            let iam_action: String?
            let spicedb_decision: String
            let cedar_decision: String
            let tier: String?
            let count: Int
        }

        let rows = try await sql.raw(
            """
            SELECT spicedb_permission, iam_action, spicedb_decision, cedar_decision, tier,
                   COUNT(*) AS count
            FROM iam_decision_logs
            WHERE created_at >= \(bind: since)
            GROUP BY spicedb_permission, iam_action, spicedb_decision, cedar_decision, tier
            ORDER BY count DESC
            LIMIT \(bind: limit)
            """
        ).all(decoding: Row.self)

        return rows.map {
            DecisionSummaryDTO(
                spicedbPermission: $0.spicedb_permission,
                iamAction: $0.iam_action,
                spicedbDecision: $0.spicedb_decision,
                cedarDecision: $0.cedar_decision,
                tier: $0.tier,
                count: $0.count
            )
        }
    }

    // MARK: - Query parsing

    /// An integer query parameter, or `nil` when absent. A malformed value is
    /// a 400 rather than a silent fallback to the default — a burn-down that
    /// quietly ignores `limit=abc` reports the wrong window.
    private func intQuery(_ req: Request, _ name: String) throws -> Int? {
        guard let raw: String = req.query[name], !raw.isEmpty else { return nil }
        guard let value = Int(raw) else {
            throw Abort(.badRequest, reason: "Query parameter '\(name)' must be an integer")
        }
        return value
    }

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

    private func requireSystemAdmin(_ req: Request) throws {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        guard user.isSystemAdmin else {
            throw Abort(.forbidden, reason: "Decision logs require system administrator access")
        }
    }
}
