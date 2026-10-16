import AppTestSupport
import Fluent
import Foundation
import NIOCore
import SQLKit
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

@Suite("idle assembly batch snapshots", .serialized, .postgresFixture)
struct SandboxIdleAssemblyTests {
    @Test func boundedQueriesPreserveFenceAndLeaseStates() async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            let builder = TestDataBuilder(db: app.db)
            let organization = try await builder.createOrganization(name: "idle-assembly")
            let project = try await builder.createProject(
                name: "idle-assembly", description: "batch fixture", organization: organization)
            let ids = (0..<513).map { _ in UUID() }
            let sandboxes = ids.enumerated().map { index, id in
                Sandbox(
                    id: id, name: "assembly-\(index)", projectID: project.id!, environment: "default",
                    image: "fixture", cpus: 1, memory: 128 * 1024 * 1024)
            }
            try await sandboxes.create(on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            let instant = ClusterInstant.testing(Date(timeIntervalSince1970: 1_800_000_000))
            let inventory = UUID()
            try await sql.raw(
                """
                INSERT INTO sandbox_idle_fences(sandbox_id, activity_revision, agent_key, inventory_session_id, fence, valid)
                VALUES (\(bind: ids[1]), 77, 'fixture-owner', \(bind: inventory), '"malformed-fence"'::jsonb, true)
                """
            ).run()
            // One clock determines lease eligibility: the boundary is expired,
            // future and indefinite leases are busy, and past leases are idle.
            for (index, deadline) in [
                (0, Optional<Date>.none), (1, Optional(instant.date)),
                (2, Optional(instant.date.addingTimeInterval(1))),
                (3, Optional(instant.date.addingTimeInterval(-1))), (4, Optional<Date>.none),
            ] {
                try await sql.raw(
                    """
                    INSERT INTO sandbox_activity_leases(id, sandbox_id, agent_key, expires_at)
                    VALUES (\(bind: UUID()), \(bind: ids[index]), 'fixture-command', \(bind: deadline))
                    """
                ).run()
            }
            let counted = try CountingIdleAssemblyDatabase(database: app.db)
            #expect(try await SandboxIdleFenceService.assemblyStates(ids: [], at: instant, on: counted).isEmpty)
            #expect(counted.statementCount == 0)
            let first = try await SandboxIdleFenceService.assemblyStates(
                ids: Array(ids.prefix(512)) + [ids[0], ids[1]], at: instant, on: counted)
            #expect(counted.statementCount == 1)
            #expect(first.count == 512)
            #expect(first[ids[0]]?.idle == nil)
            #expect(first[ids[0]]?.hasAdmittedActivity == true)
            #expect(first[ids[1]]?.hasAdmittedActivity == false)
            let idle = try #require(first[ids[1]]?.idle)
            #expect(idle.activity_revision == 77)
            #expect(idle.agent_key == "fixture-owner")
            #expect(idle.inventory_session_id == inventory)
            #expect(idle.valid)
            #expect(idle.fence == "\"malformed-fence\"")
            #expect(idle.decodedFence == nil)
            #expect(first[ids[2]]?.hasAdmittedActivity == true)
            #expect(first[ids[3]]?.hasAdmittedActivity == false)
            #expect(first[ids[4]]?.hasAdmittedActivity == true)
            #expect(first[ids[5]]?.hasAdmittedActivity == false)
            let before = counted.statementCount
            let all = try await SandboxIdleFenceService.assemblyStates(
                ids: ids + [ids[0], ids[512], ids[0]], at: instant, on: counted)
            #expect(counted.statementCount - before == 2)
            #expect(all.count == 513)
            #expect(Set(all.keys) == Set(ids))
            #expect(all[ids[1]]?.idle?.fence == idle.fence)
            #expect(all[ids[1]]?.idle?.activity_revision == idle.activity_revision)
            #expect(all[ids[1]]?.hasAdmittedActivity == false)
            #expect(all[ids[512]]?.hasAdmittedActivity == false)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}

/// Fluent history does not count raw SQL. Intercept both SQL execution APIs
/// while forwarding the database protocols to the actual disposable fixture.
private final class CountingIdleAssemblyDatabase: Database, SQLDatabase, @unchecked Sendable {
    private let database: any Database
    private let sql: any SQLDatabase
    private let lock = NSLock()
    private var statements = 0
    init(database: any Database) throws {
        self.database = database
        guard let sql = database as? any SQLDatabase else { throw ConvergenceWriteError.unsupportedDatabase }
        self.sql = sql
    }
    var statementCount: Int { lock.withLock { statements } }
    private func countStatement() { lock.withLock { statements += 1 } }
    var context: DatabaseContext { database.context }
    var inTransaction: Bool { database.inTransaction }
    var logger: Logger { sql.logger }
    var eventLoop: any EventLoop { sql.eventLoop }
    var dialect: any SQLDialect { sql.dialect }
    var version: (any SQLDatabaseReportedVersion)? { sql.version }
    var queryLogLevel: Logger.Level? { sql.queryLogLevel }
    func execute(query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> Void) -> EventLoopFuture<
        Void
    > {
        database.execute(query: query, onOutput: onOutput)
    }
    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> { database.execute(schema: schema) }
    func execute(enum value: DatabaseEnum) -> EventLoopFuture<Void> { database.execute(enum: value) }
    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        database.transaction(closure)
    }
    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        database.withConnection(closure)
    }
    func execute(sql query: any SQLExpression, _ onRow: @escaping @Sendable (any SQLRow) -> Void) -> EventLoopFuture<
        Void
    > {
        countStatement()
        return sql.execute(sql: query, onRow)
    }
    func execute(sql query: any SQLExpression, _ onRow: @escaping @Sendable (any SQLRow) -> Void) async throws {
        countStatement()
        try await sql.execute(sql: query, onRow)
    }
    func withSession<R>(_ closure: @escaping @Sendable (any SQLDatabase) async throws -> R) async throws -> R {
        try await sql.withSession(closure)
    }
}
