import Foundation
import PostgresNIO

public enum SCIMExternalResourceType: String, Codable, Sendable {
    case user = "User"
    case group = "Group"
}

public struct SCIMExternalIDSnapshot: Equatable, Sendable {
    public let id: UUID
    public let organizationID: UUID
    public let resourceType: SCIMExternalResourceType
    public let externalID: String
    public let internalID: UUID
    public let createdAt: Date?
    public let updatedAt: Date?
}

public enum SCIMExternalIDPersistenceError: Error, Equatable, Sendable {
    case unknownResourceType(String)
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Owns the organization-scoped mapping between an upstream SCIM identifier
/// and Strato's durable UUID. Assignment is one PostgreSQL upsert, so
/// concurrent provisioning requests converge without string-matching errors.
public struct SCIMExternalIDsPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func internalID(
        externalID: String,
        resourceType: SCIMExternalResourceType,
        organizationID: UUID
    ) async throws -> UUID? {
        try await database.withSession(operation: "scim_external_ids.resolve_external") { session in
            try oneOrNone(
                await session.execute(
                    FindSCIMInternalID(
                        organizationID: organizationID,
                        resourceType: resourceType,
                        externalID: externalID
                    ),
                    operation: "scim_external_ids.resolve_external.query"
                )
            )?.internalID
        }
    }

    public func externalID(
        internalID: UUID,
        resourceType: SCIMExternalResourceType,
        organizationID: UUID
    ) async throws -> String? {
        try await database.withSession(operation: "scim_external_ids.resolve_internal") { session in
            try oneOrNone(
                await session.execute(
                    FindSCIMExternalID(
                        organizationID: organizationID,
                        resourceType: resourceType,
                        internalID: internalID
                    ),
                    operation: "scim_external_ids.resolve_internal.query"
                )
            )?.externalID
        }
    }

    @discardableResult
    public func assign(
        externalID: String,
        to internalID: UUID,
        resourceType: SCIMExternalResourceType,
        organizationID: UUID
    ) async throws -> SCIMExternalIDSnapshot {
        try await database.withSession(operation: "scim_external_ids.assign") { session in
            try only(
                await session.execute(
                    AssignSCIMExternalID(
                        id: UUID(),
                        organizationID: organizationID,
                        resourceType: resourceType,
                        externalID: externalID,
                        internalID: internalID
                    ),
                    operation: "scim_external_ids.assign.query"
                )
            )
        }
    }

    /// Removes every external alias for the internal resource, matching the
    /// legacy delete behavior when historical data contains more than one.
    @discardableResult
    public func remove(
        internalID: UUID,
        resourceType: SCIMExternalResourceType,
        organizationID: UUID
    ) async throws -> [UUID] {
        try await database.withSession(operation: "scim_external_ids.remove") { session in
            try await session.execute(
                DeleteSCIMExternalIDs(
                    organizationID: organizationID,
                    resourceType: resourceType,
                    internalID: internalID
                ),
                operation: "scim_external_ids.remove.query"
            )
        }
    }

    private func oneOrNone(_ rows: [SCIMExternalIDSnapshot]) throws -> SCIMExternalIDSnapshot? {
        guard rows.count <= 1 else {
            throw SCIMExternalIDPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return rows.first
    }

    private func only(_ rows: [SCIMExternalIDSnapshot]) throws -> SCIMExternalIDSnapshot {
        guard rows.count == 1, let row = rows.first else {
            throw SCIMExternalIDPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return row
    }
}

private let scimExternalIDColumns = "id, organization_id, resource_type, external_id, internal_id, created_at, updated_at"

private protocol SCIMExternalIDStatement: PostgresPreparedStatement
where Row == SCIMExternalIDSnapshot {}

private extension SCIMExternalIDStatement {
    func decodeRow(_ row: PostgresRow) throws -> SCIMExternalIDSnapshot {
        let (id, organizationID, rawResourceType, externalID, internalID, createdAt, updatedAt) =
            try row.decode((UUID, UUID, String, String, UUID, Date?, Date?).self)
        guard let resourceType = SCIMExternalResourceType(rawValue: rawResourceType) else {
            throw SCIMExternalIDPersistenceError.unknownResourceType(rawResourceType)
        }
        return SCIMExternalIDSnapshot(
            id: id,
            organizationID: organizationID,
            resourceType: resourceType,
            externalID: externalID,
            internalID: internalID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private struct FindSCIMInternalID: SCIMExternalIDStatement {
    static let sql = """
        SELECT \(scimExternalIDColumns)
        FROM scim_external_ids
        WHERE organization_id = $1 AND resource_type = $2 AND external_id = $3
        LIMIT 1
        """

    let organizationID: UUID
    let resourceType: SCIMExternalResourceType
    let externalID: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(organizationID)
        bindings.append(resourceType.rawValue)
        bindings.append(externalID)
        return bindings
    }
}

private struct FindSCIMExternalID: SCIMExternalIDStatement {
    static let sql = """
        SELECT \(scimExternalIDColumns)
        FROM scim_external_ids
        WHERE organization_id = $1 AND resource_type = $2 AND internal_id = $3
        LIMIT 1
        """

    let organizationID: UUID
    let resourceType: SCIMExternalResourceType
    let internalID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(organizationID)
        bindings.append(resourceType.rawValue)
        bindings.append(internalID)
        return bindings
    }
}

private struct AssignSCIMExternalID: SCIMExternalIDStatement {
    static let sql = """
        INSERT INTO scim_external_ids (
            id, organization_id, resource_type, external_id, internal_id, created_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT (organization_id, resource_type, external_id)
        DO UPDATE SET internal_id = EXCLUDED.internal_id, updated_at = CURRENT_TIMESTAMP
        RETURNING \(scimExternalIDColumns)
        """

    let id: UUID
    let organizationID: UUID
    let resourceType: SCIMExternalResourceType
    let externalID: String
    let internalID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(id)
        bindings.append(organizationID)
        bindings.append(resourceType.rawValue)
        bindings.append(externalID)
        bindings.append(internalID)
        return bindings
    }
}

private struct DeleteSCIMExternalIDs: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM scim_external_ids
        WHERE organization_id = $1 AND resource_type = $2 AND internal_id = $3
        RETURNING id
        """
    typealias Row = UUID

    let organizationID: UUID
    let resourceType: SCIMExternalResourceType
    let internalID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(organizationID)
        bindings.append(resourceType.rawValue)
        bindings.append(internalID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.decode(UUID.self)
    }
}
