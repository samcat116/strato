import AsyncHTTPClient
import Fluent
import Foundation
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
struct AuditConfig: Sendable {
    var enabled: Bool
    var backendNames: [String]
    var includeReads: Bool
    var webhookURL: String?
    var lokiEndpoint: String?

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
            lokiEndpoint: Environment.get("LOKI_ENDPOINT")
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

    var isEnabled: Bool {
        config.enabled && !backends.isEmpty
    }

    init(app: Application, config: AuditConfig = .fromEnvironment()) {
        self.config = config
        self.logger = app.logger

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
            storage[AuditServiceKey.self] = newValue
        }
    }
}

extension Request {
    var audit: AuditService {
        application.audit
    }

    /// Best-effort client IP: proxy headers first, then the socket peer.
    /// Matches the extraction `APIKeyAuthenticator` uses for `lastUsedIP`.
    var auditClientIP: String? {
        headers.first(name: "X-Forwarded-For")
            ?? headers.first(name: "X-Real-IP")
            ?? remoteAddress?.description
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
