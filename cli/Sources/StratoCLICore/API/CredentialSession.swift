import Foundation
import StratoAPIClient

/// The stored token pair for one context, plus the rotation that keeps it
/// fresh.
///
/// Serialized as an actor so a burst of parallel calls can't race the refresh:
/// whoever hits the expired token first rotates it, everyone else awaits that
/// same rotation. Replaying an already-rotated refresh token revokes the
/// session server-side, so a duplicate refresh is not merely wasteful.
public actor CredentialSession {
    private let contextName: String
    private let store: CredentialStore
    /// Unauthenticated client for `/oauth/token`; the refresh must not run
    /// back through the authentication middleware that calls into here.
    private let tokenEndpoint: any APIProtocol

    private var cached: StoredCredentials?
    private var rotation: Task<StoredCredentials, any Error>?

    public init(contextName: String, store: CredentialStore, tokenEndpoint: any APIProtocol) {
        self.contextName = contextName
        self.store = store
        self.tokenEndpoint = tokenEndpoint
    }

    /// The token to sign the next request with. Refreshes proactively when the
    /// stored expiry has already passed — cheaper than eating a guaranteed 401
    /// round-trip.
    public func accessToken() async throws -> String {
        let credentials = try current()
        guard let expiresAt = credentials.expiresAt, expiresAt < Date() else {
            return credentials.accessToken
        }
        return try await refreshed(replacing: credentials.accessToken).accessToken
    }

    /// The token to retry with after `stale` was rejected. Returns immediately
    /// when another request already rotated the pair.
    public func refreshedAccessToken(replacing stale: String) async throws -> String {
        try await refreshed(replacing: stale).accessToken
    }

    private func refreshed(replacing stale: String) async throws -> StoredCredentials {
        if let cached, cached.accessToken != stale { return cached }
        if let rotation { return try await rotation.value }

        let task = Task { try await self.rotate() }
        rotation = task
        defer { rotation = nil }
        return try await task.value
    }

    private func current() throws -> StoredCredentials {
        if let cached { return cached }
        guard let credentials = try store.credentials(for: contextName) else {
            throw CLIError.notLoggedIn("No credentials for context '\(contextName)'.")
        }
        cached = credentials
        return credentials
    }

    private func rotate() async throws -> StoredCredentials {
        let credentials = try current()
        let output = try await tokenEndpoint.oauthToken(
            body: .urlEncodedForm(.init(grantType: .refreshToken, refreshToken: credentials.refreshToken)))

        guard case .ok(let ok) = output else {
            // A rejected refresh means the session is revoked, expired, or was
            // rotated elsewhere — stale credentials are useless now.
            try? store.delete(for: contextName)
            cached = nil
            throw CLIError.notLoggedIn("Your session for context '\(contextName)' has expired or been revoked.")
        }

        let token = try ok.body.json
        let updated = StoredCredentials(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn))
        )
        try store.store(updated, for: contextName)
        cached = updated
        return updated
    }
}
