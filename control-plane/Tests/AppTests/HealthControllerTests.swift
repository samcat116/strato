import Testing
import Vapor
import VaporTesting
@testable import App

@Suite("HealthController Tests", .serialized)
struct HealthControllerTests {

    // MARK: - Basic Health Check Tests

    @Test("Health endpoint returns 200 OK")
    func testHealthEndpoint() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)

        try await app.test(.GET, "/health") { res async throws in
            #expect(res.status == .ok)
        }
        try await app.shutdownForTesting()
    }

    // MARK: - Liveness Check Tests

    @Test("Liveness endpoint returns healthy status")
    func testLivenessHealthy() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)

        try await app.test(.GET, "/health/live") { res async throws in
            #expect(res.status == .ok)

            let health = try res.content.decode(HealthResponse.self)
            #expect(health.status == "healthy")
            #expect(health.checks.count > 0)

            let appCheck = health.checks.first { $0.name == "application" }
            #expect(appCheck != nil)
            #expect(appCheck?.status == "up")
            #expect(appCheck?.error == nil)
        }
        try await app.shutdownForTesting()
    }

    @Test("Liveness endpoint includes timestamp")
    func testLivenessTimestamp() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)

        try await app.test(.GET, "/health/live") { res async throws in
            let health = try res.content.decode(HealthResponse.self)

            // Timestamp should be recent (within last minute)
            let now = Date()
            let timeDifference = abs(now.timeIntervalSince(health.timestamp))
            #expect(timeDifference < 60)
        }
        try await app.shutdownForTesting()
    }

    // MARK: - Readiness Check Tests

    @Test("Readiness endpoint returns healthy when database is available")
    func testReadinessHealthy() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        try await app.test(.GET, "/health/ready") { res async throws in
            #expect(res.status == .ok)

            let health = try res.content.decode(HealthResponse.self)
            #expect(health.status == "healthy")

            let dbCheck = health.checks.first { $0.name == "database" }
            #expect(dbCheck != nil)
            #expect(dbCheck?.status == "up")
            #expect(dbCheck?.error == nil)
        }
        try await app.shutdownForTesting()
    }

    @Test("Readiness endpoint includes timestamp")
    func testReadinessTimestamp() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        try await app.test(.GET, "/health/ready") { res async throws in
            let health = try res.content.decode(HealthResponse.self)

            // Timestamp should be recent (within last minute)
            let now = Date()
            let timeDifference = abs(now.timeIntervalSince(health.timestamp))
            #expect(timeDifference < 60)
        }
        try await app.shutdownForTesting()
    }

    // MARK: - Response Structure Tests

    @Test("Health response has correct structure")
    func testHealthResponseStructure() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)

        try await app.test(.GET, "/health/live") { res async throws in
            let health = try res.content.decode(HealthResponse.self)

            // Verify required fields are present
            #expect(!health.status.isEmpty)
            #expect(health.checks.count > 0)

            // Verify check structure
            for check in health.checks {
                #expect(!check.name.isEmpty)
                #expect(!check.status.isEmpty)
            }
        }
        try await app.shutdownForTesting()
    }

    // MARK: - Content Type Tests

    @Test("Health endpoints return JSON content")
    func testHealthEndpointsReturnJSON() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        try await app.test(.GET, "/health/live") { res async throws in
            let contentType = res.headers.contentType
            #expect(contentType != nil)
            #expect(contentType?.type.description == "application")
            #expect(contentType?.subType == "json")
        }

        try await app.test(.GET, "/health/ready") { res async throws in
            let contentType = res.headers.contentType
            #expect(contentType != nil)
            #expect(contentType?.type.description == "application")
            #expect(contentType?.subType == "json")
        }
        try await app.shutdownForTesting()
    }

    // MARK: - Multiple Checks Tests

    @Test("Readiness endpoint can have multiple checks")
    func testMultipleChecks() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        try await app.test(.GET, "/health/ready") { res async throws in
            let health = try res.content.decode(HealthResponse.self)

            // Currently only database check, but structure supports multiple
            #expect(health.checks.count >= 1)

            // All check names should be unique
            let checkNames = health.checks.map { $0.name }
            let uniqueNames = Set(checkNames)
            #expect(checkNames.count == uniqueNames.count)
        }
        try await app.shutdownForTesting()
    }

    // MARK: - Overall Status Tests

    @Test("Overall status is healthy when all checks pass")
    func testOverallStatusHealthy() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        try await app.test(.GET, "/health/ready") { res async throws in
            let health = try res.content.decode(HealthResponse.self)

            #expect(health.status == "healthy")

            // All checks should be up
            for check in health.checks {
                #expect(check.status == "up")
            }
        }
        try await app.shutdownForTesting()
    }

    // MARK: - Dependency Coverage

    @Test("Readiness reports every gating dependency")
    func testReadinessCoversDependencies() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        try await app.test(.GET, "/health/ready") { res async throws in
            let health = try res.content.decode(HealthResponse.self)
            let names = Set(health.checks.map(\.name))

            // A readiness probe that only knows about Postgres would keep a
            // replica in rotation while SpiceDB is unreachable and every
            // authorized request 500s.
            #expect(names == ["database", "migrations", "spicedb", "valkey"])
        }
        try await app.shutdownForTesting()
    }

    // MARK: - Failure Signalling

    @Test("Readiness returns 503 when a required gate is closed")
    func testReadinessFailsClosed() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        // The migrations gate stands in for any fatal check: it is the one a
        // test can close without tearing down a live dependency. What is being
        // asserted is the status *code* — a load balancer reads that, not the
        // body, so a 200 here would keep a broken replica serving traffic.
        app.readiness.closeMigrationsGateForTesting()

        try await app.test(.GET, "/health/ready") { res async throws in
            #expect(res.status == .serviceUnavailable)

            let health = try res.content.decode(HealthResponse.self)
            #expect(health.status == "unhealthy")

            let migrations = health.checks.first { $0.name == "migrations" }
            #expect(migrations?.status == "down")
            #expect(migrations?.error != nil)
        }
        try await app.shutdownForTesting()
    }

    @Test("Liveness stays healthy while readiness fails")
    func testLivenessIndependentOfReadiness() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()
        app.readiness.closeMigrationsGateForTesting()

        // Liveness must not follow readiness: a dependency outage should pull
        // the replica from rotation, never restart-loop the process.
        try await app.test(.GET, "/health/live") { res async throws in
            #expect(res.status == .ok)

            let health = try res.content.decode(HealthResponse.self)
            #expect(health.status == "healthy")
        }
        try await app.shutdownForTesting()
    }

    // MARK: - Drain

    @Test("Draining replica reports 503 without probing dependencies")
    func testDrainingReportsUnready() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()

        app.readiness.beginDraining()

        try await app.test(.GET, "/health/ready") { res async throws in
            #expect(res.status == .serviceUnavailable)

            let health = try res.content.decode(HealthResponse.self)
            #expect(health.status == "draining")

            // Short-circuits: a replica on its way out should not spend probe
            // latency on dependencies it is about to drop.
            #expect(health.checks.map(\.name) == ["drain"])
        }
        try await app.shutdownForTesting()
    }

    @Test("Draining is idempotent so repeated SIGTERM logs once")
    func testBeginDrainingIsIdempotent() {
        let readiness = ReadinessState()

        #expect(readiness.isDraining == false)
        #expect(readiness.beginDraining() == true)
        #expect(readiness.beginDraining() == false)
        #expect(readiness.isDraining == true)
    }

    @Test("Draining replica still reports liveness")
    func testDrainingStaysLive() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)
        try await app.autoMigrate()
        app.readiness.beginDraining()

        // Killing a draining pod on a failed liveness probe would cut exactly
        // the in-flight work the drain exists to protect.
        try await app.test(.GET, "/health/live") { res async throws in
            #expect(res.status == .ok)
        }
        try await app.shutdownForTesting()
    }

    // MARK: - Build Identity

    @Test("Health endpoint carries build identity")
    func testHealthCarriesIdentity() async throws {
        let app = try await Application.makeForTesting()

        try await configure(app)

        // /health is documented as carrying build identity, and a blue/green
        // cutover uses instanceId to tell which replica answered.
        try await app.test(.GET, "/health") { res async throws in
            #expect(res.status == .ok)

            let health = try res.content.decode(HealthResponse.self)
            let identity = try #require(health.identity)
            #expect(identity.instanceId == app.instanceIdentity.instanceId.uuidString)
        }
        try await app.shutdownForTesting()
    }

}
