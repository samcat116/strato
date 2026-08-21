import ControlPlanePostgres
import Vapor

/// Authenticates CLI access tokens minted by the OAuth device grant.
struct OAuthTokenAuthenticator: AsyncBearerAuthenticator {
    typealias User = App.User

    private let oauth: OAuthDeviceSessionsPersistence
    private let users: UserDirectoryPersistence

    init(oauth: OAuthDeviceSessionsPersistence, users: UserDirectoryPersistence) {
        self.oauth = oauth
        self.users = users
    }

    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        guard bearer.token.hasPrefix("st_") else { return }

        let hashedToken = CLISession.hashToken(bearer.token)
        guard let session = try await oauth.session(accessTokenHash: hashedToken) else {
            return
        }
        guard !session.isRevoked, !session.isAccessTokenExpired() else { return }
        guard let snapshot = try await users.user(id: session.userID) else {
            return
        }
        let user = App.User(snapshot: snapshot)

        recordUsage(
            for: session,
            sourceIP: request.trustedClientIP,
            on: request.application
        )
        request.auth.login(user)
        request.storage[CLISessionStorageKey.self] = session
    }

    private func recordUsage(
        for session: CLISessionSnapshot,
        sourceIP: String?,
        on app: Application,
        now: Date = Date()
    ) {
        guard CLISession.lastUsedIsStale(session.lastUsedAt, now: now) else { return }

        let staleBefore = now.addingTimeInterval(-CLISession.lastUsedDebounceWindow)
        app.backgroundTasks.spawn {
            do {
                _ = try await oauth.recordSessionUsage(
                    id: session.id,
                    usedAt: now,
                    sourceIP: sourceIP,
                    staleBefore: staleBefore
                )
            } catch {
                app.logger.debug(
                    "Failed to record last-used for cli_sessions \(session.id): \(String(reflecting: error))"
                )
            }
        }
    }
}

struct CLISessionStorageKey: StorageKey {
    typealias Value = CLISessionSnapshot
}

extension Request {
    var cliSession: CLISessionSnapshot? {
        get { storage[CLISessionStorageKey.self] }
        set { storage[CLISessionStorageKey.self] = newValue }
    }
}
