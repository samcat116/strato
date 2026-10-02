import Fluent
import SQLKit
import StratoShared
import Vapor

/// Durable user activity admission. All writes serialize with lifecycle and
/// expiry through the sandbox row lock. A nil lease deadline is an active or
/// interrupted stream, not proof of idle; only terminal evidence releases it.
enum SandboxActivityService {
    static func touch(_ sandbox: Sandbox, at instant: ClusterInstant) {
        sandbox.lastActiveAt = max(sandbox.lastActiveAt ?? sandbox.createdAt ?? instant.date, instant.date)
    }

    static func touch(id: UUID, on db: any Database) async throws {
        try await db.transaction { db in
            let sandbox = try await locked(id: id, on: db)
            guard sandbox.desiredStatus != .absent else { throw Abort(.conflict, reason: "Sandbox is being deleted") }
            try await SandboxIdleFenceService.cancelForUserActivity(sandbox, on: db)
            touch(sandbox, at: try await ClusterClock.read(on: db))
            try await sandbox.save(on: db)
        }
    }

    static func admitLogQuery(id: UUID, queryID: UUID, on db: any Database) async throws {
        try await db.transaction { db in
            let sandbox = try await locked(id: id, on: db)
            guard sandbox.desiredStatus != .absent else { throw Abort(.conflict, reason: "Sandbox is being deleted") }
            try await SandboxIdleFenceService.cancelForUserActivity(sandbox, on: db)
            guard let sql = db as? any SQLDatabase else { throw ConvergenceWriteError.unsupportedDatabase }
            try await sql.raw(
                """
                INSERT INTO sandbox_activity_leases (id, sandbox_id, agent_key, expires_at)
                VALUES (\(bind: queryID), \(bind: id), 'control-plane-log-query', NULL)
                """
            ).run()
            touch(sandbox, at: try await ClusterClock.read(on: db))
            try await sandbox.save(on: db)
        }
    }

    static func admitPending(id: UUID, sessionID: UUID, agentID: UUID, agentKey: String, on db: any Database)
        async throws -> Date
    {
        try await db.transaction { db in
            let sandbox = try await locked(id: id, on: db)
            guard sandbox.hypervisorId.flatMap(UUID.init(uuidString:)) == agentID,
                sandbox.status == .running, sandbox.desiredStatus == .running,
                sandbox.generation == sandbox.observedGeneration,
                sandbox.failedGeneration != sandbox.generation
            else {
                throw Abort(.conflict, reason: "Sandbox is not ready for command admission; retry after convergence")
            }
            let now = try await ClusterClock.read(on: db)
            let deadline = now.date.addingTimeInterval(GuestExecSessionManager.pendingSessionTTL)
            guard let sql = db as? any SQLDatabase else { throw ConvergenceWriteError.unsupportedDatabase }
            try await sql.raw(
                """
                INSERT INTO sandbox_activity_leases (id, sandbox_id, agent_key, expires_at)
                VALUES (\(bind: sessionID), \(bind: id), \(bind: agentKey), \(bind: deadline))
                """
            ).run()
            try await SandboxIdleFenceService.recordAdmissionActivity(id: id, on: db)
            touch(sandbox, at: now)
            try await sandbox.save(on: db)
            return now.date
        }
    }

    static func activate(id: UUID, sessionID: UUID, on db: any Database) async throws {
        try await db.transaction { db in
            let sandbox = try await locked(id: id, on: db)
            guard sandbox.desiredStatus == .running, sandbox.status == .running,
                sandbox.generation == sandbox.observedGeneration,
                sandbox.failedGeneration != sandbox.generation
            else {
                throw Abort(.conflict, reason: "Sandbox cannot accept a stream while changing state")
            }
            let now = try await ClusterClock.read(on: db)
            guard let sql = db as? any SQLDatabase else { throw ConvergenceWriteError.unsupportedDatabase }
            struct Row: Decodable { let id: UUID }
            let changed = try await sql.raw(
                """
                UPDATE sandbox_activity_leases SET expires_at = NULL
                WHERE id = \(bind: sessionID) AND sandbox_id = \(bind: id) AND expires_at > \(bind: now.date)
                RETURNING id
                """
            ).all(decoding: Row.self)
            guard !changed.isEmpty else { throw Abort(.conflict, reason: "Command admission expired or was consumed") }
            try await SandboxIdleFenceService.recordAdmissionActivity(id: id, on: db)
            touch(sandbox, at: now)
            try await sandbox.save(on: db)
        }
    }

    static func startedFromAgent(sessionID: UUID, agentKey: String, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { throw ConvergenceWriteError.unsupportedDatabase }
        struct Lease: Decodable { let sandbox_id: UUID }
        guard
            let lease = try await sql.raw(
                """
                SELECT sandbox_id FROM sandbox_activity_leases WHERE id = \(bind: sessionID)
                    AND agent_key = \(bind: agentKey) AND expires_at IS NULL AND guest_started_at IS NULL
                """
            ).first(decoding: Lease.self)
        else { return }
        try await db.transaction { db in
            let sandbox = try await locked(id: lease.sandbox_id, on: db)
            guard let sql = db as? any SQLDatabase else { throw ConvergenceWriteError.unsupportedDatabase }
            struct Changed: Decodable { let id: UUID }
            let now = try await ClusterClock.read(on: db)
            let changed = try await sql.raw(
                """
                UPDATE sandbox_activity_leases SET guest_started_at = \(bind: now.date)
                WHERE id = \(bind: sessionID) AND agent_key = \(bind: agentKey)
                    AND expires_at IS NULL AND guest_started_at IS NULL RETURNING id
                """
            ).all(decoding: Changed.self)
            guard !changed.isEmpty else { return }
            try await SandboxIdleFenceService.recordAdmissionActivity(id: lease.sandbox_id, on: db)
            touch(sandbox, at: now)
            try await sandbox.save(on: db)
        }
    }

    static func endFromAgent(sessionID: UUID, agentKey: String, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { throw ConvergenceWriteError.unsupportedDatabase }
        struct Row: Decodable { let sandbox_id: UUID }
        guard
            let lease = try await sql.raw(
                "SELECT sandbox_id FROM sandbox_activity_leases WHERE id = \(bind: sessionID) AND agent_key = \(bind: agentKey)"
            ).first(decoding: Row.self)
        else { return }
        try await end(id: lease.sandbox_id, sessionID: sessionID, on: db)
    }

    static func end(id: UUID, sessionID: UUID, on db: any Database) async throws {
        try await db.transaction { db in
            guard let sandbox = try await Sandbox.find(id, on: db), try await sandbox.lockAndRefresh(on: db) else {
                return
            }
            guard let sql = db as? any SQLDatabase else { throw ConvergenceWriteError.unsupportedDatabase }
            struct Row: Decodable { let id: UUID }
            let removed = try await sql.raw(
                """
                DELETE FROM sandbox_activity_leases WHERE id = \(bind: sessionID) AND sandbox_id = \(bind: id)
                RETURNING id
                """
            ).all(decoding: Row.self)
            // Repeated terminal delivery must not keep an idle sandbox alive.
            guard !removed.isEmpty else { return }
            try await SandboxIdleFenceService.recordAdmissionActivity(id: id, on: db)
            touch(sandbox, at: try await ClusterClock.read(on: db))
            try await sandbox.save(on: db)
        }
    }

    /// Call while holding the sandbox row lock, at the destructive boundary.
    static func hasAdmittedActivity(id: UUID, at instant: ClusterInstant, on db: any Database) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else { throw ConvergenceWriteError.unsupportedDatabase }
        struct Row: Decodable { let id: UUID }
        return try await !sql.raw(
            """
            SELECT id FROM sandbox_activity_leases WHERE sandbox_id = \(bind: id)
            AND (expires_at IS NULL OR expires_at > \(bind: instant.date)) LIMIT 1
            """
        ).all(decoding: Row.self).isEmpty
    }

    static func locked(id: UUID, on db: any Database) async throws -> Sandbox {
        guard let sandbox = try await Sandbox.find(id, on: db), try await sandbox.lockAndRefresh(on: db) else {
            throw Abort(.notFound, reason: "Sandbox no longer exists")
        }
        return sandbox
    }
}
