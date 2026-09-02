import Vapor

/// A dedicated mint limiter evaluated only after mTLS has produced a verified
/// `AuthenticatedAgent`. It uses the ordinary API limit/window, but partitions
/// counters by the agent's full SPIFFE identity rather than the Envoy sidecar's
/// shared loopback address.
struct AgentGuestIdentityRateLimiter: Sendable {
    private let enabled: Bool
    private let limit: Int
    private let window: Int
    private let backend: RateLimitBackend

    init(
        config: RateLimitConfig,
        fallbackStore: InMemoryRateLimitStore,
        valkeyStore: (any RateLimitStore)? = nil,
        backendDeadline: Duration = RateLimitBackend.defaultDeadline
    ) {
        self.enabled = config.enabled
        self.limit = config.apiLimit
        self.window = config.apiWindow
        self.backend = RateLimitBackend(
            fallbackStore: fallbackStore,
            valkeyStore: valkeyStore,
            deadline: backendDeadline)
    }

    init(config: RateLimitConfig, backend: RateLimitBackend) {
        self.enabled = config.enabled
        self.limit = config.apiLimit
        self.window = config.apiWindow
        self.backend = backend
    }

    /// Count one request for a verified agent. Nil means limiting is disabled or
    /// the backend failed; like the global limiter, backend failures fail open.
    func hit(
        authenticatedAgent: AuthenticatedAgent,
        request: Request
    ) async -> FixedWindowRateLimitResult? {
        guard enabled else { return nil }

        let identity = authenticatedAgent.identity.key
        let count: RateLimitCount
        do {
            count = try await backend.hit(
                "rl:agent-mint:\(identity)",
                window: window,
                useValkey: request.application.valkeyEnabled)
        } catch {
            request.logger.error(
                "guest_identity_rate_limit_backend_error",
                metadata: [
                    "strato.agent.identity": .string(identity),
                    "error": .string(String(reflecting: error)),
                ])
            return nil
        }

        return FixedWindowRateLimitResult(limit: limit, count: count)
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
