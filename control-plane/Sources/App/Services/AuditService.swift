import AsyncHTTPClient
import Fluent
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Vapor

// MARK: - Event types

/// Well-known audit event types. Stored as strings so external backends and
/// future event sources don't require a schema change.
enum AuditEventType: String, Sendable {
    /// An API request (mutations always; reads when `AUDIT_INCLUDE_READS` is
    /// set or when the request used the system-admin bypass).
    case apiRequest = "api.request"
    case login = "auth.login"
    case loginFailed = "auth.login_failed"
    case logout = "auth.logout"
    case register = "auth.register"
    case oidcLogin = "auth.oidc_login"
    case oidcLoginFailed = "auth.oidc_login_failed"
    /// Self-service passkey enrollment/removal (`/api/users/me/passkeys`).
    /// Credential changes alter who can sign in, so they are audited
    /// alongside the login events rather than left to the generic API-request
    /// record.
    case passkeyAdded = "auth.passkey_added"
    case passkeyRemoved = "auth.passkey_removed"
    /// A role granted to a principal outside the resource's organization
    /// (issue #485). Cross-org access is allowed only via explicit bindings,
    /// and those bindings are deliberately loud: a distinct event type, so the
    /// trail can be filtered to exactly the grants that cross an org boundary.
    case crossOrgGrant = "iam.cross_org_grant"
    /// A cross-org principal's role revoked — the other half of the trail, so
    /// external access has a visible end as well as a visible start.
    case crossOrgRevoke = "iam.cross_org_revoke"
}

// MARK: - Record

/// The value handed to audit backends. Decoupled from the `AuditEvent` Fluent
/// model so non-database backends (Loki, webhook, log) can encode it directly.
struct AuditRecord: Content, Sendable {
    var eventType: String
    var timestamp: Date = Date()
    var userID: UUID?
    var username: String?
    var apiKeyID: UUID?
    var organizationID: UUID?
    var method: String?
    var path: String?
    var status: Int?
    var resourceType: String?
    var resourceID: String?
    var action: String?
    var sourceIP: String?
    var adminBypass: Bool = false
    var metadata: [String: String]?
}

// MARK: - Configuration

/// Audit-logging configuration, read from the environment (issue #39):
/// - `AUDIT_ENABLED` — master switch, default true.
/// - `AUDIT_BACKENDS` — comma-separated destinations: `database` (default),
///   `log`, `loki`, `webhook`.
/// - `AUDIT_INCLUDE_READS` — also audit GET/HEAD/OPTIONS API requests,
///   default false (admin-bypassed reads are always audited).
/// - `AUDIT_WEBHOOK_URL` — destination for the `webhook` backend.
/// - `LOKI_ENDPOINT` — shared with VM logs; used by the `loki` backend.
/// - `AUDIT_RETENTION_DAYS` — delete `audit_events` rows older than this many
///   days; unset (or non-positive) keeps events forever.
struct AuditConfig: Sendable {
    var enabled: Bool
    var backendNames: [String]
    var includeReads: Bool
    var webhookURL: String?
    var lokiEndpoint: String?
    var retentionDays: Int?

    static func fromEnvironment() -> AuditConfig {
        let backends =
            Environment.get("AUDIT_BACKENDS")?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty } ?? ["database"]
        return AuditConfig(
            enabled: Environment.get("AUDIT_ENABLED").flatMap(Bool.init) ?? true,
            backendNames: backends,
            includeReads: Environment.get("AUDIT_INCLUDE_READS").flatMap(Bool.init) ?? false,
            webhookURL: Environment.get("AUDIT_WEBHOOK_URL"),
            lokiEndpoint: Environment.get("LOKI_ENDPOINT"),
            retentionDays: Environment.get("AUDIT_RETENTION_DAYS").flatMap(Int.init)
        )
    }
}

// MARK: - Backend protocol

/// A destination audit events are shipped to. Writes must never throw: a
/// failing audit destination logs its own error and must not fail the request
/// that produced the event.
protocol AuditBackend: Sendable {
    var name: String { get }
    func write(_ record: AuditRecord) async
}

/// Shared encoder so every external backend ships identical JSON.
private let auditJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

// MARK: - Database backend

/// Persists events as `AuditEvent` rows — the default backend, and the one the
/// query API (`/api/audit-events`) reads from.
final class DatabaseAuditBackend: AuditBackend, @unchecked Sendable {
    let name = "database"
    private let app: Application

    init(app: Application) {
        self.app = app
    }

    func write(_ record: AuditRecord) async {
        do {
            try await AuditEvent(from: record).save(on: app.db)
        } catch {
            app.logger.error(
                "Failed to persist audit event",
                metadata: [
                    "eventType": .string(record.eventType),
                    "error": .string(String(reflecting: error)),
                ])
        }
    }
}

// MARK: - Log backend

/// Emits each event as one structured `audit_event` log line, which flows to
/// wherever the process logs go (stdout, and OTLP/Loki when swift-otel log
/// export is enabled).
struct LogAuditBackend: AuditBackend {
    let name = "log"
    let logger: Logger

    func write(_ record: AuditRecord) async {
        var metadata: Logger.Metadata = [
            "eventType": .string(record.eventType),
            "adminBypass": .stringConvertible(record.adminBypass),
        ]
        if let userID = record.userID { metadata["userID"] = .string(userID.uuidString) }
        if let username = record.username { metadata["username"] = .string(username) }
        if let organizationID = record.organizationID {
            metadata["organizationID"] = .string(organizationID.uuidString)
        }
        if let method = record.method { metadata["method"] = .string(method) }
        if let path = record.path { metadata["path"] = .string(path) }
        if let status = record.status { metadata["status"] = .stringConvertible(status) }
        if let resourceType = record.resourceType { metadata["resourceType"] = .string(resourceType) }
        if let resourceID = record.resourceID { metadata["resourceID"] = .string(resourceID) }
        if let action = record.action { metadata["action"] = .string(action) }
        if let sourceIP = record.sourceIP { metadata["sourceIP"] = .string(sourceIP) }
        logger.info("audit_event", metadata: metadata)
    }
}

// MARK: - Loki backend

/// Ships events to the same Loki deployment that stores VM console logs,
/// under `service_name=strato-audit`. Labels stay low-cardinality (service +
/// event type); the full record is the JSON log line.
final class LokiAuditBackend: AuditBackend, @unchecked Sendable {
    let name = "loki"
    private let endpoint: String
    private let httpClient: HTTPClient
    private let logger: Logger

    init(endpoint: String, httpClient: HTTPClient, logger: Logger) {
        self.endpoint = endpoint
        self.httpClient = httpClient
        self.logger = logger
    }

    func write(_ record: AuditRecord) async {
        do {
            let line = String(data: try auditJSONEncoder.encode(record), encoding: .utf8) ?? "{}"
            let push = LokiPushRequest(streams: [
                LokiStream(
                    stream: [
                        "service_name": "strato-audit",
                        "event_type": record.eventType,
                    ],
                    values: [
                        [
                            String(Int(record.timestamp.timeIntervalSince1970 * 1_000_000_000)),
                            line,
                        ]
                    ]
                )
            ])
            var request = HTTPClientRequest(url: "\(endpoint)/loki/api/v1/push")
            request.method = .POST
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(data: try auditJSONEncoder.encode(push)))
            let response = try await httpClient.execute(request, timeout: .seconds(5))
            if response.status.code >= 400 {
                logger.error(
                    "Failed to push audit event to Loki",
                    metadata: ["status": .stringConvertible(response.status.code)])
            }
        } catch {
            logger.error("Error pushing audit event to Loki: \(error)")
        }
    }
}

// MARK: - Webhook backend

/// POSTs each event as a JSON object to an operator-supplied HTTP endpoint
/// (SIEM ingestion, custom collectors).
final class WebhookAuditBackend: AuditBackend, @unchecked Sendable {
    let name = "webhook"
    private let url: String
    private let httpClient: HTTPClient
    private let logger: Logger

    init(url: String, httpClient: HTTPClient, logger: Logger) {
        self.url = url
        self.httpClient = httpClient
        self.logger = logger
    }

    func write(_ record: AuditRecord) async {
        do {
            var request = HTTPClientRequest(url: url)
            request.method = .POST
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(data: try auditJSONEncoder.encode(record)))
            let response = try await httpClient.execute(request, timeout: .seconds(5))
            if response.status.code >= 400 {
                logger.error(
                    "Audit webhook rejected event",
                    metadata: ["status": .stringConvertible(response.status.code)])
            }
        } catch {
            logger.error("Error delivering audit event to webhook: \(error)")
        }
    }
}

// MARK: - Service

/// Fans audit events out to the configured backends. Writes are awaited inline
/// (a database insert, plus short-timeout HTTP pushes for the optional external
/// backends) so an event is durably recorded before the response returns and
/// tests can assert on it deterministically.
final class AuditService: @unchecked Sendable {
    let config: AuditConfig
    private let backends: [any AuditBackend]
    private let logger: Logger
    private let app: Application

    /// The periodic retention-sweep loop, when armed. Locked because the class
    /// is shared across request handlers while boot/shutdown mutate it.
    private let retentionTask = NIOLockedValueBox<Task<Void, Never>?>(nil)

    var isEnabled: Bool {
        config.enabled && !backends.isEmpty
    }

    init(app: Application, config: AuditConfig = .fromEnvironment()) {
        self.config = config
        self.logger = app.logger
        self.app = app

        var backends: [any AuditBackend] = []
        if config.enabled {
            for backendName in config.backendNames {
                switch backendName {
                case "database":
                    backends.append(DatabaseAuditBackend(app: app))
                case "log":
                    backends.append(LogAuditBackend(logger: app.logger))
                case "loki":
                    if let endpoint = config.lokiEndpoint {
                        backends.append(
                            LokiAuditBackend(
                                endpoint: endpoint, httpClient: app.http.client.shared,
                                logger: app.logger))
                    } else {
                        app.logger.warning(
                            "Audit backend 'loki' configured but LOKI_ENDPOINT is unset; skipping")
                    }
                case "webhook":
                    if let url = config.webhookURL {
                        backends.append(
                            WebhookAuditBackend(
                                url: url, httpClient: app.http.client.shared, logger: app.logger))
                    } else {
                        app.logger.warning(
                            "Audit backend 'webhook' configured but AUDIT_WEBHOOK_URL is unset; skipping")
                    }
                default:
                    app.logger.warning("Unknown audit backend '\(backendName)'; skipping")
                }
            }
        }
        self.backends = backends
    }

    func record(_ record: AuditRecord) async {
        guard isEnabled else { return }
        for backend in backends {
            await backend.write(record)
        }
    }

    // MARK: Retention sweep

    /// How often the retention sweep runs. Retention granularity is whole
    /// days, so hourly passes are plenty.
    static let retentionSweepIntervalSeconds = 3600

    /// Sweep-lock TTL: slightly under the interval so the current holder's
    /// next tick can reacquire, while any other replica's tick inside the
    /// same window is excluded.
    static let retentionSweepLockTTLSeconds = 3300

    /// The effective retention window, or nil when retention is off. Only a
    /// positive `AUDIT_RETENTION_DAYS` enables pruning.
    var retentionDays: Int? {
        guard let days = config.retentionDays, days > 0 else { return nil }
        return days
    }

    /// Arm the periodic retention sweep. Called once from the boot lifecycle;
    /// a no-op when retention is off. The first pass runs immediately so
    /// short-lived and freshly restarted processes still prune.
    func startRetentionSweep() {
        guard let days = retentionDays else {
            if let raw = config.retentionDays, raw <= 0 {
                logger.warning(
                    "Ignoring non-positive AUDIT_RETENTION_DAYS; audit events are kept forever",
                    metadata: ["value": .stringConvertible(raw)])
            }
            return
        }
        retentionTask.withLockedValue { task in
            guard task == nil else { return }
            logger.info(
                "Audit retention enabled; events older than \(days) day(s) will be pruned")
            task = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.sweepExpiredEvents()
                    do {
                        try await Task.sleep(for: .seconds(Self.retentionSweepIntervalSeconds))
                    } catch {
                        break  // cancelled
                    }
                }
            }
        }
    }

    /// Cancel the retention sweep. Called from the application's shutdown
    /// lifecycle so the periodic database delete never outlives the
    /// application (the same hazard as the AgentService heartbeat loop).
    func shutdown() {
        retentionTask.withLockedValue { task in
            task?.cancel()
            task = nil
        }
    }

    /// One pass of the retention sweep: delete `audit_events` rows older than
    /// the configured window. Internal rather than private so tests can drive
    /// a pass directly.
    func sweepExpiredEvents() async {
        guard let days = retentionDays else { return }

        // Cluster-singleton: with multiple replicas, only one may prune per interval.
        guard
            await app.coordination.acquireSweepLock(
                "audit_retention", ttlSeconds: Self.retentionSweepLockTTLSeconds)
        else {
            logger.debug("Skipping audit retention sweep; lock held by another control-plane instance")
            return
        }

        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        do {
            // Count first so the deletion is observable; the extra query is
            // cheap against the created_at index and a row slipping between
            // the two only misstates the log line, not the data.
            let expired = try await AuditEvent.query(on: app.db)
                .filter(\.$createdAt < cutoff)
                .count()
            guard expired > 0 else { return }

            try await AuditEvent.query(on: app.db)
                .filter(\.$createdAt < cutoff)
                .delete()

            logger.info(
                "Audit retention sweep pruned expired events",
                metadata: [
                    "deleted": .stringConvertible(expired),
                    "retentionDays": .stringConvertible(days),
                ])
        } catch {
            logger.error("Audit retention sweep failed: \(error)")
        }
    }
}

// MARK: - Application / Request accessors

extension Application {
    private struct AuditServiceKey: StorageKey, LockKey {
        typealias Value = AuditService
    }

    var audit: AuditService {
        get {
            lazyService(AuditServiceKey.self) { AuditService(app: self) }
        }
        set {
            setStorageValue(AuditServiceKey.self, to: newValue)
        }
    }

    /// The audit service if something already created it. Shutdown must not
    /// instantiate the service just to shut it down.
    var auditServiceIfCreated: AuditService? {
        storage[AuditServiceKey.self]
    }
}

/// Arms the audit retention sweep at boot (a no-op unless
/// `AUDIT_RETENTION_DAYS` is set) and cancels it at shutdown so the periodic
/// database delete never outlives the application.
struct AuditRetentionLifecycleHandler: LifecycleHandler {
    func didBootAsync(_ application: Application) async throws {
        application.audit.startRetentionSweep()
    }

    func shutdownAsync(_ application: Application) async {
        application.auditServiceIfCreated?.shutdown()
    }
}

extension Request {
    var audit: AuditService {
        application.audit
    }

    /// Best-effort client IP for the audit trail.
    ///
    /// Resolved through the shared `ProxyTrustConfig`, which counts in from the
    /// *right* of `X-Forwarded-For`: hops further left are client-supplied, so
    /// taking the raw (leftmost) value let a client forge the `sourceIP` of its
    /// own audit events — including failed-auth and admin-bypass events —
    /// defeating attribution. Using the shared resolver rather than a local
    /// right-anchored read also keeps audit consistent with the rate limiter in
    /// multi-hop topologies (the supported HTTPS compose stack runs two proxies,
    /// where an unconditional rightmost read would record the inner proxy's
    /// address for every request).
    var auditClientIP: String? {
        trustedClientIP
    }

    /// Record an authentication-flow audit event (login, logout, registration,
    /// OIDC). Called explicitly from the auth handlers — these flows live under
    /// public `/auth` paths, which `AuditMiddleware` does not cover.
    func recordAuthEvent(
        _ type: AuditEventType,
        user: User? = nil,
        organizationID: UUID? = nil,
        metadata: [String: String]? = nil
    ) async {
        await audit.record(
            AuditRecord(
                eventType: type.rawValue,
                userID: user?.id,
                username: user?.username,
                apiKeyID: apiKey?.id,
                organizationID: organizationID ?? user?.currentOrganizationId,
                method: method.rawValue,
                path: url.path,
                sourceIP: auditClientIP,
                metadata: metadata
            ))
    }
}
