import Configuration
import Foundation
import Vapor

/// One operator-facing configuration setting. The registry is deliberately
/// data, not documentation assembled at call sites, so the deployment reference
/// can be generated without rediscovering defaults and accepted values.
struct ControlPlaneConfigurationEntry: Equatable, Sendable {
    enum ValueType: String, Sendable {
        case boolean
        case integer
        case number
        case string
    }

    let name: String
    let valueType: ValueType
    let defaultValue: String?
    let acceptedValues: String
    let isSecret: Bool
}

enum ControlPlaneBoolKey: String, CaseIterable, Sendable {
    case requestLogging = "REQUEST_LOGGING"
    case httpTLSEnabled = "HTTP_TLS_ENABLED"
    case runMigrations = "STRATO_RUN_MIGRATIONS"
    case selfRegistrationEnabled = "SELF_REGISTRATION_ENABLED"
    case rateLimitEnabled = "RATE_LIMIT_ENABLED"
    case rateLimitTrustForwardedFor = "RATE_LIMIT_TRUST_FORWARDED_FOR"
    case auditEnabled = "AUDIT_ENABLED"
    case auditIncludeReads = "AUDIT_INCLUDE_READS"
    case auditSynchronous = "AUDIT_SYNCHRONOUS"
    case iamDecisionLogEnabled = "IAM_DECISION_LOG_ENABLED"
    case webhookDeliveryEnabled = "WEBHOOK_DELIVERY_ENABLED"
    case otelMetricsEnabled = "OTEL_METRICS_ENABLED"
    case otelLogsEnabled = "OTEL_LOGS_ENABLED"
    case otelTracesEnabled = "OTEL_TRACES_ENABLED"
    case outboundFetchAllowPrivateHosts = "OUTBOUND_FETCH_ALLOW_PRIVATE_HOSTS"
    case imageFetchAllowPrivateHosts = "IMAGE_FETCH_ALLOW_PRIVATE_HOSTS"
    case imageS3VirtualHostStyle = "IMAGE_S3_VIRTUAL_HOST_STYLE"
    case ssfAllowUnverifiedTokens = "SSF_ALLOW_UNVERIFIED_TOKENS"
    case ssfPollEnabled = "SSF_POLL_ENABLED"
    case spireEnabled = "SPIRE_ENABLED"
    case spireLegacyEnrollments = "SPIRE_LEGACY_ENROLLMENTS"
    case spireOrgTrustDomainsEnabled = "SPIRE_ORG_TRUST_DOMAINS_ENABLED"
    case spiffeJWTSVIDAuthEnabled = "SPIFFE_JWT_SVID_AUTH_ENABLED"

    func defaultValue(for environment: Environment) -> Bool? {
        switch self {
        case .requestLogging:
            environment != .production
        case .rateLimitEnabled, .iamDecisionLogEnabled, .webhookDeliveryEnabled, .ssfPollEnabled:
            environment != .testing
        case .auditSynchronous:
            environment == .testing
        case .outboundFetchAllowPrivateHosts, .imageFetchAllowPrivateHosts:
            nil
        case .runMigrations, .selfRegistrationEnabled, .rateLimitTrustForwardedFor,
            .auditEnabled, .otelMetricsEnabled, .otelLogsEnabled, .otelTracesEnabled,
            .spireLegacyEnrollments:
            true
        case .httpTLSEnabled, .auditIncludeReads, .ssfAllowUnverifiedTokens,
            .imageS3VirtualHostStyle, .spireEnabled, .spireOrgTrustDomainsEnabled,
            .spiffeJWTSVIDAuthEnabled:
            false
        }
    }
}

enum ControlPlaneIntKey: String, CaseIterable, Sendable {
    case databasePort = "DATABASE_PORT"
    case databaseStatementTimeoutMS = "DATABASE_STATEMENT_TIMEOUT_MS"
    case databaseMigrationStatementTimeoutMS = "DATABASE_MIGRATION_STATEMENT_TIMEOUT_MS"
    case valkeyPort = "VALKEY_PORT"
    case valkeyDatabase = "VALKEY_DATABASE"
    case sessionValkeyPort = "SESSION_VALKEY_PORT"
    case sessionValkeyDatabase = "SESSION_VALKEY_DATABASE"
    case sessionTTLSeconds = "SESSION_TTL_SECONDS"
    case rateLimitAuthMax = "RATE_LIMIT_AUTH_MAX"
    case rateLimitAuthWindow = "RATE_LIMIT_AUTH_WINDOW"
    case rateLimitAPIMax = "RATE_LIMIT_API_MAX"
    case rateLimitAPIWindow = "RATE_LIMIT_API_WINDOW"
    case rateLimitFailureThreshold = "RATE_LIMIT_FAILURE_THRESHOLD"
    case rateLimitFailureBaseDelay = "RATE_LIMIT_FAILURE_BASE_DELAY"
    case rateLimitFailureMaxDelay = "RATE_LIMIT_FAILURE_MAX_DELAY"
    case rateLimitFailureWindow = "RATE_LIMIT_FAILURE_WINDOW"
    case rateLimitTrustedProxyHops = "RATE_LIMIT_TRUSTED_PROXY_HOPS"
    case auditRetentionDays = "AUDIT_RETENTION_DAYS"
    case auditMaxQueueDepth = "AUDIT_MAX_QUEUE_DEPTH"
    case auditMaxBatchSize = "AUDIT_MAX_BATCH_SIZE"
    case iamDecisionLogRetentionDays = "IAM_DECISION_LOG_RETENTION_DAYS"
    case iamDecisionLogMaxQueueDepth = "IAM_DECISION_LOG_MAX_QUEUE_DEPTH"
    case iamDecisionLogMaxBatchSize = "IAM_DECISION_LOG_MAX_BATCH_SIZE"
    case webhookDeliveryIntervalSeconds = "WEBHOOK_DELIVERY_INTERVAL_SECONDS"
    case webhookAutoDisableDays = "WEBHOOK_AUTO_DISABLE_DAYS"
    case spireSVIDTTL = "SPIRE_SVID_TTL"
    case spireIssuanceWindowHours = "SPIRE_ISSUANCE_WINDOW_HOURS"
    case guestIdentityJWTTTL = "GUEST_IDENTITY_JWT_TTL"
    case guestIdentityJWTMaxTTL = "GUEST_IDENTITY_JWT_MAX_TTL"
    case ssfPollIntervalSeconds = "SSF_POLL_INTERVAL_SECONDS"
    case sandboxRetentionHours = "SANDBOX_RETENTION_HOURS"
    case snapshotDefaultTTLSeconds = "SNAPSHOT_DEFAULT_TTL_SECONDS"

    func defaultValue(
        normalStatementTimeout: Int = DatabaseStatementTimeout.defaultMilliseconds
    ) -> Int? {
        switch self {
        case .databasePort: 5432
        case .databaseStatementTimeoutMS: DatabaseStatementTimeout.defaultMilliseconds
        case .databaseMigrationStatementTimeoutMS: normalStatementTimeout
        case .valkeyPort, .sessionValkeyPort: 6379
        case .valkeyDatabase, .sessionValkeyDatabase: 0
        case .sessionTTLSeconds: ValkeySessionDriver.defaultTTL
        case .rateLimitAuthMax: 10
        case .rateLimitAuthWindow: 60
        case .rateLimitAPIMax: 300
        case .rateLimitAPIWindow: 60
        case .rateLimitFailureThreshold: 5
        case .rateLimitFailureBaseDelay: 2
        case .rateLimitFailureMaxDelay: 300
        case .rateLimitFailureWindow: 900
        case .rateLimitTrustedProxyHops: 1
        case .auditRetentionDays: nil
        case .auditMaxQueueDepth, .iamDecisionLogMaxQueueDepth: 2048
        case .auditMaxBatchSize, .iamDecisionLogMaxBatchSize: 128
        case .iamDecisionLogRetentionDays: 30
        case .webhookDeliveryIntervalSeconds: 15
        case .webhookAutoDisableDays: 3
        case .spireSVIDTTL: 3600
        case .spireIssuanceWindowHours: 24
        case .guestIdentityJWTTTL: 300
        case .guestIdentityJWTMaxTTL: 3600
        case .ssfPollIntervalSeconds: 60
        case .sandboxRetentionHours: AgentMaintenanceLoop.defaultSandboxRetentionHours
        case .snapshotDefaultTTLSeconds: nil
        }
    }

    var validRange: ClosedRange<Int>? {
        switch self {
        case .databasePort, .valkeyPort, .sessionValkeyPort:
            1...65_535
        case .valkeyDatabase, .sessionValkeyDatabase:
            0...Int.max
        case .databaseStatementTimeoutMS, .databaseMigrationStatementTimeoutMS:
            1...DatabaseStatementTimeout.maximumMilliseconds
        case .sessionTTLSeconds:
            ValkeySessionDriver.minimumTTL...Int.max
        case .rateLimitAuthMax, .rateLimitAuthWindow, .rateLimitAPIMax, .rateLimitAPIWindow,
            .rateLimitFailureThreshold, .rateLimitFailureBaseDelay, .rateLimitFailureMaxDelay,
            .rateLimitFailureWindow, .rateLimitTrustedProxyHops, .auditMaxQueueDepth,
            .auditMaxBatchSize, .iamDecisionLogMaxQueueDepth, .iamDecisionLogMaxBatchSize,
            .webhookDeliveryIntervalSeconds, .webhookAutoDisableDays, .spireSVIDTTL,
            .spireIssuanceWindowHours, .guestIdentityJWTTTL, .guestIdentityJWTMaxTTL,
            .ssfPollIntervalSeconds:
            1...Int.max
        case .snapshotDefaultTTLSeconds:
            1...SnapshotRetention.maxTTLSeconds
        // Non-positive values intentionally disable these retention sweeps.
        case .auditRetentionDays, .iamDecisionLogRetentionDays, .sandboxRetentionHours:
            nil
        }
    }
}

enum ControlPlaneDoubleKey: String, CaseIterable, Sendable {
    case migrationLockTimeoutSeconds = "STRATO_MIGRATION_LOCK_TIMEOUT_SECONDS"
    case migrationLockPollSeconds = "STRATO_MIGRATION_LOCK_POLL_SECONDS"
    case siteControllerOfflineGraceSeconds = "SITE_CONTROLLER_OFFLINE_GRACE_SECONDS"
    case spireBundleRefreshInterval = "SPIRE_BUNDLE_REFRESH_INTERVAL"
    case spiffeJWTBundleRefreshInterval = "SPIFFE_JWT_BUNDLE_REFRESH_INTERVAL"

    var defaultValue: Double {
        switch self {
        case .migrationLockTimeoutSeconds: 240
        case .migrationLockPollSeconds: 2
        case .siteControllerOfflineGraceSeconds: 300
        case .spireBundleRefreshInterval, .spiffeJWTBundleRefreshInterval: 300
        }
    }

    var validRangeDescription: String { "greater than zero" }
}

enum ControlPlaneStringKey: String, CaseIterable, Sendable {
    case stratoVersion = "STRATO_VERSION"
    case stratoGitSHA = "STRATO_GIT_SHA"
    case agentTargetVersion = "AGENT_TARGET_VERSION"
    case agentUpdateArtifactBaseURL = "AGENT_UPDATE_ARTIFACT_BASE_URL"
    case baseURL = "BASE_URL"
    case stratoPublicURL = "STRATO_PUBLIC_URL"
    case externalHostname = "EXTERNAL_HOSTNAME"
    case webauthnRelyingPartyID = "WEBAUTHN_RELYING_PARTY_ID"
    case webauthnRelyingPartyName = "WEBAUTHN_RELYING_PARTY_NAME"
    case webauthnRelyingPartyOrigin = "WEBAUTHN_RELYING_PARTY_ORIGIN"
    case databaseHost = "DATABASE_HOST"
    case databaseUsername = "DATABASE_USERNAME"
    case databasePassword = "DATABASE_PASSWORD"
    case databaseName = "DATABASE_NAME"
    case databaseTLS = "DATABASE_TLS"
    case databaseTLSCACertPath = "DATABASE_TLS_CA_CERT_PATH"
    case valkeyHost = "VALKEY_HOST"
    case valkeyPassword = "VALKEY_PASSWORD"
    case sessionValkeyHost = "SESSION_VALKEY_HOST"
    case sessionValkeyPassword = "SESSION_VALKEY_PASSWORD"
    case schedulingStrategy = "SCHEDULING_STRATEGY"
    case auditBackends = "AUDIT_BACKENDS"
    case auditWebhookURL = "AUDIT_WEBHOOK_URL"
    case lokiEndpoint = "LOKI_ENDPOINT"
    case otelServiceName = "OTEL_SERVICE_NAME"
    case oidcDiscoveryAllowedHosts = "OIDC_DISCOVERY_ALLOWED_HOSTS"
    case oidcDiscoveryAllowedSuffixes = "OIDC_DISCOVERY_ALLOWED_SUFFIXES"
    case imageStorageBackend = "IMAGE_STORAGE_BACKEND"
    case imageStoragePath = "IMAGE_STORAGE_PATH"
    case imageS3Bucket = "IMAGE_S3_BUCKET"
    case imageS3AccessKeyID = "IMAGE_S3_ACCESS_KEY_ID"
    case imageS3SecretAccessKey = "IMAGE_S3_SECRET_ACCESS_KEY"
    case imageS3SessionToken = "IMAGE_S3_SESSION_TOKEN"
    case imageS3Region = "IMAGE_S3_REGION"
    case imageS3Endpoint = "IMAGE_S3_ENDPOINT"
    case spireTrustDomain = "SPIRE_TRUST_DOMAIN"
    case spireBundleEndpointURL = "SPIRE_BUNDLE_ENDPOINT_URL"
    case spireTrustBundlePath = "SPIRE_TRUST_BUNDLE_PATH"
    case spireServerAPIAddress = "SPIRE_SERVER_API_ADDRESS"
    case spireServerPublicAddress = "SPIRE_SERVER_PUBLIC_ADDRESS"
    case spiffeEndpointSocket = "SPIFFE_ENDPOINT_SOCKET"
    case spireAgentSelectors = "SPIRE_AGENT_SELECTORS"
    case spiffeJWTAudience = "SPIFFE_JWT_AUDIENCE"
    case spireMetricsPrometheusURL = "SPIRE_METRICS_PROMETHEUS_URL"
    case spireMetricsX509SVIDMetric = "SPIRE_METRICS_X509_SVID_METRIC"
    case spireMetricsJWTSVIDMetric = "SPIRE_METRICS_JWT_SVID_METRIC"
    case guestIdentityAudiences = "GUEST_IDENTITY_AUDIENCES"
    case ssfTransmitterAllowedHosts = "SSF_TRANSMITTER_ALLOWED_HOSTS"
    case ssfTransmitterAllowedSuffixes = "SSF_TRANSMITTER_ALLOWED_SUFFIXES"
    case ssfCallbackBaseURL = "SSF_CALLBACK_BASE_URL"
    case stratoSecretEncryptionKey = "STRATO_SECRET_ENCRYPTION_KEY"
    case iamDecisionLogMaxConcurrency = "IAM_DECISION_LOG_MAX_CONCURRENCY"
    case iamSymCCSolverPath = "IAM_SYMCC_SOLVER_PATH"

    func defaultValue(for environment: Environment) -> String? {
        switch self {
        case .stratoVersion: "dev"
        case .stratoGitSHA: "unknown"
        case .webauthnRelyingPartyID: "localhost"
        case .webauthnRelyingPartyName: "Strato"
        case .webauthnRelyingPartyOrigin: "http://localhost:8080"
        case .databaseHost: "localhost"
        case .databaseUsername: "vapor_username"
        case .databasePassword: "vapor_password"
        case .databaseName: "vapor_database"
        case .databaseTLS: environment == .development ? "disable" : "require"
        case .schedulingStrategy: SchedulingStrategy.leastLoaded.rawValue
        case .auditBackends: "database"
        case .otelServiceName: "strato-control-plane"
        case .imageStorageBackend: ImageObjectStoreFactory.Backend.filesystem.rawValue
        case .imageS3Region: "us-east-1"
        case .spireTrustDomain: "strato.local"
        case .spireAgentSelectors: "unix:uid:0"
        case .spireMetricsX509SVIDMetric: "spire_server_server_ca_sign_x509_svid"
        case .spireMetricsJWTSVIDMetric: "spire_server_server_ca_sign_jwt_svid"
        case .agentTargetVersion, .agentUpdateArtifactBaseURL, .baseURL, .stratoPublicURL,
            .externalHostname, .databaseTLSCACertPath, .valkeyHost, .valkeyPassword,
            .sessionValkeyHost, .sessionValkeyPassword, .auditWebhookURL, .lokiEndpoint,
            .oidcDiscoveryAllowedHosts, .oidcDiscoveryAllowedSuffixes, .imageStoragePath,
            .imageS3Bucket, .imageS3AccessKeyID, .imageS3SecretAccessKey, .imageS3SessionToken,
            .imageS3Endpoint, .spireBundleEndpointURL, .spireTrustBundlePath,
            .spireServerAPIAddress, .spireServerPublicAddress, .spiffeEndpointSocket,
            .spiffeJWTAudience, .spireMetricsPrometheusURL, .guestIdentityAudiences,
            .ssfTransmitterAllowedHosts, .ssfTransmitterAllowedSuffixes, .ssfCallbackBaseURL,
            .stratoSecretEncryptionKey, .iamDecisionLogMaxConcurrency, .iamSymCCSolverPath:
            nil
        }
    }

    var allowedValues: Set<String>? {
        switch self {
        case .databaseTLS: ["disable", "prefer", "require"]
        case .schedulingStrategy:
            Set([
                SchedulingStrategy.bestFit.rawValue,
                SchedulingStrategy.leastLoaded.rawValue,
                SchedulingStrategy.roundRobin.rawValue,
                SchedulingStrategy.random.rawValue,
            ])
        case .imageStorageBackend: ["filesystem", "s3"]
        case .auditBackends: ["database", "log", "loki", "webhook"]
        default: nil
        }
    }

    var isSecret: Bool {
        switch self {
        case .databasePassword, .valkeyPassword, .sessionValkeyPassword,
            .imageS3AccessKeyID, .imageS3SecretAccessKey, .imageS3SessionToken,
            .stratoSecretEncryptionKey:
            true
        default:
            false
        }
    }
}

/// Immutable, startup-resolved control-plane configuration.
///
/// Swift Configuration's optional synchronous getters deliberately turn a
/// provider conversion error into `nil`. This loader exclusively uses the
/// throwing `fetch*` APIs and applies defaults only after a successful missing
/// lookup, preserving the distinction between absent and malformed values.
struct ControlPlaneConfiguration: Sendable {
    private let booleans: [ControlPlaneBoolKey: Bool]
    private let integers: [ControlPlaneIntKey: Int]
    private let numbers: [ControlPlaneDoubleKey: Double]
    private let strings: [ControlPlaneStringKey: String]
    private let configuredNames: Set<String>

    static func load(
        environmentVariables: [String: String] = ProcessInfo.processInfo.environment,
        for environment: Environment
    ) async throws -> Self {
        let secretNames = Set(ControlPlaneStringKey.allCases.filter(\.isSecret).map(\.rawValue))
        let provider = EnvironmentVariablesProvider(
            environmentVariables: environmentVariables,
            secretsSpecifier: .specific(secretNames)
        )
        let reader = ConfigReader(provider: provider)

        func rawValue(_ name: String) -> String? {
            environmentVariables.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        var booleans: [ControlPlaneBoolKey: Bool] = [:]
        for key in ControlPlaneBoolKey.allCases {
            do {
                // Keep Swift Configuration's grammar as the compatibility
                // contract. In particular, do not trim or add `on`/`off` here.
                if let value = try await reader.fetchBool(forKey: ConfigKey(key.rawValue.lowercased())) {
                    booleans[key] = value
                } else if let defaultValue = key.defaultValue(for: environment) {
                    booleans[key] = defaultValue
                }
            } catch {
                throw ControlPlaneConfigurationError.invalidValue(
                    key: key.rawValue,
                    raw: rawValue(key.rawValue),
                    expected: "one of: true, false, yes, no, 1, 0 (case-insensitive)")
            }
        }

        var integers: [ControlPlaneIntKey: Int] = [:]
        for key in ControlPlaneIntKey.allCases where key != .databaseMigrationStatementTimeoutMS {
            let value: Int?
            do {
                value = try await reader.fetchInt(forKey: ConfigKey(key.rawValue.lowercased()))
            } catch {
                throw ControlPlaneConfigurationError.invalidValue(
                    key: key.rawValue, raw: rawValue(key.rawValue), expected: "an integer")
            }
            let resolved = value ?? key.defaultValue()
            if let resolved, let range = key.validRange, !range.contains(resolved) {
                throw ControlPlaneConfigurationError.invalidValue(
                    key: key.rawValue,
                    raw: rawValue(key.rawValue) ?? String(resolved),
                    expected: "an integer from \(range.lowerBound) through \(range.upperBound)")
            }
            integers[key] = resolved
        }

        let normalStatementTimeout =
            integers[.databaseStatementTimeoutMS]
            ?? DatabaseStatementTimeout.defaultMilliseconds
        do {
            let key = ControlPlaneIntKey.databaseMigrationStatementTimeoutMS
            let explicit = try await reader.fetchInt(forKey: ConfigKey(key.rawValue.lowercased()))
            let resolved =
                explicit ?? key.defaultValue(normalStatementTimeout: normalStatementTimeout)
                ?? normalStatementTimeout
            if let range = key.validRange, !range.contains(resolved) {
                throw ControlPlaneConfigurationError.invalidValue(
                    key: key.rawValue,
                    raw: rawValue(key.rawValue) ?? String(resolved),
                    expected: "an integer from \(range.lowerBound) through \(range.upperBound)")
            }
            integers[key] = resolved
        } catch let error as ControlPlaneConfigurationError {
            throw error
        } catch {
            let key = ControlPlaneIntKey.databaseMigrationStatementTimeoutMS
            throw ControlPlaneConfigurationError.invalidValue(
                key: key.rawValue, raw: rawValue(key.rawValue), expected: "an integer")
        }

        var numbers: [ControlPlaneDoubleKey: Double] = [:]
        for key in ControlPlaneDoubleKey.allCases {
            let value: Double?
            do {
                value = try await reader.fetchDouble(forKey: ConfigKey(key.rawValue.lowercased()))
            } catch {
                throw ControlPlaneConfigurationError.invalidValue(
                    key: key.rawValue, raw: rawValue(key.rawValue), expected: "a number")
            }
            let resolved = value ?? key.defaultValue
            guard resolved.isFinite, resolved > 0 else {
                throw ControlPlaneConfigurationError.invalidValue(
                    key: key.rawValue,
                    raw: rawValue(key.rawValue) ?? String(resolved),
                    expected: key.validRangeDescription)
            }
            numbers[key] = resolved
        }

        var strings: [ControlPlaneStringKey: String] = [:]
        for key in ControlPlaneStringKey.allCases {
            let value: String?
            do {
                value = try await reader.fetchString(
                    forKey: ConfigKey(key.rawValue.lowercased()), isSecret: key.isSecret)
            } catch {
                throw ControlPlaneConfigurationError.invalidValue(
                    key: key.rawValue, raw: key.isSecret ? nil : rawValue(key.rawValue), expected: "a string")
            }
            if let value {
                if let allowedValues = key.allowedValues {
                    let candidates =
                        key == .auditBackends
                        ? value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                        : [value.lowercased()]
                    guard !candidates.isEmpty, candidates.allSatisfy(allowedValues.contains) else {
                        throw ControlPlaneConfigurationError.invalidValue(
                            key: key.rawValue,
                            raw: value,
                            expected: "one or more of: \(allowedValues.sorted().joined(separator: ", "))")
                    }
                    strings[key] = key == .auditBackends ? candidates.joined(separator: ",") : candidates[0]
                } else {
                    strings[key] = value
                }
            } else if let defaultValue = key.defaultValue(for: environment) {
                strings[key] = defaultValue
            }
        }

        return Self(
            booleans: booleans,
            integers: integers,
            numbers: numbers,
            strings: strings,
            configuredNames: Set(environmentVariables.keys.map { $0.uppercased() })
        )
    }

    func bool(_ key: ControlPlaneBoolKey) -> Bool {
        guard let value = booleans[key] else {
            preconditionFailure("\(key.rawValue) has no default; use optionalBool(_:)")
        }
        return value
    }

    func optionalBool(_ key: ControlPlaneBoolKey) -> Bool? { booleans[key] }

    func int(_ key: ControlPlaneIntKey) -> Int {
        guard let value = integers[key] else {
            preconditionFailure("\(key.rawValue) has no default; use optionalInt(_:)")
        }
        return value
    }

    func optionalInt(_ key: ControlPlaneIntKey) -> Int? { integers[key] }

    func double(_ key: ControlPlaneDoubleKey) -> Double {
        guard let value = numbers[key] else {
            preconditionFailure("Missing resolved value for \(key.rawValue)")
        }
        return value
    }

    func string(_ key: ControlPlaneStringKey) -> String? { strings[key] }

    func requiredString(_ key: ControlPlaneStringKey) -> String {
        guard let value = strings[key] else {
            preconditionFailure("\(key.rawValue) has no default; use string(_:)")
        }
        return value
    }

    var schedulingStrategy: SchedulingStrategy {
        guard let value = SchedulingStrategy(rawValue: requiredString(.schedulingStrategy)) else {
            preconditionFailure("SCHEDULING_STRATEGY escaped startup validation")
        }
        return value
    }

    var imageStorageBackend: ImageObjectStoreFactory.Backend {
        guard let value = ImageObjectStoreFactory.Backend(rawValue: requiredString(.imageStorageBackend)) else {
            preconditionFailure("IMAGE_STORAGE_BACKEND escaped startup validation")
        }
        return value
    }

    var databaseTLSMode: DatabaseTLSMode {
        guard let value = DatabaseTLSMode(rawValue: requiredString(.databaseTLS)) else {
            preconditionFailure("DATABASE_TLS escaped startup validation")
        }
        return value
    }

    /// Returns the resolved value only when the environment supplied this key,
    /// preserving call-site fallbacks that must not be activated by a default.
    func explicitlyConfiguredString(_ key: ControlPlaneStringKey) -> String? {
        isConfigured(key.rawValue) ? strings[key] : nil
    }
    func isConfigured(_ name: String) -> Bool { configuredNames.contains(name.uppercased()) }

    static func registry(for environment: Environment) -> [ControlPlaneConfigurationEntry] {
        let bools = ControlPlaneBoolKey.allCases.map { key in
            ControlPlaneConfigurationEntry(
                name: key.rawValue,
                valueType: .boolean,
                defaultValue: key.defaultValue(for: environment).map(String.init),
                acceptedValues: "true, false, yes, no, 1, 0 (case-insensitive)",
                isSecret: false)
        }
        let ints = ControlPlaneIntKey.allCases.map { key in
            let accepted: String
            if let range = key.validRange {
                accepted = "integer from \(range.lowerBound) through \(range.upperBound)"
            } else {
                accepted = "integer"
            }
            return ControlPlaneConfigurationEntry(
                name: key.rawValue,
                valueType: .integer,
                defaultValue: key.defaultValue().map(String.init),
                acceptedValues: accepted,
                isSecret: false)
        }
        let doubles = ControlPlaneDoubleKey.allCases.map { key in
            ControlPlaneConfigurationEntry(
                name: key.rawValue,
                valueType: .number,
                defaultValue: String(key.defaultValue),
                acceptedValues: key.validRangeDescription,
                isSecret: false)
        }
        let strings = ControlPlaneStringKey.allCases.map { key in
            ControlPlaneConfigurationEntry(
                name: key.rawValue,
                valueType: .string,
                defaultValue: key.defaultValue(for: environment),
                acceptedValues: key.allowedValues?.sorted().joined(separator: ", ") ?? "string",
                isSecret: key.isSecret)
        }
        return (bools + ints + doubles + strings).sorted { $0.name < $1.name }
    }
}

enum ControlPlaneConfigurationError: Error, CustomStringConvertible {
    case invalidValue(key: String, raw: String?, expected: String)

    var description: String {
        switch self {
        case .invalidValue(let key, let raw, let expected):
            let rendered = raw.map { " \"\($0)\"" } ?? " <redacted>"
            return "Invalid \(key) value\(rendered); expected \(expected)"
        }
    }
}

extension Application {
    private struct ControlPlaneConfigurationKey: StorageKey {
        typealias Value = ControlPlaneConfiguration
    }

    var controlPlaneConfiguration: ControlPlaneConfiguration {
        get {
            guard let configuration = storage[ControlPlaneConfigurationKey.self] else {
                fatalError("ControlPlaneConfiguration was not loaded before use")
            }
            return configuration
        }
        set { setStorageValue(ControlPlaneConfigurationKey.self, to: newValue) }
    }
}

extension Request {
    var controlPlaneConfiguration: ControlPlaneConfiguration {
        application.controlPlaneConfiguration
    }
}
