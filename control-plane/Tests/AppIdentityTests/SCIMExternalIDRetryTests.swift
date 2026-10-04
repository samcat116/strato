import AppTestSupport
import Fluent
import Foundation
import SQLKit
import Testing
import Vapor

@testable import App

@Suite("SCIM external-ID insertion races", .serialized, .postgresFixture)
struct SCIMExternalIDRetryTests {
    private static let ownKey = "uq:scim_external_ids.organization_id+scim_external_ids.resource"

    @Test("Concurrent own-key inserts reread and update the winning mapping")
    func concurrentInsert() async throws {
        let app = try await Application.makeForTesting()
        do {
            let org = try await TestDataBuilder(db: app.db).createOrganization()
            let gate = SCIMInsertGate()
            app.databases.middleware.use(SCIMInsertBarrier(gate: gate))
            let first = UUID(), second = UUID()
            async let a: Void = SCIMExternalID.upsert(
                organizationID: org.requireID(), resourceType: .user, externalId: "race", internalId: first, on: app.db)
            async let b: Void = SCIMExternalID.upsert(
                organizationID: org.requireID(), resourceType: .user, externalId: "race", internalId: second, on: app.db
            )
            _ = try await (a, b)
            let rows = try await SCIMExternalID.query(on: app.db).all()
            #expect(rows.count == 1)
            #expect([first, second].contains(try #require(rows.first).internalId))
            #expect(await gate.arrivals == 2)
            #expect(await gate.updates == 1)
            #expect(rows.first?.internalId == (await gate.updatedID))
            #expect((await gate.createdID) != (await gate.updatedID))
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test(
        "Only own-key INSERT errors retry; three attempts preserve the original PostgreSQL error",
        arguments: [
            ("23505", ownKey, 3), ("23505", "unrelated_unique", 1), ("23503", ownKey, 1),
            ("23514", ownKey, 1), ("40001", ownKey, 1), ("40P01", ownKey, 1),
            ("55P03", ownKey, 1), ("57014", ownKey, 1), ("08006", ownKey, 1), ("XX000", ownKey, 1),
        ])
    func insertFailures(state: String, constraint: String, expectedAttempts: Int) async throws {
        let app = try await Application.makeForTesting()
        let counter = SCIMFailureCounter()
        do {
            let org = try await TestDataBuilder(db: app.db).createOrganization()
            app.databases.middleware.use(SCIMFailureInjector(counter: counter, state: state, constraint: constraint))
            do {
                try await SCIMExternalID.upsert(
                    organizationID: org.requireID(), resourceType: .user, externalId: "failure",
                    internalId: UUID(), on: app.db)
                Issue.record("Expected original PostgreSQL error")
            } catch {
                #expect(DatabaseTransactionFailure.sqlState(error) == state)
                #expect(!(error is DatabaseTransactionRetryExhausted))
            }
            #expect(await counter.value == expectedAttempts)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("Own-key INSERT inside an outer transaction propagates without local replay")
    func nestedInsertFailure() async throws {
        let app = try await Application.makeForTesting()
        let counter = SCIMFailureCounter()
        do {
            let org = try await TestDataBuilder(db: app.db).createOrganization()
            app.databases.middleware.use(SCIMFailureInjector(counter: counter, state: "23505", constraint: Self.ownKey))
            do {
                try await app.db.transaction { tx in
                    try await SCIMExternalID.upsert(
                        organizationID: org.requireID(), resourceType: .user, externalId: "nested",
                        internalId: UUID(), on: tx)
                }
                Issue.record("Expected outer transaction to abort")
            } catch {
                #expect(DatabaseTransactionFailure.uniqueConstraint(error) == Self.ownKey)
            }
            #expect(await counter.value == 1)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("Own-key UPDATE failure propagates without retry")
    func updateFailure() async throws {
        let app = try await Application.makeForTesting()
        let counter = SCIMFailureCounter()
        do {
            let org = try await TestDataBuilder(db: app.db).createOrganization()
            let original = UUID()
            try await SCIMExternalID.upsert(
                organizationID: org.requireID(), resourceType: .user, externalId: "update", internalId: original,
                on: app.db)
            app.databases.middleware.use(
                SCIMFailureInjector(counter: counter, state: "23505", constraint: Self.ownKey, updateOnly: true))
            do {
                try await SCIMExternalID.upsert(
                    organizationID: org.requireID(), resourceType: .user, externalId: "update", internalId: UUID(),
                    on: app.db)
                Issue.record("Expected update failure")
            } catch {
                #expect(DatabaseTransactionFailure.uniqueConstraint(error) == Self.ownKey)
            }
            #expect(await counter.value == 1)
            #expect(try await SCIMExternalID.query(on: app.db).first()?.internalId == original)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("Own-key LOOKUP failure propagates without retry")
    func lookupFailure() async throws {
        let app = try await Application.makeForTesting()
        do {
            let org = try await TestDataBuilder(db: app.db).createOrganization()
            try await SCIMExternalID.upsert(
                organizationID: org.requireID(), resourceType: .user, externalId: "lookup", internalId: UUID(),
                on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("CREATE SEQUENCE scim_lookup_attempts").run()
            try await sql.raw(
                """
                CREATE FUNCTION fail_scim_lookup() RETURNS boolean LANGUAGE plpgsql AS $$ BEGIN
                PERFORM nextval('scim_lookup_attempts');
                RAISE EXCEPTION 'lookup failure' USING ERRCODE = '23505',
                CONSTRAINT = 'uq:scim_external_ids.organization_id+scim_external_ids.resource'; END $$
                """
            ).run()
            try await sql.raw("ALTER TABLE scim_external_ids RENAME TO scim_lookup_rows").run()
            try await sql.raw(
                "CREATE VIEW scim_external_ids AS SELECT * FROM scim_lookup_rows WHERE fail_scim_lookup()"
            ).run()
            do {
                try await SCIMExternalID.upsert(
                    organizationID: org.requireID(), resourceType: .user, externalId: "lookup", internalId: UUID(),
                    on: app.db)
                Issue.record("Expected lookup failure")
            } catch {
                #expect(DatabaseTransactionFailure.uniqueConstraint(error) == Self.ownKey)
            }
            #expect(
                try await sql.raw("SELECT last_value FROM scim_lookup_attempts").first(
                    decodingColumn: "last_value", as: Int.self) == 1)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}

private actor SCIMFailureCounter {
    var value = 0
    func increment() { value += 1 }
}

private struct SCIMFailureInjector: AsyncModelMiddleware {
    let counter: SCIMFailureCounter
    let state: String
    let constraint: String
    var updateOnly = false

    private func fail(on db: any Database) async throws {
        await counter.increment()
        let sql = try #require(db as? any SQLDatabase)
        // Fixed test arguments only, never request inputs.
        try await sql.raw(
            SQLQueryString(
                stringLiteral: """
                    DO $$ BEGIN RAISE EXCEPTION 'injected SCIM failure' USING ERRCODE = '\(state)',
                    CONSTRAINT = '\(constraint)'; END $$
                    """)
        ).run()
    }

    func create(model: SCIMExternalID, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        if !updateOnly { try await fail(on: db) }
        try await next.create(model, on: db)
    }

    func update(model: SCIMExternalID, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        if updateOnly { try await fail(on: db) }
        try await next.update(model, on: db)
    }
}

private actor SCIMInsertGate {
    var arrivals = 0
    var updates = 0
    var createdID: UUID?
    var updatedID: UUID?
    private var waiter: CheckedContinuation<Void, Never>?
    func arrive() async {
        arrivals += 1
        if arrivals == 1 {
            await withCheckedContinuation { waiter = $0 }
        } else {
            waiter?.resume()
            waiter = nil
        }
    }
    func created(_ id: UUID) { createdID = id }
    func updated(_ id: UUID) { updates += 1; updatedID = id }
}

private struct SCIMInsertBarrier: AsyncModelMiddleware {
    let gate: SCIMInsertGate
    func create(model: SCIMExternalID, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        await gate.arrive()
        try await next.create(model, on: db)
        await gate.created(model.internalId)
    }
    func update(model: SCIMExternalID, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.update(model, on: db)
        await gate.updated(model.internalId)
    }
}
