import ControlPlanePostgres
import Vapor

/// Read API for the audit trail (issue #39).
///
/// - `GET /api/audit-events` — system administrators only; the full,
///   cross-organization trail.
/// - `GET /api/organizations/:organizationID/audit-events` — organization
///   admins (`manage_members`); events scoped to that organization.
struct AuditEventController: RouteCollection {
    private let auditEvents: AuditEventsPersistence

    init(auditEvents: AuditEventsPersistence) {
        self.auditEvents = auditEvents
    }

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
        // `limit`/`offset` are read straight off the request (see `intQuery`)
        // rather than decoded here: decoding them as `Int?` would surface a
        // malformed value as Vapor's generic decoding failure instead of the
        // shared "must be an integer" 400 every other list endpoint returns.
    }

    func listAll(req: Request) async throws -> AuditEventListResponse {
        _ = try await req.requireSystemAdmin()
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
        let limit = try req.intQuery("limit", default: 50, in: 1...500)
        let offset = try req.intQuery("offset", default: 0, in: 0...Int.max)

        let page = try await auditEvents.events(
            matching: AuditEventFilter(
                organizationID: organizationID,
                eventType: query.eventType,
                userID: query.userID,
                adminOnly: query.adminOnly == true,
                createdAtOrAfter: query.from.map { parseTimestamp($0, parameter: "from") },
                createdAtOrBefore: query.to.map { parseTimestamp($0, parameter: "to") }
            ),
            limit: limit,
            offset: offset
        )

        return AuditEventListResponse(
            events: page.events.map(AuditEventResponse.init),
            total: page.total,
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

    init(from event: AuditEventSnapshot) {
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
