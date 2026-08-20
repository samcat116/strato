import AppTestSupport
import Foundation
import Logging
import PostgresNIO
import Testing

@testable import ControlPlanePostgres

@Suite("Native application-settings persistence", .serialized)
struct AppSettingsPersistenceTests {
    @Test("create-if-absent returns immutable database timestamps")
    func createAndLookup() async throws {
        try await withDatabase { database in
            let settings = ControlPlanePersistence(database: database).appSettings
            let created = try await settings.createIfAbsent(key: "probe", value: "first")
            let loaded = try #require(try await settings.setting(forKey: "probe"))

            #expect(created == loaded)
            #expect(created.value == "first")
            #expect(created.createdAt != nil)
            #expect(created.updatedAt != nil)
        }
    }

    @Test("concurrent first writers converge on one stored value")
    func concurrentInsert() async throws {
        try await withDatabase { database in
            let settings = ControlPlanePersistence(database: database).appSettings
            let snapshots = try await withThrowingTaskGroup(of: AppSettingSnapshot.self) { group in
                group.addTask { try await settings.createIfAbsent(key: "race", value: "one") }
                group.addTask { try await settings.createIfAbsent(key: "race", value: "two") }
                var values: [AppSettingSnapshot] = []
                for try await snapshot in group { values.append(snapshot) }
                return values
            }

            #expect(snapshots.count == 2)
            #expect(Set(snapshots.map(\.id)).count == 1)
            #expect(Set(snapshots.map(\.value)).count == 1)
        }
    }

    private func withDatabase(
        _ test: (ControlPlanePostgres.PostgresDatabase) async throws -> Void
    ) async throws {
        let name = try await PostgresTestDatabases.shared.createBareDatabaseForTest()
        let configuration = try PostgresTestDatabases.nativeConfiguration(database: name)
        var logger = Logger(label: "strato.test.native-postgres")
        logger.logLevel = .error
        let database = ControlPlanePostgres.PostgresDatabase(
            configuration: configuration,
            eventLoopGroup: PostgresTestDatabases.appEventLoopGroup,
            logger: logger
        )
        do {
            try await database.start()
            _ = try await database.withSession(operation: "test.schema") { session in
                try await session.execute(CreateAppSettingsTable(), operation: "test.schema.create")
            }
            try await test(database)
            await database.shutdown()
            await PostgresTestDatabases.shared.dropDatabase(name)
        } catch {
            await database.shutdown()
            await PostgresTestDatabases.shared.dropDatabase(name)
            throw error
        }
    }
}

private struct CreateAppSettingsTable: PostgresPreparedStatement {
    static let sql = """
        CREATE TABLE app_settings (
            id uuid PRIMARY KEY,
            key text NOT NULL,
            value text NOT NULL,
            created_at timestamp with time zone,
            updated_at timestamp with time zone,
            CONSTRAINT "uq:app_settings.key" UNIQUE (key)
        )
        """

    typealias Row = Void

    func makeBindings() -> PostgresBindings { PostgresBindings() }
    func decodeRow(_ row: PostgresRow) throws {}
}
