import Foundation
import PostgresNIO

public struct WebhookSubscriptionSnapshot: Equatable, Sendable {
    public let id: UUID
    public let organizationID: UUID
    public let projectID: UUID?
    public let name: String
    public let url: String
    public let eventTypesJSON: String
    public let encryptedSigningSecret: String
    public let isActive: Bool
    public let disabledReason: String?
    public let failingSince: Date?
    public let createdByID: UUID
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: UUID,
        organizationID: UUID,
        projectID: UUID?,
        name: String,
        url: String,
        eventTypesJSON: String,
        encryptedSigningSecret: String,
        isActive: Bool,
        disabledReason: String? = nil,
        failingSince: Date? = nil,
        createdByID: UUID,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.organizationID = organizationID
        self.projectID = projectID
        self.name = name
        self.url = url
        self.eventTypesJSON = eventTypesJSON
        self.encryptedSigningSecret = encryptedSigningSecret
        self.isActive = isActive
        self.disabledReason = disabledReason
        self.failingSince = failingSince
        self.createdByID = createdByID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct WebhookSubscriptionWrite: Sendable {
    public let id: UUID
    public let organizationID: UUID
    public let projectID: UUID?
    public let name: String
    public let url: String
    public let eventTypesJSON: String
    public let encryptedSigningSecret: String
    public let isActive: Bool
    public let disabledReason: String?
    public let failingSince: Date?
    public let createdByID: UUID

    public init(
        id: UUID,
        organizationID: UUID,
        projectID: UUID?,
        name: String,
        url: String,
        eventTypesJSON: String,
        encryptedSigningSecret: String,
        isActive: Bool,
        disabledReason: String?,
        failingSince: Date?,
        createdByID: UUID
    ) {
        self.id = id
        self.organizationID = organizationID
        self.projectID = projectID
        self.name = name
        self.url = url
        self.eventTypesJSON = eventTypesJSON
        self.encryptedSigningSecret = encryptedSigningSecret
        self.isActive = isActive
        self.disabledReason = disabledReason
        self.failingSince = failingSince
        self.createdByID = createdByID
    }

    public init(_ snapshot: WebhookSubscriptionSnapshot) {
        self.init(
            id: snapshot.id,
            organizationID: snapshot.organizationID,
            projectID: snapshot.projectID,
            name: snapshot.name,
            url: snapshot.url,
            eventTypesJSON: snapshot.eventTypesJSON,
            encryptedSigningSecret: snapshot.encryptedSigningSecret,
            isActive: snapshot.isActive,
            disabledReason: snapshot.disabledReason,
            failingSince: snapshot.failingSince,
            createdByID: snapshot.createdByID
        )
    }
}

public enum WebhookSubscriptionsPersistenceError: Error, Equatable, Sendable {
    case unexpectedRowCount(expected: Int, actual: Int)
}

public struct WebhookSubscriptionsPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func subscriptions(organizationID: UUID) async throws -> [WebhookSubscriptionSnapshot] {
        try await database.withSession(operation: "webhooks.subscriptions.list") { session in
            try await session.execute(
                ListWebhookSubscriptions(organizationID: organizationID),
                operation: "webhooks.subscriptions.list.query")
        }
    }

    public func subscription(
        id: UUID,
        organizationID: UUID? = nil
    ) async throws -> WebhookSubscriptionSnapshot? {
        try await database.withSession(operation: "webhooks.subscriptions.lookup") { session in
            let rows = try await session.execute(
                FindWebhookSubscription(id: id, organizationID: organizationID),
                operation: "webhooks.subscriptions.lookup.query")
            guard rows.count <= 1 else {
                throw WebhookSubscriptionsPersistenceError.unexpectedRowCount(
                    expected: 1, actual: rows.count)
            }
            return rows.first
        }
    }

    public func create(_ write: WebhookSubscriptionWrite) async throws -> WebhookSubscriptionSnapshot {
        try await database.withSession(operation: "webhooks.subscriptions.create") { session in
            let rows = try await session.execute(
                InsertWebhookSubscription(write: write),
                operation: "webhooks.subscriptions.create.query")
            guard rows.count == 1, let row = rows.first else {
                throw WebhookSubscriptionsPersistenceError.unexpectedRowCount(
                    expected: 1, actual: rows.count)
            }
            return row
        }
    }

    public func replace(_ write: WebhookSubscriptionWrite) async throws -> WebhookSubscriptionSnapshot? {
        try await database.withSession(operation: "webhooks.subscriptions.replace") { session in
            let rows = try await session.execute(
                ReplaceWebhookSubscription(write: write),
                operation: "webhooks.subscriptions.replace.query")
            guard rows.count <= 1 else {
                throw WebhookSubscriptionsPersistenceError.unexpectedRowCount(
                    expected: 1, actual: rows.count)
            }
            return rows.first
        }
    }

    public func replaceSigningSecret(
        id: UUID,
        expectedCurrentValue: String? = nil,
        replacement: String
    ) async throws -> WebhookSubscriptionSnapshot? {
        try await database.withSession(operation: "webhooks.subscriptions.rotate_secret") { session in
            let rows = try await session.execute(
                ReplaceWebhookSigningSecret(
                    id: id, expectedCurrentValue: expectedCurrentValue, replacement: replacement),
                operation: "webhooks.subscriptions.rotate_secret.query")
            guard rows.count <= 1 else {
                throw WebhookSubscriptionsPersistenceError.unexpectedRowCount(
                    expected: 1, actual: rows.count)
            }
            return rows.first
        }
    }

    @discardableResult
    public func delete(id: UUID) async throws -> Bool {
        try await database.withSession(operation: "webhooks.subscriptions.delete") { session in
            try await session.execute(
                DeleteWebhookSubscription(id: id),
                operation: "webhooks.subscriptions.delete.query") == [id]
        }
    }

    public func allWithSigningSecrets() async throws -> [WebhookSubscriptionSnapshot] {
        try await database.withSession(operation: "webhooks.subscriptions.list_secrets") { session in
            try await session.execute(
                ListAllWebhookSubscriptions(),
                operation: "webhooks.subscriptions.list_secrets.query")
        }
    }

    public func recordDeliverySuccess(
        id: UUID,
        automaticDisabledReason: String
    ) async throws -> WebhookSubscriptionSnapshot? {
        try await database.withSession(operation: "webhooks.subscriptions.delivery_success") {
            session in
            let rows = try await session.execute(
                RecordWebhookDeliverySuccess(
                    id: id, automaticDisabledReason: automaticDisabledReason),
                operation: "webhooks.subscriptions.delivery_success.query")
            guard rows.count <= 1 else {
                throw WebhookSubscriptionsPersistenceError.unexpectedRowCount(
                    expected: 1, actual: rows.count)
            }
            return rows.first
        }
    }

    public func recordDeliveryFailure(
        id: UUID,
        at date: Date,
        disableBefore cutoff: Date,
        disabledReason: String
    ) async throws -> WebhookSubscriptionSnapshot? {
        try await database.withSession(operation: "webhooks.subscriptions.delivery_failure") {
            session in
            let rows = try await session.execute(
                RecordWebhookDeliveryFailure(
                    id: id, date: date, cutoff: cutoff, disabledReason: disabledReason),
                operation: "webhooks.subscriptions.delivery_failure.query")
            guard rows.count <= 1 else {
                throw WebhookSubscriptionsPersistenceError.unexpectedRowCount(
                    expected: 1, actual: rows.count)
            }
            return rows.first
        }
    }
}

private let webhookSubscriptionColumns = """
    id, organization_id, project_id, name, url, event_types, signing_secret,
    is_active, disabled_reason, failing_since, created_by_id, created_at, updated_at
    """

private protocol WebhookSubscriptionStatement: PostgresPreparedStatement
    where Row == WebhookSubscriptionSnapshot {}

private extension WebhookSubscriptionStatement {
    func decodeRow(_ row: PostgresRow) throws -> WebhookSubscriptionSnapshot {
        let value = try row.decode((
            UUID, UUID, UUID?, String, String, String, String, Bool,
            String?, Date?, UUID, Date?, Date?
        ).self)
        return WebhookSubscriptionSnapshot(
            id: value.0,
            organizationID: value.1,
            projectID: value.2,
            name: value.3,
            url: value.4,
            eventTypesJSON: value.5,
            encryptedSigningSecret: value.6,
            isActive: value.7,
            disabledReason: value.8,
            failingSince: value.9,
            createdByID: value.10,
            createdAt: value.11,
            updatedAt: value.12
        )
    }
}

private struct ListWebhookSubscriptions: WebhookSubscriptionStatement {
    static let sql = """
        SELECT \(webhookSubscriptionColumns)
        FROM webhook_subscriptions
        WHERE organization_id = $1
        ORDER BY created_at, id
        """
    let organizationID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(organizationID)
        return bindings
    }
}

private struct ListAllWebhookSubscriptions: WebhookSubscriptionStatement {
    static let sql = "SELECT \(webhookSubscriptionColumns) FROM webhook_subscriptions ORDER BY id"
    func makeBindings() -> PostgresBindings { PostgresBindings() }
}

private struct FindWebhookSubscription: WebhookSubscriptionStatement {
    static let sql = """
        SELECT \(webhookSubscriptionColumns)
        FROM webhook_subscriptions
        WHERE id = $1 AND ($2::uuid IS NULL OR organization_id = $2)
        """
    let id: UUID
    let organizationID: UUID?
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(organizationID)
        return bindings
    }
}

private struct InsertWebhookSubscription: WebhookSubscriptionStatement {
    static let sql = """
        INSERT INTO webhook_subscriptions (
            id, organization_id, project_id, name, url, event_types, signing_secret,
            is_active, disabled_reason, failing_since, created_by_id, created_at, updated_at
        ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, CURRENT_TIMESTAMP, NULL
        )
        RETURNING \(webhookSubscriptionColumns)
        """
    let write: WebhookSubscriptionWrite
    func makeBindings() -> PostgresBindings { bindings(write) }
}

private struct ReplaceWebhookSubscription: WebhookSubscriptionStatement {
    static let sql = """
        UPDATE webhook_subscriptions SET
            organization_id = $2, project_id = $3, name = $4, url = $5,
            event_types = $6, signing_secret = $7, is_active = $8,
            disabled_reason = $9, failing_since = $10, created_by_id = $11,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(webhookSubscriptionColumns)
        """
    let write: WebhookSubscriptionWrite
    func makeBindings() -> PostgresBindings { bindings(write) }
}

private func bindings(_ write: WebhookSubscriptionWrite) -> PostgresBindings {
    var bindings = PostgresBindings(capacity: 11)
    bindings.append(write.id)
    bindings.append(write.organizationID)
    bindings.append(write.projectID)
    bindings.append(write.name)
    bindings.append(write.url)
    bindings.append(write.eventTypesJSON)
    bindings.append(write.encryptedSigningSecret)
    bindings.append(write.isActive)
    bindings.append(write.disabledReason)
    bindings.append(write.failingSince)
    bindings.append(write.createdByID)
    return bindings
}

private struct ReplaceWebhookSigningSecret: WebhookSubscriptionStatement {
    static let sql = """
        UPDATE webhook_subscriptions
        SET signing_secret = $3, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND ($2::text IS NULL OR signing_secret = $2)
        RETURNING \(webhookSubscriptionColumns)
        """
    let id: UUID
    let expectedCurrentValue: String?
    let replacement: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(expectedCurrentValue)
        bindings.append(replacement)
        return bindings
    }
}

private struct RecordWebhookDeliverySuccess: WebhookSubscriptionStatement {
    static let sql = """
        UPDATE webhook_subscriptions
        SET failing_since = NULL,
            is_active = CASE
                WHEN NOT is_active AND disabled_reason = $2 THEN TRUE
                ELSE is_active
            END,
            disabled_reason = CASE
                WHEN NOT is_active AND disabled_reason = $2 THEN NULL
                ELSE disabled_reason
            END,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND (failing_since IS NOT NULL OR disabled_reason = $2)
        RETURNING \(webhookSubscriptionColumns)
        """
    let id: UUID
    let automaticDisabledReason: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(automaticDisabledReason)
        return bindings
    }
}

private struct RecordWebhookDeliveryFailure: WebhookSubscriptionStatement {
    static let sql = """
        UPDATE webhook_subscriptions
        SET failing_since = COALESCE(failing_since, $2),
            is_active = CASE
                WHEN is_active AND failing_since IS NOT NULL AND failing_since < $3
                THEN FALSE ELSE is_active
            END,
            disabled_reason = CASE
                WHEN is_active AND failing_since IS NOT NULL AND failing_since < $3
                THEN $4 ELSE disabled_reason
            END,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(webhookSubscriptionColumns)
        """
    let id: UUID
    let date: Date
    let cutoff: Date
    let disabledReason: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(id)
        bindings.append(date)
        bindings.append(cutoff)
        bindings.append(disabledReason)
        return bindings
    }
}

private struct DeleteWebhookSubscription: PostgresPreparedStatement {
    static let sql = "DELETE FROM webhook_subscriptions WHERE id = $1 RETURNING id"
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}
