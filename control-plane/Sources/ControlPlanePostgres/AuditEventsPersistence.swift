import Foundation
import PostgresNIO

public struct AuditEventWrite: Sendable {
    public let id: UUID
    public let eventType: String
    public let userID: UUID?
    public let username: String?
    public let apiKeyID: UUID?
    public let organizationID: UUID?
    public let method: String?
    public let path: String?
    public let status: Int?
    public let resourceType: String?
    public let resourceID: String?
    public let action: String?
    public let sourceIP: String?
    public let adminBypass: Bool
    public let metadata: [String: String]?
    /// Nil for normal writes, which use PostgreSQL `CURRENT_TIMESTAMP`.
    /// Explicit values exist for imported facts and retention tests.
    public let createdAt: Date?

    public init(
        id: UUID = UUID(),
        eventType: String,
        userID: UUID? = nil,
        username: String? = nil,
        apiKeyID: UUID? = nil,
        organizationID: UUID? = nil,
        method: String? = nil,
        path: String? = nil,
        status: Int? = nil,
        resourceType: String? = nil,
        resourceID: String? = nil,
        action: String? = nil,
        sourceIP: String? = nil,
        adminBypass: Bool = false,
        metadata: [String: String]? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.eventType = eventType
        self.userID = userID
        self.username = username
        self.apiKeyID = apiKeyID
        self.organizationID = organizationID
        self.method = method
        self.path = path
        self.status = status
        self.resourceType = resourceType
        self.resourceID = resourceID
        self.action = action
        self.sourceIP = sourceIP
        self.adminBypass = adminBypass
        self.metadata = metadata
        self.createdAt = createdAt
    }
}

public struct AuditEventSnapshot: Equatable, Sendable {
    public let id: UUID
    public let eventType: String
    public let userID: UUID?
    public let username: String?
    public let apiKeyID: UUID?
    public let organizationID: UUID?
    public let method: String?
    public let path: String?
    public let status: Int?
    public let resourceType: String?
    public let resourceID: String?
    public let action: String?
    public let sourceIP: String?
    public let adminBypass: Bool
    public let metadata: [String: String]?
    public let createdAt: Date?
}

public struct AuditEventFilter: Equatable, Sendable {
    public var organizationID: UUID?
    public var eventType: String?
    public var userID: UUID?
    public var adminOnly: Bool
    public var createdAtOrAfter: Date?
    public var createdAtOrBefore: Date?

    public init(
        organizationID: UUID? = nil,
        eventType: String? = nil,
        userID: UUID? = nil,
        adminOnly: Bool = false,
        createdAtOrAfter: Date? = nil,
        createdAtOrBefore: Date? = nil
    ) {
        self.organizationID = organizationID
        self.eventType = eventType
        self.userID = userID
        self.adminOnly = adminOnly
        self.createdAtOrAfter = createdAtOrAfter
        self.createdAtOrBefore = createdAtOrBefore
    }
}

public struct AuditEventPage: Equatable, Sendable {
    public let events: [AuditEventSnapshot]
    public let total: Int
}

/// Append-only audit persistence plus the two owned maintenance operations:
/// filtered chronological reads and retention pruning.
public struct AuditEventsPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    /// Append a batch with one stable prepared statement. JSON is used only as
    /// a transport envelope into `jsonb_to_recordset`; each destination column
    /// retains its existing PostgreSQL type and metadata remains text.
    public func append(_ events: [AuditEventWrite]) async throws -> [AuditEventSnapshot] {
        guard !events.isEmpty else { return [] }
        return try await database.withSession(operation: "audit_events.append") { session in
            try await session.execute(
                AppendAuditEvents(events: events),
                operation: "audit_events.append.query"
            ).map(\.snapshot)
        }
    }

    public func events(
        matching filter: AuditEventFilter = .init(),
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> AuditEventPage {
        precondition(limit > 0)
        precondition(offset >= 0)
        return try await database.withSession(operation: "audit_events.list") { session in
            let total = try await session.execute(
                CountAuditEvents(filter: filter),
                operation: "audit_events.list.count"
            ).onlyRow()
            let rows = try await session.execute(
                ListAuditEvents(filter: filter, limit: limit, offset: offset),
                operation: "audit_events.list.query"
            )
            return AuditEventPage(events: rows.map(\.snapshot), total: total)
        }
    }

    /// Delete old rows and return the exact affected count from `RETURNING`,
    /// avoiding a count/delete race between replicas.
    public func delete(createdBefore cutoff: Date) async throws -> Int {
        try await database.withSession(operation: "audit_events.retention") { session in
            try await session.execute(
                DeleteExpiredAuditEvents(cutoff: cutoff),
                operation: "audit_events.retention.delete"
            ).count
        }
    }
}

private struct AuditEventRecord: Sendable {
    let id: UUID
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
    let metadataJSON: String?
    let createdAt: Date?

    init(row: PostgresRow) throws {
        (
            id, eventType, userID, username, apiKeyID, organizationID, method,
            path, status, resourceType, resourceID, action, sourceIP,
            adminBypass, metadataJSON, createdAt
        ) = try row.decode((
            UUID, String, UUID?, String?, UUID?, UUID?, String?,
            String?, Int?, String?, String?, String?, String?,
            Bool, String?, Date?
        ).self)
    }

    var snapshot: AuditEventSnapshot {
        AuditEventSnapshot(
            id: id,
            eventType: eventType,
            userID: userID,
            username: username,
            apiKeyID: apiKeyID,
            organizationID: organizationID,
            method: method,
            path: path,
            status: status,
            resourceType: resourceType,
            resourceID: resourceID,
            action: action,
            sourceIP: sourceIP,
            adminBypass: adminBypass,
            metadata: metadataJSON.flatMap { value in
                guard let data = value.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode([String: String].self, from: data)
            },
            createdAt: createdAt
        )
    }
}

private let auditEventColumns = """
    id, event_type, user_id, username, api_key_id, organization_id, method,
    path, status, resource_type, resource_id, action, source_ip, admin_bypass,
    metadata, created_at
    """

private struct AuditEventBatchJSON: Encodable, PostgresEncodable, Sendable {
    let events: [AuditEventWriteJSON]

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(events)
    }
}

private struct AuditEventWriteJSON: Encodable, Sendable {
    let id: UUID
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
    let metadata: String?
    let createdAt: String?

    init(_ event: AuditEventWrite) throws {
        id = event.id
        eventType = event.eventType
        userID = event.userID
        username = event.username
        apiKeyID = event.apiKeyID
        organizationID = event.organizationID
        method = event.method
        path = event.path
        status = event.status
        resourceType = event.resourceType
        resourceID = event.resourceID
        action = event.action
        sourceIP = event.sourceIP
        adminBypass = event.adminBypass
        if let metadata = event.metadata {
            self.metadata = String(data: try JSONEncoder().encode(metadata), encoding: .utf8)
        } else {
            self.metadata = nil
        }
        createdAt = event.createdAt?.ISO8601Format(.iso8601(timeZone: .gmt))
    }

    enum CodingKeys: String, CodingKey {
        case id
        case eventType = "event_type"
        case userID = "user_id"
        case username
        case apiKeyID = "api_key_id"
        case organizationID = "organization_id"
        case method
        case path
        case status
        case resourceType = "resource_type"
        case resourceID = "resource_id"
        case action
        case sourceIP = "source_ip"
        case adminBypass = "admin_bypass"
        case metadata
        case createdAt = "created_at"
    }
}

private struct AppendAuditEvents: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO audit_events (
            id, event_type, user_id, username, api_key_id, organization_id,
            method, path, status, resource_type, resource_id, action, source_ip,
            admin_bypass, metadata, created_at
        )
        SELECT input.id, input.event_type, input.user_id, input.username,
               input.api_key_id, input.organization_id, input.method, input.path,
               input.status, input.resource_type, input.resource_id, input.action,
               input.source_ip, input.admin_bypass, input.metadata,
               COALESCE(input.created_at, CURRENT_TIMESTAMP)
        FROM jsonb_to_recordset($1) AS input(
            id UUID,
            event_type TEXT,
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
            admin_bypass BOOLEAN,
            metadata TEXT,
            created_at TIMESTAMPTZ
        )
        RETURNING \(auditEventColumns)
        """

    typealias Row = AuditEventRecord
    let events: [AuditEventWrite]

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        try bindings.append(AuditEventBatchJSON(events: try events.map(AuditEventWriteJSON.init)))
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> AuditEventRecord {
        try AuditEventRecord(row: row)
    }
}

private protocol FilteredAuditEventsStatement: PostgresPreparedStatement {}

private extension FilteredAuditEventsStatement {
    static var filterSQL: String {
        """
        ($1::uuid IS NULL OR organization_id = $1)
        AND ($2::text IS NULL OR event_type = $2)
        AND ($3::uuid IS NULL OR user_id = $3)
        AND ($4::boolean = false OR admin_bypass = true)
        AND ($5::timestamptz IS NULL OR created_at >= $5)
        AND ($6::timestamptz IS NULL OR created_at <= $6)
        """
    }

    static var filterBindingDataTypes: [PostgresDataType] {
        [.uuid, .text, .uuid, .bool, .timestamptz, .timestamptz]
    }
}

private func filterBindings(_ filter: AuditEventFilter, capacity: Int = 6) -> PostgresBindings {
    var bindings = PostgresBindings(capacity: capacity)
    bindings.append(filter.organizationID)
    bindings.append(filter.eventType)
    bindings.append(filter.userID)
    bindings.append(filter.adminOnly)
    bindings.append(filter.createdAtOrAfter)
    bindings.append(filter.createdAtOrBefore)
    return bindings
}

private struct CountAuditEvents: FilteredAuditEventsStatement {
    static var sql: String { "SELECT count(*)::bigint FROM audit_events WHERE \(filterSQL)" }
    static let bindingDataTypes = filterBindingDataTypes
    typealias Row = Int
    let filter: AuditEventFilter

    func makeBindings() -> PostgresBindings { filterBindings(filter) }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct ListAuditEvents: FilteredAuditEventsStatement {
    static var sql: String {
        """
        SELECT \(auditEventColumns)
        FROM audit_events
        WHERE \(filterSQL)
        ORDER BY created_at DESC, id DESC
        LIMIT $7 OFFSET $8
        """
    }
    static let bindingDataTypes = filterBindingDataTypes + [.int8, .int8]
    typealias Row = AuditEventRecord
    let filter: AuditEventFilter
    let limit: Int
    let offset: Int

    func makeBindings() -> PostgresBindings {
        var bindings = filterBindings(filter, capacity: 8)
        bindings.append(limit)
        bindings.append(offset)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> AuditEventRecord {
        try AuditEventRecord(row: row)
    }
}

private struct DeleteExpiredAuditEvents: PostgresPreparedStatement {
    static let sql = "DELETE FROM audit_events WHERE created_at < $1 RETURNING id"
    typealias Row = UUID
    let cutoff: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(cutoff)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private extension Array {
    func onlyRow() throws -> Element {
        guard count == 1, let first else {
            throw AuditEventRowCountError(expected: 1, actual: count)
        }
        return first
    }
}

private struct AuditEventRowCountError: Error, Sendable {
    let expected: Int
    let actual: Int
}
