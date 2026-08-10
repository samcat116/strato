import Foundation
import Logging
import StratoShared

/// One long-poll response: the status, the ETag to echo on the next
/// conditional request, and the body (empty for `304`).
public struct DesiredStatePollResponse: Sendable {
    public let status: UInt
    public let etag: String?
    public let body: Data

    public init(status: UInt, etag: String?, body: Data) {
        self.status = status
        self.etag = etag
        self.body = body
    }
}

/// Fetches this agent's desired state from the control plane's long-poll
/// endpoint (ADR 0001 stage 10, STR-146), replacing the pushed `desired_state`
/// frame on the WebSocket.
///
/// The loop is deliberately dumb. It fetches, hands whatever comes back to the
/// ordinary inbound message path, and fetches again. There is no local model
/// of what the control plane thinks it has sent, no
/// reconstruction of missed updates, no ordering to preserve beyond the one the
/// message queue already provides — every response is the complete, current,
/// authoritative desired state.
///
/// ## The conditional/unconditional split
///
/// Most fetches carry `If-None-Match` so the control plane can park them and
/// answer `304`. That is a bandwidth optimization and nothing more, and the one
/// way to turn it into a correctness bug is to make *every* fetch conditional —
/// which is also the most natural way to write an HTTP client. If the server's
/// notion of "unchanged" is ever wrong (a stale digest, a bug in what gets
/// normalized out of it, a proxy rewriting ETags), an always-conditional client
/// receives `304` forever and the agent is stranded with no error anywhere.
///
/// So `fullRefetchInterval` is a hard rule, not a tuning knob: past it the next
/// fetch omits `If-None-Match` entirely and the control plane must answer with a
/// full payload. That bounds how long any conceivable ETag bug can hide.
public actor DesiredStatePoller {
    /// One long-poll attempt. Injected so tests drive the loop without a socket.
    public typealias Fetcher = @Sendable (_ ifNoneMatch: String?) async throws -> DesiredStatePollResponse

    /// Where a received sync goes — in production, the ordinary inbound-message
    /// route and its `.desiredState` serialization lane.
    public typealias Deliver = @Sendable (MessageEnvelope) async -> Void

    /// How long between forced unconditional fetches. See the type doc: this
    /// is the correctness invariant, so it is short enough to bound an ETag
    /// bug to a few minutes and long enough that the steady state is still
    /// almost entirely `304`s.
    public static let defaultFullRefetchInterval: Duration = .seconds(300)

    private let fetch: Fetcher
    private let deliver: Deliver
    private let logger: Logger
    private let fullRefetchInterval: Duration
    private let clock: ContinuousClock

    /// Backoff bounds for a failing poll, matching the WebSocket reconnect
    /// loop's shape so a control plane that is down produces one recognizable
    /// retry cadence rather than two.
    private static let initialBackoff: Duration = .seconds(1)
    private static let maximumBackoff: Duration = .seconds(30)

    private var lastETag: String?
    /// Advances only after a request without a validator receives and decodes
    /// a full desired-state payload. Internal visibility lets focused tests
    /// assert the backstop clock directly.
    private(set) var lastSuccessfulFullRefetchAt: ContinuousClock.Instant?
    private var backoff: Duration = DesiredStatePoller.initialBackoff
    private var task: Task<Void, Never>?

    /// Counters for tests and for the agent's own diagnostics.
    public private(set) var deliveredSyncs = 0
    public private(set) var notModifiedResponses = 0

    public init(
        fetch: @escaping Fetcher,
        deliver: @escaping Deliver,
        logger: Logger,
        fullRefetchInterval: Duration = DesiredStatePoller.defaultFullRefetchInterval,
        clock: ContinuousClock = ContinuousClock()
    ) {
        self.fetch = fetch
        self.deliver = deliver
        self.logger = logger
        self.fullRefetchInterval = fullRefetchInterval
        self.clock = clock
    }

    /// Start polling. Idempotent: a second call while running is a no-op, so a
    /// reconnect that re-runs registration cannot end up with two loops racing
    /// each other's ETag.
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runOnce()
            }
        }
    }

    /// Stop polling and wait for the in-flight attempt to unwind, so a caller
    /// tearing down the agent doesn't leave a request holding a connection.
    public func stop() async {
        guard let task else { return }
        self.task = nil
        task.cancel()
        await task.value
    }

    public var isRunning: Bool { task != nil }

    /// One fetch/deliver/back-off cycle. Internal rather than private so tests
    /// can step the loop deterministically instead of racing `start()`.
    func runOnce() async {
        let now = clock.now
        // Nil on the very first pass: an agent that has just (re)registered has
        // no ETag worth trusting anyway, and starting from a full payload means
        // the loop's first act is always to establish ground truth.
        let fullRefetchDue =
            lastSuccessfulFullRefetchAt.map { now - $0 >= fullRefetchInterval } ?? true
        // A failed decode drops the ETag. Even before the interval elapses the
        // next request is therefore unconditional, and a valid response to it
        // must advance the full-refetch clock.
        let ifNoneMatch = fullRefetchDue ? nil : lastETag
        let unconditional = ifNoneMatch == nil

        let response: DesiredStatePollResponse
        do {
            response = try await fetch(ifNoneMatch)
        } catch {
            await backOff(after: error)
            return
        }

        backoff = Self.initialBackoff

        switch response.status {
        case 200:
            if await handlePayload(response.body) {
                lastETag = response.etag
                // Recorded only after validating the full payload, so a
                // transport failure, unexpected status, malformed body, or
                // wrong message type cannot consume the interval.
                if unconditional { lastSuccessfulFullRefetchAt = clock.now }
            } else {
                lastETag = nil
            }
        case 304:
            notModifiedResponses += 1
            // Nothing changed and the poll has already spent the server's hold
            // window suspended, so this is the loop's idle state, not a
            // failure. Re-poll immediately.
            if unconditional {
                // The control plane answered a request that carried no
                // validator with "not modified", which is not an answer to the
                // question asked. Keep the old ETag out of it so the next
                // conditional fetch cannot compound the confusion.
                logger.warning("Control plane answered an unconditional desired-state fetch with 304")
                lastETag = nil
            }
        default:
            logger.warning(
                "Unexpected desired-state poll status",
                metadata: ["status": .stringConvertible(response.status)])
        }
    }

    private func handlePayload(_ body: Data) async -> Bool {
        do {
            let envelope = try WireProtocol.makeDecoder().decode(MessageEnvelope.self, from: body)
            guard envelope.type == .desiredState else {
                logger.warning(
                    "Desired-state poll returned an unexpected message type",
                    metadata: ["type": .string(envelope.type.rawValue)])
                return false
            }
            deliveredSyncs += 1
            await deliver(envelope)
            return true
        } catch {
            // A payload we cannot decode is not retryable by re-fetching the
            // same bytes, but the next change (or the next unconditional
            // fetch) produces a different payload, so the loop keeps running.
            logger.error(
                "Failed to decode a desired-state poll payload",
                metadata: ["error": .string("\(error)")])
            return false
        }
    }

    private func backOff(after error: any Error) async {
        logger.warning(
            "Desired-state poll failed; retrying",
            metadata: [
                "error": .string("\(error)"),
                "retryIn": .stringConvertible(backoff.components.seconds),
            ])
        try? await Task.sleep(for: backoff, clock: clock)
        backoff = min(backoff * 2, Self.maximumBackoff)
    }
}
