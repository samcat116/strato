import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

public enum VolumeReplicaState: String, Codable, CaseIterable, Sendable {
    case provisioning
    case healthy
    case degraded
    case resyncing
    case faulted
}

package struct VolumeReplicaSnapshot: Equatable, Sendable {
    package let id: UUID
    package let volumeID: UUID
    package let agentId: String
    package let diskAttachment: DiskAttachment?
    package let state: VolumeReplicaState
    package let generation: Int64
    package let createdAt: Date?
    package let updatedAt: Date?
}

/// Immutable SQL bridge for replica operations that still share a
/// caller-owned Fluent transaction with the logical volume.
package enum LegacyVolumeReplicaStore {
    static func replicas(
        volumeIDs: [UUID]? = nil,
        agentId: String? = nil,
        states: [VolumeReplicaState]? = nil,
        on db: any Database
    ) async throws -> [VolumeReplicaSnapshot] {
        if let volumeIDs, volumeIDs.isEmpty { return [] }
        if let states, states.isEmpty { return [] }
        let sql = try requireSQL(db)
        var query: SQLQueryString = "SELECT \(unsafeRaw: columns) FROM volume_replicas WHERE TRUE"
        if let volumeIDs { query += " AND volume_id = ANY(\(bind: volumeIDs))" }
        if let agentId { query += " AND agent_id = \(bind: agentId)" }
        if let states { query += " AND state = ANY(\(bind: states.map(\.rawValue)))" }
        query += " ORDER BY created_at, id"
        return try await snapshots(from: sql.raw(query).all(decoding: Record.self))
    }

    static func replica(
        id: UUID,
        on db: any Database
    ) async throws -> VolumeReplicaSnapshot? {
        guard let row = try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM volume_replicas WHERE id = \(bind: id) LIMIT 1"
        ).first(decoding: Record.self) else { return nil }
        return try row.snapshot()
    }

    static func replica(
        volumeID: UUID,
        agentId: String,
        on db: any Database
    ) async throws -> VolumeReplicaSnapshot? {
        guard let row = try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: columns)
            FROM volume_replicas
            WHERE volume_id = \(bind: volumeID) AND agent_id = \(bind: agentId)
            LIMIT 1
            """
        ).first(decoding: Record.self) else { return nil }
        return try row.snapshot()
    }

    @discardableResult
    package static func insert(
        id: UUID = UUID(),
        volumeID: UUID,
        agentId: String,
        diskAttachment: DiskAttachment? = nil,
        state: VolumeReplicaState = .provisioning,
        generation: Int64 = 0,
        on db: any Database
    ) async throws -> VolumeReplicaSnapshot {
        let attachmentJSON = try encodedAttachment(diskAttachment)
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO volume_replicas (
                id, volume_id, agent_id, disk_attachment, state, generation,
                created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: volumeID), \(bind: agentId),
                CAST(\(bind: attachmentJSON) AS jsonb), \(bind: state.rawValue),
                \(bind: generation), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not create volume replica")
        }
        return try row.snapshot()
    }

    @discardableResult
    static func recordObservation(
        volumeID: UUID,
        agentId: String,
        diskAttachment: DiskAttachment?,
        state: VolumeReplicaState,
        generation: Int64,
        on db: any Database
    ) async throws -> VolumeReplicaSnapshot {
        let attachmentJSON = try encodedAttachment(diskAttachment)
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO volume_replicas (
                id, volume_id, agent_id, disk_attachment, state, generation,
                created_at, updated_at
            ) VALUES (
                \(bind: UUID()), \(bind: volumeID), \(bind: agentId),
                CAST(\(bind: attachmentJSON) AS jsonb), \(bind: state.rawValue),
                \(bind: generation), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            ON CONFLICT (volume_id, agent_id) DO UPDATE
            SET disk_attachment = COALESCE(EXCLUDED.disk_attachment, volume_replicas.disk_attachment),
                state = EXCLUDED.state,
                generation = GREATEST(volume_replicas.generation, EXCLUDED.generation),
                updated_at = CURRENT_TIMESTAMP
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not record volume replica observation")
        }
        return try row.snapshot()
    }

    static func delete(
        volumeID: UUID,
        agentId: String? = nil,
        on db: any Database
    ) async throws {
        let sql = try requireSQL(db)
        var query: SQLQueryString = "DELETE FROM volume_replicas WHERE volume_id = \(bind: volumeID)"
        if let agentId { query += " AND agent_id = \(bind: agentId)" }
        try await sql.raw(query).run()
    }

    static func count(on db: any Database) async throws -> Int {
        struct Count: Decodable { let count: Int }
        return try await requireSQL(db).raw(
            "SELECT count(*)::bigint AS count FROM volume_replicas"
        ).first(decoding: Count.self)?.count ?? 0
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let volumeID: UUID
        let agentId: String
        let diskAttachmentJSON: String?
        let state: String
        let generation: Int64
        let createdAt: Date?
        let updatedAt: Date?

        func snapshot() throws -> VolumeReplicaSnapshot {
            guard let state = VolumeReplicaState(rawValue: state) else {
                throw Abort(.internalServerError, reason: "Volume replica has invalid state '\(state)'")
            }
            let attachment: DiskAttachment?
            if let diskAttachmentJSON {
                attachment = try JSONDecoder().decode(
                    DiskAttachment.self,
                    from: Data(diskAttachmentJSON.utf8)
                )
            } else {
                attachment = nil
            }
            return VolumeReplicaSnapshot(
                id: id,
                volumeID: volumeID,
                agentId: agentId,
                diskAttachment: attachment,
                state: state,
                generation: generation,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    private static let columns = """
        id,
        volume_id AS "volumeID",
        agent_id AS "agentId",
        disk_attachment::text AS "diskAttachmentJSON",
        state,
        generation,
        created_at AS "createdAt",
        updated_at AS "updatedAt"
        """

    private static func snapshots(
        from rows: [Record]
    ) throws -> [VolumeReplicaSnapshot] {
        try rows.map { try $0.snapshot() }
    }

    private static func encodedAttachment(_ attachment: DiskAttachment?) throws -> String? {
        guard let attachment else { return nil }
        return String(decoding: try JSONEncoder().encode(attachment), as: UTF8.self)
    }

    private static func requireSQL(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Volume replicas require PostgreSQL")
        }
        return sql
    }
}
