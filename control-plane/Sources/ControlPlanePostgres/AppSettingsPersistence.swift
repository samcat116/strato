import Foundation
import PostgresNIO

/// Immutable value crossing the application-settings persistence boundary.
public struct AppSettingSnapshot: Equatable, Sendable {
    public let id: UUID
    public let key: String
    public let value: String
    public let createdAt: Date?
    public let updatedAt: Date?
}

/// Persistence operations for deployment-scoped settings.
///
/// This module owns the insert race instead of exposing CRUD. UUID generation
/// stays application-side and automatic timestamps stay database-side.
public struct AppSettingsPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func setting(forKey key: String) async throws -> AppSettingSnapshot? {
        try await database.withSession(operation: "app_settings.lookup") { session in
            try await session.execute(
                LookupAppSetting(key: key),
                operation: "app_settings.lookup.query"
            ).first?.snapshot
        }
    }

    /// Insert a setting once. If another replica wins the unique-key race,
    /// re-read its value in a new statement so PostgreSQL's READ COMMITTED
    /// snapshot can observe the committed row.
    public func createIfAbsent(key: String, value: String) async throws -> AppSettingSnapshot {
        try await database.withSession(operation: "app_settings.create_if_absent") { session in
            if let inserted = try await session.execute(
                InsertAppSetting(id: UUID(), key: key, value: value),
                operation: "app_settings.insert_if_absent"
            ).first {
                return inserted.snapshot
            }
            guard let existing = try await session.execute(
                LookupAppSetting(key: key),
                operation: "app_settings.lookup_after_conflict"
            ).first else {
                throw AppSettingsPersistenceError.conflictingRowMissing(key: key)
            }
            return existing.snapshot
        }
    }
}

public enum AppSettingsPersistenceError: Error, Sendable {
    case conflictingRowMissing(key: String)
}

private struct AppSettingRecord: Sendable {
    let id: UUID
    let key: String
    let value: String
    let createdAt: Date?
    let updatedAt: Date?

    var snapshot: AppSettingSnapshot {
        AppSettingSnapshot(
            id: id,
            key: key,
            value: value,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    init(row: PostgresRow) throws {
        (id, key, value, createdAt, updatedAt) = try row.decode(
            (UUID, String, String, Date?, Date?).self)
    }
}

private struct LookupAppSetting: PostgresPreparedStatement {
    static let sql = """
        SELECT id, key, value, created_at, updated_at
        FROM app_settings
        WHERE key = $1
        LIMIT 1
        """

    typealias Row = AppSettingRecord
    let key: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(key)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> AppSettingRecord {
        try AppSettingRecord(row: row)
    }
}

private struct InsertAppSetting: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO app_settings (id, key, value, created_at, updated_at)
        VALUES ($1, $2, $3, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT (key) DO NOTHING
        RETURNING id, key, value, created_at, updated_at
        """

    typealias Row = AppSettingRecord
    let id: UUID
    let key: String
    let value: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(key)
        bindings.append(value)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> AppSettingRecord {
        try AppSettingRecord(row: row)
    }
}
