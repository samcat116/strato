import ControlPlanePostgres
import Foundation
import StratoShared
import Vapor

/// Explicit SQL access for VM value snapshots while surrounding transactions
/// still expose Fluent's database handle.
enum LegacyVMStore {
    static func vm(id: UUID?, on db: PostgresStoreContext) async throws -> VM? {
        guard let id else { return nil }
        return try await vms(ids: [id], on: db).first
    }

    static func vms(
        ids: [UUID]? = nil,
        name: String? = nil,
        projectID: UUID? = nil,
        projectIDs: [UUID]? = nil,
        environment: String? = nil,
        hypervisorID: String? = nil,
        hypervisorIDs: [String]? = nil,
        desiredStatus: DesiredVMStatus? = nil,
        overdueAt: Date? = nil,
        terminatingBefore: Date? = nil,
        on db: PostgresStoreContext
    ) async throws -> [VM] {
        if ids?.isEmpty == true || projectIDs?.isEmpty == true || hypervisorIDs?.isEmpty == true {
            return []
        }
        var query: PostgresSQLQuery = "SELECT \(unsafeRaw: columns) FROM vms AS v WHERE TRUE"
        if let ids { query += " AND v.id = ANY(\(bind: ids))" }
        if let name { query += " AND v.name = \(bind: name)" }
        if let projectID { query += " AND v.project_id = \(bind: projectID)" }
        if let projectIDs { query += " AND v.project_id = ANY(\(bind: projectIDs))" }
        if let environment { query += " AND v.environment = \(bind: environment)" }
        if let hypervisorID { query += " AND v.hypervisor_id = \(bind: hypervisorID)" }
        if let hypervisorIDs { query += " AND v.hypervisor_id = ANY(\(bind: hypervisorIDs))" }
        if let desiredStatus { query += " AND v.desired_status = \(bind: desiredStatus.rawValue)" }
        if let overdueAt { query += " AND v.convergence_deadline <= \(bind: overdueAt)" }
        if let terminatingBefore {
            query += " AND v.desired_status = 'Absent' AND COALESCE(v.updated_at, v.created_at) <= \(bind: terminatingBefore)"
        }
        query += " ORDER BY v.id"
        return try await vmSQL(db).raw(query).all(decoding: Record.self).map { try $0.vm }
    }

    @discardableResult
    static func upsert(_ vm: VM, on db: PostgresStoreContext) async throws -> VM {
        let id = try vm.requireID()
        let tagsJSON = String(decoding: try JSONEncoder().encode(vm.tags), as: UTF8.self)
        guard let row = try await vmSQL(db).raw(
            """
            INSERT INTO vms (
                id, name, description, image, status, hypervisor_id, status_changed_at,
                desired_status, generation, observed_generation, reboot_generation,
                restore_generation, restore_snapshot_id, convergence_phase, last_error,
                failed_generation, last_error_at, divergence_detected_at,
                convergence_deadline, finalizers, hostname, metadata_enabled,
                metadata_source, metadata_seed_token, qga_available, observed_hostname,
                guest_memory_total_bytes, guest_memory_available_bytes,
                guest_memory_stats_at, guest_memory_balloon_actual_bytes, balloon_target,
                hypervisor_type, project_id, environment, tags, image_id, cpu, max_cpu,
                memory, max_memory, hugepages, shared_memory, disk, kernel_path,
                initramfs_path, cmdline, ssh_public_key, ssh_authorized_keys,
                user_data, firmware_path, secure_boot, tpm_enabled, guest_agent_enabled,
                graphics_console, console_mode, serial_mode, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: vm.name), \(bind: vm.description), \(bind: vm.image),
                \(bind: vm.status.rawValue), \(bind: vm.hypervisorId),
                \(bind: vm.statusChangedAt), \(bind: vm.desiredStatus.rawValue),
                \(bind: vm.generation), \(bind: vm.observedGeneration),
                \(bind: vm.rebootGeneration), \(bind: vm.restoreGeneration),
                \(bind: vm.restoreSnapshotID), \(bind: vm.convergencePhase),
                \(bind: vm.lastError), \(bind: vm.failedGeneration),
                \(bind: vm.lastErrorAt), \(bind: vm.divergenceDetectedAt),
                \(bind: vm.convergenceDeadline), \(bind: vm.finalizers), \(bind: vm.hostname),
                \(bind: vm.metadataEnabled), \(bind: vm.metadataSource.rawValue),
                \(bind: vm.metadataSeedToken), \(bind: vm.qgaAvailable),
                \(bind: vm.observedHostname), \(bind: vm.guestMemoryTotalBytes),
                \(bind: vm.guestMemoryAvailableBytes), \(bind: vm.guestMemoryStatsAt),
                \(bind: vm.guestMemoryBalloonActualBytes), \(bind: vm.balloonTarget),
                \(bind: vm.hypervisorType.rawValue), \(bind: vm.projectID),
                \(bind: vm.environment), CAST(\(bind: tagsJSON) AS jsonb),
                \(bind: vm.sourceImageID), \(bind: vm.cpu), \(bind: vm.maxCpu),
                \(bind: vm.memory), \(bind: vm.maxMemory), \(bind: vm.hugepages),
                \(bind: vm.sharedMemory), \(bind: vm.disk), \(bind: vm.kernelPath),
                \(bind: vm.initramfsPath), \(bind: vm.cmdline), \(bind: vm.sshPublicKey),
                \(bind: vm.sshAuthorizedKeys), \(bind: vm.userData), \(bind: vm.firmwarePath),
                \(bind: vm.secureBoot), \(bind: vm.tpmEnabled), \(bind: vm.guestAgentEnabled),
                \(bind: vm.graphicsConsole), \(bind: vm.consoleMode.rawValue),
                \(bind: vm.serialMode.rawValue), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            ON CONFLICT (id) DO UPDATE SET
                name = EXCLUDED.name, description = EXCLUDED.description, image = EXCLUDED.image,
                status = EXCLUDED.status, hypervisor_id = EXCLUDED.hypervisor_id,
                status_changed_at = EXCLUDED.status_changed_at,
                desired_status = EXCLUDED.desired_status, generation = EXCLUDED.generation,
                observed_generation = EXCLUDED.observed_generation,
                reboot_generation = EXCLUDED.reboot_generation,
                restore_generation = EXCLUDED.restore_generation,
                restore_snapshot_id = EXCLUDED.restore_snapshot_id,
                convergence_phase = EXCLUDED.convergence_phase,
                last_error = EXCLUDED.last_error, failed_generation = EXCLUDED.failed_generation,
                last_error_at = EXCLUDED.last_error_at,
                divergence_detected_at = EXCLUDED.divergence_detected_at,
                convergence_deadline = EXCLUDED.convergence_deadline,
                finalizers = EXCLUDED.finalizers, hostname = EXCLUDED.hostname,
                metadata_enabled = EXCLUDED.metadata_enabled,
                metadata_source = EXCLUDED.metadata_source,
                metadata_seed_token = EXCLUDED.metadata_seed_token,
                qga_available = EXCLUDED.qga_available,
                observed_hostname = EXCLUDED.observed_hostname,
                guest_memory_total_bytes = EXCLUDED.guest_memory_total_bytes,
                guest_memory_available_bytes = EXCLUDED.guest_memory_available_bytes,
                guest_memory_stats_at = EXCLUDED.guest_memory_stats_at,
                guest_memory_balloon_actual_bytes = EXCLUDED.guest_memory_balloon_actual_bytes,
                balloon_target = EXCLUDED.balloon_target,
                hypervisor_type = EXCLUDED.hypervisor_type, project_id = EXCLUDED.project_id,
                environment = EXCLUDED.environment, tags = EXCLUDED.tags,
                image_id = EXCLUDED.image_id, cpu = EXCLUDED.cpu, max_cpu = EXCLUDED.max_cpu,
                memory = EXCLUDED.memory, max_memory = EXCLUDED.max_memory,
                hugepages = EXCLUDED.hugepages, shared_memory = EXCLUDED.shared_memory,
                disk = EXCLUDED.disk, kernel_path = EXCLUDED.kernel_path,
                initramfs_path = EXCLUDED.initramfs_path, cmdline = EXCLUDED.cmdline,
                ssh_public_key = EXCLUDED.ssh_public_key,
                ssh_authorized_keys = EXCLUDED.ssh_authorized_keys,
                user_data = EXCLUDED.user_data, firmware_path = EXCLUDED.firmware_path,
                secure_boot = EXCLUDED.secure_boot, tpm_enabled = EXCLUDED.tpm_enabled,
                guest_agent_enabled = EXCLUDED.guest_agent_enabled,
                graphics_console = EXCLUDED.graphics_console,
                console_mode = EXCLUDED.console_mode, serial_mode = EXCLUDED.serial_mode,
                updated_at = CURRENT_TIMESTAMP
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not persist VM")
        }
        return try row.vm
    }

    @discardableResult
    static func delete(id: UUID, on db: PostgresStoreContext) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await vmSQL(db).raw(
            "DELETE FROM vms WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: Deleted.self)?.id
    }

    private struct Record: Decodable {
        let id: UUID
        let name: String
        let description: String
        let image: String
        let statusRaw: String
        let hypervisorId: String?
        let statusChangedAt: Date?
        let desiredStatusRaw: String
        let generation: Int64
        let observedGeneration: Int64
        let rebootGeneration: Int64
        let restoreGeneration: Int64
        let restoreSnapshotID: UUID?
        let convergencePhase: String?
        let lastError: String?
        let failedGeneration: Int64?
        let lastErrorAt: Date?
        let divergenceDetectedAt: Date?
        let convergenceDeadline: Date?
        let finalizers: [String]
        let hostname: String?
        let metadataEnabled: Bool
        let metadataSourceRaw: String
        let metadataSeedToken: UUID
        let qgaAvailable: Bool?
        let observedHostname: String?
        let guestMemoryTotalBytes: Int64?
        let guestMemoryAvailableBytes: Int64?
        let guestMemoryStatsAt: Date?
        let guestMemoryBalloonActualBytes: Int64?
        let balloonTarget: Int64?
        let hypervisorTypeRaw: String
        let projectID: UUID
        let environment: String
        let tagsJSON: String
        let sourceImageID: UUID?
        let cpu: Int
        let maxCpu: Int
        let memory: Int64
        let maxMemory: Int64
        let hugepages: Bool
        let sharedMemory: Bool
        let disk: Int64
        let kernelPath: String?
        let initramfsPath: String?
        let cmdline: String?
        let sshPublicKey: String?
        let sshAuthorizedKeys: [String]
        let userData: String?
        let firmwarePath: String?
        let secureBoot: Bool
        let tpmEnabled: Bool
        let guestAgentEnabled: Bool
        let graphicsConsole: Bool
        let consoleModeRaw: String
        let serialModeRaw: String
        let createdAt: Date?
        let updatedAt: Date?

        var vm: VM {
            get throws {
                guard let status = VMStatus(rawValue: statusRaw),
                    let desiredStatus = DesiredVMStatus(rawValue: desiredStatusRaw),
                    let hypervisorType = HypervisorType(rawValue: hypervisorTypeRaw),
                    let metadataSource = MetadataSource(rawValue: metadataSourceRaw),
                    let consoleMode = ConsoleMode(rawValue: consoleModeRaw),
                    let serialMode = ConsoleMode(rawValue: serialModeRaw)
                else { throw Abort(.internalServerError, reason: "VM has invalid enum data") }
                let tags = try JSONDecoder().decode([String: String].self, from: Data(tagsJSON.utf8))
                return VM(
                    id: id, name: name, description: description, image: image,
                    projectID: projectID, environment: environment, cpu: cpu,
                    memory: memory, disk: disk, status: status,
                    hypervisorType: hypervisorType, maxCpu: maxCpu, maxMemory: maxMemory,
                    hugepages: hugepages, sharedMemory: sharedMemory,
                    consoleMode: consoleMode, serialMode: serialMode,
                    secureBoot: secureBoot, tpmEnabled: tpmEnabled,
                    guestAgentEnabled: guestAgentEnabled, graphicsConsole: graphicsConsole,
                    metadataEnabled: metadataEnabled, metadataSource: metadataSource,
                    metadataSeedToken: metadataSeedToken, hypervisorId: hypervisorId,
                    statusChangedAt: statusChangedAt, desiredStatus: desiredStatus,
                    generation: generation, observedGeneration: observedGeneration,
                    rebootGeneration: rebootGeneration, restoreGeneration: restoreGeneration,
                    restoreSnapshotID: restoreSnapshotID, convergencePhase: convergencePhase,
                    lastError: lastError, failedGeneration: failedGeneration,
                    lastErrorAt: lastErrorAt, divergenceDetectedAt: divergenceDetectedAt,
                    convergenceDeadline: convergenceDeadline, finalizers: finalizers,
                    hostname: hostname, qgaAvailable: qgaAvailable,
                    observedHostname: observedHostname,
                    guestMemoryTotalBytes: guestMemoryTotalBytes,
                    guestMemoryAvailableBytes: guestMemoryAvailableBytes,
                    guestMemoryStatsAt: guestMemoryStatsAt,
                    guestMemoryBalloonActualBytes: guestMemoryBalloonActualBytes,
                    balloonTarget: balloonTarget, tags: tags, sourceImageID: sourceImageID,
                    kernelPath: kernelPath, initramfsPath: initramfsPath, cmdline: cmdline,
                    sshPublicKey: sshPublicKey, sshAuthorizedKeys: sshAuthorizedKeys,
                    userData: userData, firmwarePath: firmwarePath,
                    createdAt: createdAt, updatedAt: updatedAt)
            }
        }
    }

    private static let columns = """
        v.id, v.name, v.description, v.image, v.status AS "statusRaw",
        v.hypervisor_id AS "hypervisorId", v.status_changed_at AS "statusChangedAt",
        v.desired_status AS "desiredStatusRaw", v.generation,
        v.observed_generation AS "observedGeneration",
        v.reboot_generation AS "rebootGeneration", v.restore_generation AS "restoreGeneration",
        v.restore_snapshot_id AS "restoreSnapshotID",
        v.convergence_phase AS "convergencePhase", v.last_error AS "lastError",
        v.failed_generation AS "failedGeneration", v.last_error_at AS "lastErrorAt",
        v.divergence_detected_at AS "divergenceDetectedAt",
        v.convergence_deadline AS "convergenceDeadline", v.finalizers, v.hostname,
        v.metadata_enabled AS "metadataEnabled", v.metadata_source AS "metadataSourceRaw",
        v.metadata_seed_token AS "metadataSeedToken", v.qga_available AS "qgaAvailable",
        v.observed_hostname AS "observedHostname",
        v.guest_memory_total_bytes AS "guestMemoryTotalBytes",
        v.guest_memory_available_bytes AS "guestMemoryAvailableBytes",
        v.guest_memory_stats_at AS "guestMemoryStatsAt",
        v.guest_memory_balloon_actual_bytes AS "guestMemoryBalloonActualBytes",
        v.balloon_target AS "balloonTarget", v.hypervisor_type AS "hypervisorTypeRaw",
        v.project_id AS "projectID", v.environment, v.tags::text AS "tagsJSON",
        v.image_id AS "sourceImageID", v.cpu, v.max_cpu AS "maxCpu", v.memory,
        v.max_memory AS "maxMemory", v.hugepages, v.shared_memory AS "sharedMemory",
        v.disk, v.kernel_path AS "kernelPath", v.initramfs_path AS "initramfsPath",
        v.cmdline, v.ssh_public_key AS "sshPublicKey",
        v.ssh_authorized_keys AS "sshAuthorizedKeys", v.user_data AS "userData",
        v.firmware_path AS "firmwarePath", v.secure_boot AS "secureBoot",
        v.tpm_enabled AS "tpmEnabled", v.guest_agent_enabled AS "guestAgentEnabled",
        v.graphics_console AS "graphicsConsole", v.console_mode AS "consoleModeRaw",
        v.serial_mode AS "serialModeRaw", v.created_at AS "createdAt",
        v.updated_at AS "updatedAt"
        """
    private static let returningColumns = columns.replacingOccurrences(of: "v.", with: "")
}

private func vmSQL(_ db: PostgresStoreContext) throws -> PostgresStoreContext {
    guard let sql = db as? PostgresStoreContext else {
        throw Abort(.internalServerError, reason: "PostgreSQL SQL interface is unavailable")
    }
    return sql
}
