import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

struct LiveVMExecSession: Content, Sendable {
    let sessionId: UUID
    let userId: UUID
    let username: String?
    let attachedAt: Date
    let lastActivityAt: Date
    let terminationRequested: Bool
}

/// PostgreSQL owns admission and presence across replicas. Socket state remains
/// local to the replica holding the agent; short leases bound crash staleness.
enum VMExecSessionLimits {
    static let leaseSeconds = 60
    static let renewalBatchSize = 256

    struct Renewal: Sendable {
        let id: UUID
        let vmID: UUID
        let userID: UUID
        let lastActivity: Date
    }

    private struct Count: Decodable { let count: Int }
    private struct ID: Decodable { let id: UUID }

    /// Called inside the same transaction that accepts a recorded command.
    /// The project lock serializes the rolling rate window on every replica.
    static func admitRun(projectID: UUID, vmID: UUID, on db: any Database) async throws {
        let sql = try sql(db)
        try await lockProjectBudget(projectID: projectID, on: db)
        // Fleet confirmation catches admission refusals inside an outer transaction.
        // Fluent does not provide nested savepoints, so refuse a full VM before charging.
        try await admitVM(vmID: vmID, on: db)
        let admitted = try await sql.raw(
            """
            UPDATE vm_run_rate_limits
            SET accepted_at = ARRAY(SELECT t FROM unnest(accepted_at) t WHERE t > clock_timestamp() - interval '60 seconds') || clock_timestamp()
            WHERE project_id = \(bind: projectID)
              AND (SELECT count(*) FROM unnest(accepted_at) t WHERE t > clock_timestamp() - interval '60 seconds') < \(bind: GuestExecLimits.runsPerProjectPerMinute)
            RETURNING project_id AS id
            """
        ).all(decoding: ID.self)
        guard !admitted.isEmpty else {
            throw Abort(.tooManyRequests, reason: "Project command rate limit reached; retry after 60 seconds")
        }
    }

    /// Fleet acceptance holds all project budgets in a stable order before VM locks.
    /// Sorting prevents overlapping cross-project fleets from deadlocking each other.
    static func lockProjectBudgets(projectIDs: [UUID], on db: any Database) async throws {
        for projectID in Set(projectIDs).sorted(by: { $0.uuidString < $1.uuidString }) {
            try await lockProjectBudget(projectID: projectID, on: db)
        }
    }

    private static func lockProjectBudget(projectID: UUID, on db: any Database) async throws {
        let sql = try sql(db)
        try await sql.raw(
            "INSERT INTO vm_run_rate_limits (project_id) VALUES (\(bind: projectID)) ON CONFLICT DO NOTHING"
        ).run()
        _ = try await sql.raw(
            "SELECT project_id FROM vm_run_rate_limits WHERE project_id = \(bind: projectID) FOR UPDATE"
        ).all()
    }

    private static func admitVM(vmID: UUID, on db: any Database) async throws {
        let sql = try sql(db)
        let vm = try await sql.raw("SELECT id FROM vms WHERE id = \(bind: vmID) FOR UPDATE").all(decoding: ID.self)
        guard !vm.isEmpty else { throw Abort(.notFound) }
        let result = try await sql.raw(
            """
            SELECT (
                (SELECT count(*) FROM vm_exec_sessions WHERE vm_id = \(bind: vmID) AND expires_at > clock_timestamp()) +
                (SELECT count(*) FROM vm_command_executions WHERE vm_id = \(bind: vmID) AND status = 'pending')
            )::int AS count
            """
        ).first(decoding: Count.self)
        guard let result, result.count < GuestExecLimits.maxSessionsPerVM else {
            throw Abort(.tooManyRequests, reason: "VM concurrent exec session limit reached")
        }
    }

    static func reserve(id: UUID, vmID: UUID, userID: UUID, username: String?, on db: any Database) async throws {
        try await db.transaction { db in
            try await admitVM(vmID: vmID, on: db)
            try await sql(db).raw(
                """
                INSERT INTO vm_exec_sessions (id, vm_id, user_id, username, last_activity_at, expires_at)
                VALUES (\(bind: id), \(bind: vmID), \(bind: userID), \(bind: username), clock_timestamp(), clock_timestamp() + interval '60 seconds')
                """
            ).run()
        }
    }

    static func attach(id: UUID, on db: any Database) async throws {
        let rows = try await sql(db).raw(
            """
            UPDATE vm_exec_sessions SET attached_at = clock_timestamp(), last_activity_at = clock_timestamp(), expires_at = clock_timestamp() + interval '60 seconds'
            WHERE id = \(bind: id) AND attached_at IS NULL AND expires_at > clock_timestamp() AND NOT termination_requested
            RETURNING id
            """
        ).all(decoding: ID.self)
        guard !rows.isEmpty else { throw Abort(.gone, reason: "Exec session reservation expired") }
    }

    static func list(vmID: UUID, on db: any Database) async throws -> [LiveVMExecSession] {
        try await sql(db).raw(
            """
            SELECT id AS "sessionId", user_id AS "userId", username, attached_at AS "attachedAt",
                   last_activity_at AS "lastActivityAt", termination_requested AS "terminationRequested"
            FROM vm_exec_sessions
            WHERE vm_id = \(bind: vmID) AND attached_at IS NOT NULL AND expires_at > clock_timestamp()
            ORDER BY attached_at, id LIMIT \(bind: GuestExecLimits.maxSessionsPerVM)
            """
        ).all(decoding: LiveVMExecSession.self)
    }

    static func requestTermination(id: UUID, vmID: UUID, on db: any Database) async throws {
        let rows = try await sql(db).raw(
            """
            UPDATE vm_exec_sessions SET termination_requested = true
            WHERE id = \(bind: id) AND vm_id = \(bind: vmID) AND attached_at IS NOT NULL AND expires_at > clock_timestamp()
            RETURNING id
            """
        ).all(decoding: ID.self)
        guard !rows.isEmpty else { throw Abort(.notFound) }
    }

    static func remove(id: UUID, on db: any Database) async throws {
        try await sql(db).raw("DELETE FROM vm_exec_sessions WHERE id = \(bind: id)").run()
    }

    /// Bounded statements renew the socket owner's live, attached leases without
    /// a database round trip per socket. Missing, expired, terminated, or changed
    /// ownership rows are returned as losses; renewal never recreates a lease.
    static func renew(_ leases: [Renewal], on sql: any SQLDatabase) async throws -> Set<UUID> {
        var renewed: Set<UUID> = []
        for start in stride(from: 0, to: leases.count, by: renewalBatchSize) {
            let batch = leases[start..<min(start + renewalBatchSize, leases.count)]
            let values = SQLList(
                batch.map { lease -> SQLQueryString in
                    "(\(bind: lease.id)::uuid, \(bind: lease.vmID)::uuid, \(bind: lease.userID)::uuid, \(bind: lease.lastActivity)::timestamptz)"
                })
            let rows = try await sql.raw(
                """
                UPDATE vm_exec_sessions AS live
                SET expires_at = clock_timestamp() + interval '60 seconds',
                    last_activity_at = GREATEST(live.last_activity_at, owned.last_activity_at)
                FROM (VALUES \(values)) AS owned(id, vm_id, user_id, last_activity_at)
                WHERE live.id = owned.id AND live.vm_id = owned.vm_id AND live.user_id = owned.user_id
                  AND live.attached_at IS NOT NULL AND live.expires_at > clock_timestamp()
                  AND NOT live.termination_requested
                RETURNING live.id
                """
            ).all(decoding: ID.self)
            renewed.formUnion(rows.map(\.id))
        }
        return renewed
    }

    static func prune(on db: any Database) async throws {
        try await sql(db).raw("DELETE FROM vm_exec_sessions WHERE expires_at <= clock_timestamp()").run()
    }

    private static func sql(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        return sql
    }
}
