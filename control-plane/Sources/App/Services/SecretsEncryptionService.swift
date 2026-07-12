import Crypto
import Fluent
import Foundation
import Vapor

/// Application-level encryption for secrets that must stay recoverable.
///
/// API keys and SCIM tokens are hashed because only equality checks are needed,
/// but an OIDC client secret is POSTed verbatim to the IdP's token endpoint on
/// every login, so it can only be protected with reversible encryption. Values
/// are sealed with AES-256-GCM and stored as
/// `enc:v1:<base64(nonce || ciphertext || tag)>`.
///
/// The key comes from `STRATO_SECRET_ENCRYPTION_KEY` (32 bytes, hex- or
/// base64-encoded; `openssl rand -hex 32`). When it is unset the service runs
/// in pass-through mode: writes store plaintext (with a startup warning) and
/// reads return stored values unchanged. Values without the `enc:v1:` prefix
/// are treated as legacy plaintext on read, and
/// ``encryptStoredOIDCClientSecrets(on:logger:)`` re-encrypts them at startup
/// once a key is configured — so enabling encryption on an existing deployment
/// requires only setting the variable.
struct SecretsEncryptionService: Sendable {
    /// Marks a stored value as encrypted; the `v1` component versions the
    /// scheme (AES-256-GCM, combined nonce/ciphertext/tag) for future rotation.
    static let encryptedPrefix = "enc:v1:"

    private let key: SymmetricKey?

    /// Pass-through service for deployments without a configured key.
    static let disabled = SecretsEncryptionService(key: nil)

    init(key: SymmetricKey?) {
        self.key = key
    }

    /// Builds the service from `STRATO_SECRET_ENCRYPTION_KEY`. A missing or
    /// empty variable yields the pass-through service; a present but malformed
    /// key throws, because a typo must fail startup loudly rather than silently
    /// downgrade to plaintext storage.
    static func fromEnvironment() throws -> SecretsEncryptionService {
        guard
            let raw = Environment.get("STRATO_SECRET_ENCRYPTION_KEY")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return .disabled
        }
        return SecretsEncryptionService(key: try parseKey(raw))
    }

    /// Parses a 32-byte key from its hex (64 chars) or base64 encoding. Hex is
    /// tried first: a 64-char hex string also decodes as base64 (to the wrong
    /// 48 bytes), so the order matters.
    static func parseKey(_ raw: String) throws -> SymmetricKey {
        let data: Data
        if raw.count == 64, let hexData = Data(hexEncoded: raw) {
            data = hexData
        } else if let base64Data = Data(base64Encoded: raw) {
            data = base64Data
        } else {
            throw Abort(
                .internalServerError,
                reason: "STRATO_SECRET_ENCRYPTION_KEY must be hex- or base64-encoded")
        }
        guard data.count == 32 else {
            throw Abort(
                .internalServerError,
                reason:
                    "STRATO_SECRET_ENCRYPTION_KEY must decode to 32 bytes (got \(data.count)); generate one with `openssl rand -hex 32`"
            )
        }
        return SymmetricKey(data: data)
    }

    var isEnabled: Bool { key != nil }

    /// Encrypts a secret for storage. Pass-through when no key is configured.
    func encrypt(_ plaintext: String) throws -> String {
        guard let key else { return plaintext }
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealed.combined else {
            // Only reachable with a non-standard nonce size; seal() above
            // always uses the 12-byte default.
            throw Abort(.internalServerError, reason: "Failed to serialize encrypted secret")
        }
        return Self.encryptedPrefix + combined.base64EncodedString()
    }

    /// Recovers a secret from its stored form. Values without the encrypted
    /// prefix are legacy plaintext and are returned unchanged; encrypted values
    /// require the configured key (a missing or wrong key is a deployment
    /// configuration error, surfaced rather than papered over).
    func decrypt(_ stored: String) throws -> String {
        guard stored.hasPrefix(Self.encryptedPrefix) else { return stored }
        guard let key else {
            throw Abort(
                .internalServerError,
                reason:
                    "Stored secret is encrypted but STRATO_SECRET_ENCRYPTION_KEY is not configured; restore the key this deployment was encrypted with"
            )
        }
        guard let combined = Data(base64Encoded: String(stored.dropFirst(Self.encryptedPrefix.count))),
            let sealed = try? AES.GCM.SealedBox(combined: combined)
        else {
            throw Abort(.internalServerError, reason: "Stored encrypted secret is malformed")
        }
        let plaintextData: Data
        do {
            plaintextData = try AES.GCM.open(sealed, using: key)
        } catch {
            throw Abort(
                .internalServerError,
                reason:
                    "Failed to decrypt stored secret — STRATO_SECRET_ENCRYPTION_KEY does not match the key it was encrypted with"
            )
        }
        guard let plaintext = String(data: plaintextData, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Decrypted secret is not valid UTF-8")
        }
        return plaintext
    }

    /// Re-encrypts any plaintext OIDC client secrets. Runs at every startup so
    /// rows written before a key existed converge to encrypted form as soon as
    /// one is configured. Idempotent; concurrent replicas may both re-encrypt a
    /// row, but each writes a self-contained valid ciphertext.
    func encryptStoredOIDCClientSecrets(on db: Database, logger: Logger) async throws {
        guard isEnabled else { return }
        let providers = try await OIDCProvider.query(on: db).all()
        var migrated = 0
        for provider in providers where !provider.clientSecret.hasPrefix(Self.encryptedPrefix) {
            provider.clientSecret = try encrypt(provider.clientSecret)
            try await provider.save(on: db)
            migrated += 1
        }
        if migrated > 0 {
            logger.info("Encrypted \(migrated) stored OIDC client secret(s) at rest")
        }
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
        set { storage[SecretsEncryptionServiceKey.self] = newValue }
    }
}

extension Request {
    var secretsEncryption: SecretsEncryptionService { application.secretsEncryption }
}
