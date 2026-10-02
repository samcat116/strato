import AppTestSupport
import Fluent
import Foundation
import NIOCore
import SQLKit
import StratoShared
import Synchronization
import Testing
import Vapor
@testable import App

private final class RenewalSQLProbe: SQLDatabase, Sendable {
    let base: any SQLDatabase
    let bindCounts = Mutex<[Int]>([])
    init(_ base: any SQLDatabase) { self.base = base }
    var logger: Logger { base.logger }
    var eventLoop: any EventLoop { base.eventLoop }
    var dialect: any SQLDialect { base.dialect }
    func execute(
        sql query: any SQLExpression, _ onRow: @escaping @Sendable (any SQLRow) -> Void
    ) -> EventLoopFuture<Void> {
        bindCounts.withLock { $0.append(base.serialize(query).binds.count) }
        return base.execute(sql: query, onRow)
    }
}

private actor RenewalLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@Suite("Guest exec lease renewal", .serialized, .postgresFixture, .timeLimit(.minutes(1)))
struct GuestExecSessionRenewalTests {
    private func seed(
        count: Int, on sql: any SQLDatabase, now: Date = Date()
    ) async throws -> [VMExecSessionLimits.Renewal] {
        let leases = (0..<count).map { _ in
            VMExecSessionLimits.Renewal(id: UUID(), vmID: UUID(), userID: UUID(), lastActivity: now)
        }
        let values = SQLList(
            leases.map { lease -> SQLQueryString in
                "(\(bind: lease.id)::uuid, \(bind: lease.vmID)::uuid, \(bind: lease.userID)::uuid, \(bind: now)::timestamptz, clock_timestamp(), clock_timestamp() + interval '30 seconds')"
            })
        try await sql.raw(
            "INSERT INTO vm_exec_sessions (id, vm_id, user_id, last_activity_at, attached_at, expires_at) VALUES \(values)"
        ).run()
        return leases
    }

    private func attach(
        _ lease: VMExecSessionLimits.Renewal, to manager: GuestExecSessionManager,
        now: Date = Date(), lowercaseID: Bool = false
    ) throws -> String {
        let sessionID = lowercaseID ? lease.id.uuidString.lowercased() : lease.id.uuidString
        _ = manager.createPendingSession(
            sessionId: sessionID, resourceKind: .virtualMachine, resourceId: lease.vmID.uuidString,
            agentKey: "renewal-fixture", userId: lease.userID.uuidString, command: ["/bin/sh"], env: nil,
            workingDir: nil, tty: false, rows: nil, cols: nil, now: now)
        _ = try manager.attachSession(
            sessionId: sessionID, resourceKind: .virtualMachine, resourceId: lease.vmID.uuidString,
            userId: lease.userID.uuidString, websocket: nil, now: now)
        return sessionID
    }

    @Test("Thousands of socket leases use bounded statements and retain newer activity")
    func boundedStatements() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            let leases = try await seed(count: 4097, on: sql)
            let probe = RenewalSQLProbe(sql)
            #expect(try await VMExecSessionLimits.renew([], on: probe).isEmpty)
            #expect(probe.bindCounts.withLock { $0.isEmpty })
            let newerActivity = Date().addingTimeInterval(5)
            try await sql.raw(
                "UPDATE vm_exec_sessions SET last_activity_at = \(bind: newerActivity) WHERE id = \(bind: leases[0].id)"
            ).run()
            #expect(try await VMExecSessionLimits.renew(leases, on: probe) == Set(leases.map(\.id)))
            let counts = probe.bindCounts.withLock { $0 }
            #expect(counts.count == 17)
            #expect(counts.allSatisfy { $0 <= VMExecSessionLimits.renewalBatchSize * 4 })
            struct State: Decodable { let activity: Date; let seconds: Double }
            let state = try #require(
                try await sql.raw(
                    "SELECT last_activity_at AS activity, extract(epoch FROM expires_at - clock_timestamp())::float8 AS seconds FROM vm_exec_sessions WHERE id = \(bind: leases[0].id)"
                ).first(decoding: State.self))
            #expect(abs(state.activity.timeIntervalSince(newerActivity)) < 0.001)
            #expect(state.seconds > 50)
        }
    }

    @Test("Partial lease loss terminates only affected sockets and never revives authority")
    func partialLoss() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            let now = Date()
            let leases = try await seed(count: 521, on: sql, now: now)
            let manager = app.guestExecSessionManager
            let reasons = Mutex<[String: String]>([:])
            for (index, lease) in leases.enumerated() {
                let id = try attach(
                    lease, to: manager,
                    now: index == 6 ? now.addingTimeInterval(-Double(GuestExecLimits.idleTimeoutSeconds)) : now,
                    lowercaseID: index == 0 || index == 8)
                manager.setTerminationHandler(sessionId: id) { reason in reasons.withLock { $0[id] = reason } }
            }
            try await VMExecSessionLimits.remove(id: leases[0].id, on: app.db)
            try await sql.raw(
                "UPDATE vm_exec_sessions SET expires_at = clock_timestamp() - interval '1 second' WHERE id = \(bind: leases[1].id)"
            ).run()
            try await sql.raw(
                "UPDATE vm_exec_sessions SET termination_requested = true WHERE id = \(bind: leases[2].id)"
            ).run()
            try await sql.raw("UPDATE vm_exec_sessions SET attached_at = NULL WHERE id = \(bind: leases[3].id)").run()
            try await sql.raw("UPDATE vm_exec_sessions SET vm_id = \(bind: UUID()) WHERE id = \(bind: leases[4].id)")
                .run()
            try await sql.raw("UPDATE vm_exec_sessions SET user_id = \(bind: UUID()) WHERE id = \(bind: leases[5].id)")
                .run()
            manager.requestTermination(sessionId: leases[7].id.uuidString, reason: "operator")
            struct State: Decodable { let id: UUID; let expires: Date }
            let before = try await sql.raw("SELECT id, expires_at AS expires FROM vm_exec_sessions").all(
                decoding: State.self)
            await manager.maintainSessions(now: now)
            await manager.maintainSessions(now: now)
            let recorded = reasons.withLock { $0 }
            #expect(recorded.count == 8)
            for (index, lease) in leases.prefix(6).enumerated() {
                let id = index == 0 ? lease.id.uuidString.lowercased() : lease.id.uuidString
                #expect(recorded[id] == "Exec session terminated or presence lease expired")
            }
            #expect(recorded[leases[6].id.uuidString] == "Exec session idle timeout")
            #expect(recorded[leases[7].id.uuidString] == "operator")
            let after = try await sql.raw("SELECT id, expires_at AS expires FROM vm_exec_sessions").all(
                decoding: State.self)
            let previous = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.expires) })
            let losses = Set(leases.prefix(8).map(\.id))
            #expect(after.count == leases.count - 1)
            for state in after {
                let previousExpiry = try #require(previous[state.id])
                if losses.contains(state.id) {
                    #expect(state.expires == previousExpiry)
                } else {
                    #expect(state.expires > previousExpiry)
                }
            }
            #expect(manager.getSession(sessionId: leases[8].id.uuidString.lowercased()) != nil)
        }
    }

    @Test("Database renewal failure requests serialized termination for every affected socket")
    func renewalFailure() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            let leases = try await seed(count: 257, on: sql)
            let manager = app.guestExecSessionManager
            let reasons = Mutex<[String]>([])
            for lease in leases {
                let id = try attach(lease, to: manager)
                manager.setTerminationHandler(sessionId: id) { reason in reasons.withLock { $0.append(reason) } }
            }
            // Only this test's disposable clone is modified.
            try await sql.raw("DROP TABLE vm_exec_sessions").run()
            await manager.maintainSessions()
            await manager.maintainSessions()
            #expect(reasons.withLock { $0.count } == leases.count)
            #expect(reasons.withLock { $0.allSatisfy { $0 == "Exec session presence unavailable" } })
        }
    }

    @Test("Renewal continues while the general maintenance actor is blocked on a database row")
    func delayedMaintenance() async throws {
        let app = try await Application.makeForTesting(maxConnectionsPerEventLoop: 4)
        let release = RenewalLatch()
        let locked = RenewalLatch()
        let loop = GuestExecSessionMaintenanceLoop(app: app, interval: .milliseconds(10))
        var holder: Task<Void, any Error>?
        var sweep: Task<Void, any Error>?
        do {
            try await configure(app)
            let sql = try #require(app.db as? any SQLDatabase)
            let leases = try await seed(count: 1, on: sql)
            _ = try attach(leases[0], to: app.guestExecSessionManager)
            let builder = TestDataBuilder(db: app.db)
            let organization = try await builder.createOrganization(name: "Renewal Org")
            let agent = try await builder.createAgent(
                named: "renewal-stale-agent", status: .online, lastHeartbeat: Date().addingTimeInterval(-120),
                organizationScope: .organization(try organization.requireID()))
            let agentID = try agent.requireID()
            holder = Task {
                try await app.db.transaction { db in
                    let sql = try #require(db as? any SQLDatabase)
                    _ = try await sql.raw("SELECT id FROM agents WHERE id = \(bind: agentID) FOR UPDATE").all()
                    await locked.open()
                    await release.wait()
                }
            }
            await locked.wait()
            sweep = Task { try await app.agentMaintenance.runTick(number: 1) }
            struct Count: Decodable { let count: Int }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var blocked = false
            repeat {
                blocked =
                    try await sql.raw(
                        "SELECT count(*)::int AS count FROM pg_stat_activity WHERE datname = current_database() AND wait_event = 'transactionid'"
                    ).first(decoding: Count.self)?.count ?? 0 > 0
                if !blocked { try await Task.sleep(for: .milliseconds(10)) }
            } while !blocked && ContinuousClock.now < deadline
            #expect(blocked)
            // A renewal at the start of the old general-maintenance pass must
            // not satisfy this assertion: require another renewal after it stalls.
            try await sql.raw(
                "UPDATE vm_exec_sessions SET expires_at = clock_timestamp() + interval '30 seconds' WHERE id = \(bind: leases[0].id)"
            ).run()
            await loop.start()
            struct Remaining: Decodable { let seconds: Double }
            var renewed = false
            repeat {
                renewed =
                    try await sql.raw(
                        "SELECT extract(epoch FROM expires_at - clock_timestamp())::float8 AS seconds FROM vm_exec_sessions WHERE id = \(bind: leases[0].id)"
                    ).first(decoding: Remaining.self)?.seconds ?? 0 > 50
                if !renewed { try await Task.sleep(for: .milliseconds(10)) }
            } while !renewed && ContinuousClock.now < deadline
            #expect(renewed)
            #expect(try await Agent.find(agentID, on: app.db)?.status == .online)
        } catch {
            await release.open()
            try? await holder?.value
            try? await sweep?.value
            await loop.shutdown()
            try await app.shutdownForTesting()
            throw error
        }
        await release.open()
        try await holder?.value
        try await sweep?.value
        await loop.shutdown()
        try await app.shutdownForTesting()
    }
}
