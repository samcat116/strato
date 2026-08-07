import Vapor
import Fluent

struct APIKeyAuthenticator: AsyncBearerAuthenticator {
    typealias User = App.User

    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        // Check if the bearer token is an API key format (starts with "sk_")
        guard bearer.token.hasPrefix("sk_") else {
            return  // Not an API key format, skip this authenticator
        }

        // Hash the provided key
        let hashedKey = APIKey.hashAPIKey(bearer.token)

        // Find the API key in the database
        guard
            let apiKey = try await APIKey.query(on: request.db)
                .filter(\.$keyHash == hashedKey)
                .filter(\.$isActive == true)
                .with(\.$user)
                .first()
        else {
            return  // API key not found or inactive
        }

        // Check if the key is expired
        if apiKey.isExpired {
            return  // Key is expired
        }

        // Record last-used information (debounced, in the background). Resolved
        // through the shared proxy-trust config: the raw `X-Forwarded-For` this
        // used to read is client-supplied, so a key's recorded `lastUsedIP` was
        // forgeable by whoever presented the key.
        apiKey.recordUsage(ip: request.trustedClientIP, on: request.application)

        // Authenticate the user
        request.auth.login(apiKey.user)

        // Store the API key in the request for later use
        request.storage[APIKeyStorageKey.self] = apiKey
    }
}

// Storage key for storing the authenticated API key
struct APIKeyStorageKey: StorageKey {
    typealias Value = APIKey
}

// Extension to easily access the authenticated API key
extension Request {
    var apiKey: APIKey? {
        get { storage[APIKeyStorageKey.self] }
        set { storage[APIKeyStorageKey.self] = newValue }
    }

    var isAPIKeyAuthenticated: Bool {
        return apiKey != nil
    }

    /// The credential this request authenticated with, if it was a bearer
    /// credential that can carry a restriction. Nil for a session cookie
    /// (the user is present in person) and for an agent's JWT-SVID (a workload
    /// identity names a principal and never narrows one).
    ///
    /// The three bearer authenticators guard on disjoint token prefixes
    /// (`sk_` / `st_` / compact JWS), so at most one of these is ever set.
    var credential: CredentialReference? {
        if let apiKey { return CredentialReference(kind: .apiKey, id: apiKey.id) }
        if let cliSession { return CredentialReference(kind: .cliSession, id: cliSession.id) }
        return nil
    }

    /// What this request's credential permits (STR-115). `.unrestricted` when
    /// there is no credential to narrow — the authenticators already hold the
    /// full row, so this costs no query.
    var credentialRestriction: CredentialRestriction {
        if let apiKey { return apiKey.restriction }
        if let cliSession { return cliSession.restriction }
        return .unrestricted
    }
}

// MARK: - Bearer Authorization Header Authenticator

struct BearerAuthorizationHeaderAuthenticator: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        // Check for Authorization header with Bearer token. Each authenticator
        // guards on its own token shape (`sk_` API keys, `st_` CLI access
        // tokens, compact-JWS JWT-SVIDs), so all three can run unconditionally.
        if let authorization = request.headers.bearerAuthorization {
            try await APIKeyAuthenticator().authenticate(bearer: authorization, for: request)
            try await OAuthTokenAuthenticator().authenticate(bearer: authorization, for: request)
            try await JWTSVIDAuthenticator().authenticate(bearer: authorization, for: request)
        }

        return try await next.respond(to: request)
    }
}

// MARK: - Credential restriction backstop

/// The one thing a credential restriction cannot be enforced by the evaluator:
/// a mutation on a route that never asks the evaluator anything.
///
/// A restriction is `bindings ∩ restriction`, evaluated inside Cedar
/// (STR-115) — so on every route the evaluator gates, this middleware has
/// nothing to do. The exceptions are the route classes that authorize by
/// construction rather than by decision: `loginOnly` (the caller's own API
/// keys, passkeys and OAuth sessions — row-scoped to their user record) and
/// `isPublic` (registration, the device-grant surface). Those handlers never
/// name an action, so there is no question to ask Cedar and no restriction to
/// intersect; a restricted credential mutating through them would slip both
/// systems.
///
/// The concrete escalation this stops: `POST /api/api-keys` is `loginOnly`, so
/// without this a credential restricted to `vm:read` could mint an
/// unrestricted one.
///
/// Reads pass. `loginOnly` reads are the caller's own rows, and denying a
/// restricted credential its own key list would break `strato` without
/// protecting anything.
struct CredentialRestrictionMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard !request.credentialRestriction.isUnrestricted else {
            return try await next.respond(to: request)
        }
        switch request.method {
        case .GET, .HEAD, .OPTIONS:
            return try await next.respond(to: request)
        default:
            break
        }

        let reason: CredentialDenialReason
        switch AuthorizationMiddleware.classify(request: request) {
        case .loginOnly:
            reason = .loginOnlyMutation
        case .isPublic:
            reason = .publicMutation
        case .resource, .handlerChecked:
            // The evaluator sees this mutation and intersects the restriction
            // itself, with a real decision row behind whatever it answers.
            return try await next.respond(to: request)
        case nil:
            // An unclassified path is denied by `AuthorizationMiddleware`
            // anyway; let it produce that denial rather than shadowing it.
            return try await next.respond(to: request)
        }

        await request.recordCredentialRestrictionDenial(reason)
        throw Abort(.forbidden, reason: reason.deniedReason)
    }
}
