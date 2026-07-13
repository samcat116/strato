import Foundation
import NIOConcurrencyHelpers
import Valkey
import Vapor

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

/// Holds the long-lived tasks that drive the Valkey client: the client's
/// `run()` loop (which owns the connection pool) and every pub/sub
/// subscription loop. All are cancelled together at shutdown so no loop
/// retries against a torn-down client.
final class ValkeyBackgroundTasks: Sendable {
    private let tasks = NIOLockedValueBox<[Task<Void, Never>]>([])

    func spawn(_ operation: @escaping @Sendable () async -> Void) {
        tasks.withLockedValue { $0.append(Task { await operation() }) }
    }

    func cancelAll() {
        tasks.withLockedValue { list in
            for task in list { task.cancel() }
            list.removeAll()
        }
    }
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

    /// The shared Valkey client. Only available after `configureValkey` ran
    /// (i.e. never in the `.testing` environment, which uses in-memory stores).
    var valkey: ValkeyClient {
        guard let client = storage[ValkeyClientKey.self] else {
            fatalError("Valkey not configured. Call configureValkey() in configure() first.")
        }
        return client
    }

    /// Tracker for the Valkey run loop and subscription loops.
    var valkeyTasks: ValkeyBackgroundTasks {
        guard let tasks = storage[ValkeyTasksKey.self] else {
            fatalError("Valkey not configured. Call configureValkey() in configure() first.")
        }
        return tasks
    }

    /// Configure the Valkey client and start its connection-pool run loop at
    /// boot (commands issued before the loop starts simply wait on the pool).
    /// - Parameter config: Valkey configuration
    func configureValkey(_ config: ValkeyConfiguration) {
        let clientConfig = ValkeyClientConfiguration(
            authentication: config.password.map {
                .init(username: "default", password: $0)
            },
            databaseNumber: config.database
        )
        let client = ValkeyClient(
            .hostname(config.hostname, port: config.port),
            configuration: clientConfig,
            logger: logger
        )

        storage[ValkeyClientKey.self] = client
        storage[ValkeyTasksKey.self] = ValkeyBackgroundTasks()
        valkeyConfiguration = config
        valkeyEnabled = true
        lifecycle.use(ValkeyLifecycleHandler())

        logger.info(
            "Valkey configured",
            metadata: [
                "hostname": .string(config.hostname),
                "port": .stringConvertible(config.port),
                "database": .stringConvertible(config.database),
            ])
    }

    /// Check Valkey health
    /// - Returns: Current Valkey service status
    func checkValkeyHealth() async -> ValkeyServiceStatus {
        guard valkeyEnabled else {
            return .unavailable
        }

        do {
            _ = try await valkey.ping()
            return .connected
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

    private struct ValkeyClientKey: StorageKey {
        typealias Value = ValkeyClient
    }

    private struct ValkeyTasksKey: StorageKey {
        typealias Value = ValkeyBackgroundTasks
    }
}

/// Starts the Valkey client's `run()` loop at boot (it drives the connection
/// pool and never returns until cancelled) and cancels it — together with all
/// subscription loops — at shutdown. Registered by `configureValkey`, so it
/// runs before `CoordinationLifecycleHandler`'s boot-time ping.
struct ValkeyLifecycleHandler: LifecycleHandler {
    func didBootAsync(_ application: Application) async throws {
        let client = application.valkey
        application.valkeyTasks.spawn {
            await client.run()
        }
    }

    func shutdownAsync(_ application: Application) async {
        application.valkeyTasks.cancelAll()
    }
}

// MARK: - Request Extension

extension Request {
    /// Check if Valkey is available for this request
    var valkeyEnabled: Bool {
        application.valkeyEnabled
    }
}
