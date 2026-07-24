import Fluent
import Vapor

/// Authenticates CLI access tokens (prefix `st_`) minted by the OAuth device
/// grant. Mirrors `APIKeyAuthenticator`: each bearer authenticator guards on
/// its own token prefix so both can run from
/// `BearerAuthorizationHeaderAuthenticator` without stepping on each other.
struct OAuthTokenAuthenticator: AsyncBearerAuthenticator {
    typealias User = App.User

    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        guard bearer.token.hasPrefix("st_") else {
            return  // Not a CLI access token, skip this authenticator
        }

        let hashedToken = CLISession.hashToken(bearer.token)

        guard
            let session = try await CLISession.query(on: request.db)
                .filter(\.$accessTokenHash == hashedToken)
                .with(\.$user)
                .first()
        else {
            return  // Unknown token
        }

        guard !session.isRevoked, !session.isAccessTokenExpired else {
            return  // Revoked session or expired access token; CLI must refresh
        }

        session.recordUsage(ip: request.trustedClientIP, on: request.application)

        request.auth.login(session.user)
        request.storage[CLISessionStorageKey.self] = session
    }
}

struct CLISessionStorageKey: StorageKey {
    typealias Value = CLISession
}

extension Request {
    var cliSession: CLISession? {
        get { storage[CLISessionStorageKey.self] }
        set { storage[CLISessionStorageKey.self] = newValue }
    }
}
