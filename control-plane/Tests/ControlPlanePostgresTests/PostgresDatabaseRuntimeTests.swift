import Foundation
import PostgresNIO
import Testing

@testable import ControlPlanePostgres

@Suite("Native Postgres runtime", .serialized)
struct PostgresDatabaseRuntimeTests {
    @Test("Every leased physical connection has the serving timeout")
    func connectionInitializationAndReuse() async throws {
        try await withBareNativePostgresDatabase(
            maximumConnections: 1,
            statementTimeoutMilliseconds: 73
        ) { database in
            for _ in 0..<3 {
                try await database.withSession(operation: "test.connection_initialization") { session in
                    let rows = try await session.query(
                        "SELECT current_setting('statement_timeout') AS value",
                        operation: "test.connection_initialization.read"
                    )
                    #expect(try rows.first?.decode(String.self) == "73ms")
                }
            }
        }
    }

    @Test("Pool acquisition has a deadline and a timed-out waiter does not leak")
    func acquisitionTimeout() async throws {
        try await withBareNativePostgresDatabase(
            maximumConnections: 1,
            connectionAcquireTimeout: .milliseconds(100)
        ) { database in
            try await database.withSession(operation: "test.hold_only_connection") { _ in
                do {
                    try await database.withSession(operation: "test.timed_out_waiter") { _ in () }
                    Issue.record("Expected the nested connection acquisition to time out")
                } catch let error as PostgresDatabaseError {
                    guard case .connectionAcquisitionTimedOut = error else {
                        Issue.record("Unexpected PostgresDatabaseError: \(error)")
                        return
                    }
                }
            }

            try await database.healthCheck()
        }
    }

    @Test("Transactions commit on success and roll back on failure")
    func transactionCommitAndRollback() async throws {
        try await withBareNativePostgresDatabase { database in
            _ = try await database.withSession(operation: "test.transaction_schema") { session in
                try await session.command(
                    "CREATE TABLE native_transaction_probe (id UUID PRIMARY KEY)",
                    operation: "test.transaction_schema.create"
                )
            }

            let committedID = UUID()
            try await database.withTransaction(operation: "test.transaction_commit") { session in
                let rows = try await session.query(
                    "INSERT INTO native_transaction_probe (id) VALUES (\(committedID)) RETURNING id",
                    operation: "test.transaction_commit.insert"
                )
                #expect(rows.count == 1)
            }

            let rolledBackID = UUID()
            do {
                try await database.withTransaction(operation: "test.transaction_rollback") { session in
                    _ = try await session.query(
                        "INSERT INTO native_transaction_probe (id) VALUES (\(rolledBackID)) RETURNING id",
                        operation: "test.transaction_rollback.insert"
                    )
                    throw TransactionProbeFailure()
                }
                Issue.record("Expected transaction body to fail")
            } catch is TransactionProbeFailure {}

            try await database.withSession(operation: "test.transaction_verify") { session in
                let rows = try await session.query(
                    "SELECT id FROM native_transaction_probe ORDER BY id",
                    operation: "test.transaction_verify.read"
                )
                #expect(try rows.map { try $0.decode(UUID.self) } == [committedID])
            }
        }
    }

    @Test("A prepared-row decoder failure releases the only lease")
    func streamedDecodeFailureReleasesLease() async throws {
        try await withBareNativePostgresDatabase(maximumConnections: 1) { database in
            do {
                try await database.withSession(operation: "test.stream_decode_failure") { session in
                    _ = try await session.execute(
                        FailingRowDecoderStatement(),
                        operation: "test.stream_decode_failure.query"
                    )
                }
                Issue.record("Expected row decoding to fail")
            } catch is RowDecoderProbeFailure {}

            var lastError: (any Error)?
            for _ in 0..<20 {
                do {
                    try await database.healthCheck()
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            if let lastError { throw lastError }
        }
    }

    @Test("Cancelling a query releases the only lease")
    func cancellationReleasesLease() async throws {
        try await withBareNativePostgresDatabase(maximumConnections: 1) { database in
            let query = Task {
                try await database.withSession(operation: "test.cancel_query") { session in
                    _ = try await session.query(
                        "SELECT pg_sleep(10)",
                        operation: "test.cancel_query.sleep"
                    )
                }
            }
            try await Task.sleep(for: .milliseconds(100))
            query.cancel()
            do {
                try await query.value
                Issue.record("Expected the sleeping query to be cancelled")
            } catch {}

            try await database.healthCheck()
        }
    }

    @Test("A terminated physical connection is replaced and initialized")
    func reconnectInitialization() async throws {
        try await withBareNativePostgresDatabase(
            maximumConnections: 1,
            statementTimeoutMilliseconds: 81
        ) { database in
            do {
                try await database.withSession(operation: "test.terminate_connection") { session in
                    _ = try await session.query(
                        "SELECT pg_terminate_backend(pg_backend_pid())",
                        operation: "test.terminate_connection.query"
                    )
                }
            } catch {}

            var lastError: (any Error)?
            for _ in 0..<20 {
                do {
                    try await database.healthCheck()
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            if let lastError { throw lastError }
            try await database.withSession(operation: "test.reconnect_timeout") { session in
                let rows = try await session.query(
                    "SELECT current_setting('statement_timeout') AS value",
                    operation: "test.reconnect_timeout.read"
                )
                #expect(try rows.first?.decode(String.self) == "81ms")
            }
        }
    }
}

private struct TransactionProbeFailure: Error {}
private struct RowDecoderProbeFailure: Error {}

private struct FailingRowDecoderStatement: PostgresPreparedStatement {
    static let sql = "SELECT value FROM generate_series(1, 3) AS value ORDER BY value"
    typealias Row = Int

    func makeBindings() -> PostgresBindings { PostgresBindings() }

    func decodeRow(_ row: PostgresRow) throws -> Int {
        let value = try row.decode(Int.self)
        if value == 2 { throw RowDecoderProbeFailure() }
        return value
    }
}
