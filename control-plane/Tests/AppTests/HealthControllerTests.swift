import Testing
import Vapor
import VaporTesting
@testable import App

@Suite("HealthController Tests")
struct HealthControllerTests {

    // MARK: - Basic Health Check Tests

    @Test("Health endpoint returns 200 OK")
    func testHealthEndpoint() async throws {
        let app = try await Application.makeForTesting()
        defer { app.shutdown() }

        try await configure(app)

        try await app.test(.GET, "/health") { res async in
            #expect(res.status == .ok)
        }
    }

    // MARK: - Liveness Check Tests

    @Test("Liveness endpoint returns healthy status")
    func testLivenessHealthy() async throws {
        let app = try await Application.makeForTesting()
        defer { app.shutdown() }

        try await configure(app)

        try await app.test(.GET, "/health/live") { res async in
            #expect(res.status == .ok)

            let health = try res.content.decode(HealthResponse.self)
            #expect(health.status == "healthy")
            #expect(health.checks.count > 0)

            let appCheck = health.checks.first { $0.name == "application" }
            #expect(appCheck != nil)
            #expect(appCheck?.status == "up")
            #expect(appCheck?.error == nil)
        }
    }

    @Test("Liveness endpoint includes timestamp")
    func testLivenessTimestamp() async throws {
        let app = try await Application.makeForTesting()
        defer { app.shutdown() }

        try await configure(app)

        try await app.test(.GET, "/health/live") { res async in
            let health = try res.content.decode(HealthResponse.self)

            // Timestamp should be recent (within last minute)
            let now = Date()
            let timeDifference = abs(now.timeIntervalSince(health.timestamp))
            #expect(timeDifference < 60)
        }
    }

    // MARK: - Readiness Check Tests

    @Test("Readiness endpoint returns healthy when database is available")
    func testReadinessHealthy() async throws {
        let app = try await Application.makeForTesting()
        defer { app.shutdown() }

        try await configure(app)
        try await app.autoMigrate()

        try await app.test(.GET, "/health/ready") { res async in
            #expect(res.status == .ok)

            let health = try res.content.decode(HealthResponse.self)
            #expect(health.status == "healthy")

            let dbCheck = health.checks.first { $0.name == "database" }
            #expect(dbCheck != nil)
            #expect(dbCheck?.status == "up")
            #expect(dbCheck?.error == nil)
        }
    }

    @Test("Readiness endpoint returns unhealthy when database is unavailable")
    func testReadinessUnhealthyDatabase() async throws {
        let app = try await Application.makeForTesting()
        defer { app.shutdown() }

        try await configure(app)
        // Don't run migrations to simulate database unavailability
        // The test database won't have the vms table

        try await app.test(.GET, "/health/ready") { res async in
            #expect(res.status == .ok) // Still returns 200, but with unhealthy status

            let health = try res.content.decode(HealthResponse.self)
            #expect(health.status == "unhealthy")

            let dbCheck = health.checks.first { $0.name == "database" }
            #expect(dbCheck != nil)
            #expect(dbCheck?.status == "down")
            #expect(dbCheck?.error != nil)
        }
    }

    @Test("Readiness endpoint includes timestamp")
    func testReadinessTimestamp() async throws {
        let app = try await Application.makeForTesting()
        defer { app.shutdown() }

        try await configure(app)
        try await app.autoMigrate()

        try await app.test(.GET, "/health/ready") { res async in
            let health = try res.content.decode(HealthResponse.self)

            // Timestamp should be recent (within last minute)
            let now = Date()
            let timeDifference = abs(now.timeIntervalSince(health.timestamp))
            #expect(timeDifference < 60)
        }
    }

    // MARK: - Response Structure Tests

    @Test("Health response has correct structure")
    func testHealthResponseStructure() async throws {
        let app = try await Application.makeForTesting()
        defer { app.shutdown() }

        try await configure(app)

        try await app.test(.GET, "/health/live") { res async in
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
    }

    @Test("Health check includes error message when check fails")
    func testHealthCheckErrorMessage() async throws {
        let app = try await Application.makeForTesting()
        defer { app.shutdown() }

        try await configure(app)
        // Don't run migrations to trigger database error

        try await app.test(.GET, "/health/ready") { res async in
            let health = try res.content.decode(HealthResponse.self)

            let dbCheck = health.checks.first { $0.name == "database" }
            #expect(dbCheck != nil)
            #expect(dbCheck?.status == "down")
            #expect(dbCheck?.error != nil)
            #expect(!dbCheck!.error!.isEmpty)
        }
    }

    // MARK: - Content Type Tests

    @Test("Health endpoints return JSON content")
    func testHealthEndpointsReturnJSON() async throws {
        let app = try await Application.makeForTesting()
        defer { app.shutdown() }

        try await configure(app)
        try await app.autoMigrate()

        try await app.test(.GET, "/health/live") { res async in
            let contentType = res.headers.contentType
            #expect(contentType != nil)
            #expect(contentType?.type == .application)
            #expect(contentType?.subType == "json")
        }

        try await app.test(.GET, "/health/ready") { res async in
            let contentType = res.headers.contentType
            #expect(contentType != nil)
            #expect(contentType?.type == .application)
            #expect(contentType?.subType == "json")
        }
    }

    // MARK: - Multiple Checks Tests

    @Test("Readiness endpoint can have multiple checks")
    func testMultipleChecks() async throws {
        let app = try await Application.makeForTesting()
        defer { app.shutdown() }

        try await configure(app)
        try await app.autoMigrate()

        try await app.test(.GET, "/health/ready") { res async in
            let health = try res.content.decode(HealthResponse.self)

            // Currently only database check, but structure supports multiple
            #expect(health.checks.count >= 1)

            // All check names should be unique
            let checkNames = health.checks.map { $0.name }
            let uniqueNames = Set(checkNames)
            #expect(checkNames.count == uniqueNames.count)
        }
    }

    // MARK: - Overall Status Tests

    @Test("Overall status is healthy when all checks pass")
    func testOverallStatusHealthy() async throws {
        let app = try await Application.makeForTesting()
        defer { app.shutdown() }

        try await configure(app)
        try await app.autoMigrate()

        try await app.test(.GET, "/health/ready") { res async in
            let health = try res.content.decode(HealthResponse.self)

            #expect(health.status == "healthy")

            // All checks should be up
            for check in health.checks {
                #expect(check.status == "up")
            }
        }
    }

    @Test("Overall status is unhealthy when any check fails")
    func testOverallStatusUnhealthy() async throws {
        let app = try await Application.makeForTesting()
        defer { app.shutdown() }

        try await configure(app)
        // Don't migrate to cause database check to fail

        try await app.test(.GET, "/health/ready") { res async in
            let health = try res.content.decode(HealthResponse.self)

            #expect(health.status == "unhealthy")

            // At least one check should be down
            let failedChecks = health.checks.filter { $0.status == "down" }
            #expect(failedChecks.count > 0)
        }
    }
}
