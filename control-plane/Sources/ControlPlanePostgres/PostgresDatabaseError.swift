import Foundation

public enum PostgresDatabaseError: Error, CustomStringConvertible, Sendable {
    case invalidMaximumConnections(Int)
    case invalidConnectionAcquireTimeout(Duration)
    case invalidStatementTimeout(Int)
    case alreadyShutdown
    case connectionAcquisitionTimedOut(Duration)

    public var description: String {
        switch self {
        case .invalidMaximumConnections(let value):
            "DATABASE_MAX_CONNECTIONS must be greater than zero; received \(value)"
        case .invalidConnectionAcquireTimeout(let value):
            "DATABASE_CONNECTION_ACQUIRE_TIMEOUT_MS must be greater than zero; received \(value)"
        case .invalidStatementTimeout(let value):
            "DATABASE_STATEMENT_TIMEOUT_MS must be between 1 and \(Int(Int32.max)); received \(value)"
        case .alreadyShutdown:
            "The PostgreSQL client has already been shut down"
        case .connectionAcquisitionTimedOut(let timeout):
            "Timed out after \(timeout) while waiting for a PostgreSQL connection"
        }
    }
}

/// Retains both failures when transaction cleanup also fails. Callers can map
/// the primary database error while logs still retain the underlying causes.
public struct PostgresTransactionFailure: Error, Sendable {
    public let primary: any Error
    public let rollback: (any Error)?

    public init(primary: any Error, rollback: (any Error)? = nil) {
        self.primary = primary
        self.rollback = rollback
    }
}
