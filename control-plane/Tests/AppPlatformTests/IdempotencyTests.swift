import Foundation
import Fluent
import SQLKit
import Testing
import Vapor

import AppTestSupport
@testable import App

@Suite("Mutation idempotency")
struct IdempotencyTests {
    private actor Latch {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            open = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private actor MutationCount {
        private(set) var value = 0

        func increment() { value += 1 }
    }

    private struct CommitThenRejectResponder: AsyncResponder {
        let actor: MutationActor
        let resourceID: UUID
        let mutationID: UUID
        let responseBody: Data

        func respond(to request: Request) async throws -> Response {
            guard let context = request.idempotencyContext else {
                throw Abort(.internalServerError, reason: "Missing idempotency context")
            }
            try await request.db.transaction { db in
                try await IdempotencyService.reserve(context, actor: actor, on: db)
                try await IdempotencyService.complete(
                    context,
                    actor: actor,
                    resourceKind: .virtualMachine,
                    resourceID: resourceID,
                    accepted: .init(mutationID: mutationID, targetGeneration: 1),
                    responseBody: responseBody,
                    on: db)
            }
            throw Abort(.conflict, reason: "Stale controller preflight")
        }
    }

    @Test("request digest ignores JSON object key order but binds every value")
    func canonicalRequestDigest() throws {
        let first = Data(#"{"name":"db","shape":{"memory":4096,"cpu":2}}"#.utf8)
        let reordered = Data(#"{"shape":{"cpu":2,"memory":4096},"name":"db"}"#.utf8)
        let changed = Data(#"{"shape":{"cpu":4,"memory":4096},"name":"db"}"#.utf8)

        let expected = try IdempotencyRequestDigest.compute(
            method: .POST, path: "/api/vms", body: first)

        #expect(
            try IdempotencyRequestDigest.compute(
                method: .POST, path: "/api/vms", body: reordered) == expected)
        #expect(
            try IdempotencyRequestDigest.compute(
                method: .POST, path: "/api/vms", body: changed) != expected)
        #expect(
            try IdempotencyRequestDigest.compute(
                method: .PATCH, path: "/api/vms", body: first) != expected)
        #expect(
            try IdempotencyRequestDigest.compute(
                method: .POST, path: "/api/sandboxes", body: first) != expected)
        #expect(
            try IdempotencyRequestDigest.compute(
                method: .POST, path: "/api/vms?force=true", body: first) != expected)
    }

    @Test("expiry sweep removes only elapsed replay claims")
    func expirySweep() async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let now = Date()
            let actor = MutationActor.user(UUID())
            try await IdempotencyKey(
                actor: actor,
                key: "expired",
                requestDigest: Data(repeating: 1, count: 32),
                expiresAt: now.addingTimeInterval(1)
            ).create(on: app.db)
            try await IdempotencyKey(
                actor: actor,
                key: "active",
                requestDigest: Data(repeating: 2, count: 32),
                expiresAt: now.addingTimeInterval(60)
            ).create(on: app.db)

            #expect(
                try await IdempotencyService.sweepExpired(
                    on: app.db, now: now.addingTimeInterval(2)) == 1)
            #expect(try await IdempotencyKey.query(on: app.db).count() == 1)
            #expect(try await IdempotencyKey.query(on: app.db).first()?.key == "active")

            let reusable = IdempotencyKey(
                actor: actor,
                key: "reusable",
                requestDigest: Data(repeating: 3, count: 32),
                expiresAt: now.addingTimeInterval(60))
            try await reusable.create(on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw(
                """
                UPDATE idempotency_keys
                SET created_at = \(bind: now.addingTimeInterval(-120)),
                    expires_at = \(bind: now.addingTimeInterval(-60))
                WHERE id = \(bind: try reusable.requireID())
                """
            ).run()

            let context = IdempotencyRequestContext(
                actor: actor, key: "reusable", requestDigest: Data(repeating: 4, count: 32))
            let newMutationID = UUID()
            try await app.db.transaction { db in
                try await IdempotencyService.reserve(context, actor: actor, on: db)
                try await IdempotencyService.complete(
                    context,
                    actor: actor,
                    resourceKind: .virtualMachine,
                    resourceID: UUID(),
                    accepted: .init(mutationID: newMutationID, targetGeneration: 1),
                    on: db)
            }
            let replacement = try #require(
                try await IdempotencyService.activeClaim(for: context, on: app.db))
            #expect(replacement.mutationID == newMutationID)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("the same key belongs independently to each authenticated principal")
    func keysArePrincipalScoped() async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let key = UUID().uuidString
            let firstActor = MutationActor.user(UUID())
            let secondActor = MutationActor.user(UUID())
            for actor in [firstActor, secondActor] {
                let context = IdempotencyRequestContext(
                    actor: actor, key: key, requestDigest: Data(repeating: 9, count: 32))
                try await app.db.transaction { db in
                    try await IdempotencyService.reserve(context, actor: actor, on: db)
                    try await IdempotencyService.complete(
                        context,
                        actor: actor,
                        resourceKind: .virtualMachine,
                        resourceID: UUID(),
                        accepted: .init(mutationID: UUID(), targetGeneration: 1),
                        on: db)
                }
            }

            #expect(try await IdempotencyKey.query(on: app.db).count() == 2)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("the accepted response commits with the mutation and remains stable")
    func acceptedResponseBodyIsStable() async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let actor = MutationActor.user(UUID())
            let context = IdempotencyRequestContext(
                actor: actor,
                key: UUID().uuidString,
                requestDigest: Data(repeating: 5, count: 32))
            let original = Data(#"{"mutationId":"first"}"#.utf8)
            try await app.db.transaction { db in
                try await IdempotencyService.reserve(context, actor: actor, on: db)
                try await IdempotencyService.complete(
                    context,
                    actor: actor,
                    resourceKind: .virtualMachine,
                    resourceID: UUID(),
                    accepted: .init(mutationID: UUID(), targetGeneration: 1),
                    responseBody: original,
                    on: db)
            }

            let laterReplay = Data(#"{"mutationId":"first","resource":"newer"}"#.utf8)
            #expect(
                try await IdempotencyService.storeResponseBody(
                    laterReplay, for: context, on: app.db))

            let claim = try #require(
                try await IdempotencyService.activeClaim(for: context, on: app.db))
            #expect(claim.responseBody == original)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("an in-flight duplicate waits for the winner and never reaches the mutation")
    func inFlightDuplicateSerializes() async throws {
        // The winner parks inside an open transaction while the duplicate and
        // this test body's pg_stat_activity poll each need a connection of
        // their own — three concurrent holders, which can all land on the same
        // loop of the shared two-loop group. With the harness default pool the
        // duplicate's `db.transaction` can starve behind the winner's parked
        // connection and the whole suite hangs on the resulting three-way
        // latch deadlock, so give every holder a slot even on one loop.
        let app = try await Application.makeForTesting(maxConnectionsPerEventLoop: 4)
        do {
            try await configure(app)
            try await app.autoMigrate()

            let actor = MutationActor.user(UUID())
            let context = IdempotencyRequestContext(
                actor: actor,
                key: UUID().uuidString,
                requestDigest: Data(repeating: 7, count: 32))
            let firstReserved = Latch()
            let secondEnteredTransaction = Latch()
            let releaseFirst = Latch()
            let mutations = MutationCount()

            let first = Task {
                try await app.db.transaction { db in
                    try await IdempotencyService.reserve(context, actor: actor, on: db)
                    await mutations.increment()
                    await firstReserved.signal()
                    await releaseFirst.wait()
                    try await IdempotencyService.complete(
                        context,
                        actor: actor,
                        resourceKind: .virtualMachine,
                        resourceID: UUID(),
                        accepted: .init(mutationID: UUID(), targetGeneration: 1),
                        on: db)
                }
            }

            await firstReserved.wait()
            let second = Task { () -> Bool in
                do {
                    try await app.db.transaction { db in
                        await secondEnteredTransaction.signal()
                        try await IdempotencyService.reserve(context, actor: actor, on: db)
                        await mutations.increment()
                    }
                    return false
                } catch is IdempotencyReplayRequired {
                    return true
                } catch {
                    Issue.record("Unexpected duplicate reservation error: \(error)")
                    return false
                }
            }

            await secondEnteredTransaction.wait()
            // Release the winner only once the duplicate's INSERT is visibly
            // blocked on the winner's uncommitted reservation, so the test
            // exercises PostgreSQL's in-flight wait every run rather than the
            // easier committed-row conflict.
            let sql = try #require(app.db as? any SQLDatabase)
            struct WaiterCount: Decodable { let count: Int }
            let blockedDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while true {
                let waiters = try await sql.raw(
                    """
                    SELECT COUNT(*) AS count FROM pg_stat_activity
                    WHERE datname = current_database()
                      AND wait_event_type = 'Lock'
                      AND query ILIKE '%idempotency_keys%'
                    """
                ).first(decoding: WaiterCount.self)
                if (waiters?.count ?? 0) > 0 { break }
                if ContinuousClock.now > blockedDeadline {
                    Issue.record("The duplicate reserve never blocked on the winner's reservation")
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            await releaseFirst.signal()
            try await first.value
            #expect(await second.value)
            #expect(await mutations.value == 1)
            #expect(try await IdempotencyKey.query(on: app.db).count() == 1)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("a winner committed during controller preflight replaces the stale error")
    func committedWinnerReplacesPreflightError() async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let user = try await TestDataBuilder(db: app.db).createUser(
                username: "idempotency-preflight", email: "idempotency-preflight@example.com")
            let actor = MutationActor.user(try user.requireID())
            let key = UUID().uuidString
            let mutationID = UUID()
            let body = Data(
                #"{"mutationId":"\#(mutationID.uuidString)","targetGeneration":1}"#.utf8)
            let request = Request(
                application: app,
                method: .POST,
                url: URI(path: "/api/vms/preflight-race"),
                on: app.eventLoopGroup.next())
            request.auth.login(user)
            request.headers.replaceOrAdd(name: IdempotencyMiddleware.headerName, value: key)

            let response = try await IdempotencyMiddleware().respond(
                to: request,
                chainingTo: CommitThenRejectResponder(
                    actor: actor,
                    resourceID: UUID(),
                    mutationID: mutationID,
                    responseBody: body))

            #expect(response.status == .accepted)
            #expect(response.body.data == body)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}
