import Foundation
import PostgresNIO
import Synchronization

/// Opt-in query counting used by integration tests that enforce batching.
/// SQL text and bindings are never retained.
public final class PostgresQueryHistory: Sendable {
    private struct State: Sendable {
        var enabled = false
        var count = 0
    }

    private let state = Mutex(State())

    public init() {}

    public func start() {
        state.withLock {
            $0.enabled = true
            $0.count = 0
        }
    }

    public func stop() {
        state.withLock { $0.enabled = false }
    }

    public var count: Int { state.withLock { $0.count } }

    fileprivate func record() {
        state.withLock {
            guard $0.enabled else { return }
            $0.count += 1
        }
    }
}

/// A scoped, fully-draining SQL context for domain modules that are still
/// being split out of the Vapor target. It exposes neither a client nor a
/// connection and keeps a transaction pinned when nested operations receive
/// the transaction context.
public struct PostgresStoreContext: Sendable {
    public struct Dialect: Sendable {
        public let name = "postgresql"
    }

    public var dialect: Dialect { Dialect() }

    private enum Backend: Sendable {
        case database(PostgresDatabase)
        case session(PostgresSession)
    }

    private let backend: Backend
    public let history: PostgresQueryHistory

    public init(database: PostgresDatabase) {
        backend = .database(database)
        history = PostgresQueryHistory()
    }

    private init(session: PostgresSession, history: PostgresQueryHistory) {
        backend = .session(session)
        self.history = history
    }

    public func transaction<Result: Sendable>(
        isolation: PostgresTransactionIsolation = .readCommitted,
        _ body: @escaping @Sendable (PostgresStoreContext) async throws -> Result
    ) async throws -> Result {
        switch backend {
        case .database(let database):
            return try await database.withTransaction(
                operation: "domain.transaction", isolation: isolation
            ) { session in
                try await body(PostgresStoreContext(session: session, history: history))
            }
        case .session(let session):
            return try await session.withTransaction(isolation: isolation) { transaction in
                try await body(PostgresStoreContext(session: transaction, history: history))
            }
        }
    }

    public func raw(_ query: PostgresSQLQuery) -> PostgresStoreQuery {
        PostgresStoreQuery(context: self, query: query)
    }

    fileprivate func execute(_ query: PostgresSQLQuery) async throws -> [PostgresRow] {
        history.record()
        let compiled = try query.postgresQuery()
        switch backend {
        case .database(let database):
            return try await database.withSession(operation: "domain.query") { session in
                try await session.query(compiled, operation: "domain.query.execute")
            }
        case .session(let session):
            return try await session.query(compiled, operation: "domain.query.execute")
        }
    }

#if DEBUG
    /// Test-only bridge for legacy integration helpers while their call sites
    /// move to intent-oriented persistence modules.
    package var testIAMPersistence: IAMPersistence {
        switch backend {
        case .database(let database):
            return IAMPersistence(database: database)
        case .session:
            preconditionFailure("A test IAM module cannot escape a transaction session")
        }
    }

    package var testWorkloadsPersistence: WorkloadsPersistence {
        switch backend {
        case .database(let database):
            return WorkloadsPersistence(database: database)
        case .session:
            preconditionFailure("A test workload module cannot escape a transaction session")
        }
    }
#endif
}

public struct PostgresStoreQuery: Sendable {
    fileprivate let context: PostgresStoreContext
    fileprivate let query: PostgresSQLQuery

    public func all<Value: Decodable & Sendable>(decoding type: Value.Type) async throws -> [Value] {
        try await context.execute(query).map { try PostgresRecordDecoder.decode(type, from: $0) }
    }

    public func first<Value: Decodable & Sendable>(decoding type: Value.Type) async throws -> Value? {
        try await context.execute(query).first.map { try PostgresRecordDecoder.decode(type, from: $0) }
    }

    public func first<Value: PostgresDecodable & Sendable>(
        decodingColumn column: String,
        as type: Value.Type
    ) async throws -> Value? {
        try await first()?.decode(column: column, as: type)
    }

    public func all() async throws -> [PostgresStoreRow] {
        try await context.execute(query).map(PostgresStoreRow.init)
    }

    public func first() async throws -> PostgresStoreRow? {
        try await context.execute(query).first.map(PostgresStoreRow.init)
    }

    @discardableResult
    public func run() async throws -> Int {
        try await context.execute(query).count
    }
}

public struct PostgresStoreRow: Sendable {
    private let row: PostgresRandomAccessRow

    fileprivate init(_ row: PostgresRow) {
        self.row = row.makeRandomAccess()
    }

    public func decode<Value: PostgresDecodable & Sendable>(
        column: String, as type: Value.Type
    ) throws -> Value {
        try row[column].decode(type)
    }
}
