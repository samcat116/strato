import Fluent
import Vapor

/// Enforces per-user security state set by SSF signal handlers (issue #38):
///
/// - **Disabled accounts** (`User.disabledAt`): every authenticated request is
///   rejected with 403 and the session is destroyed, regardless of whether the
///   request authenticated via session or API key.
/// - **Session revocation** (`User.sessionEpoch`): each session records the
///   user's epoch at login (see `Request.stampSessionEpoch`). Bumping the
///   user's epoch invalidates all existing sessions: a mismatch destroys the
///   session and rejects the request with 401. Sessions created before the
///   epoch existed carry no stamp and count as epoch 0.
///
/// Must be registered after both authenticators (session + bearer) so it sees
/// the resolved user, and before `SpiceDBAuthMiddleware` so revoked sessions
/// never reach authorization. Denials return a `Response` rather than throwing
/// so the sessions middleware still runs its response path and actually
/// deletes the destroyed session record and cookie.
struct UserSecurityMiddleware: AsyncMiddleware {
    static let sessionEpochKey = "session_epoch"

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let user = request.auth.get(User.self) else {
            return try await next.respond(to: request)
        }

        if user.disabledAt != nil {
            request.logger.info(
                "Rejecting request for disabled account",
                metadata: ["username": .string(user.username)])
            destroySession(on: request)
            request.auth.logout(User.self)
            return errorResponse(.forbidden, reason: "Account is disabled", on: request)
        }

        // Epoch enforcement only applies to session-authenticated requests:
        // the session must exist and name this user.
        if request.hasSession,
            let sessionUserID = request.session.authenticated(User.self),
            sessionUserID == user.id
        {
            let stampedEpoch = request.session.data[Self.sessionEpochKey].flatMap(Int.init) ?? 0
            // A stale stamp on an API-key-authenticated request is ignored, NOT
            // re-stamped: the bearer key — not the cookie — is the credential
            // here, and refreshing the epoch would silently resurrect a session
            // that was explicitly revoked, letting that cookie pass later
            // cookie-only requests. Leaving the stale stamp in place keeps the
            // revoked cookie dead while the request proceeds on the key.
            if stampedEpoch != user.sessionEpoch, !request.isAPIKeyAuthenticated {
                request.logger.info(
                    "Rejecting revoked session",
                    metadata: [
                        "username": .string(user.username),
                        "sessionEpoch": .stringConvertible(stampedEpoch),
                        "userEpoch": .stringConvertible(user.sessionEpoch),
                    ])
                destroySession(on: request)
                request.auth.logout(User.self)
                return errorResponse(.unauthorized, reason: "Session has been revoked", on: request)
            }
        }

        return try await next.respond(to: request)
    }

    private func destroySession(on request: Request) {
        guard request.hasSession else { return }
        request.session.unauthenticate(User.self)
        request.session.destroy()
    }

    /// The same JSON shape Vapor's ErrorMiddleware produces for thrown Aborts.
    private func errorResponse(_ status: HTTPStatus, reason: String, on request: Request) -> Response {
        struct ErrorBody: Content {
            let error: Bool
            let reason: String
        }
        let response = Response(status: status)
        try? response.content.encode(ErrorBody(error: true, reason: reason), as: .json)
        return response
    }
}

extension Request {
    /// Record the user's current session epoch in the session. Call after
    /// every `auth.login` that establishes a browser session; sessions whose
    /// stamp no longer matches the user's epoch are destroyed by
    /// `UserSecurityMiddleware`.
    func stampSessionEpoch(for user: User) {
        session.data[UserSecurityMiddleware.sessionEpochKey] = String(user.sessionEpoch)
    }
}

/// Guard for login/registration handlers: a disabled account must never get
/// a session. `UserSecurityMiddleware` only sees already-authenticated
/// requests, and login endpoints are reached unauthenticated — without this
/// check they would mint a session that the middleware destroys one request
/// later, while reporting a successful login.
func rejectDisabledAccount(_ user: User) throws {
    guard user.disabledAt == nil else {
        throw Abort(.forbidden, reason: "Account is disabled")
    }
}
