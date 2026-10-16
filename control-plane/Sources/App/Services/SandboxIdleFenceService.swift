import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

/// All operations run under the sandbox row lock. Evidence only nominates;
/// destruction requires a still-owned, non-expired durable admission token.
enum SandboxIdleFenceService {
    struct State: Decodable {
        let activity_revision: Int64
        let agent_key: String
        let inventory_session_id: UUID?
        let report: String?
        let received_at: Date?
        let fence: String?
        let valid: Bool
        let expires_at: Date?
        var decodedReport: SandboxIdleActivityReport? {
            report.flatMap {
                try? WireProtocol.makeDecoder().decode(SandboxIdleActivityReport.self, from: Data($0.utf8))
            }
        }
        var decodedFence: SandboxAutomaticSuspensionFence? {
            fence.flatMap {
                try? WireProtocol.makeDecoder().decode(SandboxAutomaticSuspensionFence.self, from: Data($0.utf8))
            }
        }
    }
    static func state(id: UUID, on db: any Database) async throws -> State? {
        guard let sql = db as? any SQLDatabase else { throw ConvergenceWriteError.unsupportedDatabase }
        return try await sql.raw(
            """
            SELECT activity_revision, agent_key, inventory_session_id, report::text AS report, received_at,
                fence::text AS fence, valid, expires_at FROM sandbox_idle_fences WHERE sandbox_id = \(bind: id)
            """
        ).first(decoding: State.self)
    }
    struct AssemblyState {
        let idle: State?
        let hasAdmittedActivity: Bool
    }

    /// One statement per bounded ID chunk keeps fence and lease evidence in
    /// the same database snapshot; the caller supplies one clock for the sync.
    /// Desired state never needs the potentially large full idle reports.
    static func assemblyStates(ids: [UUID], at instant: ClusterInstant, on db: any Database) async throws
        -> [UUID: AssemblyState]
    {
        guard !ids.isEmpty else { return [:] }
        guard let sql = db as? any SQLDatabase else { throw ConvergenceWriteError.unsupportedDatabase }
        struct Row: Decodable {
            let id: UUID
            let idle: State?
            let busy: Bool
            enum CodingKeys: String, CodingKey { case sandbox_id, activity_revision, busy }
            init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decode(UUID.self, forKey: .sandbox_id)
                busy = try values.decode(Bool.self, forKey: .busy)
                idle =
                    try values.decodeIfPresent(Int64.self, forKey: .activity_revision) == nil
                    ? nil : State(from: decoder)
            }
        }
        var result: [UUID: AssemblyState] = [:]
        let uniqueIDs = Array(Set(ids))
        for start in stride(from: 0, to: uniqueIDs.count, by: 512) {
            let page = Array(uniqueIDs[start..<min(start + 512, uniqueIDs.count)])
            let rows = try await sql.raw(
                """
                SELECT s.id AS sandbox_id, f.activity_revision, f.agent_key, f.inventory_session_id,
                    NULL::text AS report, f.received_at, f.fence::text AS fence, f.valid, f.expires_at,
                    EXISTS (SELECT 1 FROM sandbox_activity_leases l WHERE l.sandbox_id = s.id
                        AND (l.expires_at IS NULL OR l.expires_at > \(bind: instant.date))) AS busy
                FROM sandboxes s LEFT JOIN sandbox_idle_fences f ON f.sandbox_id = s.id
                WHERE s.id IN (\(binds: page))
                """
            ).all(decoding: Row.self)
            for row in rows {
                result[row.id] = AssemblyState(idle: row.idle, hasAdmittedActivity: row.busy)
            }
        }
        return result
    }

    static func observe(
        _ report: SandboxIdleActivityReport?, sandbox: Sandbox, at now: ClusterInstant, on db: any Database
    ) async throws {
        guard let sql = db as? any SQLDatabase, let owner = sandbox.hypervisorId, let ownerID = UUID(uuidString: owner)
        else { return }
        let id = try sandbox.requireID()
        let inventory = try? await InventorySessionFence.current(agentID: ownerID, on: db)
        let previous = try await state(id: id, on: db)
        // A prepared operation deliberately stops sampling during capture. Nil
        // is not quiet evidence and cannot nominate; the already-closed CP
        // admission remains owned until expiry/user activity invalidates it.
        if report == nil, previous?.inventory_session_id == inventory, previous?.valid == true,
            previous?.decodedFence?.generation == sandbox.generation,
            sandbox.desiredStatus == .suspended
        {
            return
        }
        if previous?.inventory_session_id == inventory, let report, let old = previous?.decodedReport,
            report.agentIncarnation == old.agentIncarnation && report.connectionEpoch == old.connectionEpoch
                && report.residencyEpoch == old.residencyEpoch && !report.isNewer(than: old)
        {
            return
        }
        // Reconcile interrupted guest exec leases only from two ordered,
        // current-owner v5 proofs of no guest sessions/anonymous work or local
        // handshakes. CP log-query leases and pending admissions are excluded.
        if let report, let old = previous?.decodedReport, inventory != nil,
            previous?.inventory_session_id == inventory, report.isNewer(than: old),
            report.generation == sandbox.generation,
            report.controlPlaneActivityRevision == previous?.activity_revision,
            old.controlPlaneActivityRevision == previous?.activity_revision,
            report.evidenceAgeMilliseconds <= 30_000,
            report.idleFenceSupported, let guest = report.guest, let oldGuest = old.guest,
            guest.hasCompleteQuiescentCoverage, oldGuest.hasCompleteQuiescentCoverage,
            guest.monitorIncarnation == oldGuest.monitorIncarnation,
            guest.sampleSequence > oldGuest.sampleSequence,
            report.activeExecSessionIds?.isEmpty == true, report.hostPendingCommandCount == 0,
            report.snapshotOrRestoreInProgress == false,
            let agent = try await Agent.find(ownerID, on: db), !agent.administrativelyOffline
        {
            struct Released: Decodable { let id: UUID }
            let ended = try await sql.raw(
                """
                DELETE FROM sandbox_activity_leases WHERE sandbox_id = \(bind: id)
                    AND agent_key = \(bind: agent.identity.key) AND expires_at IS NULL
                    AND guest_started_at IS NOT NULL RETURNING id
                """
            ).all(decoding: Released.self)
            if !ended.isEmpty {
                SandboxActivityService.touch(sandbox, at: now)
                try await sandbox.save(on: db)
            }
        }
        // Identity resets and missing coverage invalidate all previously issued
        // claims. A new incarnation must accumulate its own residency window.
        let unchanged =
            inventory != nil && previous?.inventory_session_id == inventory
            && report?.idleFenceSupported == true && report?.guest?.hasCompleteQuiescentCoverage == true
            && report?.activeExecSessionIds?.isEmpty == true && report?.hostPendingCommandCount == 0
            && report?.snapshotOrRestoreInProgress == false && report?.generation == sandbox.generation
            && previous?.decodedReport.map { old in
                report?.isNewer(than: old) == true && old.guest?.monitorIncarnation == report?.guest?.monitorIncarnation
                    && old.guest?.activityEpoch == report?.guest?.activityEpoch
                    && old.activityEpoch == report?.activityEpoch
            } == true
        let measured = report?.guest.map { $0.isBounded && $0.coverage == .complete && $0.trusted } == true
        let userWork =
            report?.activeExecSessionIds.map { !$0.isEmpty } == true
            || report?.hostPendingCommandCount.map { $0 > 0 } == true
        if !unchanged, measured || userWork, sandbox.status == .running || sandbox.status == .starting {
            SandboxActivityService.touch(sandbox, at: now)
            try await sandbox.save(on: db)
        }
        let encoded = try report.map { String(decoding: try WireProtocol.makeEncoder().encode($0), as: UTF8.self) }
        try await sql.raw(
            """
            INSERT INTO sandbox_idle_fences (sandbox_id, agent_key, inventory_session_id, report, received_at)
            VALUES (\(bind: id), \(bind: owner), \(bind: inventory), \(bind: encoded)::jsonb, \(bind: now.date))
            ON CONFLICT (sandbox_id) DO UPDATE SET agent_key = EXCLUDED.agent_key,
                inventory_session_id = EXCLUDED.inventory_session_id,
                report = EXCLUDED.report, received_at = EXCLUDED.received_at,
                activity_revision = sandbox_idle_fences.activity_revision + \(bind: unchanged ? 0 : 1),
                valid = sandbox_idle_fences.valid AND \(bind: unchanged)
            """
        ).run()
    }
    /// Event ordering must advance even when PostgreSQL wall time is equal or
    /// moves backward; monotonic timestamps alone cannot fence dispatch races.
    static func recordAdmissionActivity(id: UUID, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { throw ConvergenceWriteError.unsupportedDatabase }
        try await sql.raw(
            """
            UPDATE sandbox_idle_fences SET activity_revision = activity_revision + 1,
                valid = false WHERE sandbox_id = \(bind: id)
            """
        ).run()
    }

    /// Metadata/log/snapshot activity cancels only automatic intent. Explicit
    /// user suspension and deletion retain their existing lifecycle meaning.
    static func cancelForUserActivity(_ sandbox: Sandbox, on db: any Database) async throws {
        let id = try sandbox.requireID()
        try await recordAdmissionActivity(id: id, on: db)
        guard sandbox.desiredStatus == .suspended,
            let state = try await state(id: id, on: db),
            state.decodedFence?.generation == sandbox.generation
        else { return }
        let generation = sandbox.generation
        try await SandboxSuspensionService.admitWake(sandbox, on: db)
        sandbox.setDesiredStatus(.running)
        guard case .applied = try await sandbox.advanceDesiredStateGeneration(expectedGeneration: generation, on: db)
        else {
            throw Abort(.conflict, reason: "Automatic suspension cancellation was superseded")
        }
        sandbox.extendConvergenceDeadline(
            by: OperationResourceKind.sandbox.completionBudgetSeconds(for: .boot),
            from: try await ClusterClock.read(on: db))
        var scope = try await ResourceEvent.scope(of: .sandbox, id: id, on: db)
        scope.generation = sandbox.generation
        _ = try await ResourceEvent.record(
            .boot, resourceKind: .sandbox, resourceID: id,
            actor: .system, scope: scope, on: db)
    }

    static func finalizePendingAdmission(_ sandbox: Sandbox, on db: any Database) async throws {
        let id = try sandbox.requireID()
        guard let sql = db as? any SQLDatabase, let state = try await state(id: id, on: db),
            !state.valid, let fence = state.decodedFence, fence.generation == sandbox.generation,
            fence.activityRevision == state.activity_revision, sandbox.desiredStatus == .suspended,
            let report = state.decodedReport, report.isCompleteQuiet,
            report.generation == fence.generation - 1
        else { return }
        try await sql.raw("UPDATE sandbox_idle_fences SET valid = true WHERE sandbox_id = \(bind: id)").run()
    }
    struct CandidatePage {
        let sandboxes: [Sandbox]
        /// Advances over every coarse candidate, including rejected reports.
        let nextCursor: UUID?
    }

    static let maximumCandidatePageSize = 64

    /// Selection is only a bounded optimization. nominate still rechecks all
    /// evidence under the sandbox lock with a freshly read cluster clock.
    static func nominationCandidates(
        after cursor: UUID?, limit: Int = maximumCandidatePageSize,
        at now: ClusterInstant, on db: any Database
    ) async throws -> CandidatePage {
        guard now.permitsDestructiveSweeps else { return CandidatePage(sandboxes: [], nextCursor: nil) }
        guard let sql = db as? any SQLDatabase else { throw ConvergenceWriteError.unsupportedDatabase }
        let pageSize = max(1, min(limit, maximumCandidatePageSize))
        struct Row: Decodable {
            let id: UUID
            let report: String
            let last_active_at: Date?
            let created_at: Date?
        }
        let rows = try await sql.raw(
            """
            SELECT s.id, f.report::text AS report, s.last_active_at, s.created_at
            FROM sandbox_idle_fences f JOIN sandboxes s ON s.id = f.sandbox_id
            JOIN agents a ON a.id::text = lower(s.hypervisor_id)
            WHERE s.status = \(bind: SandboxStatus.running.rawValue)
                AND s.desired_status = \(bind: DesiredSandboxStatus.running.rawValue)
                AND s.observed_generation = s.generation AND s.failed_generation IS DISTINCT FROM s.generation
                AND s.generation < 9223372036854775807 AND f.activity_revision < 9223372036854775807
                AND f.agent_key = s.hypervisor_id AND NOT a.administratively_offline
                AND f.inventory_session_id IS NOT NULL AND f.inventory_session_id = a.inventory_session_id
                AND f.received_at <= \(bind: now.date)
                AND f.received_at >= \(bind: now.date.addingTimeInterval(-30))
                AND f.report ->> 'generation' = s.generation::text
                AND f.report ->> 'controlPlaneActivityRevision' = f.activity_revision::text
                AND f.report ->> 'idleFenceSupported' = 'true'
                AND f.report -> 'policy' ->> 'enabled' = 'true'
                AND f.report -> 'activeExecSessionIds' = '[]'::jsonb
                AND f.report ->> 'pendingCommandCount' = '0'
                AND f.report ->> 'hostPendingCommandCount' = '0'
                AND f.report ->> 'snapshotOrRestoreInProgress' = 'false'
                AND f.report -> 'guest' ->> 'coverage' = 'complete'
                AND f.report -> 'guest' ->> 'trusted' = 'true'
                AND f.report -> 'guest' ->> 'nic_count' = '0'
                AND NOT EXISTS (SELECT 1 FROM sandbox_network_interfaces n WHERE n.sandbox_id = s.id)
                AND NOT EXISTS (SELECT 1 FROM sandbox_activity_leases l WHERE l.sandbox_id = s.id
                    AND (l.expires_at IS NULL OR l.expires_at > \(bind: now.date)))
                AND (\(bind: cursor)::uuid IS NULL OR s.id > \(bind: cursor)::uuid)
            ORDER BY s.id LIMIT \(bind: pageSize)
            """
        ).all(decoding: Row.self)
        let ids = rows.compactMap { row -> UUID? in
            guard
                let report = try? WireProtocol.makeDecoder().decode(
                    SandboxIdleActivityReport.self, from: Data(row.report.utf8)), report.isCompleteQuiet,
                let policy = report.policy, policy.enabled, !policy.excludedSandboxIDs.contains(row.id),
                policy.idleSeconds.isFinite, policy.idleSeconds > 0,
                policy.minimumResidencySeconds.isFinite, policy.minimumResidencySeconds > 0,
                let quiet = report.hostQuietMilliseconds,
                Double(quiet) / 1000 >= policy.idleSeconds,
                now.date.timeIntervalSince(row.last_active_at ?? row.created_at ?? now.date)
                    >= policy.idleSeconds,
                Double(report.residentForMilliseconds) / 1000 >= policy.minimumResidencySeconds
            else { return nil }
            return row.id
        }
        let sandboxes = ids.isEmpty ? [] : try await Sandbox.query(on: db).filter(\.$id ~~ ids).all()
        return CandidatePage(
            sandboxes: sandboxes, nextCursor: rows.count == pageSize ? rows.last?.id : nil)
    }

    static func nominate(
        _ sandbox: Sandbox, app: Application, at now: ClusterInstant, mutation: ResourceMutation? = nil
    ) async throws {
        // Independent global switch; root agent opt-in is also required.
        guard now.permitsDestructiveSweeps, app.controlPlaneConfiguration.bool(.sandboxIdleSuspendEnabled) else {
            return
        }
        let id = try sandbox.requireID()
        _ = try await (mutation ?? app.resourceMutation).accept(
            .shutdown, on: sandbox, actor: .system,
            dispatch: .stateSync, on: app.db, app: app
        ) { db in
            let current = try await ClusterClock.read(on: db)
            guard sandbox.status == .running, sandbox.desiredStatus == .running,
                sandbox.isConverged, sandbox.generation < Int64.max,
                try await SandboxNetworkInterface.query(on: db).filter(\.$sandbox.$id == id).count() == 0,
                let state = try await state(id: id, on: db), state.activity_revision < Int64.max,
                let report = state.decodedReport,
                state.agent_key == sandbox.hypervisorId, state.inventory_session_id != nil,
                let ownerID = UUID(uuidString: state.agent_key),
                let owner = try await Agent.find(ownerID, on: db), !owner.administrativelyOffline,
                state.inventory_session_id == (try await InventorySessionFence.current(agentID: ownerID, on: db)),
                report.generation == sandbox.generation, report.controlPlaneActivityRevision == state.activity_revision,
                report.isCompleteQuiet, let received = state.received_at,
                received <= current.date, current.date.timeIntervalSince(received) <= 30,
                let policy = report.policy, policy.enabled, !policy.excludedSandboxIDs.contains(id),
                policy.idleSeconds.isFinite, policy.idleSeconds > 0,
                policy.minimumResidencySeconds.isFinite, policy.minimumResidencySeconds > 0,
                let quiet = report.hostQuietMilliseconds,
                Double(quiet) / 1000 >= policy.idleSeconds,
                current.date.timeIntervalSince(sandbox.lastActiveAt ?? sandbox.createdAt ?? current.date)
                    >= policy.idleSeconds,
                Double(report.residentForMilliseconds) / 1000 >= policy.minimumResidencySeconds,
                !(try await SandboxActivityService.hasAdmittedActivity(id: id, at: current, on: db))
            else { throw Abort(.conflict, reason: "Sandbox idle eligibility changed") }
            try await SandboxSuspensionService.admitSuspension(sandbox, on: db)
            sandbox.setDesiredStatus(.suspended)
            let fence = SandboxAutomaticSuspensionFence(
                operationId: UUID(), generation: sandbox.generation + 1,
                activityRevision: state.activity_revision + 1, admissionToken: UUID(), guestProtocolVersion: 5)
            let encoded = String(decoding: try WireProtocol.makeEncoder().encode(fence), as: UTF8.self)
            guard let sql = db as? any SQLDatabase else { throw ConvergenceWriteError.unsupportedDatabase }
            try await sql.raw(
                """
                UPDATE sandbox_idle_fences SET fence = \(bind: encoded)::jsonb,
                    valid = false, expires_at = \(bind: current.date.addingTimeInterval(1200))
                WHERE sandbox_id = \(bind: id)
                """
            ).run()
        }
    }

    static func validate(id: UUID, owner: String, fence: SandboxAutomaticSuspensionFence, on db: any Database)
        async throws
    {
        try await db.transaction { db in
            let sandbox = try await SandboxActivityService.locked(id: id, on: db)
            let now = try await ClusterClock.read(on: db)
            guard fence.isValid, sandbox.hypervisorId == owner, sandbox.desiredStatus == .suspended,
                sandbox.generation == fence.generation,
                let state = try await state(id: id, on: db), state.agent_key == owner,
                state.valid, state.decodedFence == fence, state.activity_revision == fence.activityRevision,
                let session = state.inventory_session_id, let ownerID = UUID(uuidString: owner),
                let agent = try await Agent.find(ownerID, on: db), !agent.administrativelyOffline,
                session == (try await InventorySessionFence.current(agentID: ownerID, on: db)),
                state.expires_at.map({ $0 > now.date }) == true,
                !(try await SandboxActivityService.hasAdmittedActivity(id: id, at: now, on: db))
            else { throw Abort(.conflict, reason: "Automatic suspension admission is no longer owned") }
        }
    }
}
