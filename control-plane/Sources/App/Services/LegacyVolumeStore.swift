import ControlPlanePostgres
import Foundation
import StratoShared
import Vapor

enum VolumeAttachmentFilter {
    case any
    case unattached
    case attachedTo(UUID)
    case attachedToAny([UUID])
}

/// Explicit SQL access for the immutable volume cohort while surrounding
/// multi-resource transactions still use Fluent's transaction handle.
enum LegacyVolumeStore {
    static func volume(id: UUID?, on db: PostgresStoreContext) async throws -> Volume? {
        guard let id else { return nil }
        return try await volumes(ids: [id], on: db).first
    }

    static func volumes(
        ids: [UUID]? = nil,
        projectID: UUID? = nil,
        projectIDs: [UUID]? = nil,
        name: String? = nil,
        attachment: VolumeAttachmentFilter = .any,
        volumeType: VolumeType? = nil,
        desiredStatus: DesiredVolumeStatus? = nil,
        overdueAt: Date? = nil,
        terminatingBefore: Date? = nil,
        on db: PostgresStoreContext
    ) async throws -> [Volume] {
        if ids?.isEmpty == true || projectIDs?.isEmpty == true { return [] }
        var query: PostgresSQLQuery = "SELECT \(unsafeRaw: columns) FROM volumes AS v WHERE TRUE"
        if let ids { query += " AND v.id = ANY(\(bind: ids))" }
        if let projectID { query += " AND v.project_id = \(bind: projectID)" }
        if let projectIDs { query += " AND v.project_id = ANY(\(bind: projectIDs))" }
        if let name { query += " AND v.name = \(bind: name)" }
        switch attachment {
        case .any:
            break
        case .unattached:
            query += " AND v.vm_id IS NULL"
        case .attachedTo(let vmID):
            query += " AND v.vm_id = \(bind: vmID)"
        case .attachedToAny(let vmIDs):
            guard !vmIDs.isEmpty else { return [] }
            query += " AND v.vm_id = ANY(\(bind: vmIDs))"
        }
        if let volumeType { query += " AND v.type = \(bind: volumeType.rawValue)" }
        if let desiredStatus { query += " AND v.desired_status = \(bind: desiredStatus.rawValue)" }
        if let overdueAt { query += " AND v.convergence_deadline <= \(bind: overdueAt)" }
        if let terminatingBefore {
            query += " AND v.desired_status = 'Absent' AND COALESCE(v.updated_at, v.created_at) <= \(bind: terminatingBefore)"
        }
        query += " ORDER BY v.id"
        return try await volumeSQL(db).raw(query).all(decoding: Record.self).map { try $0.volume }
    }

    @discardableResult
    static func upsert(_ volume: Volume, on db: PostgresStoreContext) async throws -> Volume {
        let id = try volume.requireID()
        guard let row = try await volumeSQL(db).raw(
            """
            INSERT INTO volumes (
                id, name, description, project_id, environment, size, format, type,
                status, desired_status, generation, observed_generation,
                observed_size_bytes, convergence_phase, error_message,
                failed_generation, convergence_deadline, finalizers, pool_id,
                attached_agent_id, vm_id, device_name, boot_order, readonly,
                iops_total, bps_total, applied_iops_total, applied_bps_total,
                source_image_id, source_volume_id, created_by_id, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: volume.name), \(bind: volume.description),
                \(bind: volume.projectID), \(bind: volume.environment), \(bind: volume.size),
                \(bind: volume.format.rawValue), \(bind: volume.volumeType.rawValue),
                \(bind: volume.status.rawValue), \(bind: volume.desiredStatus.rawValue),
                \(bind: volume.generation), \(bind: volume.observedGeneration),
                \(bind: volume.observedSizeBytes), \(bind: volume.convergencePhase),
                \(bind: volume.errorMessage), \(bind: volume.failedGeneration),
                \(bind: volume.convergenceDeadline), \(bind: volume.finalizers),
                \(bind: volume.poolID), \(bind: volume.attachedAgentId), \(bind: volume.vmID),
                \(bind: volume.deviceName), \(bind: volume.bootOrder), \(bind: volume.readonly),
                \(bind: volume.iopsTotal), \(bind: volume.bpsTotal),
                \(bind: volume.appliedIOPSTotal), \(bind: volume.appliedBPSTotal),
                \(bind: volume.sourceImageID), \(bind: volume.sourceVolumeID),
                \(bind: volume.createdByID), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            ON CONFLICT (id) DO UPDATE SET
                name = EXCLUDED.name, description = EXCLUDED.description,
                project_id = EXCLUDED.project_id, environment = EXCLUDED.environment,
                size = EXCLUDED.size, format = EXCLUDED.format, type = EXCLUDED.type,
                status = EXCLUDED.status, desired_status = EXCLUDED.desired_status,
                generation = EXCLUDED.generation,
                observed_generation = EXCLUDED.observed_generation,
                observed_size_bytes = EXCLUDED.observed_size_bytes,
                convergence_phase = EXCLUDED.convergence_phase,
                error_message = EXCLUDED.error_message,
                failed_generation = EXCLUDED.failed_generation,
                convergence_deadline = EXCLUDED.convergence_deadline,
                finalizers = EXCLUDED.finalizers, pool_id = EXCLUDED.pool_id,
                attached_agent_id = EXCLUDED.attached_agent_id, vm_id = EXCLUDED.vm_id,
                device_name = EXCLUDED.device_name, boot_order = EXCLUDED.boot_order,
                readonly = EXCLUDED.readonly, iops_total = EXCLUDED.iops_total,
                bps_total = EXCLUDED.bps_total,
                applied_iops_total = EXCLUDED.applied_iops_total,
                applied_bps_total = EXCLUDED.applied_bps_total,
                source_image_id = EXCLUDED.source_image_id,
                source_volume_id = EXCLUDED.source_volume_id,
                updated_at = CURRENT_TIMESTAMP
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not persist volume")
        }
        return try row.volume
    }

    @discardableResult
    static func delete(id: UUID, on db: PostgresStoreContext) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await volumeSQL(db).raw(
            "DELETE FROM volumes WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: Deleted.self)?.id
    }

    private struct Record: Decodable {
        let id: UUID
        let name: String
        let description: String
        let projectID: UUID
        let environment: String
        let size: Int64
        let formatRaw: String
        let volumeTypeRaw: String
        let statusRaw: String
        let desiredStatusRaw: String
        let generation: Int64
        let observedGeneration: Int64
        let observedSizeBytes: Int64?
        let convergencePhase: String?
        let errorMessage: String?
        let failedGeneration: Int64?
        let convergenceDeadline: Date?
        let finalizers: [String]
        let poolID: UUID?
        let attachedAgentID: String?
        let vmID: UUID?
        let deviceName: String?
        let bootOrder: Int?
        let readonly: Bool
        let iopsTotal: Int64?
        let bpsTotal: Int64?
        let appliedIOPSTotal: Int64?
        let appliedBPSTotal: Int64?
        let sourceImageID: UUID?
        let sourceVolumeID: UUID?
        let createdByID: UUID
        let createdAt: Date?
        let updatedAt: Date?

        var volume: Volume {
            get throws {
                guard let format = VolumeFormat(rawValue: formatRaw),
                    let volumeType = VolumeType(rawValue: volumeTypeRaw),
                    let status = VolumeStatus(rawValue: statusRaw),
                    let desiredStatus = DesiredVolumeStatus(rawValue: desiredStatusRaw)
                else { throw Abort(.internalServerError, reason: "Volume has invalid enum data") }
                return Volume(
                    id: id, name: name, description: description, projectID: projectID,
                    environment: environment, size: size, format: format,
                    volumeType: volumeType, status: status, desiredStatus: desiredStatus,
                    generation: generation, observedGeneration: observedGeneration,
                    observedSizeBytes: observedSizeBytes, convergencePhase: convergencePhase,
                    errorMessage: errorMessage, failedGeneration: failedGeneration,
                    convergenceDeadline: convergenceDeadline, finalizers: finalizers,
                    createdByID: createdByID, poolID: poolID,
                    attachedAgentId: attachedAgentID, vmID: vmID,
                    deviceName: deviceName, bootOrder: bootOrder, readonly: readonly,
                    iopsTotal: iopsTotal, bpsTotal: bpsTotal,
                    appliedIOPSTotal: appliedIOPSTotal, appliedBPSTotal: appliedBPSTotal,
                    sourceImageID: sourceImageID, sourceVolumeID: sourceVolumeID,
                    createdAt: createdAt, updatedAt: updatedAt)
            }
        }
    }

    private static let columns = """
        v.id, v.name, v.description, v.project_id AS "projectID", v.environment,
        v.size, v.format AS "formatRaw", v.type AS "volumeTypeRaw",
        v.status AS "statusRaw", v.desired_status AS "desiredStatusRaw",
        v.generation, v.observed_generation AS "observedGeneration",
        v.observed_size_bytes AS "observedSizeBytes",
        v.convergence_phase AS "convergencePhase", v.error_message AS "errorMessage",
        v.failed_generation AS "failedGeneration",
        v.convergence_deadline AS "convergenceDeadline", v.finalizers,
        v.pool_id AS "poolID", v.attached_agent_id AS "attachedAgentID",
        v.vm_id AS "vmID", v.device_name AS "deviceName", v.boot_order AS "bootOrder",
        v.readonly, v.iops_total AS "iopsTotal", v.bps_total AS "bpsTotal",
        v.applied_iops_total AS "appliedIOPSTotal",
        v.applied_bps_total AS "appliedBPSTotal", v.source_image_id AS "sourceImageID",
        v.source_volume_id AS "sourceVolumeID", v.created_by_id AS "createdByID",
        v.created_at AS "createdAt", v.updated_at AS "updatedAt"
        """
    private static let returningColumns = columns.replacingOccurrences(of: "v.", with: "")
}

private func volumeSQL(_ db: PostgresStoreContext) throws -> PostgresStoreContext {
    guard let sql = db as? PostgresStoreContext else {
        throw Abort(.internalServerError, reason: "PostgreSQL SQL interface is unavailable")
    }
    return sql
}
