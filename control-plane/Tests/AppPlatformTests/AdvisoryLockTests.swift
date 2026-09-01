import AppTestSupport
import Fluent
import Foundation
import Logging
import MetricsTestKit
import Testing
import Vapor

@testable import App

@Suite("Advisory locks", .serialized)
struct AdvisoryLockTests {
    @Test("Namespaces have unique, stable values in acquisition order")
    func namespaceValuesAreUniqueAndOrdered() {
        let values = AdvisoryLockNamespace.allCases.map(\.rawValue)

        #expect(Set(values).count == values.count)
        #expect(values == Array(Int32(1)...Int32(12)))
    }

    @Test("UUID digests are stable and singleton locks use zero")
    func digestGoldensAndSingleton() throws {
        let zero = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        let patterned = try #require(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))

        #expect(AdvisoryLockKey.digest(zero) == 927_402_239)
        #expect(AdvisoryLockKey.digest(patterned) == -1_459_950_230)
        #expect(AdvisoryLockKey.singleton(.resolverIndex).objectDigest == 0)
    }

    @Test("The order checker accepts forward paths and reports backward acquisition")
    func acquisitionOrderIsChecked() {
        let project = AdvisoryLockKey.digest(.projectNetwork, 1)
        let lineage = AdvisoryLockKey.digest(.sandboxSnapshotLineage, 1)
        let quotaOne = AdvisoryLockKey.digest(.quota, 1)
        let quotaTwo = AdvisoryLockKey.digest(.quota, 2)

        #expect(AdvisoryLock.acquisitionOrderViolation(held: [project], acquiring: quotaOne) == nil)
        #expect(
            AdvisoryLock.acquisitionOrderViolation(
                held: [project, lineage], acquiring: quotaOne) == nil)
        #expect(AdvisoryLock.acquisitionOrderViolation(held: [quotaOne], acquiring: quotaOne) == nil)
        #expect(AdvisoryLock.acquisitionOrderViolation(held: [quotaOne], acquiring: quotaTwo) == nil)

        let violation = AdvisoryLock.acquisitionOrderViolation(
            held: [quotaOne], acquiring: project)
        #expect(violation?.contains("project_network") == true)
        #expect(violation?.contains("quota") == true)

        let descendingDigest = AdvisoryLock.acquisitionOrderViolation(
            held: [quotaTwo], acquiring: quotaOne)
        #expect(descendingDigest?.contains("quota/1") == true)
        #expect(descendingDigest?.contains("quota/2") == true)
    }

    @Test("A transaction lock rejects autocommit use")
    func transactionLockRequiresTransaction() async throws {
        try await withTestApp { app in
            let key = AdvisoryLockKey.digest(.dnsZone, 17)
            var rejectedKey: AdvisoryLockKey?

            do {
                try await AdvisoryLock.acquireTransactionLock(key, on: app.db)
            } catch AdvisoryLockError.transactionRequired(let errorKey) {
                rejectedKey = errorKey
            }

            #expect(rejectedKey == key)
        }
    }

    @Test("Equal digests in different namespaces do not block")
    func equalDigestsInDifferentNamespacesDoNotBlock() async throws {
        try await withSharedDatabase { holder, waiter in
            let digest = Int32(bitPattern: 0xdead_beef)
            let heldKey = AdvisoryLockKey.digest(.dnsZone, digest)
            let independentKey = AdvisoryLockKey.digest(.volumeAttachment, digest)

            let acquired = try await holder.db.transaction { heldTransaction in
                try await AdvisoryLock.acquireTransactionLock(heldKey, on: heldTransaction)
                return try await AdvisoryLock.withSessionLock(
                    independentKey,
                    on: waiter.db,
                    timeout: .milliseconds(100),
                    pollInterval: .milliseconds(10),
                    logger: waiter.logger
                ) { _ in true }
            }

            #expect(acquired)
        }
    }

    @Test("The same namespace and object serialize until transaction commit")
    func sameKeySerializes() async throws {
        try await withSharedDatabase { holder, waiter in
            let objectID = try #require(
                UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
            let key = AdvisoryLockKey.object(.volumeAttachment, id: objectID)

            let timedOut = try await holder.db.transaction { heldTransaction in
                try await AdvisoryLock.acquireTransactionLock(key, on: heldTransaction)
                do {
                    _ = try await AdvisoryLock.withSessionLock(
                        key,
                        on: waiter.db,
                        timeout: .milliseconds(100),
                        pollInterval: .milliseconds(10),
                        logger: waiter.logger
                    ) { _ in true }
                    return false
                } catch AdvisoryLockError.acquisitionTimedOut {
                    return true
                }
            }

            #expect(timedOut)
            let acquiredAfterCommit = try await AdvisoryLock.withSessionLock(
                key,
                on: waiter.db,
                timeout: .milliseconds(100),
                pollInterval: .milliseconds(10),
                logger: waiter.logger
            ) { _ in true }
            #expect(acquiredAfterCommit)
        }
    }

    @Test("Enrollment lock contention returns conflict at its deadline")
    func enrollmentDeadlineReturnsConflict() async throws {
        try await withSharedDatabase { holder, waiter in
            let enrollmentID = UUID()
            let key = AdvisoryLockKey.object(.agentEnrollment, id: enrollmentID)

            let attempt = try await AdvisoryLock.withSessionLock(
                key,
                on: holder.db,
                timeout: .seconds(1),
                pollInterval: .milliseconds(10),
                logger: holder.logger
            ) { _ in
                do {
                    try await AgentEnrollment.withOperationLock(
                        enrollmentID: enrollmentID,
                        on: waiter.db,
                        logger: waiter.logger,
                        timeout: .milliseconds(75),
                        pollInterval: .milliseconds(10)
                    ) { _ in () }
                    return EnrollmentLockAttempt(statusCode: nil, reason: nil)
                } catch let abort as Abort {
                    return EnrollmentLockAttempt(
                        statusCode: Int(abort.status.code), reason: abort.reason)
                }
            }

            #expect(attempt.statusCode == 409)
            #expect(attempt.reason == "Another operation on this enrollment is in progress")
        }
    }

    @Test("A false session unlock is logged critically and counted")
    func falseSessionUnlockIsVisible() async throws {
        let recorder = AdvisoryLockLogRecorder()
        let logger = Logger(label: "test.advisory-lock") { _ in
            AdvisoryLockRecordingLogHandler(recorder: recorder)
        }
        let metrics = TestMetrics()
        let objectID = try #require(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))
        let key = AdvisoryLockKey.object(.agentEnrollment, id: objectID)

        try await withTestApp { app in
            var releaseFailure: ReleaseFailure?
            do {
                _ = try await AdvisoryLock.withSessionLock(
                    key,
                    on: app.db,
                    timeout: .seconds(1),
                    pollInterval: .milliseconds(10),
                    logger: logger,
                    metricsFactory: metrics
                ) { connection in
                    let released = try await AdvisoryLock.releaseSessionLockForTesting(
                        key, on: connection)
                    #expect(released)
                    return ()
                }
            } catch AdvisoryLockError.releaseFailed(let failedKey, let reason) {
                releaseFailure = ReleaseFailure(key: failedKey, reason: reason)
            }

            #expect(releaseFailure?.key == key)
            #expect(releaseFailure?.reason.contains("did not hold the lock") == true)

            let event = try #require(
                recorder.events.first { event in
                    event.level == .critical
                        && event.message.description
                            == "Failed to release a PostgreSQL advisory session lock"
                })
            #expect(event.metadata?["namespace"]?.description == "agent_enrollment")
            #expect(event.metadata?["objectId"]?.description == objectID.uuidString.lowercased())
            #expect(event.metadata?["objectDigest"]?.description == String(key.objectDigest))

            let failures = try metrics.expectCounter(
                "strato_advisory_lock_release_failures_total",
                [("namespace", "agent_enrollment")])
            #expect(failures.totalValue == 1)
            let acquisitions = try metrics.expectCounter(
                "strato_advisory_lock_acquisitions_total",
                [("namespace", "agent_enrollment")])
            #expect(acquisitions.totalValue == 1)
            let waits = try metrics.expectTimer(
                "strato_advisory_lock_wait_duration_seconds",
                [("namespace", "agent_enrollment")])
            #expect(waits.values.count == 1)
        }
    }

    private func withSharedDatabase(
        _ body: (Application, Application) async throws -> Void
    ) async throws {
        let databaseName = try await PostgresTestDatabases.shared.createDatabaseForTest()
        let holder = try await Application.makeForTesting(
            database: databaseName, owningDatabase: false)
        let waiter: Application
        do {
            waiter = try await Application.makeForTesting(
                database: databaseName, owningDatabase: true)
        } catch {
            try? await holder.asyncShutdown()
            await PostgresTestDatabases.shared.dropDatabase(databaseName)
            throw error
        }

        do {
            try await body(holder, waiter)
        } catch {
            try? await holder.asyncShutdown()
            try? await waiter.shutdownForTesting()
            throw error
        }

        do {
            try await holder.asyncShutdown()
        } catch {
            try? await waiter.shutdownForTesting()
            throw error
        }
        try await waiter.shutdownForTesting()
    }
}

private struct EnrollmentLockAttempt: Sendable {
    let statusCode: Int?
    let reason: String?
}

private struct ReleaseFailure: Sendable {
    let key: AdvisoryLockKey
    let reason: String
}

private struct AdvisoryLockRecordingLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    let recorder: AdvisoryLockLogRecorder

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        recorder.append(event)
    }
}

private final class AdvisoryLockLogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [LogEvent] = []

    var events: [LogEvent] {
        lock.withLock { recordedEvents }
    }

    func append(_ event: LogEvent) {
        lock.withLock { recordedEvents.append(event) }
    }
}
