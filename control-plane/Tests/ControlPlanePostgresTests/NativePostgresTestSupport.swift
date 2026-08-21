import AppTestSupport
import Logging

@testable import ControlPlanePostgres

func withBareNativePostgresDatabase(
    maximumConnections: Int = 1,
    connectionAcquireTimeout: Duration = .seconds(10),
    statementTimeoutMilliseconds: Int = 300_000,
    _ body: (ControlPlanePostgres.PostgresDatabase) async throws -> Void
) async throws {
    let name = try await PostgresTestDatabases.shared.createBareDatabaseForTest()
    var configuration = try PostgresTestDatabases.nativeConfiguration(database: name)
    configuration.maximumConnections = maximumConnections
    configuration.connectionAcquireTimeout = connectionAcquireTimeout
    configuration.statementTimeoutMilliseconds = statementTimeoutMilliseconds

    var logger = Logger(label: "strato.test.native-postgres")
    logger.logLevel = .error
    let database = ControlPlanePostgres.PostgresDatabase(
        configuration: configuration,
        eventLoopGroup: PostgresTestDatabases.appEventLoopGroup,
        logger: logger
    )

    do {
        try await database.start()
        try await body(database)
        await database.shutdown()
        await PostgresTestDatabases.shared.dropDatabase(name)
    } catch {
        await database.shutdown()
        await PostgresTestDatabases.shared.dropDatabase(name)
        throw error
    }
}

func migrationOptions(
    runMigrations: Bool = true,
    servingStatementTimeoutMilliseconds: Int = 300_000,
    migrationStatementTimeoutMilliseconds: Int = 0
) -> SchemaMigrator.Options {
    .init(
        runMigrations: runMigrations,
        lockTimeout: .seconds(10),
        lockPollInterval: .milliseconds(10),
        servingStatementTimeoutMilliseconds: servingStatementTimeoutMilliseconds,
        migrationStatementTimeoutMilliseconds: migrationStatementTimeoutMilliseconds
    )
}

func testLogger() -> Logger {
    var logger = Logger(label: "strato.test.schema-migrator")
    logger.logLevel = .error
    return logger
}
