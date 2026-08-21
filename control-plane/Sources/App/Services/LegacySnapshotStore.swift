import ControlPlanePostgres
import Foundation
import StratoShared
import Vapor

/// Explicit SQL access for the snapshot cohort while callers still pass a
/// Fluent transaction. The records themselves are immutable values; no Fluent
/// model, relation loader, or dirty-tracking state escapes this boundary.
enum LegacyVolumeSnapshotStore {
    static func snapshot(id: UUID?, on db: PostgresStoreContext) async throws -> VolumeSnapshot? {
        guard let id else { return nil }
        return try await snapshots(ids: [id], on: db).first
    }

    static func snapshots(
        ids: [UUID]? = nil,
        volumeID: UUID? = nil,
        projectID: UUID? = nil,
        projectIDs: [UUID]? = nil,
        agentID: String? = nil,
        overdueAt: Date? = nil,
        expiredAt: Date? = nil,
        terminating: Bool? = nil,
        orderByCreatedDescending: Bool = false,
        on db: PostgresStoreContext
    ) async throws -> [VolumeSnapshot] {
        if ids?.isEmpty == true || projectIDs?.isEmpty == true { return [] }
        var query: PostgresSQLQuery = "SELECT \(unsafeRaw: columns) FROM volume_snapshots AS s WHERE TRUE"
        if let ids { query += " AND s.id = ANY(\(bind: ids))" }
        if let volumeID { query += " AND s.volume_id = \(bind: volumeID)" }
        if let projectID { query += " AND s.project_id = \(bind: projectID)" }
        if let projectIDs { query += " AND s.project_id = ANY(\(bind: projectIDs))" }
        if let agentID { query += " AND s.agent_id = \(bind: agentID)" }
        if let overdueAt { query += " AND s.convergence_deadline <= \(bind: overdueAt)" }
        if let expiredAt {
            query += " AND s.expires_at <= \(bind: expiredAt) AND s.desired_status <> 'Absent'"
        }
        if let terminating {
            query += terminating
                ? " AND s.desired_status = 'Absent'"
                : " AND s.desired_status <> 'Absent'"
        }
        query += orderByCreatedDescending
            ? " ORDER BY s.created_at DESC, s.id DESC"
            : " ORDER BY s.id"
        return try await requireSQL(db).raw(query).all(decoding: Record.self).map { try $0.snapshot }
    }

    @discardableResult
    static func upsert(_ snapshot: VolumeSnapshot, on db: PostgresStoreContext) async throws -> VolumeSnapshot {
        let id = try snapshot.requireID()
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO volume_snapshots (
                id, name, description, volume_id, project_id, environment,
                size, observed_size_bytes, status, error_message, storage_path,
                agent_id, desired_status, generation, observed_generation,
                convergence_phase, failed_generation, convergence_deadline,
                finalizers, expires_at, created_by_id, created_at
            ) VALUES (
                \(bind: id), \(bind: snapshot.name), \(bind: snapshot.description),
                \(bind: snapshot.volumeID), \(bind: snapshot.projectID),
                \(bind: snapshot.environment), \(bind: snapshot.size),
                \(bind: snapshot.observedSizeBytes), \(bind: snapshot.status.rawValue),
                \(bind: snapshot.errorMessage), \(bind: snapshot.storagePath),
                \(bind: snapshot.agentId), \(bind: snapshot.desiredStatus.rawValue),
                \(bind: snapshot.generation), \(bind: snapshot.observedGeneration),
                \(bind: snapshot.convergencePhase), \(bind: snapshot.failedGeneration),
                \(bind: snapshot.convergenceDeadline), \(bind: snapshot.finalizers),
                \(bind: snapshot.expiresAt), \(bind: snapshot.createdByID), CURRENT_TIMESTAMP
            )
            ON CONFLICT (id) DO UPDATE SET
                name = EXCLUDED.name,
                description = EXCLUDED.description,
                volume_id = EXCLUDED.volume_id,
                project_id = EXCLUDED.project_id,
                environment = EXCLUDED.environment,
                size = EXCLUDED.size,
                observed_size_bytes = EXCLUDED.observed_size_bytes,
                status = EXCLUDED.status,
                error_message = EXCLUDED.error_message,
                storage_path = EXCLUDED.storage_path,
                agent_id = EXCLUDED.agent_id,
                desired_status = EXCLUDED.desired_status,
                generation = EXCLUDED.generation,
                observed_generation = EXCLUDED.observed_generation,
                convergence_phase = EXCLUDED.convergence_phase,
                failed_generation = EXCLUDED.failed_generation,
                convergence_deadline = EXCLUDED.convergence_deadline,
                finalizers = EXCLUDED.finalizers,
                expires_at = EXCLUDED.expires_at
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not persist volume snapshot")
        }
        return try row.snapshot
    }

    @discardableResult
    static func delete(id: UUID, on db: PostgresStoreContext) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            "DELETE FROM volume_snapshots WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: Deleted.self)?.id
    }

    private struct Record: Decodable {
        let id: UUID
        let name: String
        let description: String
        let volumeID: UUID
        let projectID: UUID
        let environment: String
        let size: Int64
        let observedSizeBytes: Int64?
        let statusRaw: String
        let errorMessage: String?
        let storagePath: String?
        let agentID: String?
        let desiredStatusRaw: String
        let generation: Int64
        let observedGeneration: Int64
        let convergencePhase: String?
        let failedGeneration: Int64?
        let convergenceDeadline: Date?
        let finalizers: [String]
        let expiresAt: Date?
        let createdByID: UUID
        let createdAt: Date?

        var snapshot: VolumeSnapshot {
            get throws {
                guard let status = SnapshotStatus(rawValue: statusRaw),
                    let desiredStatus = DesiredSnapshotStatus(rawValue: desiredStatusRaw)
                else {
                    throw Abort(.internalServerError, reason: "Volume snapshot has invalid enum data")
                }
                return VolumeSnapshot(
                    id: id, name: name, description: description, volumeID: volumeID,
                    projectID: projectID, environment: environment, size: size,
                    observedSizeBytes: observedSizeBytes, status: status,
                    errorMessage: errorMessage, storagePath: storagePath, agentId: agentID,
                    desiredStatus: desiredStatus, generation: generation,
                    observedGeneration: observedGeneration, convergencePhase: convergencePhase,
                    failedGeneration: failedGeneration, convergenceDeadline: convergenceDeadline,
                    finalizers: finalizers, expiresAt: expiresAt, createdByID: createdByID,
                    createdAt: createdAt)
            }
        }
    }

    private static let columns = """
        s.id, s.name, s.description, s.volume_id AS "volumeID",
        s.project_id AS "projectID", s.environment, s.size,
        s.observed_size_bytes AS "observedSizeBytes", s.status AS "statusRaw",
        s.error_message AS "errorMessage", s.storage_path AS "storagePath",
        s.agent_id AS "agentID", s.desired_status AS "desiredStatusRaw",
        s.generation, s.observed_generation AS "observedGeneration",
        s.convergence_phase AS "convergencePhase",
        s.failed_generation AS "failedGeneration",
        s.convergence_deadline AS "convergenceDeadline", s.finalizers,
        s.expires_at AS "expiresAt", s.created_by_id AS "createdByID",
        s.created_at AS "createdAt"
        """
    private static let returningColumns = columns.replacingOccurrences(of: "s.", with: "")
}

enum LegacyVMSnapshotStore {
    static func snapshot(id: UUID?, on db: PostgresStoreContext) async throws -> VMSnapshot? {
        guard let id else { return nil }
        return try await snapshots(ids: [id], on: db).first
    }

    static func snapshots(
        ids: [UUID]? = nil,
        vmID: UUID? = nil,
        projectIDs: [UUID]? = nil,
        agentID: String? = nil,
        overdueAt: Date? = nil,
        expiredAt: Date? = nil,
        terminating: Bool? = nil,
        orderByCreatedDescending: Bool = false,
        on db: PostgresStoreContext
    ) async throws -> [VMSnapshot] {
        if ids?.isEmpty == true || projectIDs?.isEmpty == true { return [] }
        var query: PostgresSQLQuery = "SELECT \(unsafeRaw: columns) FROM vm_snapshots AS s WHERE TRUE"
        if let ids { query += " AND s.id = ANY(\(bind: ids))" }
        if let vmID { query += " AND s.vm_id = \(bind: vmID)" }
        if let projectIDs { query += " AND s.project_id = ANY(\(bind: projectIDs))" }
        if let agentID { query += " AND s.agent_id = \(bind: agentID)" }
        if let overdueAt { query += " AND s.convergence_deadline <= \(bind: overdueAt)" }
        if let expiredAt {
            query += " AND s.expires_at <= \(bind: expiredAt) AND s.desired_status <> 'Absent'"
        }
        if let terminating {
            query += terminating
                ? " AND s.desired_status = 'Absent'"
                : " AND s.desired_status <> 'Absent'"
        }
        query += orderByCreatedDescending
            ? " ORDER BY s.created_at DESC, s.id DESC"
            : " ORDER BY s.id"
        return try await requireSQL(db).raw(query).all(decoding: Record.self).map { try $0.snapshot }
    }

    @discardableResult
    static func upsert(_ snapshot: VMSnapshot, on db: PostgresStoreContext) async throws -> VMSnapshot {
        let id = try snapshot.requireID()
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO vm_snapshots (
                id, name, description, vm_id, project_id, environment, status,
                size, agent_id, qemu_version, architecture, error_message,
                desired_status, generation, observed_generation,
                convergence_phase, failed_generation, convergence_deadline,
                finalizers, expires_at, created_by_id, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: snapshot.name), \(bind: snapshot.description),
                \(bind: snapshot.vmID), \(bind: snapshot.projectID),
                \(bind: snapshot.environment), \(bind: snapshot.status.rawValue),
                \(bind: snapshot.size), \(bind: snapshot.agentId),
                \(bind: snapshot.qemuVersion), \(bind: snapshot.architecture),
                \(bind: snapshot.errorMessage), \(bind: snapshot.desiredStatus.rawValue),
                \(bind: snapshot.generation), \(bind: snapshot.observedGeneration),
                \(bind: snapshot.convergencePhase), \(bind: snapshot.failedGeneration),
                \(bind: snapshot.convergenceDeadline), \(bind: snapshot.finalizers),
                \(bind: snapshot.expiresAt), \(bind: snapshot.createdByID),
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            ON CONFLICT (id) DO UPDATE SET
                name = EXCLUDED.name,
                description = EXCLUDED.description,
                vm_id = EXCLUDED.vm_id,
                project_id = EXCLUDED.project_id,
                environment = EXCLUDED.environment,
                status = EXCLUDED.status,
                size = EXCLUDED.size,
                agent_id = EXCLUDED.agent_id,
                qemu_version = EXCLUDED.qemu_version,
                architecture = EXCLUDED.architecture,
                error_message = EXCLUDED.error_message,
                desired_status = EXCLUDED.desired_status,
                generation = EXCLUDED.generation,
                observed_generation = EXCLUDED.observed_generation,
                convergence_phase = EXCLUDED.convergence_phase,
                failed_generation = EXCLUDED.failed_generation,
                convergence_deadline = EXCLUDED.convergence_deadline,
                finalizers = EXCLUDED.finalizers,
                expires_at = EXCLUDED.expires_at,
                updated_at = CURRENT_TIMESTAMP
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not persist VM snapshot")
        }
        return try row.snapshot
    }

    @discardableResult
    static func delete(id: UUID, on db: PostgresStoreContext) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            "DELETE FROM vm_snapshots WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: Deleted.self)?.id
    }

    private struct Record: Decodable {
        let id: UUID
        let name: String
        let description: String
        let vmID: UUID
        let projectID: UUID
        let environment: String
        let statusRaw: String
        let size: Int64?
        let agentID: String?
        let qemuVersion: String?
        let architecture: String?
        let errorMessage: String?
        let desiredStatusRaw: String
        let generation: Int64
        let observedGeneration: Int64
        let convergencePhase: String?
        let failedGeneration: Int64?
        let convergenceDeadline: Date?
        let finalizers: [String]
        let expiresAt: Date?
        let createdByID: UUID
        let createdAt: Date?
        let updatedAt: Date?

        var snapshot: VMSnapshot {
            get throws {
                guard let status = VMSnapshotStatus(rawValue: statusRaw),
                    let desiredStatus = DesiredSnapshotStatus(rawValue: desiredStatusRaw)
                else {
                    throw Abort(.internalServerError, reason: "VM snapshot has invalid enum data")
                }
                return VMSnapshot(
                    id: id, name: name, description: description, vmID: vmID,
                    projectID: projectID, environment: environment, status: status,
                    size: size, agentId: agentID, qemuVersion: qemuVersion,
                    architecture: architecture, errorMessage: errorMessage,
                    desiredStatus: desiredStatus, generation: generation,
                    observedGeneration: observedGeneration, convergencePhase: convergencePhase,
                    failedGeneration: failedGeneration, convergenceDeadline: convergenceDeadline,
                    finalizers: finalizers, expiresAt: expiresAt, createdByID: createdByID,
                    createdAt: createdAt, updatedAt: updatedAt)
            }
        }
    }

    private static let columns = """
        s.id, s.name, s.description, s.vm_id AS "vmID",
        s.project_id AS "projectID", s.environment, s.status AS "statusRaw",
        s.size, s.agent_id AS "agentID", s.qemu_version AS "qemuVersion",
        s.architecture, s.error_message AS "errorMessage",
        s.desired_status AS "desiredStatusRaw", s.generation,
        s.observed_generation AS "observedGeneration",
        s.convergence_phase AS "convergencePhase",
        s.failed_generation AS "failedGeneration",
        s.convergence_deadline AS "convergenceDeadline", s.finalizers,
        s.expires_at AS "expiresAt", s.created_by_id AS "createdByID",
        s.created_at AS "createdAt", s.updated_at AS "updatedAt"
        """
    private static let returningColumns = columns.replacingOccurrences(of: "s.", with: "")
}

enum LegacySandboxSnapshotStore {
    static func snapshot(id: UUID?, on db: PostgresStoreContext) async throws -> SandboxSnapshot? {
        guard let id else { return nil }
        return try await snapshots(ids: [id], on: db).first
    }

    static func snapshots(
        ids: [UUID]? = nil,
        sandboxID: UUID? = nil,
        projectIDs: [UUID]? = nil,
        agentID: String? = nil,
        overdueAt: Date? = nil,
        expiredAt: Date? = nil,
        terminating: Bool? = nil,
        orderByCreatedDescending: Bool = false,
        on db: PostgresStoreContext
    ) async throws -> [SandboxSnapshot] {
        if ids?.isEmpty == true || projectIDs?.isEmpty == true { return [] }
        var query: PostgresSQLQuery = "SELECT \(unsafeRaw: columns) FROM sandbox_snapshots AS s WHERE TRUE"
        if let ids { query += " AND s.id = ANY(\(bind: ids))" }
        if let sandboxID { query += " AND s.sandbox_id = \(bind: sandboxID)" }
        if let projectIDs { query += " AND s.project_id = ANY(\(bind: projectIDs))" }
        if let agentID { query += " AND s.agent_id = \(bind: agentID)" }
        if let overdueAt { query += " AND s.convergence_deadline <= \(bind: overdueAt)" }
        if let expiredAt {
            query += " AND s.expires_at <= \(bind: expiredAt) AND s.desired_status <> 'Absent'"
        }
        if let terminating {
            query += terminating
                ? " AND s.desired_status = 'Absent'"
                : " AND s.desired_status <> 'Absent'"
        }
        query += orderByCreatedDescending
            ? " ORDER BY s.created_at DESC, s.id DESC"
            : " ORDER BY s.id"
        return try await requireSQL(db).raw(query).all(decoding: Record.self).map { try $0.snapshot }
    }

    @discardableResult
    static func upsert(_ snapshot: SandboxSnapshot, on db: PostgresStoreContext) async throws
        -> SandboxSnapshot
    {
        let id = try snapshot.requireID()
        let artifacts = try snapshot.exportedArtifacts.map {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        }
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO sandbox_snapshots (
                id, name, sandbox_id, project_id, environment, status, size,
                agent_id, storage_path, firecracker_version, architecture,
                guest_control_protocol_version, fork_layout_version,
                cpu_template, source_cpu_model, exported_at, exported_artifacts,
                error_message, desired_status, generation, observed_generation,
                convergence_phase, failed_generation, convergence_deadline,
                finalizers, export_desired, capture_mode, expires_at,
                created_by_id, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: snapshot.name), \(bind: snapshot.sandboxID),
                \(bind: snapshot.projectID), \(bind: snapshot.environment),
                \(bind: snapshot.status.rawValue), \(bind: snapshot.size),
                \(bind: snapshot.agentId), \(bind: snapshot.storagePath),
                \(bind: snapshot.firecrackerVersion), \(bind: snapshot.architecture),
                \(bind: snapshot.guestControlProtocolVersion),
                \(bind: snapshot.forkLayoutVersion), \(bind: snapshot.cpuTemplate),
                \(bind: snapshot.sourceCPUModel), \(bind: snapshot.exportedAt),
                CASE WHEN \(bind: artifacts)::text IS NULL THEN NULL
                     ELSE ARRAY(SELECT value FROM jsonb_array_elements(CAST(\(bind: artifacts) AS jsonb))) END,
                \(bind: snapshot.errorMessage), \(bind: snapshot.desiredStatus.rawValue),
                \(bind: snapshot.generation), \(bind: snapshot.observedGeneration),
                \(bind: snapshot.convergencePhase), \(bind: snapshot.failedGeneration),
                \(bind: snapshot.convergenceDeadline), \(bind: snapshot.finalizers),
                \(bind: snapshot.exportDesired), \(bind: snapshot.captureMode.rawValue),
                \(bind: snapshot.expiresAt), \(bind: snapshot.createdByID),
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            ON CONFLICT (id) DO UPDATE SET
                name = EXCLUDED.name,
                sandbox_id = EXCLUDED.sandbox_id,
                project_id = EXCLUDED.project_id,
                environment = EXCLUDED.environment,
                status = EXCLUDED.status,
                size = EXCLUDED.size,
                agent_id = EXCLUDED.agent_id,
                storage_path = EXCLUDED.storage_path,
                firecracker_version = EXCLUDED.firecracker_version,
                architecture = EXCLUDED.architecture,
                guest_control_protocol_version = EXCLUDED.guest_control_protocol_version,
                fork_layout_version = EXCLUDED.fork_layout_version,
                cpu_template = EXCLUDED.cpu_template,
                source_cpu_model = EXCLUDED.source_cpu_model,
                exported_at = EXCLUDED.exported_at,
                exported_artifacts = EXCLUDED.exported_artifacts,
                error_message = EXCLUDED.error_message,
                desired_status = EXCLUDED.desired_status,
                generation = EXCLUDED.generation,
                observed_generation = EXCLUDED.observed_generation,
                convergence_phase = EXCLUDED.convergence_phase,
                failed_generation = EXCLUDED.failed_generation,
                convergence_deadline = EXCLUDED.convergence_deadline,
                finalizers = EXCLUDED.finalizers,
                export_desired = EXCLUDED.export_desired,
                capture_mode = EXCLUDED.capture_mode,
                expires_at = EXCLUDED.expires_at,
                updated_at = CURRENT_TIMESTAMP
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not persist sandbox snapshot")
        }
        return try row.snapshot
    }

    @discardableResult
    static func delete(id: UUID, on db: PostgresStoreContext) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            "DELETE FROM sandbox_snapshots WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: Deleted.self)?.id
    }

    private struct Record: Decodable {
        let id: UUID
        let name: String
        let sandboxID: UUID
        let projectID: UUID
        let environment: String
        let statusRaw: String
        let size: Int64?
        let agentID: String?
        let storagePath: String?
        let firecrackerVersion: String?
        let architecture: String?
        let guestControlProtocolVersion: Int?
        let forkLayoutVersion: Int?
        let cpuTemplate: String?
        let sourceCPUModel: String?
        let exportedAt: Date?
        let exportedArtifactsJSON: String?
        let errorMessage: String?
        let desiredStatusRaw: String
        let generation: Int64
        let observedGeneration: Int64
        let convergencePhase: String?
        let failedGeneration: Int64?
        let convergenceDeadline: Date?
        let finalizers: [String]
        let exportDesired: Bool
        let captureModeRaw: String
        let expiresAt: Date?
        let createdByID: UUID
        let createdAt: Date?
        let updatedAt: Date?

        var snapshot: SandboxSnapshot {
            get throws {
                guard let status = SandboxSnapshotStatus(rawValue: statusRaw),
                    let desiredStatus = DesiredSnapshotStatus(rawValue: desiredStatusRaw),
                    let captureMode = SandboxSnapshotMode(rawValue: captureModeRaw)
                else {
                    throw Abort(.internalServerError, reason: "Sandbox snapshot has invalid enum data")
                }
                let artifacts = try exportedArtifactsJSON.map {
                    try JSONDecoder().decode(
                        [SandboxSnapshotExportedArtifact].self, from: Data($0.utf8))
                }
                return SandboxSnapshot(
                    id: id, name: name, sandboxID: sandboxID, projectID: projectID,
                    environment: environment, status: status, size: size, agentId: agentID,
                    storagePath: storagePath, firecrackerVersion: firecrackerVersion,
                    architecture: architecture,
                    guestControlProtocolVersion: guestControlProtocolVersion,
                    forkLayoutVersion: forkLayoutVersion, cpuTemplate: cpuTemplate,
                    sourceCPUModel: sourceCPUModel, exportedAt: exportedAt,
                    exportedArtifacts: artifacts, errorMessage: errorMessage,
                    desiredStatus: desiredStatus, generation: generation,
                    observedGeneration: observedGeneration, convergencePhase: convergencePhase,
                    failedGeneration: failedGeneration, convergenceDeadline: convergenceDeadline,
                    finalizers: finalizers, exportDesired: exportDesired,
                    captureMode: captureMode, expiresAt: expiresAt, createdByID: createdByID,
                    createdAt: createdAt, updatedAt: updatedAt)
            }
        }
    }

    private static let columns = """
        s.id, s.name, s.sandbox_id AS "sandboxID", s.project_id AS "projectID",
        s.environment, s.status AS "statusRaw", s.size, s.agent_id AS "agentID",
        s.storage_path AS "storagePath", s.firecracker_version AS "firecrackerVersion",
        s.architecture, s.guest_control_protocol_version AS "guestControlProtocolVersion",
        s.fork_layout_version AS "forkLayoutVersion", s.cpu_template AS "cpuTemplate",
        s.source_cpu_model AS "sourceCPUModel", s.exported_at AS "exportedAt",
        to_json(s.exported_artifacts)::text AS "exportedArtifactsJSON",
        s.error_message AS "errorMessage", s.desired_status AS "desiredStatusRaw",
        s.generation, s.observed_generation AS "observedGeneration",
        s.convergence_phase AS "convergencePhase",
        s.failed_generation AS "failedGeneration",
        s.convergence_deadline AS "convergenceDeadline", s.finalizers,
        s.export_desired AS "exportDesired", s.capture_mode AS "captureModeRaw",
        s.expires_at AS "expiresAt", s.created_by_id AS "createdByID",
        s.created_at AS "createdAt", s.updated_at AS "updatedAt"
        """
    private static let returningColumns = columns.replacingOccurrences(of: "s.", with: "")
}

private func requireSQL(_ db: PostgresStoreContext) throws -> PostgresStoreContext {
    guard let sql = db as? PostgresStoreContext else {
        throw Abort(.internalServerError, reason: "PostgreSQL SQL interface is unavailable")
    }
    return sql
}
