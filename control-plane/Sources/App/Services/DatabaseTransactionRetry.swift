import Fluent
import Foundation
import Metrics
import PostgresNIO
import Vapor

/// Only server-confirmed transaction aborts qualify. Cancellation (57014),
/// connection errors (class 08), and unknown outcomes never qualify: rerunning
/// after a lost COMMIT acknowledgement could duplicate a committed mutation.
enum DatabaseTransactionFailure: String, Sendable {
    case serializationFailure = "40001"
    case deadlock = "40P01"
    case lockNotAvailable = "55P03"

    static func classify(_ error: any Error) -> Self? {
        guard let state = sqlState(error) else { return nil }
        return Self(rawValue: state)
    }

    static func sqlState(_ error: any Error) -> String? {
        (error as? PSQLError)?.serverInfo?[.sqlState]
    }

    static func uniqueConstraint(_ error: any Error) -> String? {
        guard let postgres = error as? PSQLError,
            postgres.serverInfo?[.sqlState] == "23505"
        else { return nil }
        return postgres.serverInfo?[.constraintName]
    }
}

struct DatabaseTransactionRetryExhausted: AbortError {
    let sqlState: String
    var status: HTTPResponseStatus { .serviceUnavailable }
    var reason: String { "Database contention prevented this mutation. Retry the request." }
    var headers: HTTPHeaders { ["Retry-After": "1"] }
}

/// Opt-in whole-transaction retry. Each body must open and finish its complete
/// transaction, re-read mutable state and recreate/reset inserted Fluent models.
/// Keep external effects after the successful transaction: a rolled-back attempt
/// may write audit/outbox rows, but must not send a webhook or call an agent.
/// Nested calls execute once and propagate to the owner of the outer transaction.
enum DatabaseTransactionRetry {
    static let ipamConstraints: Set<String> = [
        "uq_vm_interface_addresses_network_address",
        "uq_sandbox_interface_addresses_network_address",
    ]

    static let workloadCreateConstraints = ipamConstraints.union(["uq_security_groups_default"])

    static func resetNewModel<M: Model>(_ model: M) {
        model.id = nil
        model._$idExists = false
    }

    /// Restore the insertion and convergence state Fluent mutates even when
    /// PostgreSQL rolls the attempt back. Call before every create attempt.
    static func resetNewResource<M: ConvergingResource>(_ resource: M, generation: Int64) {
        resetNewModel(resource)
        resource.generation = generation
    }

    static func run<T: Sendable>(
        on database: any Database,
        attempts: Int = 3,
        uniqueConstraints: Set<String> = [],
        operation: @escaping @Sendable (any Database) async throws -> T
    ) async throws -> T {
        try await retrying(on: database, attempts: attempts, uniqueConstraints: uniqueConstraints) {
            try await database.transaction(operation)
        }
    }

    static func retrying<T>(
        on database: any Database,
        attempts: Int = 3,
        uniqueConstraints: Set<String> = [],
        operation: () async throws -> T
    ) async throws -> T {
        precondition((1...5).contains(attempts), "Transaction retries must be bounded")
        // Fluent treats nested transactions as the same transaction: retrying
        // inside an aborted outer transaction cannot recover it.
        guard !database.inTransaction else { return try await operation() }
        for attempt in 1...attempts {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch {
                let failure = DatabaseTransactionFailure.classify(error)
                let unique = DatabaseTransactionFailure.uniqueConstraint(error)
                guard failure != nil || unique.map(uniqueConstraints.contains) == true else { throw error }
                let state = DatabaseTransactionFailure.sqlState(error)!
                Counter(
                    label: "strato_database_transaction_aborts_total",
                    dimensions: [
                        ("sqlstate_class", String(state.prefix(2))),
                        ("outcome", attempt == attempts ? "exhausted" : "retry"),
                    ]
                ).increment()
                guard attempt < attempts else {
                    throw DatabaseTransactionRetryExhausted(sqlState: state)
                }
                // Release the transaction/connection before backoff. Cancellation
                // interrupts the sleep and prevents another mutation attempt.
                try await Task.sleep(for: .milliseconds(Int.random(in: 10...30) * (1 << (attempt - 1))))
            }
        }
        preconditionFailure("The final attempt returns or throws")
    }
}
