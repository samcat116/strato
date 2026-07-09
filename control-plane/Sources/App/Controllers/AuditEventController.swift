import Fluent
import Vapor

/// Read API for the audit trail (issue #39).
///
/// - `GET /api/audit-events` — system administrators only; the full,
///   cross-organization trail.
/// - `GET /api/organizations/:organizationID/audit-events` — organization
///   admins (`manage_members`); events scoped to that organization.
struct AuditEventController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.grouped("api", "audit-events").get(use: listAll)
        routes.grouped("api", "organizations", ":organizationID", "audit-events")
            .get(use: listForOrganization)
    }

    struct ListQuery: Content {
        var eventType: String?
        var userID: UUID?
        var organizationID: UUID?
        /// Only events served via the system-admin bypass.
        var adminOnly: Bool?
        /// ISO8601 timestamps (e.g. `2026-07-09T12:00:00Z`).
        var from: String?
        var to: String?
        var limit: Int?
        var offset: Int?
    }

    func listAll(req: Request) async throws -> AuditEventListResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        guard user.isSystemAdmin else {
            throw Abort(.forbidden, reason: "System administrator access required")
        }
        let query = try req.query.decode(ListQuery.self)
        return try await list(query: query, organizationID: query.organizationID, on: req)
    }

    func listForOrganization(req: Request) async throws -> AuditEventListResponse {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)
        let query = try req.query.decode(ListQuery.self)
        return try await list(query: query, organizationID: organizationID, on: req)
    }

    private func list(
        query: ListQuery, organizationID: UUID?, on req: Request
    ) async throws -> AuditEventListResponse {
        let limit = min(max(query.limit ?? 50, 1), 500)
        let offset = max(query.offset ?? 0, 0)

        let dbQuery = AuditEvent.query(on: req.db)
        if let organizationID {
            dbQuery.filter(\.$organizationID == organizationID)
        }
        if let eventType = query.eventType {
            dbQuery.filter(\.$eventType == eventType)
        }
        if let userID = query.userID {
            dbQuery.filter(\.$userID == userID)
        }
        if query.adminOnly == true {
            dbQuery.filter(\.$adminBypass == true)
        }
        if let from = query.from {
            dbQuery.filter(\.$createdAt >= parseTimestamp(from, parameter: "from"))
        }
        if let to = query.to {
            dbQuery.filter(\.$createdAt <= parseTimestamp(to, parameter: "to"))
        }

        let total = try await dbQuery.copy().count()
        let events =
            try await dbQuery
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .range(offset..<(offset + limit))
            .all()

        return AuditEventListResponse(
            events: events.map(AuditEventResponse.init),
            total: total,
            limit: limit,
            offset: offset
        )
    }

    /// Accept ISO8601 (with or without fractional seconds) or epoch seconds.
    private func parseTimestamp(_ value: String, parameter: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        if let epoch = Double(value) {
            return Date(timeIntervalSince1970: epoch)
        }
        // A malformed bound matching nothing would silently hide events;
        // distant past/future keeps the filter permissive instead.
        return parameter == "from" ? Date.distantPast : Date.distantFuture
    }
}

// MARK: - DTOs

struct AuditEventResponse: Content {
    let id: UUID?
    let eventType: String
    let userID: UUID?
    let username: String?
    let apiKeyID: UUID?
    let organizationID: UUID?
    let method: String?
    let path: String?
    let status: Int?
    let resourceType: String?
    let resourceID: String?
    let action: String?
    let sourceIP: String?
    let adminBypass: Bool
    let metadata: [String: String]?
    let createdAt: Date?

    init(from event: AuditEvent) {
        self.id = event.id
        self.eventType = event.eventType
        self.userID = event.userID
        self.username = event.username
        self.apiKeyID = event.apiKeyID
        self.organizationID = event.organizationID
        self.method = event.method
        self.path = event.path
        self.status = event.status
        self.resourceType = event.resourceType
        self.resourceID = event.resourceID
        self.action = event.action
        self.sourceIP = event.sourceIP
        self.adminBypass = event.adminBypass
        self.metadata = event.metadata
        self.createdAt = event.createdAt
    }
}

struct AuditEventListResponse: Content {
    let events: [AuditEventResponse]
    let total: Int
    let limit: Int
    let offset: Int
}
