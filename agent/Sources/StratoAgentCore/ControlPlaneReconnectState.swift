/// Actor-owned bookkeeping for the control-plane WebSocket reconnect loop.
///
/// `Agent` owns and mutates this value from its actor. Keeping the transition
/// rules here makes the important race testable without importing the agent's
/// executable target.
public struct ControlPlaneReconnectState: Sendable {
    public enum LossDisposition: Equatable, Sendable {
        case startLoop
        case loopAlreadyActive
    }

    public struct Attempt: Equatable, Sendable {
        fileprivate let lossGeneration: UInt64
    }

    private var lossGeneration: UInt64 = 0
    private var loopActive = false
    private var startupLossPending = false

    public init() {}

    /// Remembers a socket close that arrives before `Agent.start()` has entered
    /// its steady running state. Startup cannot launch the reconnect loop while
    /// its initial registration is still unwinding, but it must not forget the
    /// close and later declare that dead socket healthy.
    public mutating func recordStartupConnectionLoss() {
        lossGeneration &+= 1
        startupLossPending = true
    }

    public var connectionWasLostDuringStartup: Bool {
        startupLossPending
    }

    /// Consumes the startup edge when `Agent.start()` is ready to hand recovery
    /// to the ordinary reconnect loop.
    public mutating func consumeStartupConnectionLoss() -> Bool {
        defer { startupLossPending = false }
        return startupLossPending
    }

    /// Records an unexpected socket close and says whether it needs to start
    /// the single reconnect loop.
    public mutating func recordConnectionLoss() -> LossDisposition {
        // Every close matters, including one that arrives while the reconnect
        // loop is restoring connection-scoped state. Advancing first makes the
        // current attempt stale without spawning a duplicate loop.
        lossGeneration &+= 1
        guard !loopActive else { return .loopAlreadyActive }
        loopActive = true
        return .startLoop
    }

    /// Captures the connection-loss generation a reconnect attempt is trying
    /// to recover from.
    public func beginAttempt() -> Attempt {
        Attempt(lossGeneration: lossGeneration)
    }

    /// True only when no newer socket loss arrived while the attempt was
    /// connecting, registering, or restoring connection-scoped state.
    public func canFinish(_ attempt: Attempt) -> Bool {
        loopActive && attempt.lossGeneration == lossGeneration
    }

    public mutating func finishLoop() {
        loopActive = false
    }
}

/// Fences frontend-bound frames to the registered socket that activated them.
/// A frame can sit in a per-session serial lane while its socket closes; the
/// generation check keeps that stale work from starting after a successor has
/// registered.
public struct ControlPlaneInteractiveSessionFence: Sendable {
    private var activeGeneration: ControlPlaneWebSocketState.Generation?

    public init() {}

    public mutating func activate(
        generation: ControlPlaneWebSocketState.Generation
    ) {
        activeGeneration = generation
    }

    public mutating func quiesce() {
        activeGeneration = nil
    }

    public func accepts(
        generation: ControlPlaneWebSocketState.Generation
    ) -> Bool {
        activeGeneration == generation
    }
}
