import FluentPostgresDriver
import Vapor

/// A server-enforced upper bound for every statement issued through a pooled
/// control-plane PostgreSQL connection.
///
/// PostgreSQL interprets a bare `statement_timeout` startup value as
/// milliseconds. Supplying it in the startup message means the bound is active
/// before the connection can execute its first query, and PostgresKit carries
/// the parameter to every connection the Fluent pool opens.
struct DatabaseStatementTimeout: Equatable, Sendable {
    static let environmentKey = "DATABASE_STATEMENT_TIMEOUT_MS"
    static let defaultMilliseconds = 300_000
    static let maximumMilliseconds = Int(Int32.max)

    let milliseconds: Int

    init(milliseconds: Int) throws {
        guard (1...Self.maximumMilliseconds).contains(milliseconds) else {
            throw DatabaseStatementTimeoutConfigurationError.invalidValue(String(milliseconds))
        }
        self.milliseconds = milliseconds
    }

    static func fromEnvironment() throws -> DatabaseStatementTimeout {
        try resolve(Environment.get(environmentKey))
    }

    /// Resolve an explicit environment value, or the documented five-minute
    /// default when it is absent. Split out so tests do not mutate the process
    /// environment while other suites read it concurrently.
    static func resolve(_ raw: String?) throws -> DatabaseStatementTimeout {
        guard let raw else {
            return try DatabaseStatementTimeout(milliseconds: defaultMilliseconds)
        }
        guard let milliseconds = Int(raw), (1...maximumMilliseconds).contains(milliseconds) else {
            throw DatabaseStatementTimeoutConfigurationError.invalidValue(raw)
        }
        return try DatabaseStatementTimeout(milliseconds: milliseconds)
    }

    /// Add the timeout to Postgres' startup message. Replacing an existing
    /// entry makes this safe to apply to a configuration assembled elsewhere
    /// (including the integration-test pool) without sending two values for the
    /// same setting.
    func apply(to configuration: inout SQLPostgresConfiguration) {
        configuration.coreConfiguration.options.additionalStartupParameters.removeAll {
            $0.0 == "statement_timeout"
        }
        configuration.coreConfiguration.options.additionalStartupParameters.append(
            ("statement_timeout", String(milliseconds))
        )
    }
}

enum DatabaseStatementTimeoutConfigurationError: Error, CustomStringConvertible {
    case invalidValue(String)

    var description: String {
        switch self {
        case .invalidValue(let raw):
            return
                "Invalid \(DatabaseStatementTimeout.environmentKey) value \"\(raw)\"; "
                + "expected an integer from 1 through "
                + "\(DatabaseStatementTimeout.maximumMilliseconds) milliseconds"
        }
    }
}
