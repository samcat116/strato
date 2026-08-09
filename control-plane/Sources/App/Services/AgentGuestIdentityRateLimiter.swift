import Vapor

/// The fixed-window result for one authenticated agent's guest-identity mint
/// request. This mirrors the ordinary API limiter's response contract without
/// putting every sidecar-forwarded request into the same loopback-IP bucket.
struct AgentGuestIdentityRateLimitResult: Sendable {
    let limit: Int
    let remaining: Int
    let resetAfter: Int
    let exceeded: Bool

    func applyHeaders(to response: Response) {
        response.headers.replaceOrAdd(name: "X-RateLimit-Limit", value: String(limit))
        response.headers.replaceOrAdd(name: "X-RateLimit-Remaining", value: String(remaining))
        response.headers.replaceOrAdd(name: "X-RateLimit-Reset", value: String(resetAfter))
    }

    func limitedResponse() -> Response {
        let response = Response(status: .tooManyRequests)
        response.headers.contentType = .json
        struct ErrorBody: Content { let error: Bool; let reason: String }
        do {
            try response.content.encode(
                ErrorBody(
                    error: true,
                    reason: "Rate limit exceeded. Try again in \(resetAfter)s."))
        } catch {
            response.body = .init(string: #"{"error":true,"reason":"Rate limit exceeded."}"#)
        }
        applyHeaders(to: response)
        response.headers.replaceOrAdd(name: "Retry-After", value: String(resetAfter))
        return response
    }
}

/// A dedicated mint limiter evaluated only after mTLS has produced a verified
/// `AuthenticatedAgent`. It uses the ordinary API limit/window, but partitions
/// counters by the agent's full SPIFFE identity rather than the Envoy sidecar's
/// shared loopback address.
struct AgentGuestIdentityRateLimiter: Sendable {
    private let enabled: Bool
    private let limit: Int
    private let window: Int
    private let fallbackStore: InMemoryRateLimitStore
    private let valkeyStore: ValkeyRateLimitStore?

    init(
        config: RateLimitConfig,
        fallbackStore: InMemoryRateLimitStore,
        valkeyStore: ValkeyRateLimitStore? = nil
    ) {
        self.enabled = config.enabled
        self.limit = config.apiLimit
        self.window = config.apiWindow
        self.fallbackStore = fallbackStore
        self.valkeyStore = valkeyStore
    }

    /// Count one request for a verified agent. Nil means limiting is disabled or
    /// the backend failed; like the global limiter, backend failures fail open.
    func hit(
        authenticatedAgent: AuthenticatedAgent,
        request: Request
    ) async -> AgentGuestIdentityRateLimitResult? {
        guard enabled else { return nil }

        let identity = authenticatedAgent.identity.key
        let store: any RateLimitStore
        if request.application.valkeyEnabled, let valkeyStore {
            store = valkeyStore
        } else {
            store = fallbackStore
        }
        let count: RateLimitCount
        do {
            count = try await store.hit("rl:agent-mint:\(identity)", window: window)
        } catch {
            request.logger.error(
                "guest_identity_rate_limit_backend_error",
                metadata: [
                    "agentIdentity": .string(identity),
                    "error": .string(String(reflecting: error)),
                ])
            return nil
        }

        return AgentGuestIdentityRateLimitResult(
            limit: limit,
            remaining: max(0, limit - count.count),
            resetAfter: count.ttl,
            exceeded: count.count > limit)
    }
}

extension Application {
    private struct AgentGuestIdentityRateLimiterKey: StorageKey {
        typealias Value = AgentGuestIdentityRateLimiter
    }

    var agentGuestIdentityRateLimiter: AgentGuestIdentityRateLimiter? {
        get { storage[AgentGuestIdentityRateLimiterKey.self] }
        set { setStorageValue(AgentGuestIdentityRateLimiterKey.self, to: newValue) }
    }
}
