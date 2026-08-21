import ControlPlanePostgres
import PostgresNIO
import Testing

@Suite("Postgres database configuration")
struct PostgresDatabaseConfigurationTests {
    @Test("uses the required pool defaults")
    func defaults() throws {
        let configuration = try PostgresDatabase.Configuration(
            hostname: "localhost",
            username: "strato",
            password: "secret",
            database: "strato_test",
            tls: .disable,
            statementTimeoutMilliseconds: 300_000
        )

        #expect(configuration.maximumConnections == 20)
        #expect(configuration.connectionAcquireTimeout == .seconds(10))
    }

    @Test("rejects an empty pool")
    func maximumConnectionsMustBePositive() {
        #expect(throws: PostgresDatabaseError.self) {
            _ = try PostgresDatabase.Configuration(
                hostname: "localhost",
                username: "strato",
                password: nil,
                database: "strato_test",
                tls: .disable,
                maximumConnections: 0,
                statementTimeoutMilliseconds: 300_000
            )
        }
    }

    @Test("rejects non-positive acquisition deadlines")
    func acquisitionTimeoutMustBePositive() {
        #expect(throws: PostgresDatabaseError.self) {
            _ = try PostgresDatabase.Configuration(
                hostname: "localhost",
                username: "strato",
                password: nil,
                database: "strato_test",
                tls: .disable,
                connectionAcquireTimeout: .zero,
                statementTimeoutMilliseconds: 300_000
            )
        }
    }

    @Test("rejects statement timeouts PostgreSQL cannot represent")
    func statementTimeoutRange() {
        #expect(throws: PostgresDatabaseError.self) {
            _ = try PostgresDatabase.Configuration(
                hostname: "localhost",
                username: "strato",
                password: nil,
                database: "strato_test",
                tls: .disable,
                statementTimeoutMilliseconds: 0
            )
        }
    }
}
