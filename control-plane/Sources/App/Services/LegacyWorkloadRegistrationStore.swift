import ControlPlanePostgres
import Fluent
import Foundation
import SQLKit
import Vapor

/// Immutable workload-registration state for operations that still have to
/// participate in a caller-owned Fluent transaction. This bridge disappears
/// with those domain transactions; it does not expose a mutable model.
struct LegacyWorkloadRegistrationRecord: Decodable, Sendable {
    let id: UUID
    let spiffeID: String
    let kindRawValue: String
    let agentName: String?
    let serviceAccountID: UUID?
    let organizationID: UUID?
    let displayName: String?
    let createdBy: UUID?
    let createdAt: Date?
    let vmID: UUID?

    var kind: WorkloadRegistrationKind? {
        WorkloadRegistrationKind(rawValue: kindRawValue)
    }
}

enum LegacyWorkloadRegistrationStore {
    static func registration(
        id: UUID,
        on db: any Database
    ) async throws -> LegacyWorkloadRegistrationRecord? {
        try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: columns)
            FROM workload_registrations
            WHERE id = \(bind: id)
            """
        ).first(decoding: LegacyWorkloadRegistrationRecord.self)
    }

    static func registration(
        spiffeID: String,
        on db: any Database
    ) async throws -> LegacyWorkloadRegistrationRecord? {
        try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: columns)
            FROM workload_registrations
            WHERE spiffe_id = \(bind: spiffeID)
            """
        ).first(decoding: LegacyWorkloadRegistrationRecord.self)
    }

    static func registrations(
        vmIDs: [UUID],
        on db: any Database
    ) async throws -> [LegacyWorkloadRegistrationRecord] {
        guard !vmIDs.isEmpty else { return [] }
        return try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: columns)
            FROM workload_registrations
            WHERE vm_id = ANY(\(bind: vmIDs))
            ORDER BY vm_id, id
            """
        ).all(decoding: LegacyWorkloadRegistrationRecord.self)
    }

    static func all(on db: any Database) async throws -> [LegacyWorkloadRegistrationRecord] {
        try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM workload_registrations ORDER BY spiffe_id, id"
        ).all(decoding: LegacyWorkloadRegistrationRecord.self)
    }

    @discardableResult
    static func insert(
        _ write: WorkloadRegistrationWrite,
        on db: any Database
    ) async throws -> LegacyWorkloadRegistrationRecord {
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO workload_registrations (
                id, spiffe_id, kind, agent_name, service_account_id, organization_id,
                display_name, created_by, created_at, vm_id
            ) VALUES (
                \(bind: write.id), \(bind: write.spiffeID),
                CAST(\(bind: write.kind) AS workload_registration_kind),
                \(bind: write.agentName), \(bind: write.serviceAccountID),
                \(bind: write.organizationID), \(bind: write.displayName),
                \(bind: write.createdBy), CURRENT_TIMESTAMP, \(bind: write.vmID)
            )
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: LegacyWorkloadRegistrationRecord.self) else {
            throw Abort(.internalServerError, reason: "Could not create workload registration")
        }
        return row
    }

    static func delete(id: UUID, on db: any Database) async throws {
        try await requireSQL(db).raw(
            "DELETE FROM workload_registrations WHERE id = \(bind: id)"
        ).run()
    }

    static func deleteAgent(spiffeID: String, on db: any Database) async throws {
        try await requireSQL(db).raw(
            """
            DELETE FROM workload_registrations
            WHERE kind = 'agent' AND spiffe_id = \(bind: spiffeID)
            """
        ).run()
    }

    static func ids(
        vmIDs: [UUID] = [],
        organizationIDs: [UUID] = [],
        serviceAccountIDs: [UUID] = [],
        kind: WorkloadRegistrationKind? = nil,
        on db: any Database
    ) async throws -> [UUID] {
        struct Identifier: Decodable { let id: UUID }
        guard !vmIDs.isEmpty || !organizationIDs.isEmpty || !serviceAccountIDs.isEmpty else {
            return []
        }
        return try await requireSQL(db).raw(
            """
            SELECT id
            FROM workload_registrations
            WHERE (\(bind: kind?.rawValue)::text IS NULL OR kind::text = \(bind: kind?.rawValue))
              AND (
                   (cardinality(\(bind: vmIDs)) > 0 AND vm_id = ANY(\(bind: vmIDs)))
                OR (cardinality(\(bind: organizationIDs)) > 0
                    AND organization_id = ANY(\(bind: organizationIDs)))
                OR (cardinality(\(bind: serviceAccountIDs)) > 0
                    AND service_account_id = ANY(\(bind: serviceAccountIDs)))
              )
            ORDER BY id
            """
        ).all(decoding: Identifier.self).map(\.id)
    }

    private static let columns = """
        id,
        spiffe_id AS "spiffeID",
        kind::text AS "kindRawValue",
        agent_name AS "agentName",
        service_account_id AS "serviceAccountID",
        organization_id AS "organizationID",
        display_name AS "displayName",
        created_by AS "createdBy",
        created_at AS "createdAt",
        vm_id AS "vmID"
        """

    private static func requireSQL(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Workload registry requires PostgreSQL")
        }
        return sql
    }
}
