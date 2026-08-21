import NIOSSL
import PostgresNIO
import Vapor

/// How the control plane negotiates TLS on its PostgreSQL connection.
///
/// Postgres traffic carries the database credentials and every byte of
/// application data, so it must be encrypted on any deployment where the
/// database is reachable off-box (a remote managed Postgres, or the Helm chart
/// pointed at an external database). The mode is read from `DATABASE_TLS` and
/// defaults to ``require`` everywhere except development, where the database is
/// a throwaway container on a private Docker network and demanding a cert would
/// only add friction. See issue #56.
enum DatabaseTLSMode: String, Sendable {
    /// No TLS. Only appropriate when DB traffic never leaves a trusted host
    /// (the single-host `deploy/compose` topology).
    case disable
    /// Use TLS if the server offers it, fall back to plaintext otherwise.
    case prefer
    /// Require TLS; fail the connection if the server won't negotiate it.
    case require

    /// Resolve the configured mode, defaulting by environment.
    ///
    /// Throws ``DatabaseTLSConfigurationError/invalidMode`` on an unrecognized
    /// `DATABASE_TLS` value rather than silently downgrading to plaintext.
    static func fromConfiguration(_ configuration: ControlPlaneConfiguration) throws -> DatabaseTLSMode {
        try resolve(configuration.string(.databaseTLS), for: .production)
    }

    /// Resolve a raw `DATABASE_TLS` value, defaulting by environment when nil.
    /// Split out from ``fromConfiguration(_:)`` so tests can exercise the mode
    /// mapping directly.
    static func resolve(_ raw: String?, for environment: Environment) throws -> DatabaseTLSMode {
        guard let raw else {
            // Encrypt by default; only local development opts into plaintext.
            return environment == .development ? .disable : .require
        }
        guard let mode = DatabaseTLSMode(rawValue: raw.lowercased()) else {
            throw DatabaseTLSConfigurationError.invalidMode(raw)
        }
        return mode
    }
}

enum DatabaseTLSConfigurationError: Error, CustomStringConvertible {
    case invalidMode(String)
    case caCertificateLoadFailed(path: String, underlying: Error)

    var description: String {
        switch self {
        case .invalidMode(let raw):
            return "Invalid DATABASE_TLS value \"\(raw)\"; expected one of: disable, prefer, require"
        case .caCertificateLoadFailed(let path, let underlying):
            return "Failed to load DATABASE_TLS_CA_CERT_PATH \"\(path)\": \(underlying)"
        }
    }
}

/// Native PostgresNIO client TLS uses `TLSConfiguration` directly rather than
/// a driver-specific context.
func makeNativeDatabaseTLS(configuration: ControlPlaneConfiguration, logger: Logger) throws
    -> PostgresClient.Configuration.TLS
{
    let mode = try DatabaseTLSMode.fromConfiguration(configuration)
    switch mode {
    case .disable:
        return .disable
    case .prefer, .require:
        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        if let caPath = configuration.string(.databaseTLSCACertPath), !caPath.isEmpty {
            do {
                tlsConfiguration.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(caPath))
            } catch {
                throw DatabaseTLSConfigurationError.caCertificateLoadFailed(path: caPath, underlying: error)
            }
        }
        return mode == .prefer ? .prefer(tlsConfiguration) : .require(tlsConfiguration)
    }
}
