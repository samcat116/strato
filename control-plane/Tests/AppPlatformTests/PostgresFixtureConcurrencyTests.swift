import AppTestSupport
import Foundation
import NIOCore
import PostgresNIO
import SQLKit
import Testing
import Vapor

@testable import App

private actor FixtureSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor FixtureApplicationHolder {
    var app: Application?
    var database: String?
    func store(_ app: Application) {
        self.app = app
        database = app.storage[TestDatabaseNameKey.self]
    }
}

@Suite("PostgreSQL fixture admission")
struct PostgresFixtureConcurrencyTests {
    @Test("waiting cancellation and throwing owners return permits")
    func cancellationAndFailure() async throws {
        let gate = PostgresFixtureConcurrency(limit: 1)
        let entered = FixtureSignal()
        let release = FixtureSignal()
        let owner = Task {
            try await gate.withPermit {
                await entered.signal()
                await release.wait()
            }
        }
        await entered.wait()
        let waiting = Task { try await gate.withPermit { Issue.record("cancelled waiter ran") } }
        for _ in 0..<10_000 {
            if gate.waitingCount == 1 { break }
            await Task.yield()
        }
        #expect(gate.waitingCount == 1)
        waiting.cancel()
        do {
            try await waiting.value
            Issue.record("cancelled waiter succeeded")
        } catch is CancellationError {}
        await release.signal()
        try await owner.value
        struct ExpectedFailure: Error {}
        do {
            try await gate.withPermit { throw ExpectedFailure() }
        } catch is ExpectedFailure {}
        try await gate.withPermit { try Task.checkCancellation() }
    }

    @Test("admitted cancellation retains permit through complete cleanup")
    func cancellationDuringTeardown() async throws {
        let gate = PostgresFixtureConcurrency(limit: 1)
        let entered = FixtureSignal()
        let finishCleanup = FixtureSignal()
        let cleanupStarted = FixtureSignal()
        let owner = Task {
            try await gate.withPermit {
                await entered.signal()
                do { try await Task.sleep(for: .seconds(60)) } catch {
                    await Task.detached {
                        await cleanupStarted.signal()
                        await finishCleanup.wait()
                    }.value
                    throw error
                }
            }
        }
        await entered.wait()
        owner.cancel()
        await cleanupStarted.wait()
        let waiting = Task { try await gate.withPermit { await finishCleanup.signal() } }
        // Cancellation must still reach a queued waiter while teardown owns
        // the sole permit. If it were released early, this operation would run.
        for _ in 0..<10_000 {
            if gate.waitingCount == 1 { break }
            await Task.yield()
        }
        #expect(gate.waitingCount == 1)
        waiting.cancel()
        do { try await waiting.value; Issue.record("teardown permit was released early") } catch is CancellationError {}
        await finishCleanup.signal()
        do { try await owner.value; Issue.record("cancelled owner succeeded") } catch is CancellationError {}
        try await gate.withPermit {}
    }

    @Test("supported trait scopes every parameterized case", .postgresFixture, arguments: 0..<32)
    func actualFixtures(_ index: Int) async throws {
        #expect(PostgresFixtureScope.current != nil)
        #expect(PostgresFixtureConcurrency.shared.peakActive <= 4)
        // Scope cleanup owns this app, including an early exit before configure.
        let app = try await Application.makeForTesting()
        try await configure(app)
        try await app.db.withConnection { _ in
            try await Task.sleep(for: .milliseconds(20))
        }
        if index == 31 {
            print("fixture_admission cases_peak=\(PostgresFixtureConcurrency.shared.peakActive) limit=4")
        }
        // Deliberately omit manual teardown to exercise the fallback owner.
    }

    @Test(
        "scope closes pools and drops clones after failure or cancellation", .postgresFixture,
        arguments: [false, true])
    func scopeLifecycle(_ cancel: Bool) async throws {
        let holder = FixtureApplicationHolder()
        let entered = FixtureSignal()
        struct ExpectedFailure: Error {}
        let task = Task {
            do {
                try await PostgresFixtureScope.withScope {
                    let app = try await Application.makeForTesting()
                    await holder.store(app)
                    try await configure(app)
                    await entered.signal()
                    if cancel { try await Task.sleep(for: .seconds(60)) }
                    throw ExpectedFailure()
                }
            } catch {
                await entered.signal()
                throw error
            }
        }
        await entered.wait()
        if cancel { task.cancel() }
        do { try await task.value; Issue.record("fixture failure did not propagate") } catch is CancellationError {
            #expect(cancel)
        } catch is ExpectedFailure { #expect(!cancel) }
        let app = try #require(await holder.app)
        let database = try #require(await holder.database)
        #expect(app.didShutdown)
        let observer = try await Application.makeForTesting()
        let sql = try #require(observer.db as? any SQLDatabase)
        let row = try #require(
            try await sql.raw(
                "SELECT COUNT(*) AS count FROM pg_database WHERE datname = \(bind: database)"
            ).first())
        #expect(try row.decode(column: "count", as: Int.self) == 0)
    }

    @Test("bounded connection fan-out completes the same excess demand", .postgresFixture)
    func boundedConnections() async throws {
        let gate = PostgresFixtureConcurrency(limit: 4)
        let config = connectionConfiguration()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for taskID in 0..<32 {
                group.addTask {
                    try await gate.withPermit {
                        var connections: [PostgresConnection] = []
                        do {
                            for offset in 0..<4 {
                                connections.append(
                                    try await PostgresConnection.connect(
                                        on: PostgresTestDatabases.appEventLoopGroup.next(),
                                        configuration: config, id: taskID * 4 + offset,
                                        logger: Logger(label: "fixture-bounded-control")))
                            }
                            try await Task.sleep(for: .milliseconds(30))
                        } catch {
                            let owned = connections
                            await Task.detached {
                                for connection in owned { try? await connection.close() }
                            }.value
                            throw error
                        }
                        let owned = connections
                        await Task.detached {
                            for connection in owned { try? await connection.close() }
                        }.value
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(gate.peakActive == 4)
        print("fixture_bounded_control completed_connections=128 peak_owners=4 connections_per_owner=4")
    }

    private func connectionConfiguration() -> PostgresConnection.Configuration {
        PostgresConnection.Configuration(
            host: Environment.get("DATABASE_HOST") ?? "localhost",
            port: Environment.get("DATABASE_PORT").flatMap(Int.init) ?? 5432,
            username: Environment.get("DATABASE_USERNAME") ?? "strato",
            password: Environment.get("DATABASE_PASSWORD") ?? "strato_password",
            database: Environment.get("DATABASE_NAME") ?? "strato_test", tls: .disable)
    }

    @Test(
        "unbounded negative control reaches actual PostgreSQL 53300",
        .enabled(
            if:
                ProcessInfo.processInfo.environment["STRATO_TEST_FIXTURE_SATURATION_PROBE"] == "1"))
    func saturationNegativeControl() async throws {
        // Opt-in only on our explicitly disposable PostgreSQL server. Never
        // exhaust a developer's persistent/shared database as a routine test.
        try #require(ProcessInfo.processInfo.environment["STRATO_TEST_DISPOSABLE_POSTGRES"] == "1")
        let config = connectionConfiguration()
        var connections: [PostgresConnection] = []
        var observed: String?
        do {
            for id in 1...110 {
                do {
                    let connection = try await PostgresConnection.connect(
                        on: PostgresTestDatabases.appEventLoopGroup.next(),
                        configuration: config, id: id, logger: Logger(label: "fixture-negative-control"))
                    connections.append(connection)
                } catch let error as PSQLError {
                    observed = error.serverInfo?[.sqlState]
                    break
                }
            }
        } catch {
            let owned = connections
            await Task.detached { for connection in owned { try? await connection.close() } }.value
            throw error
        }
        let owned = connections
        await Task.detached { for connection in owned { try? await connection.close() } }.value
        #expect(observed == "53300")
        #expect(connections.count >= 90)
        print("fixture_negative_control sqlstate=\(observed ?? "none") opened=\(connections.count)")
    }
}
