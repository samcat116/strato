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

        // Update last used information (async, don't wait)
        let clientIP =
            request.headers.first(name: "X-Forwarded-For") ?? request.headers.first(name: "X-Real-IP")
            ?? request.remoteAddress?.description

        Task {
            try? await apiKey.updateLastUsed(ip: clientIP)
            try? await apiKey.save(on: request.db)
        }

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
}

// MARK: - Bearer Authorization Header Authenticator

struct BearerAuthorizationHeaderAuthenticator: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        // Check for Authorization header with Bearer token
        if let authorization = request.headers.bearerAuthorization {
            try await APIKeyAuthenticator().authenticate(bearer: authorization, for: request)
        }

        return try await next.respond(to: request)
    }
}

// MARK: - API Key Scope Enforcement

/// Enforces an API key's scopes at request time.
///
/// Scopes were validated when a key was created but never checked afterward, so
/// a key minted as read-only still wielded the full write/admin power of its
/// owning user (issue #173). This middleware closes that gap: for any request
/// authenticated with an API key it derives the scope the HTTP method requires
/// (`read` for safe methods, `write` for mutations) and rejects the request
/// with 403 when the key lacks it. `admin` is a superset that grants everything.
///
/// Requests that are not API-key authenticated (session cookie, dev bypass, or
/// no credentials at all) carry no `request.apiKey` and pass through untouched.
struct APIKeyScopeMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let apiKey = request.apiKey else {
            return try await next.respond(to: request)
        }

        let required = APIKeyScope.required(for: request.method)
        guard apiKey.grants(required) else {
            throw Abort(
                .forbidden,
                reason: "API key lacks the required '\(required.rawValue)' scope for this operation"
            )
        }

        return try await next.respond(to: request)
    }
}
