import AppTestSupport
import Fluent
import Testing
import Vapor

@testable import App

@Suite("Database bootstrap", .postgresFixture)
struct DatabaseBootstrapTests {
    @Test("Production registers PostgreSQL before attaching model middleware and migrating")
    func productionStartsWithoutRegisteredDatabase() async throws {
        let databaseName = try await PostgresTestDatabases.shared.createBareDatabaseForTest()
        let app = try await Application.make(.production, .shared(PostgresTestDatabases.appEventLoopGroup))
        let scope = try PostgresFixtureScope.requireCurrent()
        await scope.register(app)

        do {
            #expect(app.databases.configuration(for: .psql) == nil)
            app.controlPlaneConfiguration = try await ControlPlaneConfiguration.load(
                environmentVariables: [
                    "DATABASE_HOST": Environment.get("DATABASE_HOST") ?? "localhost",
                    "DATABASE_PORT": Environment.get("DATABASE_PORT") ?? "5432",
                    "DATABASE_USERNAME": Environment.get("DATABASE_USERNAME") ?? "strato",
                    "DATABASE_PASSWORD": Environment.get("DATABASE_PASSWORD") ?? "strato_password",
                    "DATABASE_NAME": databaseName,
                    // This is a disposable local fixture, not the hosted database.
                    "DATABASE_TLS": "disable",
                ],
                for: .production)

            try await app.bootstrapDatabase()

            let configuration = try #require(app.databases.configuration(for: .psql))
            #expect(configuration.middleware.contains { $0 is UserIdentityMiddleware })
            #expect(try await User.query(on: app.db).count() == 0)
        } catch {
            try? await app.asyncShutdown()
            await PostgresTestDatabases.shared.dropDatabase(databaseName)
            throw error
        }

        try await app.asyncShutdown()
        await PostgresTestDatabases.shared.dropDatabase(databaseName)
    }

    @Test("Testing keeps its preconfigured fixture database and attaches identity middleware")
    func testingKeepsFixtureDatabase() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            // If bootstrap replaces the test driver, it cannot migrate this host.
            app.controlPlaneConfiguration = try await ControlPlaneConfiguration.load(
                environmentVariables: ["DATABASE_HOST": "invalid.example", "DATABASE_PORT": "1"],
                for: .testing)
            try await app.bootstrapDatabase()

            let configuration = try #require(app.databases.configuration(for: .psql))
            #expect(configuration.middleware.contains { $0 is UserIdentityMiddleware })
            #expect(try await User.query(on: app.db).count() == 0)
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}
