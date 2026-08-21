import Foundation
import Logging
import Metrics
import NIOCore
import PostgresNIO
import Synchronization

/// Owns Strato's native PostgresNIO client and its connection lifecycle.
public final class PostgresDatabase: Sendable {
    public struct Configuration: Sendable {
        public static let defaultMaximumConnections = 20
        public static let defaultConnectionAcquireTimeout: Duration = .seconds(10)

        public var hostname: String
        public var port: Int
        public var username: String
        public var password: String?
        public var database: String
        public var tls: PostgresClient.Configuration.TLS
        public var maximumConnections: Int
        public var connectionAcquireTimeout: Duration
        public var statementTimeoutMilliseconds: Int

        public init(
            hostname: String,
            port: Int = 5432,
            username: String,
            password: String?,
            database: String,
            tls: PostgresClient.Configuration.TLS,
            maximumConnections: Int = Self.defaultMaximumConnections,
            connectionAcquireTimeout: Duration = Self.defaultConnectionAcquireTimeout,
            statementTimeoutMilliseconds: Int
        ) throws {
            guard maximumConnections > 0 else {
                throw PostgresDatabaseError.invalidMaximumConnections(maximumConnections)
            }
            guard connectionAcquireTimeout > .zero else {
                throw PostgresDatabaseError.invalidConnectionAcquireTimeout(connectionAcquireTimeout)
            }
            guard (1...Int(Int32.max)).contains(statementTimeoutMilliseconds) else {
                throw PostgresDatabaseError.invalidStatementTimeout(statementTimeoutMilliseconds)
            }
            self.hostname = hostname
            self.port = port
            self.username = username
            self.password = password
            self.database = database
            self.tls = tls
            self.maximumConnections = maximumConnections
            self.connectionAcquireTimeout = connectionAcquireTimeout
            self.statementTimeoutMilliseconds = statementTimeoutMilliseconds
        }

        func clientConfiguration() -> PostgresClient.Configuration {
            var configuration = PostgresClient.Configuration(
                host: hostname,
                port: port,
                username: username,
                password: password,
                database: database,
                tls: tls
            )
            configuration.options.minimumConnections = 0
            configuration.options.maximumConnections = maximumConnections
            return configuration
        }
    }

    private enum LifecycleState: Sendable {
        case idle
        case running(Task<Void, Never>)
        case shutdown
    }

    private enum AcquisitionEvent: Sendable {
        case acquired
        case operationFinished
    }

    private enum AcquisitionWaitResult: Sendable {
        case acquired
        case operationFinished
        case timeout
        case cancelled
    }

    private let client: PostgresClient
    private let logger: Logger
    private let connectionAcquireTimeout: Duration
    private let statementTimeoutMilliseconds: Int
    private let lifecycle = Mutex<LifecycleState>(.idle)
    private let initializedConnections = Mutex<Set<PostgresConnection.ID>>([])

    public init(
        configuration: Configuration,
        eventLoopGroup: any EventLoopGroup,
        logger: Logger
    ) {
        self.client = PostgresClient(
            configuration: configuration.clientConfiguration(),
            eventLoopGroup: eventLoopGroup,
            backgroundLogger: logger
        )
        self.logger = logger
        self.connectionAcquireTimeout = configuration.connectionAcquireTimeout
        self.statementTimeoutMilliseconds = configuration.statementTimeoutMilliseconds
    }

    /// Start the client's structured run task and prove a usable connection.
    public func start() async throws {
        let startResult: Result<Void, PostgresDatabaseError> = lifecycle.withLock { state in
            switch state {
            case .idle:
                let task = Task { [client] in await client.run() }
                state = .running(task)
                return .success(())
            case .running:
                return .success(())
            case .shutdown:
                return .failure(.alreadyShutdown)
            }
        }
        try startResult.get()

        do {
            try await healthCheck()
        } catch {
            await shutdown()
            throw error
        }
    }

    public func healthCheck() async throws {
        try await withSession(operation: "health_check") { session in
            let rows = try await session.query("SELECT 1 AS readiness", operation: "health_check.query")
            guard rows.count == 1 else {
                throw PostgresHealthCheckError.unexpectedRowCount(rows.count)
            }
        }
    }

    /// Lease one initialized connection for the closure's lifetime.
    public func withSession<Value: Sendable>(
        operation: PostgresOperation,
        _ body: @escaping @Sendable (PostgresSession) async throws -> Value
    ) async throws -> Value {
        let (acquisitionEvents, acquisitionContinuation) = AsyncStream.makeStream(
            of: AcquisitionEvent.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let (operationPermission, permissionContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )

        // `PostgresClient` exposes scoped leases but not a public standalone
        // acquire operation. Signal as soon as its closure receives a lease,
        // then hold that closure on a gate while only acquisition races the
        // configured deadline. Once acquired, the caller's operation has no
        // artificial wall-clock timeout.
        let operationTask = Task { [self] () -> Result<Value, any Error> in
            do {
                let value = try await client.withConnection { connection in
                    acquisitionContinuation.yield(.acquired)
                    acquisitionContinuation.finish()

                    var iterator = operationPermission.makeAsyncIterator()
                    guard await iterator.next() != nil else { throw CancellationError() }
                    return try await withTaskCancellationHandler {
                        try Task.checkCancellation()
                        try await initializeIfNeeded(connection)
                        return try await body(
                            PostgresSession(connection: connection, logger: logger))
                    } onCancel: {
                        // PostgresNIO does not cancel an already-issued query
                        // when its awaiting Swift task is cancelled. Closing
                        // the leased physical connection interrupts the server
                        // operation and ensures the pool replaces, rather than
                        // leaks, that lease.
                        let _: EventLoopFuture<Void> = connection.close()
                    }
                }
                return .success(value)
            } catch {
                acquisitionContinuation.yield(.operationFinished)
                acquisitionContinuation.finish()
                return .failure(error)
            }
        }

        let timeout = connectionAcquireTimeout
        let result = await withTaskGroup(of: AcquisitionWaitResult.self) { group in
            group.addTask {
                var iterator = acquisitionEvents.makeAsyncIterator()
                switch await iterator.next() {
                case .acquired:
                    return .acquired
                case .operationFinished:
                    return .operationFinished
                case nil:
                    return .cancelled
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timeout
                } catch {
                    return .cancelled
                }
            }

            let first = await group.next()!
            group.cancelAll()
            return first
        }

        switch result {
        case .acquired:
            permissionContinuation.yield()
            permissionContinuation.finish()
            return try await withTaskCancellationHandler {
                try await operationTask.value.get()
            } onCancel: {
                operationTask.cancel()
                permissionContinuation.finish()
            }
        case .operationFinished:
            permissionContinuation.finish()
            return try await operationTask.value.get()
        case .timeout:
            Counter(label: "strato_postgres_connection_acquisition_timeouts_total").increment()
            operationTask.cancel()
            permissionContinuation.finish()
            _ = await operationTask.value
            throw PostgresDatabaseError.connectionAcquisitionTimedOut(timeout)
        case .cancelled:
            operationTask.cancel()
            permissionContinuation.finish()
            _ = await operationTask.value
            throw CancellationError()
        }
    }

    /// Run a transaction without automatic retries. Isolation SQL comes from a
    /// closed enum; application values never become SQL fragments.
    public func withTransaction<Result: Sendable>(
        operation: PostgresOperation,
        isolation: PostgresTransactionIsolation = .readCommitted,
        _ body: @escaping @Sendable (PostgresSession) async throws -> Result
    ) async throws -> Result {
        try await withSession(operation: operation) { session in
            try await session.withTransaction(isolation: isolation, body)
        }
    }

    /// Cancel and await the client run task. The caller must drain tracked
    /// background work first; Vapor registers this lifecycle handler before its
    /// background-task handler so reverse shutdown order enforces that rule.
    public func shutdown() async {
        let task = lifecycle.withLock { state -> Task<Void, Never>? in
            switch state {
            case .idle:
                state = .shutdown
                return nil
            case .running(let task):
                state = .shutdown
                return task
            case .shutdown:
                return nil
            }
        }
        task?.cancel()
        await task?.value
    }

    private func initializeIfNeeded(_ connection: PostgresConnection) async throws {
        let isNew = initializedConnections.withLock { ids in
            ids.insert(connection.id).inserted
        }
        guard isNew else { return }

        do {
            let timeout = String(statementTimeoutMilliseconds)
            let rows = try await connection.query(
                "SELECT set_config('statement_timeout', \(timeout), false)",
                logger: logger
            )
            for try await _ in rows {}
            connection.closeFuture.whenComplete { [self, id = connection.id] _ in
                _ = initializedConnections.withLock { ids in
                    ids.remove(id)
                }
            }
        } catch {
            _ = initializedConnections.withLock { ids in
                ids.remove(connection.id)
            }
            throw error
        }
    }
}

public enum PostgresHealthCheckError: Error, Sendable {
    case unexpectedRowCount(Int)
}
