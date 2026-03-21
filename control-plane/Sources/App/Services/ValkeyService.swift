import Foundation
import Vapor
import Redis

/// Configuration for Valkey/Redis connection
struct ValkeyConfiguration: Sendable {
    let hostname: String
    let port: Int
    let password: String?
    let database: Int

    init(
        hostname: String = "localhost",
        port: Int = 6379,
        password: String? = nil,
        database: Int = 0
    ) {
        self.hostname = hostname
        self.port = port
        self.password = password
        self.database = database
    }

    /// Create configuration from environment variables
    /// Returns nil if VALKEY_HOST is not set (Valkey disabled)
    static func fromEnvironment() -> ValkeyConfiguration? {
        guard let hostname = Environment.get("VALKEY_HOST"), !hostname.isEmpty else {
            return nil
        }

        return ValkeyConfiguration(
            hostname: hostname,
            port: Environment.get("VALKEY_PORT").flatMap(Int.init) ?? 6379,
            password: Environment.get("VALKEY_PASSWORD"),
            database: Environment.get("VALKEY_DATABASE").flatMap(Int.init) ?? 0
        )
    }
}

/// Service status for health checks
enum ValkeyServiceStatus: String, Sendable, Codable {
    case connected
    case disconnected
    case unavailable
}

// MARK: - Application Extension

extension Application {
    /// Whether Valkey is enabled and configured
    var valkeyEnabled: Bool {
        get { storage[ValkeyEnabledKey.self] ?? false }
        set { storage[ValkeyEnabledKey.self] = newValue }
    }

    /// Valkey configuration (if enabled)
    var valkeyConfiguration: ValkeyConfiguration? {
        get { storage[ValkeyConfigKey.self] }
        set { storage[ValkeyConfigKey.self] = newValue }
    }

    /// Configure Valkey connection
    /// - Parameter config: Valkey configuration
    /// - Throws: If configuration fails
    func configureValkey(_ config: ValkeyConfiguration) throws {
        // Build Redis configuration
        var redisConfig = try RedisConfiguration(
            hostname: config.hostname,
            port: config.port,
            password: config.password,
            database: config.database,
            pool: .init(
                maximumConnectionCount: .maximumActiveConnections(8),
                minimumConnectionCount: 1,
                connectionBackoffFactor: 2,
                initialConnectionBackoffDelay: .milliseconds(100)
            )
        )

        // Apply configuration to Vapor's Redis
        redis.configuration = redisConfig

        // Store our config
        valkeyConfiguration = config
        valkeyEnabled = true

        logger.info("Valkey configured", metadata: [
            "hostname": .string(config.hostname),
            "port": .stringConvertible(config.port),
            "database": .stringConvertible(config.database)
        ])
    }

    /// Check Valkey health
    /// - Returns: Current Valkey service status
    func checkValkeyHealth() async -> ValkeyServiceStatus {
        guard valkeyEnabled else {
            return .unavailable
        }

        do {
            let pong = try await redis.ping().get()
            return pong == "PONG" ? .connected : .disconnected
        } catch {
            logger.warning("Valkey health check failed: \(error)")
            return .disconnected
        }
    }

    // MARK: - Storage Keys

    private struct ValkeyEnabledKey: StorageKey {
        typealias Value = Bool
    }

    private struct ValkeyConfigKey: StorageKey {
        typealias Value = ValkeyConfiguration
    }
}

// MARK: - Request Extension

extension Request {
    /// Check if Valkey is available for this request
    var valkeyEnabled: Bool {
        application.valkeyEnabled
    }
}
