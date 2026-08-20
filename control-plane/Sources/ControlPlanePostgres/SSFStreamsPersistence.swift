import Foundation
import PostgresNIO

public enum SSFDeliveryMethod: String, Codable, Sendable {
    case push
    case poll
}

public struct SSFStreamWrite: Sendable {
    public let id: UUID
    public let organizationID: UUID
    public let name: String
    public let description: String?
    public let transmitterURL: String
    public let encryptedAuthToken: String?
    public let expectedIssuer: String?
    public let expectedAudience: [String]
    public let deliveryMethod: SSFDeliveryMethod
    public let eventsRequested: [String]
    public let enabled: Bool
    public let createdByID: UUID

    public init(
        id: UUID = UUID(),
        organizationID: UUID,
        name: String,
        description: String? = nil,
        transmitterURL: String,
        encryptedAuthToken: String? = nil,
        expectedIssuer: String? = nil,
        expectedAudience: [String] = [],
        deliveryMethod: SSFDeliveryMethod,
        eventsRequested: [String] = [],
        enabled: Bool = true,
        createdByID: UUID
    ) {
        self.id = id
        self.organizationID = organizationID
        self.name = name
        self.description = description
        self.transmitterURL = transmitterURL
        self.encryptedAuthToken = encryptedAuthToken
        self.expectedIssuer = expectedIssuer
        self.expectedAudience = expectedAudience
        self.deliveryMethod = deliveryMethod
        self.eventsRequested = eventsRequested
        self.enabled = enabled
        self.createdByID = createdByID
    }
}

public struct SSFStreamChanges: Sendable {
    public let name: String?
    public let description: String?
    public let encryptedAuthToken: String?
    public let expectedIssuer: String?
    public let expectedAudience: [String]?
    public let eventsRequested: [String]?
    public let enabled: Bool?

    public init(
        name: String? = nil,
        description: String? = nil,
        encryptedAuthToken: String? = nil,
        expectedIssuer: String? = nil,
        expectedAudience: [String]? = nil,
        eventsRequested: [String]? = nil,
        enabled: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.encryptedAuthToken = encryptedAuthToken
        self.expectedIssuer = expectedIssuer
        self.expectedAudience = expectedAudience
        self.eventsRequested = eventsRequested
        self.enabled = enabled
    }
}

public struct SSFStreamSnapshot: Equatable, Sendable {
    public let id: UUID
    public let organizationID: UUID
    public let name: String
    public let description: String?
    public let transmitterURL: String
    public let encryptedAuthToken: String?
    public let expectedIssuer: String?
    public let expectedAudience: [String]
    public let deliveryMethod: String
    public let eventsRequested: [String]
    public let remoteStreamID: String?
    public let pollEndpoint: String?
    public let pushTokenHash: String?
    public let pushTokenPrefix: String?
    public let enabled: Bool
    public let verifiedAt: Date?
    public let lastEventAt: Date?
    public let lastError: String?
    public let createdByID: UUID
    public let createdAt: Date?
    public let updatedAt: Date?

    public var deliveryMethodValue: SSFDeliveryMethod? {
        SSFDeliveryMethod(rawValue: deliveryMethod)
    }

    public var isRegistered: Bool {
        remoteStreamID != nil
    }
}

public enum SSFStreamPersistenceError: Error, Equatable, Sendable {
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Owns local SSF receiver configuration and registration state.
public struct SSFStreamsPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func streams(organizationID: UUID) async throws -> [SSFStreamSnapshot] {
        try await database.withSession(operation: "ssf_streams.list") { session in
            try await session.execute(
                ListSSFStreams(organizationID: organizationID),
                operation: "ssf_streams.list.query"
            ).map(\.snapshot)
        }
    }

    public func stream(id: UUID) async throws -> SSFStreamSnapshot? {
        try await database.withSession(operation: "ssf_streams.lookup") { session in
            try oneOrNone(
                await session.execute(
                    FindSSFStream(id: id),
                    operation: "ssf_streams.lookup.query"
                )
            )
        }
    }

    public func ownedStream(id: UUID, organizationID: UUID) async throws -> SSFStreamSnapshot? {
        try await database.withSession(operation: "ssf_streams.lookup_owned") { session in
            try oneOrNone(
                await session.execute(
                    FindOwnedSSFStream(id: id, organizationID: organizationID),
                    operation: "ssf_streams.lookup_owned.query"
                )
            )
        }
    }

    public func create(_ write: SSFStreamWrite) async throws -> SSFStreamSnapshot {
        try await database.withSession(operation: "ssf_streams.create") { session in
            try only(
                await session.execute(
                    InsertSSFStream(write: write),
                    operation: "ssf_streams.create.query"
                )
            )
        }
    }

    public func updateOwnedStream(
        id: UUID,
        organizationID: UUID,
        changes: SSFStreamChanges
    ) async throws -> SSFStreamSnapshot? {
        try await database.withSession(operation: "ssf_streams.update_owned") { session in
            try oneOrNone(
                await session.execute(
                    UpdateOwnedSSFStream(
                        id: id,
                        organizationID: organizationID,
                        changes: changes
                    ),
                    operation: "ssf_streams.update_owned.query"
                )
            )
        }
    }

    @discardableResult
    public func deleteOwnedStream(id: UUID, organizationID: UUID) async throws -> Bool {
        try await database.withSession(operation: "ssf_streams.delete_owned") { session in
            try await session.execute(
                DeleteOwnedSSFStream(id: id, organizationID: organizationID),
                operation: "ssf_streams.delete_owned.query"
            ).count == 1
        }
    }

    /// Clear the local registration before replacing a remote stream.
    public func clearRegistration(id: UUID) async throws -> SSFStreamSnapshot? {
        try await database.withSession(operation: "ssf_streams.clear_registration") { session in
            try oneOrNone(
                await session.execute(
                    ClearSSFRegistration(id: id),
                    operation: "ssf_streams.clear_registration.query"
                )
            )
        }
    }

    public func completeRegistration(
        id: UUID,
        remoteStreamID: String,
        pollEndpoint: String?,
        pushTokenHash: String?,
        pushTokenPrefix: String?
    ) async throws -> SSFStreamSnapshot? {
        try await database.withSession(operation: "ssf_streams.complete_registration") { session in
            try oneOrNone(
                await session.execute(
                    CompleteSSFRegistration(
                        id: id,
                        remoteStreamID: remoteStreamID,
                        pollEndpoint: pollEndpoint,
                        pushTokenHash: pushTokenHash,
                        pushTokenPrefix: pushTokenPrefix
                    ),
                    operation: "ssf_streams.complete_registration.query"
                )
            )
        }
    }

    public func registeredPollStreams() async throws -> [SSFStreamSnapshot] {
        try await database.withSession(operation: "ssf_streams.list_registered_poll") { session in
            try await session.execute(
                ListRegisteredPollStreams(),
                operation: "ssf_streams.list_registered_poll.query"
            ).map(\.snapshot)
        }
    }

    /// Streams whose recoverable transmitter credential needs startup inspection.
    public func streamsWithAuthTokens() async throws -> [SSFStreamSnapshot] {
        try await database.withSession(operation: "ssf_streams.list_with_auth_tokens") { session in
            try await session.execute(
                ListSSFStreamsWithAuthTokens(),
                operation: "ssf_streams.list_with_auth_tokens.query"
            ).map(\.snapshot)
        }
    }

    /// Compare-and-set a stored token so concurrent startup convergence cannot
    /// overwrite a credential that an administrator rotated in the meantime.
    @discardableResult
    public func replaceEncryptedAuthToken(
        id: UUID,
        expectedCurrentValue: String,
        replacement: String
    ) async throws -> Bool {
        try await database.withSession(operation: "ssf_streams.replace_auth_token") { session in
            try await session.execute(
                ReplaceSSFStreamAuthToken(
                    id: id,
                    expectedCurrentValue: expectedCurrentValue,
                    replacement: replacement
                ),
                operation: "ssf_streams.replace_auth_token.query"
            ).count == 1
        }
    }

    @discardableResult
    public func recordEvent(id: UUID, at date: Date) async throws -> Bool {
        try await database.withSession(operation: "ssf_streams.record_event") { session in
            try await session.execute(
                RecordSSFEvent(id: id, date: date),
                operation: "ssf_streams.record_event.query"
            ).count == 1
        }
    }

    @discardableResult
    public func markVerified(id: UUID, at date: Date) async throws -> Bool {
        try await database.withSession(operation: "ssf_streams.mark_verified") { session in
            try await session.execute(
                MarkSSFStreamVerified(id: id, date: date),
                operation: "ssf_streams.mark_verified.query"
            ).count == 1
        }
    }

    @discardableResult
    public func recordError(id: UUID, message: String) async throws -> Bool {
        try await database.withSession(operation: "ssf_streams.record_error") { session in
            try await session.execute(
                RecordSSFStreamError(id: id, message: message),
                operation: "ssf_streams.record_error.query"
            ).count == 1
        }
    }

    private func oneOrNone(_ rows: [SSFStreamRecord]) throws -> SSFStreamSnapshot? {
        guard rows.count <= 1 else {
            throw SSFStreamPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return rows.first?.snapshot
    }

    private func only(_ rows: [SSFStreamRecord]) throws -> SSFStreamSnapshot {
        guard rows.count == 1, let row = rows.first else {
            throw SSFStreamPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return row.snapshot
    }
}

private struct SSFStreamRecord: Sendable {
    let id: UUID
    let organizationID: UUID
    let name: String
    let description: String?
    let transmitterURL: String
    let encryptedAuthToken: String?
    let expectedIssuer: String?
    let expectedAudienceJSON: String
    let deliveryMethod: String
    let eventsRequestedJSON: String
    let remoteStreamID: String?
    let pollEndpoint: String?
    let pushTokenHash: String?
    let pushTokenPrefix: String?
    let enabled: Bool
    let verifiedAt: Date?
    let lastEventAt: Date?
    let lastError: String?
    let createdByID: UUID
    let createdAt: Date?
    let updatedAt: Date?

    init(row: PostgresRow) throws {
        (
            id, organizationID, name, description, transmitterURL,
            encryptedAuthToken, expectedIssuer, expectedAudienceJSON,
            deliveryMethod, eventsRequestedJSON, remoteStreamID, pollEndpoint,
            pushTokenHash, pushTokenPrefix, enabled, verifiedAt, lastEventAt,
            lastError, createdByID, createdAt, updatedAt
        ) = try row.decode(
            (
                UUID, UUID, String, String?, String,
                String?, String?, String, String, String,
                String?, String?, String?, String?, Bool,
                Date?, Date?, String?, UUID, Date?, Date?
            ).self
        )
    }

    var snapshot: SSFStreamSnapshot {
        SSFStreamSnapshot(
            id: id,
            organizationID: organizationID,
            name: name,
            description: description,
            transmitterURL: transmitterURL,
            encryptedAuthToken: encryptedAuthToken,
            expectedIssuer: expectedIssuer,
            expectedAudience: decodeStringArray(expectedAudienceJSON),
            deliveryMethod: deliveryMethod,
            eventsRequested: decodeStringArray(eventsRequestedJSON),
            remoteStreamID: remoteStreamID,
            pollEndpoint: pollEndpoint,
            pushTokenHash: pushTokenHash,
            pushTokenPrefix: pushTokenPrefix,
            enabled: enabled,
            verifiedAt: verifiedAt,
            lastEventAt: lastEventAt,
            lastError: lastError,
            createdByID: createdByID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private func encodeStringArray(_ values: [String]) -> String {
    guard let data = try? JSONEncoder().encode(values),
        let value = String(data: data, encoding: .utf8)
    else {
        return "[]"
    }
    return value
}

private func decodeStringArray(_ value: String) -> [String] {
    guard let data = value.data(using: .utf8),
        let values = try? JSONDecoder().decode([String].self, from: data)
    else {
        return []
    }
    return values
}

private let ssfStreamColumns = """
    id, organization_id, name, description, transmitter_url, auth_token,
    expected_issuer, expected_audience, delivery_method, events_requested,
    remote_stream_id, poll_endpoint, push_token_hash, push_token_prefix,
    enabled, verified_at, last_event_at, last_error, created_by_id,
    created_at, updated_at
    """

private protocol SSFStreamRecordStatement: PostgresPreparedStatement where Row == SSFStreamRecord {}

private extension SSFStreamRecordStatement {
    func decodeRow(_ row: PostgresRow) throws -> SSFStreamRecord {
        try SSFStreamRecord(row: row)
    }
}

private struct ListSSFStreams: SSFStreamRecordStatement {
    static let sql = """
        SELECT \(ssfStreamColumns)
        FROM ssf_streams
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

private struct FindSSFStream: SSFStreamRecordStatement {
    static let sql = "SELECT \(ssfStreamColumns) FROM ssf_streams WHERE id = $1"
    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct FindOwnedSSFStream: SSFStreamRecordStatement {
    static let sql = """
        SELECT \(ssfStreamColumns)
        FROM ssf_streams
        WHERE id = $1 AND organization_id = $2
        """
    let id: UUID
    let organizationID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(organizationID)
        return bindings
    }
}

private struct InsertSSFStream: SSFStreamRecordStatement {
    static let sql = """
        INSERT INTO ssf_streams (
            id, organization_id, name, description, transmitter_url, auth_token,
            expected_issuer, expected_audience, delivery_method, events_requested,
            remote_stream_id, poll_endpoint, push_token_hash, push_token_prefix,
            enabled, verified_at, last_event_at, last_error, created_by_id,
            created_at, updated_at
        ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
            NULL, NULL, NULL, NULL, $11, NULL, NULL, NULL, $12,
            CURRENT_TIMESTAMP, NULL
        )
        RETURNING \(ssfStreamColumns)
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .uuid, .text, .text, .text, .text, .text, .text,
        .text, .text, .bool, .uuid,
    ]

    let write: SSFStreamWrite

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 12)
        bindings.append(write.id)
        bindings.append(write.organizationID)
        bindings.append(write.name)
        bindings.append(write.description)
        bindings.append(write.transmitterURL)
        bindings.append(write.encryptedAuthToken)
        bindings.append(write.expectedIssuer)
        bindings.append(encodeStringArray(write.expectedAudience))
        bindings.append(write.deliveryMethod.rawValue)
        bindings.append(encodeStringArray(write.eventsRequested))
        bindings.append(write.enabled)
        bindings.append(write.createdByID)
        return bindings
    }
}

private struct UpdateOwnedSSFStream: SSFStreamRecordStatement {
    static let sql = """
        UPDATE ssf_streams
        SET name = COALESCE($3, name),
            description = COALESCE($4, description),
            auth_token = COALESCE($5, auth_token),
            expected_issuer = COALESCE($6, expected_issuer),
            expected_audience = COALESCE($7, expected_audience),
            events_requested = COALESCE($8, events_requested),
            enabled = COALESCE($9, enabled),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND organization_id = $2
        RETURNING \(ssfStreamColumns)
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .uuid, .text, .text, .text, .text, .text, .text, .bool,
    ]

    let id: UUID
    let organizationID: UUID
    let changes: SSFStreamChanges

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 9)
        bindings.append(id)
        bindings.append(organizationID)
        bindings.append(changes.name)
        bindings.append(changes.description)
        bindings.append(changes.encryptedAuthToken)
        bindings.append(changes.expectedIssuer)
        bindings.append(changes.expectedAudience.map(encodeStringArray))
        bindings.append(changes.eventsRequested.map(encodeStringArray))
        bindings.append(changes.enabled)
        return bindings
    }
}

private struct DeleteOwnedSSFStream: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = "DELETE FROM ssf_streams WHERE id = $1 AND organization_id = $2 RETURNING id"

    let id: UUID
    let organizationID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(organizationID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.decode(UUID.self)
    }
}

private struct ClearSSFRegistration: SSFStreamRecordStatement {
    static let sql = """
        UPDATE ssf_streams
        SET remote_stream_id = NULL,
            poll_endpoint = NULL,
            push_token_hash = NULL,
            push_token_prefix = NULL,
            verified_at = NULL,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(ssfStreamColumns)
        """
    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct CompleteSSFRegistration: SSFStreamRecordStatement {
    static let sql = """
        UPDATE ssf_streams
        SET remote_stream_id = $2,
            poll_endpoint = $3,
            push_token_hash = $4,
            push_token_prefix = $5,
            verified_at = NULL,
            last_error = NULL,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(ssfStreamColumns)
        """
    static let bindingDataTypes: [PostgresDataType] = [.uuid, .text, .text, .text, .text]

    let id: UUID
    let remoteStreamID: String
    let pollEndpoint: String?
    let pushTokenHash: String?
    let pushTokenPrefix: String?

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(id)
        bindings.append(remoteStreamID)
        bindings.append(pollEndpoint)
        bindings.append(pushTokenHash)
        bindings.append(pushTokenPrefix)
        return bindings
    }
}

private struct ListRegisteredPollStreams: SSFStreamRecordStatement {
    static let sql = """
        SELECT \(ssfStreamColumns)
        FROM ssf_streams
        WHERE enabled = TRUE
          AND delivery_method = 'poll'
          AND remote_stream_id IS NOT NULL
        ORDER BY created_at, id
        """

    func makeBindings() -> PostgresBindings {
        PostgresBindings()
    }
}

private struct ListSSFStreamsWithAuthTokens: SSFStreamRecordStatement {
    static let sql = """
        SELECT \(ssfStreamColumns)
        FROM ssf_streams
        WHERE auth_token IS NOT NULL
        ORDER BY id
        """

    func makeBindings() -> PostgresBindings {
        PostgresBindings()
    }
}

private struct ReplaceSSFStreamAuthToken: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        UPDATE ssf_streams
        SET auth_token = $3, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND auth_token = $2
        RETURNING id
        """

    let id: UUID
    let expectedCurrentValue: String
    let replacement: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(expectedCurrentValue)
        bindings.append(replacement)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.decode(UUID.self)
    }
}

private struct RecordSSFEvent: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        UPDATE ssf_streams
        SET last_event_at = $2, last_error = NULL, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING id
        """
    let id: UUID
    let date: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(date)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.decode(UUID.self)
    }
}

private struct MarkSSFStreamVerified: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        UPDATE ssf_streams
        SET verified_at = $2, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING id
        """
    let id: UUID
    let date: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(date)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.decode(UUID.self)
    }
}

private struct RecordSSFStreamError: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        UPDATE ssf_streams
        SET last_error = $2, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING id
        """
    let id: UUID
    let message: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(message)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.decode(UUID.self)
    }
}
