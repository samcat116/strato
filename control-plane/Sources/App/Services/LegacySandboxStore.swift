import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

/// Explicit SQL access for immutable sandbox snapshots while surrounding
/// multi-resource transactions still expose Fluent's transaction handle.
enum LegacySandboxStore {
    static func sandbox(id: UUID?, on db: any Database) async throws -> Sandbox? {
        guard let id else { return nil }
        return try await sandboxes(ids: [id], on: db).first
    }

    static func sandboxes(
        ids: [UUID]? = nil,
        projectID: UUID? = nil,
        projectIDs: [UUID]? = nil,
        environment: String? = nil,
        hypervisorID: String? = nil,
        hypervisorIDs: [String]? = nil,
        desiredStatus: DesiredSandboxStatus? = nil,
        overdueAt: Date? = nil,
        terminatingBefore: Date? = nil,
        restoredFromSnapshotID: UUID? = nil,
        restoredFromSnapshotIDs: [UUID]? = nil,
        on db: any Database
    ) async throws -> [Sandbox] {
        if ids?.isEmpty == true || projectIDs?.isEmpty == true || hypervisorIDs?.isEmpty == true
            || restoredFromSnapshotIDs?.isEmpty == true
        {
            return []
        }
        var query: SQLQueryString = "SELECT \(unsafeRaw: columns) FROM sandboxes AS s WHERE TRUE"
        if let ids { query += " AND s.id = ANY(\(bind: ids))" }
        if let projectID { query += " AND s.project_id = \(bind: projectID)" }
        if let projectIDs { query += " AND s.project_id = ANY(\(bind: projectIDs))" }
        if let environment { query += " AND s.environment = \(bind: environment)" }
        if let hypervisorID { query += " AND s.hypervisor_id = \(bind: hypervisorID)" }
        if let hypervisorIDs { query += " AND s.hypervisor_id = ANY(\(bind: hypervisorIDs))" }
        if let desiredStatus { query += " AND s.desired_status = \(bind: desiredStatus.rawValue)" }
        if let overdueAt { query += " AND s.convergence_deadline <= \(bind: overdueAt)" }
        if let terminatingBefore {
            query += " AND s.desired_status = 'Absent' AND COALESCE(s.updated_at, s.created_at) <= \(bind: terminatingBefore)"
        }
        if let restoredFromSnapshotID {
            query += " AND s.restored_from_snapshot_id = \(bind: restoredFromSnapshotID)"
        }
        if let restoredFromSnapshotIDs {
            query += " AND s.restored_from_snapshot_id = ANY(\(bind: restoredFromSnapshotIDs))"
        }
        query += " ORDER BY s.id"
        return try await sandboxSQL(db).raw(query).all(decoding: Record.self).map { try $0.sandbox }
    }

    @discardableResult
    static func upsert(_ sandbox: Sandbox, on db: any Database) async throws -> Sandbox {
        let id = try sandbox.requireID()
        let envJSON = String(decoding: try JSONEncoder().encode(sandbox.env), as: UTF8.self)
        guard let row = try await sandboxSQL(db).raw(
            """
            INSERT INTO sandboxes (
                id, name, project_id, environment, image, image_digest, vcpus, memory,
                entrypoint, cmd, env, working_dir, ttl_seconds, hypervisor_id,
                restored_from_snapshot_id, cpu_template, status, status_changed_at,
                exit_code, desired_status, generation, observed_generation,
                restore_generation, restore_snapshot_id, convergence_phase, last_error,
                failed_generation, last_error_at, divergence_detected_at,
                convergence_deadline, finalizers, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: sandbox.name), \(bind: sandbox.projectID),
                \(bind: sandbox.environment), \(bind: sandbox.image),
                \(bind: sandbox.imageDigest), \(bind: sandbox.cpus), \(bind: sandbox.memory),
                \(bind: sandbox.entrypoint), \(bind: sandbox.cmd), CAST(\(bind: envJSON) AS jsonb),
                \(bind: sandbox.workingDir), \(bind: sandbox.ttlSeconds),
                \(bind: sandbox.hypervisorId), \(bind: sandbox.restoredFromSnapshotId),
                \(bind: sandbox.cpuTemplate), \(bind: sandbox.status.rawValue),
                \(bind: sandbox.statusChangedAt), \(bind: sandbox.exitCode),
                \(bind: sandbox.desiredStatus.rawValue), \(bind: sandbox.generation),
                \(bind: sandbox.observedGeneration), \(bind: sandbox.restoreGeneration),
                \(bind: sandbox.restoreSnapshotID), \(bind: sandbox.convergencePhase),
                \(bind: sandbox.lastError), \(bind: sandbox.failedGeneration),
                \(bind: sandbox.lastErrorAt), \(bind: sandbox.divergenceDetectedAt),
                \(bind: sandbox.convergenceDeadline), \(bind: sandbox.finalizers),
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            ON CONFLICT (id) DO UPDATE SET
                name = EXCLUDED.name, project_id = EXCLUDED.project_id,
                environment = EXCLUDED.environment, image = EXCLUDED.image,
                image_digest = EXCLUDED.image_digest, vcpus = EXCLUDED.vcpus,
                memory = EXCLUDED.memory, entrypoint = EXCLUDED.entrypoint,
                cmd = EXCLUDED.cmd, env = EXCLUDED.env,
                working_dir = EXCLUDED.working_dir, ttl_seconds = EXCLUDED.ttl_seconds,
                hypervisor_id = EXCLUDED.hypervisor_id,
                restored_from_snapshot_id = EXCLUDED.restored_from_snapshot_id,
                cpu_template = EXCLUDED.cpu_template, status = EXCLUDED.status,
                status_changed_at = EXCLUDED.status_changed_at, exit_code = EXCLUDED.exit_code,
                desired_status = EXCLUDED.desired_status, generation = EXCLUDED.generation,
                observed_generation = EXCLUDED.observed_generation,
                restore_generation = EXCLUDED.restore_generation,
                restore_snapshot_id = EXCLUDED.restore_snapshot_id,
                convergence_phase = EXCLUDED.convergence_phase,
                last_error = EXCLUDED.last_error, failed_generation = EXCLUDED.failed_generation,
                last_error_at = EXCLUDED.last_error_at,
                divergence_detected_at = EXCLUDED.divergence_detected_at,
                convergence_deadline = EXCLUDED.convergence_deadline,
                finalizers = EXCLUDED.finalizers, updated_at = CURRENT_TIMESTAMP
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not persist sandbox")
        }
        return try row.sandbox
    }

    static func updateImageDigest(id: UUID, digest: String, on db: any Database) async throws {
        try await sandboxSQL(db).raw(
            "UPDATE sandboxes SET image_digest = \(bind: digest), updated_at = CURRENT_TIMESTAMP WHERE id = \(bind: id)"
        ).run()
    }

    @discardableResult
    static func delete(id: UUID, on db: any Database) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await sandboxSQL(db).raw(
            "DELETE FROM sandboxes WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: Deleted.self)?.id
    }

    private struct Record: Decodable {
        let id: UUID
        let name: String
        let projectID: UUID
        let environment: String
        let image: String
        let imageDigest: String?
        let cpus: Int
        let memory: Int64
        let entrypoint: [String]?
        let cmd: [String]?
        let envJSON: String
        let workingDir: String?
        let ttlSeconds: Int?
        let hypervisorId: String?
        let restoredFromSnapshotId: UUID?
        let cpuTemplate: String?
        let statusRaw: String
        let statusChangedAt: Date?
        let exitCode: Int?
        let desiredStatusRaw: String
        let generation: Int64
        let observedGeneration: Int64
        let restoreGeneration: Int64
        let restoreSnapshotID: UUID?
        let convergencePhase: String?
        let lastError: String?
        let failedGeneration: Int64?
        let lastErrorAt: Date?
        let divergenceDetectedAt: Date?
        let convergenceDeadline: Date?
        let finalizers: [String]
        let createdAt: Date?
        let updatedAt: Date?

        var sandbox: Sandbox {
            get throws {
                guard let status = SandboxStatus(rawValue: statusRaw),
                    let desiredStatus = DesiredSandboxStatus(rawValue: desiredStatusRaw)
                else { throw Abort(.internalServerError, reason: "Sandbox has invalid enum data") }
                let env = try JSONDecoder().decode([String: String].self, from: Data(envJSON.utf8))
                return Sandbox(
                    id: id, name: name, projectID: projectID, environment: environment,
                    image: image, cpus: cpus, memory: memory, entrypoint: entrypoint,
                    cmd: cmd, env: env, workingDir: workingDir, ttlSeconds: ttlSeconds,
                    restoredFromSnapshotId: restoredFromSnapshotId, cpuTemplate: cpuTemplate,
                    imageDigest: imageDigest, hypervisorId: hypervisorId, status: status,
                    statusChangedAt: statusChangedAt, exitCode: exitCode,
                    desiredStatus: desiredStatus, generation: generation,
                    observedGeneration: observedGeneration, restoreGeneration: restoreGeneration,
                    restoreSnapshotID: restoreSnapshotID, convergencePhase: convergencePhase,
                    lastError: lastError, failedGeneration: failedGeneration,
                    lastErrorAt: lastErrorAt, divergenceDetectedAt: divergenceDetectedAt,
                    convergenceDeadline: convergenceDeadline, finalizers: finalizers,
                    createdAt: createdAt, updatedAt: updatedAt)
            }
        }
    }

    private static let columns = """
        s.id, s.name, s.project_id AS "projectID", s.environment, s.image,
        s.image_digest AS "imageDigest", s.vcpus AS cpus, s.memory, s.entrypoint,
        s.cmd, s.env::text AS "envJSON", s.working_dir AS "workingDir",
        s.ttl_seconds AS "ttlSeconds", s.hypervisor_id AS "hypervisorId",
        s.restored_from_snapshot_id AS "restoredFromSnapshotId",
        s.cpu_template AS "cpuTemplate", s.status AS "statusRaw",
        s.status_changed_at AS "statusChangedAt", s.exit_code AS "exitCode",
        s.desired_status AS "desiredStatusRaw", s.generation,
        s.observed_generation AS "observedGeneration",
        s.restore_generation AS "restoreGeneration",
        s.restore_snapshot_id AS "restoreSnapshotID",
        s.convergence_phase AS "convergencePhase", s.last_error AS "lastError",
        s.failed_generation AS "failedGeneration", s.last_error_at AS "lastErrorAt",
        s.divergence_detected_at AS "divergenceDetectedAt",
        s.convergence_deadline AS "convergenceDeadline", s.finalizers,
        s.created_at AS "createdAt", s.updated_at AS "updatedAt"
        """
    private static let returningColumns = columns.replacingOccurrences(of: "s.", with: "")
}

private func sandboxSQL(_ db: any Database) throws -> any SQLDatabase {
    guard let sql = db as? any SQLDatabase else {
        throw Abort(.internalServerError, reason: "PostgreSQL SQL interface is unavailable")
    }
    return sql
}
