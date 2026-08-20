import Logging
import Metrics
import PostgresNIO
import Tracing

/// Scoped access to one initialized physical PostgreSQL connection.
///
/// A session never exposes its connection or a streaming row sequence. Every
/// operation drains its rows before returning, so a connection lease cannot be
/// retained accidentally by a controller or background worker.
public struct PostgresSession: Sendable {
    private let connection: PostgresConnection
    private let logger: Logger

    init(connection: PostgresConnection, logger: Logger) {
        self.connection = connection
        self.logger = logger
    }

    /// Execute a stable prepared statement and fully drain its result.
    public func execute<Statement: PostgresPreparedStatement>(
        _ statement: Statement,
        operation: PostgresOperation
    ) async throws -> [Statement.Row] where Statement.Row: Sendable {
        try await observe(operation: operation) {
            let rows = try await connection.execute(statement, logger: logger)
            var result: [Statement.Row] = []
            for try await row in rows {
                result.append(row)
            }
            return result
        }
    }

    /// Execute a stable prepared statement that returns no rows.
    @discardableResult
    public func execute<Statement: PostgresPreparedStatement>(
        _ statement: Statement,
        operation: PostgresOperation
    ) async throws -> String where Statement.Row == Void {
        try await observe(operation: operation) {
            // PostgresNIO's command-tag overload reads the tag before its row
            // stream has been consumed. Select the sequence overload
            // explicitly so even no-row prepared statements drain the stream
            // before this scoped connection can return to the pool.
            let rows: AsyncThrowingMapSequence<PostgresRowSequence, Void> = try await connection.execute(
                statement,
                logger: logger
            )
            for try await _ in rows {}
            return "completed"
        }
    }

    public func query(_ query: PostgresQuery, operation: PostgresOperation) async throws -> [PostgresRow] {
        try await observe(operation: operation) {
            try await connection.query(query, logger: logger).collect()
        }
    }

    @discardableResult
    public func command(_ sql: String, operation: PostgresOperation) async throws -> String {
        try await observe(operation: operation) {
            let rows = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
            for try await _ in rows {}
            return "completed"
        }
    }

    public func withTransaction<Result: Sendable>(
        isolation: PostgresTransactionIsolation = .readCommitted,
        _ body: (PostgresSession) async throws -> Result
    ) async throws -> Result {
        try await command(isolation.beginSQL, operation: "transaction.begin")
        do {
            let result = try await body(self)
            try await command("COMMIT", operation: "transaction.commit")
            return result
        } catch {
            let primary = error
            do {
                try await command("ROLLBACK", operation: "transaction.rollback")
            } catch {
                throw PostgresTransactionFailure(primary: primary, rollback: error)
            }
            throw primary
        }
    }

    private func observe<Result: Sendable>(
        operation: PostgresOperation,
        _ body: () async throws -> Result
    ) async throws -> Result {
        let clock = ContinuousClock()
        let start = clock.now
        return try await withSpan("postgres.\(operation.name)", ofKind: .client) { span in
            span.attributes["db.system"] = "postgresql"
            span.attributes["db.operation.name"] = operation.name
            do {
                let result = try await body()
                record(operation: operation, outcome: "success", duration: start.duration(to: clock.now))
                return result
            } catch {
                span.attributes["error.type"] = String(reflecting: type(of: error))
                if let error = error as? PSQLError {
                    span.attributes["db.response.status_code"] = error.serverInfo?[.sqlState] ?? error.code.description
                }
                record(operation: operation, outcome: "error", duration: start.duration(to: clock.now))
                throw error
            }
        }
    }

    private func record(operation: PostgresOperation, outcome: String, duration: Duration) {
        Counter(
            label: "strato_postgres_operations_total",
            dimensions: [("operation", operation.name), ("outcome", outcome)]
        ).increment()
        Timer(
            label: "strato_postgres_operation_duration_seconds",
            dimensions: [("operation", operation.name)]
        ).recordSeconds(duration.seconds)
    }
}

private extension Duration {
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
