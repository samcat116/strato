import Foundation
import PostgresNIO

public enum WebhookDeliveryStatus: String, Codable, Sendable {
    case pending
    case succeeded
    case dead
}

public struct WebhookDeliverySnapshot: Equatable, Sendable {
    public let id: UUID
    public let subscriptionID: UUID
    public let eventID: UUID
    public let eventType: String
    public let payload: String
    public let status: WebhookDeliveryStatus
    public let attempts: Int
    public let nextAttemptAt: Date
    public let lastAttemptAt: Date?
    public let responseStatus: Int?
    public let lastError: String?
    public let deliveredAt: Date?
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: UUID,
        subscriptionID: UUID,
        eventID: UUID,
        eventType: String,
        payload: String,
        status: WebhookDeliveryStatus,
        attempts: Int,
        nextAttemptAt: Date,
        lastAttemptAt: Date?,
        responseStatus: Int?,
        lastError: String?,
        deliveredAt: Date?,
        createdAt: Date?,
        updatedAt: Date?
    ) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.eventID = eventID
        self.eventType = eventType
        self.payload = payload
        self.status = status
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.lastAttemptAt = lastAttemptAt
        self.responseStatus = responseStatus
        self.lastError = lastError
        self.deliveredAt = deliveredAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct WebhookDeliveryWrite: Sendable {
    public let id: UUID
    public let subscriptionID: UUID
    public let eventID: UUID
    public let eventType: String
    public let payload: String
    public let status: WebhookDeliveryStatus
    public let attempts: Int
    public let nextAttemptAt: Date
    public let lastAttemptAt: Date?
    public let responseStatus: Int?
    public let lastError: String?
    public let deliveredAt: Date?

    public init(
        id: UUID = UUID(),
        subscriptionID: UUID,
        eventID: UUID,
        eventType: String,
        payload: String,
        status: WebhookDeliveryStatus = .pending,
        attempts: Int = 0,
        nextAttemptAt: Date = Date(),
        lastAttemptAt: Date? = nil,
        responseStatus: Int? = nil,
        lastError: String? = nil,
        deliveredAt: Date? = nil
    ) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.eventID = eventID
        self.eventType = eventType
        self.payload = payload
        self.status = status
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.lastAttemptAt = lastAttemptAt
        self.responseStatus = responseStatus
        self.lastError = lastError
        self.deliveredAt = deliveredAt
    }

    public init(_ snapshot: WebhookDeliverySnapshot) {
        self.init(
            id: snapshot.id,
            subscriptionID: snapshot.subscriptionID,
            eventID: snapshot.eventID,
            eventType: snapshot.eventType,
            payload: snapshot.payload,
            status: snapshot.status,
            attempts: snapshot.attempts,
            nextAttemptAt: snapshot.nextAttemptAt,
            lastAttemptAt: snapshot.lastAttemptAt,
            responseStatus: snapshot.responseStatus,
            lastError: snapshot.lastError,
            deliveredAt: snapshot.deliveredAt)
    }
}

public enum WebhookDeliveriesPersistenceError: Error, Equatable, Sendable {
    case unexpectedRowCount(expected: Int, actual: Int)
    case invalidStatus(String)
}

public struct WebhookDeliveriesPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func create(_ write: WebhookDeliveryWrite) async throws -> WebhookDeliverySnapshot {
        let rows = try await database.withSession(operation: "webhooks.deliveries.create") { session in
            try await session.execute(
                InsertWebhookDelivery(write: write),
                operation: "webhooks.deliveries.create.query")
        }
        return try requireOne(rows)
    }

    public func replace(_ write: WebhookDeliveryWrite) async throws -> WebhookDeliverySnapshot? {
        let rows = try await database.withSession(operation: "webhooks.deliveries.replace") { session in
            try await session.execute(
                ReplaceWebhookDelivery(write: write),
                operation: "webhooks.deliveries.replace.query")
        }
        return try oneOrNone(rows)
    }

    public func delivery(id: UUID) async throws -> WebhookDeliverySnapshot? {
        let rows = try await database.withSession(operation: "webhooks.deliveries.lookup") { session in
            try await session.execute(
                FindWebhookDelivery(id: id),
                operation: "webhooks.deliveries.lookup.query")
        }
        return try oneOrNone(rows)
    }

    public func deliveries(
        subscriptionID: UUID,
        limit: Int
    ) async throws -> [WebhookDeliverySnapshot] {
        try await database.withSession(operation: "webhooks.deliveries.list") { session in
            try await session.execute(
                ListWebhookDeliveries(subscriptionID: subscriptionID, limit: limit),
                operation: "webhooks.deliveries.list.query")
        }
    }

    public func all() async throws -> [WebhookDeliverySnapshot] {
        try await database.withSession(operation: "webhooks.deliveries.all") { session in
            try await session.execute(
                ListAllWebhookDeliveries(), operation: "webhooks.deliveries.all.query")
        }
    }

    public func count() async throws -> Int {
        try await database.withSession(operation: "webhooks.deliveries.count") { session in
            let values = try await session.execute(
                CountWebhookDeliveries(), operation: "webhooks.deliveries.count.query")
            guard values.count == 1, let value = values.first else {
                throw WebhookDeliveriesPersistenceError.unexpectedRowCount(
                    expected: 1, actual: values.count)
            }
            return value
        }
    }

    public func deleteAll() async throws {
        _ = try await database.withSession(operation: "webhooks.deliveries.delete_all") { session in
            try await session.command(
                "DELETE FROM webhook_deliveries",
                operation: "webhooks.deliveries.delete_all.query")
        }
    }

    public func claimDue(
        limit: Int,
        leaseSeconds: Int
    ) async throws -> [UUID] {
        try await database.withSession(operation: "webhooks.deliveries.claim") { session in
            try await session.execute(
                ClaimDueWebhookDeliveries(limit: limit, leaseSeconds: leaseSeconds),
                operation: "webhooks.deliveries.claim.query")
        }
    }

    public func parkDisabled(id: UUID) async throws -> WebhookDeliverySnapshot? {
        let rows = try await database.withSession(
            operation: "webhooks.deliveries.park_disabled"
        ) { session in
            try await session.execute(
                ParkDisabledWebhookDelivery(id: id),
                operation: "webhooks.deliveries.park_disabled.query")
        }
        return try oneOrNone(rows)
    }

    public func recordSuccess(
        id: UUID,
        responseStatus: Int,
        at date: Date
    ) async throws -> WebhookDeliverySnapshot? {
        let rows = try await database.withSession(
            operation: "webhooks.deliveries.record_success"
        ) { session in
            try await session.execute(
                RecordSuccessfulWebhookDelivery(id: id, responseStatus: responseStatus, date: date),
                operation: "webhooks.deliveries.record_success.query")
        }
        return try oneOrNone(rows)
    }

    public func recordFailure(
        id: UUID,
        responseStatus: Int?,
        error: String,
        at date: Date,
        maximumAttempts: Int,
        nextAttemptAt: Date
    ) async throws -> WebhookDeliverySnapshot? {
        let rows = try await database.withSession(
            operation: "webhooks.deliveries.record_failure"
        ) { session in
            try await session.execute(
                RecordFailedWebhookDelivery(
                    id: id,
                    responseStatus: responseStatus,
                    error: error,
                    date: date,
                    maximumAttempts: maximumAttempts,
                    nextAttemptAt: nextAttemptAt),
                operation: "webhooks.deliveries.record_failure.query")
        }
        return try oneOrNone(rows)
    }

    public func redeliver(
        id: UUID,
        subscriptionID: UUID
    ) async throws -> WebhookDeliverySnapshot? {
        let rows = try await database.withSession(operation: "webhooks.deliveries.redeliver") { session in
            try await session.execute(
                RedeliverWebhookDelivery(id: id, subscriptionID: subscriptionID),
                operation: "webhooks.deliveries.redeliver.query")
        }
        return try oneOrNone(rows)
    }

    @discardableResult
    public func pruneTerminal(createdBefore cutoff: Date) async throws -> Int {
        try await database.withSession(operation: "webhooks.deliveries.prune") { session in
            try await session.execute(
                PruneWebhookDeliveries(cutoff: cutoff),
                operation: "webhooks.deliveries.prune.query").count
        }
    }

    private func requireOne(
        _ rows: [WebhookDeliverySnapshot]
    ) throws -> WebhookDeliverySnapshot {
        guard rows.count == 1, let row = rows.first else {
            throw WebhookDeliveriesPersistenceError.unexpectedRowCount(
                expected: 1, actual: rows.count)
        }
        return row
    }

    private func oneOrNone(
        _ rows: [WebhookDeliverySnapshot]
    ) throws -> WebhookDeliverySnapshot? {
        guard rows.count <= 1 else {
            throw WebhookDeliveriesPersistenceError.unexpectedRowCount(
                expected: 1, actual: rows.count)
        }
        return rows.first
    }
}

private let webhookDeliveryColumns = """
    id, subscription_id, event_id, event_type, payload, status, attempts,
    next_attempt_at, last_attempt_at, response_status, last_error, delivered_at,
    created_at, updated_at
    """

private protocol WebhookDeliveryStatement: PostgresPreparedStatement
    where Row == WebhookDeliverySnapshot {}

private extension WebhookDeliveryStatement {
    func decodeRow(_ row: PostgresRow) throws -> WebhookDeliverySnapshot {
        let value = try row.decode((
            UUID, UUID, UUID, String, String, String, Int, Date,
            Date?, Int?, String?, Date?, Date?, Date?
        ).self)
        guard let status = WebhookDeliveryStatus(rawValue: value.5) else {
            throw WebhookDeliveriesPersistenceError.invalidStatus(value.5)
        }
        return WebhookDeliverySnapshot(
            id: value.0,
            subscriptionID: value.1,
            eventID: value.2,
            eventType: value.3,
            payload: value.4,
            status: status,
            attempts: value.6,
            nextAttemptAt: value.7,
            lastAttemptAt: value.8,
            responseStatus: value.9,
            lastError: value.10,
            deliveredAt: value.11,
            createdAt: value.12,
            updatedAt: value.13)
    }
}

private struct InsertWebhookDelivery: WebhookDeliveryStatement {
    static let sql = """
        INSERT INTO webhook_deliveries (
            id, subscription_id, event_id, event_type, payload, status, attempts,
            next_attempt_at, last_attempt_at, response_status, last_error,
            delivered_at, created_at, updated_at
        ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
            CURRENT_TIMESTAMP, NULL
        )
        RETURNING \(webhookDeliveryColumns)
        """
    let write: WebhookDeliveryWrite
    func makeBindings() -> PostgresBindings { bindings(for: write) }
}

private struct ReplaceWebhookDelivery: WebhookDeliveryStatement {
    static let sql = """
        UPDATE webhook_deliveries SET
            subscription_id = $2, event_id = $3, event_type = $4, payload = $5,
            status = $6, attempts = $7, next_attempt_at = $8,
            last_attempt_at = $9, response_status = $10, last_error = $11,
            delivered_at = $12, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(webhookDeliveryColumns)
        """
    let write: WebhookDeliveryWrite
    func makeBindings() -> PostgresBindings { bindings(for: write) }
}

private func bindings(for write: WebhookDeliveryWrite) -> PostgresBindings {
    var bindings = PostgresBindings(capacity: 12)
    bindings.append(write.id)
    bindings.append(write.subscriptionID)
    bindings.append(write.eventID)
    bindings.append(write.eventType)
    bindings.append(write.payload)
    bindings.append(write.status.rawValue)
    bindings.append(write.attempts)
    bindings.append(write.nextAttemptAt)
    bindings.append(write.lastAttemptAt)
    bindings.append(write.responseStatus)
    bindings.append(write.lastError)
    bindings.append(write.deliveredAt)
    return bindings
}

private struct FindWebhookDelivery: WebhookDeliveryStatement {
    static let sql = "SELECT \(webhookDeliveryColumns) FROM webhook_deliveries WHERE id = $1"
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct ListWebhookDeliveries: WebhookDeliveryStatement {
    static let sql = """
        SELECT \(webhookDeliveryColumns)
        FROM webhook_deliveries
        WHERE subscription_id = $1
        ORDER BY created_at DESC, id DESC
        LIMIT $2
        """
    let subscriptionID: UUID
    let limit: Int
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(subscriptionID)
        bindings.append(limit)
        return bindings
    }
}

private struct ListAllWebhookDeliveries: WebhookDeliveryStatement {
    static let sql = """
        SELECT \(webhookDeliveryColumns)
        FROM webhook_deliveries
        ORDER BY created_at, id
        """
    func makeBindings() -> PostgresBindings { PostgresBindings() }
}

private struct CountWebhookDeliveries: PostgresPreparedStatement {
    static let sql = "SELECT COUNT(*)::bigint FROM webhook_deliveries"
    typealias Row = Int
    func makeBindings() -> PostgresBindings { PostgresBindings() }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct ClaimDueWebhookDeliveries: PostgresPreparedStatement {
    static let sql = """
        WITH due AS MATERIALIZED (
            SELECT id
            FROM webhook_deliveries
            WHERE status = 'pending' AND next_attempt_at <= CURRENT_TIMESTAMP
            ORDER BY next_attempt_at, id
            LIMIT $1
            FOR UPDATE SKIP LOCKED
        )
        UPDATE webhook_deliveries AS delivery
        SET next_attempt_at = CURRENT_TIMESTAMP + ($2 * interval '1 second'),
            updated_at = CURRENT_TIMESTAMP
        FROM due
        WHERE delivery.id = due.id
        RETURNING delivery.id
        """
    typealias Row = UUID
    let limit: Int
    let leaseSeconds: Int
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(limit)
        bindings.append(leaseSeconds)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct ParkDisabledWebhookDelivery: WebhookDeliveryStatement {
    static let sql = """
        UPDATE webhook_deliveries
        SET status = 'dead', last_error = 'Subscription is disabled',
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(webhookDeliveryColumns)
        """
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct RecordSuccessfulWebhookDelivery: WebhookDeliveryStatement {
    static let sql = """
        UPDATE webhook_deliveries
        SET attempts = attempts + 1, last_attempt_at = $3, response_status = $2,
            status = 'succeeded', delivered_at = $3, last_error = NULL,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(webhookDeliveryColumns)
        """
    let id: UUID
    let responseStatus: Int
    let date: Date
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(responseStatus)
        bindings.append(date)
        return bindings
    }
}

private struct RecordFailedWebhookDelivery: WebhookDeliveryStatement {
    static let sql = """
        UPDATE webhook_deliveries
        SET attempts = attempts + 1, last_attempt_at = $4, response_status = $2,
            last_error = $3,
            status = CASE WHEN attempts + 1 >= $5 THEN 'dead' ELSE status END,
            next_attempt_at = CASE WHEN attempts + 1 >= $5 THEN next_attempt_at ELSE $6 END,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(webhookDeliveryColumns)
        """
    let id: UUID
    let responseStatus: Int?
    let error: String
    let date: Date
    let maximumAttempts: Int
    let nextAttemptAt: Date
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 6)
        bindings.append(id)
        bindings.append(responseStatus)
        bindings.append(error)
        bindings.append(date)
        bindings.append(maximumAttempts)
        bindings.append(nextAttemptAt)
        return bindings
    }
}

private struct RedeliverWebhookDelivery: WebhookDeliveryStatement {
    static let sql = """
        UPDATE webhook_deliveries
        SET status = 'pending', attempts = 0, next_attempt_at = CURRENT_TIMESTAMP,
            last_error = NULL, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND subscription_id = $2 AND status <> 'pending'
        RETURNING \(webhookDeliveryColumns)
        """
    let id: UUID
    let subscriptionID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(subscriptionID)
        return bindings
    }
}

private struct PruneWebhookDeliveries: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM webhook_deliveries
        WHERE status <> 'pending' AND created_at < $1
        RETURNING id
        """
    typealias Row = UUID
    let cutoff: Date
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(cutoff)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}
