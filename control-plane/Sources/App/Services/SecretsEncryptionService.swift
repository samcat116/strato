import Crypto
import Fluent
import Foundation
import NIOConcurrencyHelpers
import SQLKit
import Vapor

/// Application-level encryption for secrets that must stay recoverable.
///
/// API keys and SCIM tokens are hashed because only equality checks are needed.
/// OIDC client secrets, SSF management tokens, registry pull secrets, and
/// webhook signing secrets must be recovered verbatim, so they are sealed with
/// AES-256-GCM instead. New values use
/// `enc:v2:<key-id>:<base64(nonce || ciphertext || tag)>`, where `key-id` is the
/// first eight bytes of SHA-256(key), rendered as lowercase hex. Legacy
/// `enc:v1:<base64>` values remain readable and are re-sealed during rotation.
///
/// `STRATO_SECRET_ENCRYPTION_KEY` is the primary write key. Comma-separated
/// `STRATO_SECRET_ENCRYPTION_KEYS_PREVIOUS` entries are decrypt-only keys used
/// during rotation. `@unchecked` is required because Linux swift-crypto does
/// not annotate `SymmetricKey` as `Sendable`; this service's key material is
/// immutable and its small mutable status is lock-protected.
struct SecretsEncryptionService: @unchecked Sendable {
    static let encryptedPrefix = "enc:v2:"
    static let legacyEncryptedPrefix = "enc:v1:"

    private enum WriteEnvelope: Sendable {
        case v1
        case v2
    }

    private struct KeyMaterial {
        let id: String
        let key: SymmetricKey
    }

    private struct State {
        var writeEnvelope: WriteEnvelope
        var plaintextWritesAllowed = true
        var unopenableByTable: [String: Int] = [:]
    }

    private final class StateBox: @unchecked Sendable {
        let value: NIOLockedValueBox<State>

        init(writeEnvelope: WriteEnvelope) {
            self.value = NIOLockedValueBox(State(writeEnvelope: writeEnvelope))
        }
    }

    private let primary: KeyMaterial?
    private let decryptKeys: [KeyMaterial]
    private let startsInLegacyWriteMode: Bool
    private let state: StateBox

    /// A fresh pass-through service for deployments without a configured key.
    /// This is computed, rather than shared, because a failed boot audit marks
    /// its own instance as refusing later plaintext writes.
    static var disabled: SecretsEncryptionService { SecretsEncryptionService(key: nil) }

    init(key: SymmetricKey?, previousKeys: [SymmetricKey] = []) {
        self.init(
            key: key,
            previousKeys: previousKeys,
            startsInLegacyWriteMode: false)
    }

    private init(
        key: SymmetricKey?,
        previousKeys: [SymmetricKey],
        startsInLegacyWriteMode: Bool
    ) {
        self.primary = key.map(Self.material(for:))
        self.decryptKeys = ([key].compactMap { $0 } + previousKeys).map(Self.material(for:))
        self.startsInLegacyWriteMode = startsInLegacyWriteMode
        self.state = StateBox(
            writeEnvelope: startsInLegacyWriteMode ? .v1 : .v2)
    }

    /// Builds the primary/decrypt-only keyring from startup configuration.
    /// Empty previous-key configuration means no previous keys. Empty entries
    /// inside a non-empty comma-separated list are rejected, as is a previous
    /// list without a primary write key.
    static func fromConfiguration(
        _ configuration: ControlPlaneConfiguration
    ) throws -> SecretsEncryptionService {
        let primaryRaw = configuration.string(.stratoSecretEncryptionKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let previousRaw = configuration.string(.stratoSecretEncryptionKeysPrevious)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let previousKeys: [SymmetricKey]
        if let previousRaw, !previousRaw.isEmpty {
            let entries = previousRaw.split(
                separator: ",", omittingEmptySubsequences: false)
            guard entries.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw Abort(
                    .internalServerError,
                    reason:
                        "STRATO_SECRET_ENCRYPTION_KEYS_PREVIOUS contains an empty entry; provide a comma-separated list of 32-byte hex or base64 keys"
                )
            }
            previousKeys = try entries.enumerated().map { index, entry in
                try parseKey(
                    String(entry).trimmingCharacters(in: .whitespacesAndNewlines),
                    settingName: "STRATO_SECRET_ENCRYPTION_KEYS_PREVIOUS entry \(index + 1)")
            }
        } else {
            previousKeys = []
        }

        guard let primaryRaw, !primaryRaw.isEmpty else {
            guard previousKeys.isEmpty else {
                throw Abort(
                    .internalServerError,
                    reason:
                        "STRATO_SECRET_ENCRYPTION_KEYS_PREVIOUS requires STRATO_SECRET_ENCRYPTION_KEY; previous keys are decrypt-only and cannot protect new writes"
                )
            }
            return .disabled
        }

        // Existing v1 deployments must survive the binary's rolling upgrade:
        // old replicas cannot parse v2. The startup audit switches this shared
        // state to v2 when rotation is explicit, v2 already exists, or the
        // database has no stored-secret rows. Directly constructed services use
        // v2 immediately (tests and non-application callers have no old replica).
        return SecretsEncryptionService(
            key: try parseKey(primaryRaw),
            previousKeys: previousKeys,
            startsInLegacyWriteMode: previousKeys.isEmpty)
    }

    /// Parses a 32-byte key from its hex (64 chars) or base64 encoding. Hex is
    /// tried first because a 64-character hex string also decodes as base64 to
    /// the wrong length.
    static func parseKey(
        _ raw: String,
        settingName: String = "STRATO_SECRET_ENCRYPTION_KEY"
    ) throws -> SymmetricKey {
        let data: Data
        if raw.count == 64, let hexData = Data(hexEncoded: raw) {
            data = hexData
        } else if let base64Data = Data(base64Encoded: raw) {
            data = base64Data
        } else {
            throw Abort(
                .internalServerError,
                reason: "\(settingName) must be hex- or base64-encoded")
        }
        guard data.count == 32 else {
            throw Abort(
                .internalServerError,
                reason:
                    "\(settingName) must decode to 32 bytes (got \(data.count)); generate one with `openssl rand -hex 32`"
            )
        }
        return SymmetricKey(data: data)
    }

    var isEnabled: Bool { primary != nil }

    /// Current boot-audit degradation, retained for readiness until restart.
    var degradation: SecretsEncryptionDegradation? {
        let counts = state.value.withLockedValue { $0.unopenableByTable }
        return counts.values.reduce(0, +) > 0
            ? SecretsEncryptionDegradation(unopenableByTable: counts)
            : nil
    }

    /// Encrypts a secret for storage. A never-encrypted deployment without a
    /// configured key retains the existing plaintext compatibility path. Once
    /// the boot audit has observed ciphertext without a key, this instance
    /// refuses plaintext writes instead of allowing a permanently mixed state.
    func encrypt(_ plaintext: String) throws -> String {
        guard let primary else {
            guard state.value.withLockedValue({ $0.plaintextWritesAllowed }) else {
                throw SecretsEncryptionError.plaintextWriteRefused
            }
            return plaintext
        }
        let envelope = state.value.withLockedValue { $0.writeEnvelope }
        return try seal(plaintext, using: primary, envelope: envelope)
    }

    /// Recovers legacy plaintext, v1 ciphertext, or a v2 key-identified value.
    /// Unknown keys and malformed ciphertext are distinct typed failures so use
    /// sites can treat operator configuration faults differently from corrupt
    /// data.
    func decrypt(_ stored: String) throws -> String {
        guard Self.isEncryptedEnvelopeCandidate(stored) else { return stored }
        let parsed = try parseEnvelope(stored)

        switch parsed {
        case .v1(let sealed):
            guard !decryptKeys.isEmpty else {
                throw SecretsEncryptionError.noConfiguredKey
            }
            for material in decryptKeys {
                if let plaintext = try openIfAuthenticated(sealed, using: material.key) {
                    return plaintext
                }
            }
            throw SecretsEncryptionError.unknownKey(keyID: nil)

        case .v2(let keyID, let sealed):
            guard !decryptKeys.isEmpty else {
                throw SecretsEncryptionError.noConfiguredKey
            }
            let candidates = decryptKeys.filter { $0.id == keyID }
            guard !candidates.isEmpty else {
                throw SecretsEncryptionError.unknownKey(keyID: keyID)
            }
            for material in candidates {
                if let plaintext = try openIfAuthenticated(sealed, using: material.key) {
                    return plaintext
                }
            }
            throw SecretsEncryptionError.malformedCiphertext(
                "ciphertext did not authenticate with its declared key \(keyID)")
        }
    }

    /// Audits and seals all recoverable stored secrets to the primary key.
    ///
    /// Every changed value is written with an exact-value compare-and-swap so
    /// concurrent API writes and simultaneous replica boots cannot be clobbered.
    /// Unknown/malformed ciphertext is counted and left byte-for-byte intact.
    /// With no primary, the presence of a versioned `enc:v<digits>:` envelope
    /// is an unambiguous boot error and permanently closes plaintext writes on
    /// this service instance. Other `enc:`-prefixed values remain valid legacy
    /// plaintext because earlier APIs did not reserve that prefix.
    @discardableResult
    func encryptStoredSecrets(
        on db: Database,
        logger: Logger
    ) async throws -> SecretsEncryptionSealReport {
        guard let sql = db as? SQLDatabase else {
            throw Abort(
                .internalServerError,
                reason: "Stored-secret sealing requires a SQL database")
        }

        let loaded = try await StoredSecretTable.loadAll(on: sql)
        let hasStoredRows = loaded.values.contains { !$0.isEmpty }
        let hasV2 = loaded.values.joined().contains { $0.value.hasPrefix(Self.encryptedPrefix) }
        if primary != nil,
            !startsInLegacyWriteMode || hasV2 || !hasStoredRows || decryptKeys.count > 1
        {
            state.value.withLockedValue { $0.writeEnvelope = .v2 }
        }

        if primary == nil {
            let reports = StoredSecretTable.allCases.map { table in
                let unopenable = loaded[table, default: []].count {
                    Self.isEncryptedEnvelopeCandidate($0.value)
                }
                return SecretsEncryptionTableReport(
                    table: table.metricLabel, rewrapped: 0, unopenable: unopenable)
            }
            let report = SecretsEncryptionSealReport(tables: reports)
            record(report: report, logger: logger)
            state.value.withLockedValue { current in
                current.unopenableByTable = report.unopenableByTable
                if report.totalUnopenable > 0 {
                    current.plaintextWritesAllowed = false
                }
            }
            guard report.totalUnopenable == 0 else {
                throw SecretsEncryptionError.encryptedRowsWithoutKey(
                    report.nonzeroSummary)
            }
            return report
        }

        var reports: [SecretsEncryptionTableReport] = []
        for table in StoredSecretTable.allCases {
            var rewrapped = 0
            var unopenable = 0
            for row in loaded[table, default: []] {
                do {
                    let replacement = try replacementForPrimary(row.value)
                    if let replacement,
                        try await table.compareAndSwap(
                            id: row.id, old: row.value, new: replacement, on: sql)
                    {
                        rewrapped += 1
                    }
                } catch is SecretsEncryptionError {
                    unopenable += 1
                }
            }
            reports.append(
                SecretsEncryptionTableReport(
                    table: table.metricLabel,
                    rewrapped: rewrapped,
                    unopenable: unopenable))
        }

        let report = SecretsEncryptionSealReport(tables: reports)
        state.value.withLockedValue { current in
            current.unopenableByTable = report.unopenableByTable
            current.plaintextWritesAllowed = true
        }
        record(report: report, logger: logger)
        return report
    }

    private func replacementForPrimary(_ stored: String) throws -> String? {
        guard let primary else { return nil }
        let envelope = state.value.withLockedValue { $0.writeEnvelope }

        guard Self.isEncryptedEnvelopeCandidate(stored) else {
            return try seal(stored, using: primary, envelope: envelope)
        }

        let parsed = try parseEnvelope(stored)
        let plaintext = try decrypt(stored)
        switch parsed {
        case .v1:
            // During the first rolling binary upgrade, keep primary-key v1
            // values stable until previous keys explicitly activate rotation.
            guard envelope == .v2 else { return nil }
            return try seal(plaintext, using: primary, envelope: .v2)
        case .v2(let keyID, _):
            guard keyID != primary.id else { return nil }
            return try seal(plaintext, using: primary, envelope: .v2)
        }
    }

    private func seal(
        _ plaintext: String,
        using material: KeyMaterial,
        envelope: WriteEnvelope
    ) throws -> String {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: material.key)
        guard let combined = sealed.combined else {
            throw SecretsEncryptionError.serializationFailed
        }
        switch envelope {
        case .v1:
            return Self.legacyEncryptedPrefix + combined.base64EncodedString()
        case .v2:
            return Self.encryptedPrefix + material.id + ":" + combined.base64EncodedString()
        }
    }

    private enum ParsedEnvelope {
        case v1(AES.GCM.SealedBox)
        case v2(keyID: String, AES.GCM.SealedBox)
    }

    private func parseEnvelope(_ stored: String) throws -> ParsedEnvelope {
        if stored.hasPrefix(Self.legacyEncryptedPrefix) {
            let encoded = String(stored.dropFirst(Self.legacyEncryptedPrefix.count))
            return .v1(try parseSealedBox(encoded))
        }
        if stored.hasPrefix(Self.encryptedPrefix) {
            let remainder = stored.dropFirst(Self.encryptedPrefix.count)
            guard let separator = remainder.firstIndex(of: ":") else {
                throw SecretsEncryptionError.malformedCiphertext("v2 envelope has no key id separator")
            }
            let keyID = String(remainder[..<separator]).lowercased()
            guard keyID.count == 16, keyID.allSatisfy(\.isHexDigit) else {
                throw SecretsEncryptionError.malformedCiphertext("v2 envelope has an invalid key id")
            }
            let encoded = String(remainder[remainder.index(after: separator)...])
            return .v2(keyID: keyID, try parseSealedBox(encoded))
        }
        throw SecretsEncryptionError.malformedCiphertext("unsupported encrypted envelope version")
    }

    /// Identifies only the versioned namespace introduced by this service.
    /// Plaintext secrets were historically unconstrained, so a value such as
    /// `enc:customer-token` must not be reinterpreted as ciphertext.
    private static func isEncryptedEnvelopeCandidate(_ stored: String) -> Bool {
        guard stored.hasPrefix("enc:v") else { return false }
        let versionAndPayload = stored.dropFirst("enc:v".count)
        guard let separator = versionAndPayload.firstIndex(of: ":") else { return false }
        let version = versionAndPayload[..<separator]
        return !version.isEmpty && version.allSatisfy(\.isNumber)
    }

    private func parseSealedBox(_ encoded: String) throws -> AES.GCM.SealedBox {
        guard let combined = Data(base64Encoded: encoded),
            let sealed = try? AES.GCM.SealedBox(combined: combined)
        else {
            throw SecretsEncryptionError.malformedCiphertext("payload is not a valid AES-GCM combined box")
        }
        return sealed
    }

    private func openIfAuthenticated(
        _ sealed: AES.GCM.SealedBox,
        using key: SymmetricKey
    ) throws -> String? {
        guard let plaintextData = try? AES.GCM.open(sealed, using: key) else {
            return nil
        }
        guard let plaintext = String(data: plaintextData, encoding: .utf8) else {
            throw SecretsEncryptionError.malformedCiphertext("decrypted value is not valid UTF-8")
        }
        return plaintext
    }

    private func record(report: SecretsEncryptionSealReport, logger: Logger) {
        for table in report.tables {
            let level: Logger.Level = table.unopenable > 0 ? .warning : .info
            logger.log(
                level: level,
                "Stored secret sealing summary",
                metadata: [
                    "table": .string(table.table),
                    "rewrapped": .stringConvertible(table.rewrapped),
                    "unopenable": .stringConvertible(table.unopenable),
                ])
            Telemetry.recordUnopenableStoredSecrets(
                table: table.table, count: table.unopenable)
        }
    }

    private static func material(for key: SymmetricKey) -> KeyMaterial {
        let bytes = key.withUnsafeBytes { Data($0) }
        let id = SHA256.hash(data: bytes).prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return KeyMaterial(id: id, key: key)
    }
}

enum SecretsEncryptionError: Error, AbortError, LocalizedError, Sendable, Equatable {
    case noConfiguredKey
    case unknownKey(keyID: String?)
    case malformedCiphertext(String)
    case serializationFailed
    case encryptedRowsWithoutKey(String)
    case plaintextWriteRefused

    var status: HTTPResponseStatus { .internalServerError }

    var isMissingKeyConfiguration: Bool {
        switch self {
        case .noConfiguredKey, .unknownKey:
            true
        default:
            false
        }
    }

    var reason: String {
        switch self {
        case .noConfiguredKey:
            "Stored secret is encrypted but no secret-encryption key is configured; restore the key this deployment was encrypted with"
        case .unknownKey(let keyID):
            if let keyID {
                "Stored secret is sealed under key \(keyID), which this deployment does not have; restore that key in STRATO_SECRET_ENCRYPTION_KEYS_PREVIOUS"
            } else {
                "Legacy stored secret is sealed under a key this deployment does not have; restore the previous key in STRATO_SECRET_ENCRYPTION_KEYS_PREVIOUS"
            }
        case .malformedCiphertext(let detail):
            "Stored encrypted secret is malformed: \(detail)"
        case .serializationFailed:
            "Failed to serialize encrypted secret"
        case .encryptedRowsWithoutKey(let summary):
            "Encrypted stored secrets exist but STRATO_SECRET_ENCRYPTION_KEY is not configured (\(summary)); restore the key this deployment was encrypted with"
        case .plaintextWriteRefused:
            "Refusing to store a plaintext secret because this deployment already contains encrypted stored secrets; restore STRATO_SECRET_ENCRYPTION_KEY"
        }
    }

    var errorDescription: String? { reason }
}

struct SecretsEncryptionDegradation: Sendable, Equatable {
    let unopenableByTable: [String: Int]

    var total: Int { unopenableByTable.values.reduce(0, +) }

    var summary: String {
        unopenableByTable
            .filter { $0.value > 0 }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
    }
}

struct SecretsEncryptionTableReport: Sendable, Equatable {
    let table: String
    let rewrapped: Int
    let unopenable: Int
}

struct SecretsEncryptionSealReport: Sendable, Equatable {
    let tables: [SecretsEncryptionTableReport]

    var totalRewrapped: Int { tables.reduce(0) { $0 + $1.rewrapped } }
    var totalUnopenable: Int { tables.reduce(0) { $0 + $1.unopenable } }
    var unopenableByTable: [String: Int] {
        Dictionary(uniqueKeysWithValues: tables.map { ($0.table, $0.unopenable) })
    }
    var nonzeroSummary: String {
        tables.filter { $0.unopenable > 0 }
            .map { "\($0.table)=\($0.unopenable)" }
            .joined(separator: ", ")
    }
}

private struct StoredSecretRow: Decodable {
    let id: UUID
    let value: String
}

private enum StoredSecretTable: CaseIterable, Hashable {
    case oidcProviders
    case ssfStreams
    case registryPullSecrets
    case webhookSubscriptions

    var metricLabel: String {
        switch self {
        case .oidcProviders: "oidc_providers.client_secret"
        case .ssfStreams: "ssf_streams.auth_token"
        case .registryPullSecrets: "registry_pull_secrets.secret"
        case .webhookSubscriptions: "webhook_subscriptions.signing_secret"
        }
    }

    static func loadAll(
        on sql: SQLDatabase
    ) async throws -> [StoredSecretTable: [StoredSecretRow]] {
        var result: [StoredSecretTable: [StoredSecretRow]] = [:]
        for table in allCases {
            result[table] = try await table.load(on: sql)
        }
        return result
    }

    func load(on sql: SQLDatabase) async throws -> [StoredSecretRow] {
        switch self {
        case .oidcProviders:
            try await sql.raw(
                "SELECT id, client_secret AS value FROM oidc_providers"
            ).all(decoding: StoredSecretRow.self)
        case .ssfStreams:
            try await sql.raw(
                "SELECT id, auth_token AS value FROM ssf_streams WHERE auth_token IS NOT NULL"
            ).all(decoding: StoredSecretRow.self)
        case .registryPullSecrets:
            try await sql.raw(
                "SELECT id, secret AS value FROM registry_pull_secrets"
            ).all(decoding: StoredSecretRow.self)
        case .webhookSubscriptions:
            try await sql.raw(
                "SELECT id, signing_secret AS value FROM webhook_subscriptions"
            ).all(decoding: StoredSecretRow.self)
        }
    }

    func compareAndSwap(
        id: UUID,
        old: String,
        new: String,
        on sql: SQLDatabase
    ) async throws -> Bool {
        struct Updated: Decodable { let id: UUID }
        let updated: Updated?
        switch self {
        case .oidcProviders:
            updated = try await sql.raw(
                """
                UPDATE oidc_providers SET client_secret = \(bind: new)
                WHERE id = \(bind: id) AND client_secret = \(bind: old)
                RETURNING id
                """
            ).first(decoding: Updated.self)
        case .ssfStreams:
            updated = try await sql.raw(
                """
                UPDATE ssf_streams SET auth_token = \(bind: new)
                WHERE id = \(bind: id) AND auth_token = \(bind: old)
                RETURNING id
                """
            ).first(decoding: Updated.self)
        case .registryPullSecrets:
            updated = try await sql.raw(
                """
                UPDATE registry_pull_secrets SET secret = \(bind: new)
                WHERE id = \(bind: id) AND secret = \(bind: old)
                RETURNING id
                """
            ).first(decoding: Updated.self)
        case .webhookSubscriptions:
            updated = try await sql.raw(
                """
                UPDATE webhook_subscriptions SET signing_secret = \(bind: new)
                WHERE id = \(bind: id) AND signing_secret = \(bind: old)
                RETURNING id
                """
            ).first(decoding: Updated.self)
        }
        return updated != nil
    }
}

extension Data {
    /// Decodes a lowercase/uppercase hex string; nil on odd length or non-hex
    /// characters.
    init?(hexEncoded string: String) {
        guard string.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

extension Application {
    private struct SecretsEncryptionServiceKey: StorageKey {
        typealias Value = SecretsEncryptionService
    }

    /// The application's secrets-encryption service. Defaults to pass-through
    /// until `configure()` installs the environment-derived service.
    var secretsEncryption: SecretsEncryptionService {
        get { storage[SecretsEncryptionServiceKey.self] ?? .disabled }
        set { setStorageValue(SecretsEncryptionServiceKey.self, to: newValue) }
    }
}

extension Request {
    var secretsEncryption: SecretsEncryptionService { application.secretsEncryption }
}
