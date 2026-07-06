import FluentPostgresDriver
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
    static func fromEnvironment(for environment: Environment) throws -> DatabaseTLSMode {
        guard let raw = Environment.get("DATABASE_TLS") else {
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

/// Build the PostgreSQL TLS parameter from `DATABASE_TLS` (mode) and the
/// optional `DATABASE_TLS_CA_CERT_PATH` (PEM CA bundle used to verify the
/// server certificate). When no CA path is given, the system default trust
/// store is used, which is correct for a database presenting a publicly-rooted
/// or otherwise system-trusted certificate.
func makeDatabaseTLS(for environment: Environment, logger: Logger) throws
    -> PostgresConnection.Configuration.TLS
{
    let mode = try DatabaseTLSMode.fromEnvironment(for: environment)
    switch mode {
    case .disable:
        logger.warning("Database TLS is disabled; connection credentials and data are sent in plain text")
        return .disable
    case .prefer, .require:
        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        if let caPath = Environment.get("DATABASE_TLS_CA_CERT_PATH"), !caPath.isEmpty {
            do {
                tlsConfiguration.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(caPath))
            } catch {
                throw DatabaseTLSConfigurationError.caCertificateLoadFailed(path: caPath, underlying: error)
            }
            logger.info("Database TLS enabled (\(mode.rawValue)) with CA bundle from \(caPath)")
        } else {
            logger.info("Database TLS enabled (\(mode.rawValue)) using the system trust store")
        }
        let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
        return mode == .prefer ? .prefer(sslContext) : .require(sslContext)
    }
}
