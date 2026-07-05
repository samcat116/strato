import Foundation
import Vapor
import Redis

/// Tunable limits for the rate limiter. Two fixed-window policies are enforced:
/// a strict one for authentication/registration traffic and a looser one for the
/// rest of the API. Repeated *failed* authentications additionally trigger an
/// exponential lockout on top of the fixed window.
///
/// All values are read from the environment in ``fromEnvironment(for:)`` so an
/// operator can tighten or relax limits without a rebuild.
struct RateLimitConfig: Sendable {
    var enabled: Bool

    /// Strict bucket for `/auth/*` and registration.
    var authLimit: Int
    var authWindow: Int

    /// General bucket for every other throttled route.
    var apiLimit: Int
    var apiWindow: Int

    /// Consecutive auth failures tolerated before the exponential lockout kicks in.
    var failureThreshold: Int
    /// First lockout duration (seconds); doubles with each failure past the
    /// threshold, capped at ``failureMaxDelay``.
    var failureBaseDelay: Int
    var failureMaxDelay: Int
    /// How long a run of failures is remembered (seconds). A quiet period longer
    /// than this resets the backoff.
    var failureWindow: Int

    /// Trust `X-Forwarded-For`/`X-Real-IP` for the client identity. Correct when
    /// the control plane sits behind a trusted ingress/proxy (the supported
    /// deployment); disable if clients can reach it directly and could spoof the
    /// header to evade per-IP limits.
    var trustForwardedFor: Bool

    static func fromEnvironment(for environment: Environment) -> RateLimitConfig {
        func int(_ name: String, _ fallback: Int) -> Int {
            Environment.get(name).flatMap(Int.init) ?? fallback
        }
        return RateLimitConfig(
            // On by default outside tests; the suite fires many requests from one
            // client and would otherwise trip the limiter. Opt in with
            // RATE_LIMIT_ENABLED=true, opt out with =false.
            enabled: Environment.get("RATE_LIMIT_ENABLED").flatMap(Bool.init)
                ?? (environment != .testing),
            authLimit: int("RATE_LIMIT_AUTH_MAX", 10),
            authWindow: int("RATE_LIMIT_AUTH_WINDOW", 60),
            apiLimit: int("RATE_LIMIT_API_MAX", 300),
            apiWindow: int("RATE_LIMIT_API_WINDOW", 60),
            failureThreshold: int("RATE_LIMIT_FAILURE_THRESHOLD", 5),
            failureBaseDelay: int("RATE_LIMIT_FAILURE_BASE_DELAY", 2),
            failureMaxDelay: int("RATE_LIMIT_FAILURE_MAX_DELAY", 300),
            failureWindow: int("RATE_LIMIT_FAILURE_WINDOW", 900),
            trustForwardedFor: Environment.get("RATE_LIMIT_TRUST_FORWARDED_FOR")
                .flatMap(Bool.init) ?? true
        )
    }
}

/// Which policy a request falls under.
private enum RateLimitScope: String {
    case auth
    case api
}

/// Per-IP (unauthenticated) and per-user (authenticated) request throttling.
///
/// Registered after the session/bearer authenticators so it can bucket
/// authenticated traffic per user, and before the authorization middleware and
/// controllers so throttled requests are rejected before doing real work. It:
///
///  1. Applies a strict fixed-window limit to `/auth/*` and registration, and a
///     looser one to the rest of the API.
///  2. Escalates an *exponential* lockout for an identity that keeps failing
///     authentication, on top of the fixed window (mitigates credential
///     stuffing / brute force against passkeys).
///  3. Emits `X-RateLimit-*` headers on throttled responses and a `429` with
///     `Retry-After` when a limit is hit.
///
/// Counters live in Valkey when configured (shared across replicas), otherwise in
/// a process-local actor.
struct RateLimitMiddleware: AsyncMiddleware {
    let config: RateLimitConfig
    /// Shared in-memory fallback, used when Valkey isn't configured.
    let fallbackStore: InMemoryRateLimitStore

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard config.enabled, let scope = scope(for: request) else {
            return try await next.respond(to: request)
        }

        let store = store(for: request)
        let identity = identity(for: request)
        let policy = policy(for: scope)

        // 1. Exponential backoff: reject early if this identity is currently
        //    locked out from a run of failed auth attempts.
        if scope == .auth, let retryAfter = await activeLockout(store, identity: identity) {
            request.logger.warning(
                "rate_limit_locked_out",
                metadata: [
                    "identity": .string(identity),
                    "retryAfter": .stringConvertible(retryAfter),
                ])
            return lockoutResponse(retryAfter: retryAfter)
        }

        // 2. Fixed-window counter for this scope.
        let key = "rl:\(scope.rawValue):\(identity)"
        let count: RateLimitCount
        do {
            count = try await store.hit(key, window: policy.window)
        } catch {
            // Fail open: a limiter backend error must not take down the API.
            request.logger.error(
                "rate_limit_backend_error",
                metadata: [
                    "error": .string(String(reflecting: error))
                ])
            return try await next.respond(to: request)
        }

        let remaining = max(0, policy.limit - count.count)
        if count.count > policy.limit {
            request.logger.warning(
                "rate_limit_exceeded",
                metadata: [
                    "scope": .string(scope.rawValue),
                    "identity": .string(identity),
                    "path": .string(request.url.path),
                ])
            return limitedResponse(limit: policy.limit, resetAfter: count.ttl)
        }

        // Auth failures are usually *thrown* (`Abort(.unauthorized)`, a WebAuthn
        // verification error) rather than returned, and this middleware sits
        // inside `ErrorMiddleware`, so the error propagates up through here before
        // it becomes a response. Inspect both paths so the backoff sees failures.
        let response: Response
        do {
            response = try await next.respond(to: request)
        } catch {
            if scope == .auth {
                let status = (error as? any AbortError)?.status ?? .internalServerError
                await recordAuthOutcome(status, store: store, identity: identity)
            }
            throw error
        }

        // 3. Track auth outcome so the exponential backoff can escalate/relax.
        if scope == .auth {
            await recordAuthOutcome(response.status, store: store, identity: identity)
        }

        applyHeaders(to: response, limit: policy.limit, remaining: remaining, resetAfter: count.ttl)
        return response
    }

    // MARK: - Backoff

    /// Seconds remaining on an active lockout, or `nil` when the identity isn't
    /// locked out (or the backend errored — fail open rather than block auth).
    private func activeLockout(_ store: RateLimitStore, identity: String) async -> Int? {
        // `try?` flattens the backend's `Int?` result, so a missing key, a nil
        // value, and a backend error all collapse to nil here (fail open).
        guard let lockUntil = try? await store.readInt(lockKey(identity)) else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        guard lockUntil > now else { return nil }
        return lockUntil - now
    }

    /// On a failed authentication, increment the failure counter and, past the
    /// threshold, (re)arm an exponentially growing lockout. On success, clear the
    /// failure state so a legitimate user isn't penalised for earlier typos.
    private func recordAuthOutcome(_ status: HTTPResponseStatus, store: RateLimitStore, identity: String) async {
        switch status.code {
        case 200..<300:
            try? await store.reset(failureKey(identity))
            try? await store.reset(lockKey(identity))
        case 401, 403:
            guard let failures = try? await store.hit(failureKey(identity), window: config.failureWindow) else {
                return
            }
            let over = failures.count - config.failureThreshold
            guard over > 0 else { return }
            // 2s, 4s, 8s, ... capped at failureMaxDelay.
            let delay = min(config.failureMaxDelay, config.failureBaseDelay << min(over - 1, 30))
            let lockUntil = Int(Date().timeIntervalSince1970) + delay
            try? await store.writeInt(lockKey(identity), value: lockUntil, ttl: delay)
        default:
            break
        }
    }

    private func failureKey(_ identity: String) -> String { "rl:authfail:\(identity)" }
    private func lockKey(_ identity: String) -> String { "rl:authlock:\(identity)" }

    // MARK: - Classification

    /// Nil means "not throttled" (health probes, websocket upgrades).
    private func scope(for request: Request) -> RateLimitScope? {
        let path = request.url.path

        // Health/readiness probes must never be throttled.
        if path == "/health" || path.hasPrefix("/health/") { return nil }

        // WebSocket upgrades are long-lived and authenticate separately; leaving
        // them out avoids counting a single stream against the per-request budget.
        if request.headers.first(name: .upgrade)?.lowercased() == "websocket" { return nil }

        if path.hasPrefix("/auth/") || path == "/api/users/register" {
            return .auth
        }
        return .api
    }

    private func policy(for scope: RateLimitScope) -> (limit: Int, window: Int) {
        switch scope {
        case .auth: return (config.authLimit, config.authWindow)
        case .api: return (config.apiLimit, config.apiWindow)
        }
    }

    /// Bucket identity: the authenticated user when present, else the client IP.
    private func identity(for request: Request) -> String {
        if let user = request.auth.get(User.self), let id = user.id {
            return "user:\(id.uuidString)"
        }
        return "ip:\(clientIP(for: request))"
    }

    private func clientIP(for request: Request) -> String {
        if config.trustForwardedFor {
            if let forwarded = request.headers.first(name: "X-Forwarded-For"),
                let first = forwarded.split(separator: ",").first
            {
                return first.trimmingCharacters(in: .whitespaces)
            }
            if let realIP = request.headers.first(name: "X-Real-IP") {
                return realIP
            }
        }
        return request.remoteAddress?.ipAddress ?? "unknown"
    }

    // MARK: - Store selection

    private func store(for request: Request) -> RateLimitStore {
        if request.application.valkeyEnabled {
            return RedisRateLimitStore(client: request.redis)
        }
        return fallbackStore
    }

    // MARK: - Responses / headers

    private func applyHeaders(to response: Response, limit: Int, remaining: Int, resetAfter: Int) {
        response.headers.replaceOrAdd(name: "X-RateLimit-Limit", value: String(limit))
        response.headers.replaceOrAdd(name: "X-RateLimit-Remaining", value: String(remaining))
        response.headers.replaceOrAdd(name: "X-RateLimit-Reset", value: String(resetAfter))
    }

    private func limitedResponse(limit: Int, resetAfter: Int) -> Response {
        let response = errorResponse(
            status: .tooManyRequests,
            reason: "Rate limit exceeded. Try again in \(resetAfter)s."
        )
        applyHeaders(to: response, limit: limit, remaining: 0, resetAfter: resetAfter)
        response.headers.replaceOrAdd(name: "Retry-After", value: String(resetAfter))
        return response
    }

    private func lockoutResponse(retryAfter: Int) -> Response {
        let response = errorResponse(
            status: .tooManyRequests,
            reason: "Too many failed authentication attempts. Try again in \(retryAfter)s."
        )
        response.headers.replaceOrAdd(name: "Retry-After", value: String(retryAfter))
        return response
    }

    /// Build a JSON error body matching Vapor's `ErrorMiddleware` shape so clients
    /// get a consistent `{ "error": true, "reason": ... }` payload.
    private func errorResponse(status: HTTPResponseStatus, reason: String) -> Response {
        let response = Response(status: status)
        response.headers.contentType = .json
        struct ErrorBody: Content { let error: Bool; let reason: String }
        do {
            try response.content.encode(ErrorBody(error: true, reason: reason))
        } catch {
            response.body = .init(string: #"{"error":true,"reason":"Rate limit exceeded."}"#)
        }
        return response
    }
}
