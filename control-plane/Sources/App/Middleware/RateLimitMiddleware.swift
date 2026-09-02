import Foundation
import Vapor

/// Tunable limits for the rate limiter. Two fixed-window policies are enforced:
/// a strict one for authentication/registration traffic and a looser one for the
/// rest of the API. Repeated *failed* authentications additionally trigger an
/// exponential lockout on top of the fixed window.
///
/// All values come from the immutable startup configuration snapshot so an
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

    /// How far to trust `X-Forwarded-For` when bucketing by client address.
    /// Shared with audit `sourceIP` and API-key `lastUsedIP` so a request is
    /// attributed to the same address everywhere. See `ProxyTrustConfig`.
    ///
    /// Set the hop count too low and everyone behind the outer proxy shares one
    /// bucket (one user's failed logins could lock out the rest); set it too
    /// high and a client could spoof its own bucket. Match it to the real
    /// deployment.
    var proxyTrust: ProxyTrustConfig

    static func fromConfiguration(_ configuration: ControlPlaneConfiguration) -> RateLimitConfig {
        return RateLimitConfig(
            // On by default outside tests; the suite fires many requests from one
            // client and would otherwise trip the limiter. Opt in with
            // RATE_LIMIT_ENABLED=true, opt out with =false.
            enabled: configuration.bool(.rateLimitEnabled),
            authLimit: configuration.int(.rateLimitAuthMax),
            authWindow: configuration.int(.rateLimitAuthWindow),
            apiLimit: configuration.int(.rateLimitAPIMax),
            apiWindow: configuration.int(.rateLimitAPIWindow),
            failureThreshold: configuration.int(.rateLimitFailureThreshold),
            failureBaseDelay: configuration.int(.rateLimitFailureBaseDelay),
            failureMaxDelay: configuration.int(.rateLimitFailureMaxDelay),
            failureWindow: configuration.int(.rateLimitFailureWindow),
            proxyTrust: .fromConfiguration(configuration)
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
    /// A coordination dependency that cannot answer promptly must not consume
    /// the caller's entire HTTP deadline before the limiter fails open.
    static let backendDeadline = RateLimitBackend.defaultDeadline

    let config: RateLimitConfig
    private let backend: RateLimitBackend

    init(
        config: RateLimitConfig,
        fallbackStore: InMemoryRateLimitStore,
        valkeyStore: (any RateLimitStore)? = nil,
        backendDeadline: Duration = RateLimitMiddleware.backendDeadline
    ) {
        self.config = config
        self.backend = RateLimitBackend(
            fallbackStore: fallbackStore,
            valkeyStore: valkeyStore,
            deadline: backendDeadline)
    }

    init(config: RateLimitConfig, backend: RateLimitBackend) {
        self.config = config
        self.backend = backend
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard config.enabled, let scope = scope(for: request) else {
            return try await next.respond(to: request)
        }

        let identity = identity(for: request)
        let policy = policy(for: scope)

        // 1. Exponential backoff: reject early if this identity is currently
        //    locked out from a run of failed auth attempts.
        if scope == .auth, let retryAfter = await activeLockout(identity: identity) {
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
        let result: FixedWindowRateLimitResult
        do {
            let count = try await backend.hit(key, window: policy.window)
            result = FixedWindowRateLimitResult(limit: policy.limit, count: count)
        } catch {
            // Fail open: a limiter backend error must not take down the API.
            request.logger.error(
                "rate_limit_backend_error",
                metadata: [
                    "error": .string(String(reflecting: error))
                ])
            return try await next.respond(to: request)
        }

        if result.exceeded {
            let route = request.secretSafeLogPath
            request.logger.warning(
                "rate_limit_exceeded",
                metadata: [
                    "scope": .string(scope.rawValue),
                    "identity": .string(identity),
                    "http.route": .string(route),
                    "path": .string(route),
                ])
            return result.limitedResponse()
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
                await recordAuthOutcome(status, identity: identity)
            }
            throw error
        }

        // 3. Track auth outcome so the exponential backoff can escalate/relax.
        if scope == .auth {
            await recordAuthOutcome(response.status, identity: identity)
        }

        result.applyHeaders(to: response)
        return response
    }

    // MARK: - Backoff

    /// Seconds remaining on an active lockout, or `nil` when the identity isn't
    /// locked out (or the backend errored — fail open rather than block auth).
    private func activeLockout(identity: String) async -> Int? {
        // `try?` flattens the backend's `Int?` result, so a missing key, a nil
        // value, a backend error, and a backend that misses its deadline all
        // collapse to nil here (fail open).
        guard
            let lockUntil = try? await backend.readInt(lockKey(identity))
        else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        guard lockUntil > now else { return nil }
        return lockUntil - now
    }

    /// On a failed authentication, increment the failure counter and, past the
    /// threshold, (re)arm an exponentially growing lockout. On success, clear the
    /// failure state so a legitimate user isn't penalised for earlier typos.
    private func recordAuthOutcome(_ status: HTTPResponseStatus, identity: String) async {
        switch status.code {
        case 200..<300:
            try? await backend.reset(failureKey(identity))
            try? await backend.reset(lockKey(identity))
        case 401, 403:
            guard let failures = try? await backend.hit(failureKey(identity), window: config.failureWindow) else {
                return
            }
            let over = failures.count - config.failureThreshold
            guard over > 0 else { return }
            // 2s, 4s, 8s, ... capped at failureMaxDelay.
            let delay = min(config.failureMaxDelay, config.failureBaseDelay << min(over - 1, 30))
            let lockUntil = Int(Date().timeIntervalSince1970) + delay
            try? await backend.writeInt(lockKey(identity), value: lockUntil, ttl: delay)
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

        // The desired-state long-poll (STR-146) is the pull half of the same
        // agent channel, and is excluded for both of the reasons above at once.
        // It is long-lived — a parked poll holds a request open for its whole
        // hold window — and it authenticates by SVID client certificate, so it
        // never resolves a `User` and would bucket by IP. Every agent's request
        // arrives from the pod-local Envoy sidecar, so that one bucket is
        // `ip:127.0.0.1` for the entire fleet: the larger the fleet, the sooner
        // its own agents throttle each other out of their desired state.
        if path == "/agent/desired-state" { return nil }

        // Guest JWT-SVID minting also arrives from the pod-local sidecar, but it
        // is a short request that still needs abuse protection. The controller
        // applies a dedicated fixed-window limit immediately after mTLS
        // authentication, keyed by the verified agent SPIFFE identity. Leaving
        // it in this pre-controller limiter would put the whole fleet in the
        // same `ip:127.0.0.1` API bucket before that identity exists.
        let components = path.split(separator: "/")
        if request.method == .POST,
            components.count == 4,
            components[0] == "agent",
            components[1] == "vms",
            components[3] == "jwt-svid"
        {
            return nil
        }

        if path.hasPrefix("/auth/") || path == "/api/users/register" {
            return .auth
        }

        // OAuth device grant: `/oauth/token` is polled every ~5s per login and
        // must fit the roomy api bucket (device codes are 256-bit, and per-code
        // interval enforcement returns slow_down); the endpoints that create
        // rows or probe token hashes get the tight auth bucket.
        if path == "/oauth/device_authorization" || path == "/oauth/revoke" {
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

    /// The bucket's client address. Uses the middleware's own configured
    /// `proxyTrust` rather than `request.trustedClientIP` so a test can drive
    /// the limiter with an explicit hop count without mutating application
    /// storage; both read the identical resolution logic.
    private func clientIP(for request: Request) -> String {
        config.proxyTrust.clientIP(headers: request.headers, remoteAddress: request.remoteAddress)
            ?? "unknown"
    }

    // MARK: - Responses / headers

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
