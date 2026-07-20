import Fluent
import Foundation
import NIOConcurrencyHelpers
import Vapor

/// Provides the deployment-stable secret that keys WebAuthn decoy credentials.
///
/// `WebAuthnService.beginAuthentication` answers an unknown username with a
/// decoy credential derived from HMAC(key, username) so login responses are
/// indistinguishable for existing and non-existing accounts (the
/// username-enumeration fix). The decoy is only convincing if it is *stable*:
/// the same unknown username must yield the same credential ID on every
/// request, across restarts and across replicas — hence a persisted,
/// per-deployment secret rather than an in-process random value.
///
/// The key is auto-generated on first use and stored in `app_settings`. It was
/// historically shared with image-download URL signing (the `AppSetting` key
/// name still says so); that use is gone — agents authenticate downloads with
/// their SPIFFE SVID over mTLS (issue #493) — but the stored key survives so
/// existing deployments keep emitting the same decoys.
enum DecoyKeyService {
    /// Gets the decoy key, generating and persisting one if none exists yet.
    /// Concurrent first calls (multi-replica boot) race benignly: the loser of
    /// the insert re-reads the winner's key.
    static func getKey(from app: Application) async throws -> String {
        if let cachedKey = app.decoyKeyCache.key {
            return cachedKey
        }

        if let setting = try await AppSetting.query(on: app.db)
            .filter(\.$key == AppSetting.decoyCredentialKey)
            .first()
        {
            app.decoyKeyCache.key = setting.value
            return setting.value
        }

        let newKey = generateRandomKey()
        let setting = AppSetting(key: AppSetting.decoyCredentialKey, value: newKey)

        do {
            try await setting.save(on: app.db)
            app.decoyKeyCache.key = newKey
            app.logger.info("Generated and stored new decoy credential key")
            return newKey
        } catch {
            // Handle race condition: another instance may have inserted the key
            // Re-query to get the existing key
            if let existingSetting = try await AppSetting.query(on: app.db)
                .filter(\.$key == AppSetting.decoyCredentialKey)
                .first()
            {
                app.decoyKeyCache.key = existingSetting.value
                app.logger.info("Loaded decoy credential key from database (concurrent insert)")
                return existingSetting.value
            }
            // If still not found, rethrow the original error
            throw error
        }
    }

    /// Generates a cryptographically secure random key
    /// - Returns: 64-character hex string (256 bits)
    private static func generateRandomKey() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<bytes.count {
            bytes[i] = UInt8.random(in: 0...255, using: &generator)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Application Extension for Decoy Key Cache

extension Application {
    /// In-memory cache for the decoy key, so login begins don't pay a DB
    /// point query each.
    var decoyKeyCache: DecoyKeyCache {
        get {
            lazyService(DecoyKeyCacheKey.self) { DecoyKeyCache() }
        }
        set {
            storage[DecoyKeyCacheKey.self] = newValue
        }
    }

    private struct DecoyKeyCacheKey: StorageKey, LockKey {
        typealias Value = DecoyKeyCache
    }
}

/// Thread-safe cache for the decoy key
final class DecoyKeyCache: @unchecked Sendable {
    private let lock = NIOLock()
    private var _key: String?

    var key: String? {
        get { lock.withLock { _key } }
        set { lock.withLock { _key = newValue } }
    }
}
