import Fluent
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
    /// — newest first.
    func list(req: Request) async throws -> [DecisionLogDTO] {
        try requireSystemAdmin(req)

        let limit = min(max((try? req.query.get(Int.self, at: "limit")) ?? 100, 1), 500)
        let mismatchesOnly = (try? req.query.get(Bool.self, at: "mismatchesOnly")) ?? false

        let query = IAMDecisionLog.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .limit(limit)
        if mismatchesOnly {
            query.filter(\.$decisionsMatch == false)
        }
        if let before = try? req.query.get(Date.self, at: "before") {
            query.filter(\.$createdAt < before)
        }

        return try await query.all().map { try DecisionLogDTO($0) }
    }

    /// `GET /api/iam/decision-logs/summary` — the burn-down view: decision
    /// counts bucketed by permission, action, both verdicts, and tier, largest
    /// buckets first. One glance says which mismatch classes remain and how
    /// big each is.
    func summary(req: Request) async throws -> [DecisionSummaryDTO] {
        try requireSystemAdmin(req)

        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "Decision-log summary requires an SQL database")
        }

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
            GROUP BY spicedb_permission, iam_action, spicedb_decision, cedar_decision, tier
            ORDER BY count DESC
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

    private func requireSystemAdmin(_ req: Request) throws {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        guard user.isSystemAdmin else {
            throw Abort(.forbidden, reason: "Decision logs require system administrator access")
        }
    }
}
