import Foundation
import NIOConcurrencyHelpers
import Valkey
import Vapor

/// Which of the two stores a Valkey client backs.
///
/// The two have opposite failure contracts, which is the whole reason they are
/// separable (issue #855): coordination is documented as fail-open — "flushing
/// the store degrades to slower convergence, never to incorrect state"
/// (`CoordinationStore`) — while losing session storage logs every signed-in
/// user out at once, and passkeys are the only interactive auth.
enum ValkeyRole: String, Sendable, CaseIterable {
    case coordination
    case session

    /// Environment-variable prefix this role reads its endpoint from.
    var environmentPrefix: String {
        switch self {
        case .coordination: return "VALKEY_"
        case .session: return "SESSION_VALKEY_"
        }
    }
}

/// Configuration for one Valkey/Redis endpoint.
struct ValkeyConfiguration: Sendable, Equatable {
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

    /// Resolve one prefixed group of variables (`<prefix>HOST`, `PORT`,
    /// `PASSWORD`, `DATABASE`), or nil when the group's host is unset.
    ///
    /// The group is **all-or-nothing**: the remaining fields fall back to their
    /// own defaults (6379 / no password / database 0) rather than borrowing from
    /// another prefix. That is deliberate — a per-field merge would let
    /// `SESSION_VALKEY_HOST` alone send the *coordination* password to a
    /// different server, so one variable can never produce a half-merged
    /// endpoint. See `ValkeyStoreConfiguration.resolve`.
    ///
    /// `lookup` is injected so precedence is a pure function: setting process
    /// environment variables from tests races the parallel suite's own
    /// `Environment.get` calls (same reasoning as `DatabaseTLSMode.resolve`).
    static func resolve(prefix: String, _ lookup: (String) -> String?) -> ValkeyConfiguration? {
        guard let hostname = lookup(prefix + "HOST"), !hostname.isEmpty else {
            return nil
        }
        return ValkeyConfiguration(
            hostname: hostname,
            port: lookup(prefix + "PORT").flatMap(Int.init) ?? 6379,
            password: lookup(prefix + "PASSWORD"),
            database: lookup(prefix + "DATABASE").flatMap(Int.init) ?? 0
        )
    }
}

/// The endpoints this process's two Valkey-backed stores use.
///
/// Coordination is required and keeps the historical `VALKEY_*` names. Sessions
/// are optional-by-prefix: `SESSION_VALKEY_HOST` selects a separate endpoint,
/// and its absence means sessions ride the coordination endpoint — so a
/// deployment that only ever set `VALKEY_HOST` upgrades untouched, down to the
/// connection count (see `ValkeyClients`, which then shares one client).
struct ValkeyStoreConfiguration: Sendable, Equatable {
    let coordination: ValkeyConfiguration
    let session: ValkeyConfiguration

    /// Configuration that was set but could not take effect, phrased for an
    /// operator. Returned rather than logged so resolution stays pure;
    /// `configureValkey` emits these.
    let warnings: [String]

    /// Same server *and* same database, so one client instance can serve both
    /// stores. `databaseNumber` is baked into `ValkeyClientConfiguration`, which
    /// is why a differing database has to mean a second client.
    var sharesOneInstance: Bool { coordination == session }

    /// Endpoint for `role`.
    func configuration(for role: ValkeyRole) -> ValkeyConfiguration {
        switch role {
        case .coordination: return coordination
        case .session: return session
        }
    }

    /// Resolve both roles, or nil when coordination has no host (Valkey
    /// unconfigured, which is fatal outside `.testing`).
    static func resolve(_ lookup: (String) -> String?) -> ValkeyStoreConfiguration? {
        guard
            let coordination = ValkeyConfiguration.resolve(
                prefix: ValkeyRole.coordination.environmentPrefix, lookup)
        else {
            return nil
        }

        let sessionPrefix = ValkeyRole.session.environmentPrefix
        if let session = ValkeyConfiguration.resolve(prefix: sessionPrefix, lookup) {
            return ValkeyStoreConfiguration(coordination: coordination, session: session, warnings: [])
        }

        // The mirror hazard of the all-or-nothing rule: a half-set session group
        // (`SESSION_VALKEY_DATABASE` without `SESSION_VALKEY_HOST`) is silently
        // inert. Say so rather than letting an operator believe it took effect.
        let orphans = ["PORT", "PASSWORD", "DATABASE"]
            .map { sessionPrefix + $0 }
            .filter { lookup($0)?.isEmpty == false }
        let warnings =
            orphans.isEmpty
            ? []
            : [
                "Ignoring \(orphans.joined(separator: ", ")): \(sessionPrefix)HOST is not set, "
                    + "so session storage uses the coordination endpoint."
            ]
        return ValkeyStoreConfiguration(coordination: coordination, session: coordination, warnings: warnings)
    }

    /// Resolve from the process environment.
    static func fromEnvironment() -> ValkeyStoreConfiguration? {
        resolve { Environment.get($0) }
    }
}

/// The per-role Valkey clients.
///
/// When both roles resolved to the same endpoint these two properties are the
/// *same* instance — which is why anything that drives clients must go through
/// ``distinctClients`` rather than touching both properties.
struct ValkeyClients: Sendable {
    let coordination: ValkeyClient
    let session: ValkeyClient
    let configuration: ValkeyStoreConfiguration

    func client(for role: ValkeyRole) -> ValkeyClient {
        switch role {
        case .coordination: return coordination
        case .session: return session
        }
    }

    /// Each underlying client exactly once, in role order.
    ///
    /// Configuration equality is what *decides* whether the two roles share a
    /// client; object identity is what *enforces* it here. The distinction
    /// matters because `ValkeyClient.run()` carries
    /// `precondition(!atomicOp.original, "ValkeyClient.run() should just be called once!")`
    /// — a second `run()` on one instance traps the process at boot, so this is
    /// a correctness requirement, not a de-duplication nicety.
    var distinctClients: [(role: ValkeyRole, client: ValkeyClient)] {
        var seen = Set<ObjectIdentifier>()
        var result: [(role: ValkeyRole, client: ValkeyClient)] = []
        for role in ValkeyRole.allCases {
            let client = client(for: role)
            if seen.insert(ObjectIdentifier(client)).inserted {
                result.append((role, client))
            }
        }
        return result
    }
}

/// Holds the long-lived tasks that drive the Valkey clients: each client's
/// `run()` loop (which owns its connection pool) and every pub/sub
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
        set { setStorageValue(ValkeyEnabledKey.self, to: newValue) }
    }

    /// Endpoints both stores resolved to (if enabled)
    var valkeyConfiguration: ValkeyStoreConfiguration? {
        get { storage[ValkeyConfigKey.self] }
        set { setStorageValue(ValkeyConfigKey.self, to: newValue) }
    }

    /// The per-role Valkey clients. Only available after `configureValkey` ran
    /// (i.e. never in the `.testing` environment, which uses in-memory stores).
    var valkeyClients: ValkeyClients {
        guard let clients = storage[ValkeyClientsKey.self] else {
            fatalError("Valkey not configured. Call configureValkey() in configure() first.")
        }
        return clients
    }

    /// Client backing agent presence, socket routing, sweep locks, placement
    /// reservations, and rate-limit counters — everything that fails open.
    var coordinationValkey: ValkeyClient { valkeyClients.coordination }

    /// Client backing session storage. The coordination client unless
    /// `SESSION_VALKEY_HOST` selects a separate endpoint.
    var sessionValkey: ValkeyClient { valkeyClients.session }

    /// Tracker for the Valkey run loops and subscription loops.
    var valkeyTasks: ValkeyBackgroundTasks {
        guard let tasks = storage[ValkeyTasksKey.self] else {
            fatalError("Valkey not configured. Call configureValkey() in configure() first.")
        }
        return tasks
    }

    /// Configure the Valkey clients and start their connection-pool run loops at
    /// boot (commands issued before a loop starts simply wait on the pool).
    ///
    /// Both `ValkeyClientConfiguration` values are built here, and here is after
    /// `bootstrapObservability()`: `ValkeyTracingConfiguration.tracer` defaults
    /// to `InstrumentationSystem.tracer` and latches when the configuration is
    /// *initialized*, so hoisting either into a global or a lazy initializer
    /// would leave that client emitting no spans for the process lifetime.
    /// - Parameter config: endpoints for both stores
    func configureValkey(_ config: ValkeyStoreConfiguration) {
        for warning in config.warnings {
            logger.warning("\(warning)")
        }

        func makeClient(_ endpoint: ValkeyConfiguration) -> ValkeyClient {
            let clientConfig = ValkeyClientConfiguration(
                authentication: endpoint.password.map {
                    .init(username: "default", password: $0)
                },
                databaseNumber: endpoint.database
            )
            return ValkeyClient(
                .hostname(endpoint.hostname, port: endpoint.port),
                configuration: clientConfig,
                logger: logger
            )
        }

        let coordination = makeClient(config.coordination)
        // Same endpoint and database means one client, so a deployment that only
        // sets VALKEY_HOST opens exactly the connection pool it opens today.
        let session = config.sharesOneInstance ? coordination : makeClient(config.session)

        setStorageValue(
            ValkeyClientsKey.self,
            to: ValkeyClients(coordination: coordination, session: session, configuration: config))
        setStorageValue(ValkeyTasksKey.self, to: ValkeyBackgroundTasks())
        valkeyConfiguration = config
        valkeyEnabled = true
        lifecycle.use(ValkeyLifecycleHandler())

        for (role, _) in valkeyClients.distinctClients {
            let endpoint = config.configuration(for: role)
            logger.info(
                "Valkey configured",
                metadata: [
                    "role": .string(config.sharesOneInstance ? "coordination+session" : role.rawValue),
                    "hostname": .string(endpoint.hostname),
                    "port": .stringConvertible(endpoint.port),
                    "database": .stringConvertible(endpoint.database),
                ])
        }
    }

    // MARK: - Storage Keys

    private struct ValkeyEnabledKey: StorageKey {
        typealias Value = Bool
    }

    private struct ValkeyConfigKey: StorageKey {
        typealias Value = ValkeyStoreConfiguration
    }

    private struct ValkeyClientsKey: StorageKey {
        typealias Value = ValkeyClients
    }

    private struct ValkeyTasksKey: StorageKey {
        typealias Value = ValkeyBackgroundTasks
    }
}

/// Starts each Valkey client's `run()` loop at boot (it drives the connection
/// pool and never returns until cancelled) and cancels them — together with all
/// subscription loops — at shutdown. Registered by `configureValkey`, so it
/// runs before `ValkeyReachabilityLifecycleHandler`'s boot-time ping.
struct ValkeyLifecycleHandler: LifecycleHandler {
    func didBootAsync(_ application: Application) async throws {
        // One loop per *distinct* client: when coordination and sessions share
        // an endpoint they share the instance, and `run()` traps on a second call.
        for (_, client) in application.valkeyClients.distinctClients {
            application.valkeyTasks.spawn {
                await client.run()
            }
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
