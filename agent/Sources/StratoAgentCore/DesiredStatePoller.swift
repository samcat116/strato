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
///
/// ## Pacing
///
/// Every attempt that produces nothing the loop can act on — a thrown fetch,
/// but equally a `200` whose body will not decode, a wrong message type, a
/// `304` answering an unconditional request, or a status outside the contract
/// — backs off on one shared 1s → 30s doubling schedule (STR-291). The
/// unusable-response cases matter *more* than the transport ones: they drop
/// the ETag, which makes the next request unconditional, which the control
/// plane must answer with a freshly assembled full payload — and their trigger
/// is usually a property of the control plane's output, so it fires for every
/// agent in the site at once. Unpaced, that is a correlated full-assembly
/// storm against the database at the exact moment the control plane is
/// already in trouble. The backoff resets only on a response the loop could
/// actually use: a delivered `200`, or a `304` answering a conditional
/// request. The clock is generic rather than a concrete `ContinuousClock` so
/// tests can assert that schedule without sleeping it out for real.
public actor DesiredStatePoller<PollClock: Clock> where PollClock.Duration == Duration {
    /// One long-poll attempt. Injected so tests drive the loop without a socket.
    public typealias Fetcher = @Sendable (_ ifNoneMatch: String?) async throws -> DesiredStatePollResponse

    /// Where a received sync goes — in production, the ordinary inbound-message
    /// route and its `.desiredState` serialization lane.
    public typealias Deliver = @Sendable (MessageEnvelope) async -> Void

    /// How long between forced unconditional fetches. See the type doc: this
    /// is the correctness invariant, so it is short enough to bound an ETag
    /// bug to a few minutes and long enough that the steady state is still
    /// almost entirely `304`s. (Computed because generic types cannot hold
    /// static storage.)
    public static var defaultFullRefetchInterval: Duration { .seconds(300) }

    /// The floor under back-to-back conditional polls. A healthy control
    /// plane spends its hold window parked before answering a conditional
    /// `304`, so this normally costs nothing; it exists so a server or
    /// intermediary that answers instantly produces a bounded request rate
    /// instead of a hot loop. That safety used to be an assumption about the
    /// *server's* behavior held only in a comment here — this makes it true
    /// by construction.
    static var minimumConditionalPollInterval: Duration { .seconds(1) }

    private let fetch: Fetcher
    private let deliver: Deliver
    private let logger: Logger
    private let fullRefetchInterval: Duration
    private let clock: PollClock

    /// Backoff bounds for a failing poll, matching the WebSocket reconnect
    /// loop's shape so a control plane that is down produces one recognizable
    /// retry cadence rather than two.
    private static var initialBackoff: Duration { .seconds(1) }
    private static var maximumBackoff: Duration { .seconds(30) }

    private var lastETag: String?
    /// Advances only after a request without a validator receives and decodes
    /// a full desired-state payload. Internal visibility lets focused tests
    /// assert the backstop clock directly.
    private(set) var lastSuccessfulFullRefetchAt: PollClock.Instant?
    private var backoff: Duration
    /// The current streak of unusable responses, unbroken by interleaved
    /// transport errors. Decides which occurrence logs at `error`; reset only
    /// with the backoff, by a usable response.
    private var consecutiveUnusableResponses = 0
    private var task: Task<Void, Never>?

    /// Counters for tests and for the agent's own diagnostics.
    public private(set) var deliveredSyncs = 0
    public private(set) var notModifiedResponses = 0
    /// Fetches that completed but returned something the loop could not act
    /// on: an undecodable payload, a wrong message type, an unconditional
    /// `304`, an unexpected status. A sustained nonzero rate here means this
    /// agent is not converging on anything at all — and because the trigger
    /// is usually the control plane's output, neither is anyone else.
    public private(set) var unusableResponses = 0

    public init(
        fetch: @escaping Fetcher,
        deliver: @escaping Deliver,
        logger: Logger,
        fullRefetchInterval: Duration = DesiredStatePoller.defaultFullRefetchInterval,
        clock: PollClock = ContinuousClock()
    ) {
        self.fetch = fetch
        self.deliver = deliver
        self.logger = logger
        self.fullRefetchInterval = fullRefetchInterval
        self.clock = clock
        self.backoff = Self.initialBackoff
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
        let attemptStart = clock.now
        // Nil on the very first pass: an agent that has just (re)registered has
        // no ETag worth trusting anyway, and starting from a full payload means
        // the loop's first act is always to establish ground truth.
        let fullRefetchDue =
            lastSuccessfulFullRefetchAt.map { $0.duration(to: attemptStart) >= fullRefetchInterval } ?? true
        // A failed decode drops the ETag. Even before the interval elapses the
        // next request is therefore unconditional, and a valid response to it
        // must advance the full-refetch clock.
        let ifNoneMatch = fullRefetchDue ? nil : lastETag
        let unconditional = ifNoneMatch == nil

        let response: DesiredStatePollResponse
        do {
            response = try await fetch(ifNoneMatch)
        } catch {
            await backOff(after: .transport(error))
            return
        }

        switch response.status {
        case 200:
            if let failure = await handlePayload(response.body) {
                // Staying conditional after failing to apply a payload would
                // mean never being told again: the control plane believes it
                // has already delivered. Dropping the ETag is what makes the
                // retry a full fetch — and exactly why the retry must be
                // paced, because an unconditional request is never parked and
                // always costs the control plane a complete assembly.
                lastETag = nil
                await backOff(after: .unusable(failure))
            } else {
                lastETag = response.etag
                // Recorded only after validating the full payload, so a
                // transport failure, unexpected status, malformed body, or
                // wrong message type cannot consume the interval.
                if unconditional { lastSuccessfulFullRefetchAt = clock.now }
                noteUsableResponse()
            }
        case 304 where unconditional:
            // The control plane answered a request that carried no validator
            // with "not modified", which is not an answer to the question
            // asked. Keep the old ETag out of it so the next conditional
            // fetch cannot compound the confusion — and back off, because
            // whatever answered this way (an intermediary answering from a
            // cache, a control-plane bug on the unconditional path) will
            // answer an immediate retry the same way.
            lastETag = nil
            await backOff(after: .unusable("a 304 answered an unconditional request"))
        case 304:
            notModifiedResponses += 1
            // Nothing changed: this is the loop's idle state, not a failure.
            noteUsableResponse()
            // Normally the poll spent the server's hold window suspended and
            // the re-poll is effectively immediate; a suspiciously fast
            // answer is floored instead. Delivered `200`s are deliberately
            // exempt from the floor — a burst of real changes should
            // converge at full speed.
            await enforceConditionalPollFloor(since: attemptStart)
        default:
            await backOff(after: .unusable("unexpected status \(response.status)"))
        }
    }

    /// Decode and deliver one `200` body. Returns nil on success, or a
    /// description of why the response was unusable, for `backOff`'s log line.
    private func handlePayload(_ body: Data) async -> String? {
        do {
            let envelope = try WireProtocol.makeDecoder().decode(MessageEnvelope.self, from: body)
            guard envelope.type == .desiredState else {
                return "unexpected message type '\(envelope.type.rawValue)'"
            }
            deliveredSyncs += 1
            await deliver(envelope)
            return nil
        } catch {
            // A payload we cannot decode is not retryable by re-fetching the
            // same bytes — and yet the retry *will* fetch equivalent bytes,
            // because the dropped ETag makes it unconditional. What actually
            // breaks the loop is a control-plane fix or the next change to
            // desired state, so the backoff's job is to make the wait cheap.
            return "undecodable payload: \(error)"
        }
    }

    /// Why one poll attempt produced nothing the loop could act on.
    private enum PollFailure {
        /// The fetch itself threw: connection refused, timeout, TLS failure.
        case transport(any Error)
        /// The fetch completed and the response was unusable. Distinct from
        /// `transport` because these are properties of the control plane's
        /// *output* rather than of one host's network path — when one fires
        /// it usually fires for the whole site at once, which is why the
        /// first occurrence logs at `error` and why pacing the retry matters
        /// most here.
        case unusable(String)
    }

    /// Sleep out the current backoff, then double it toward the ceiling.
    /// Both failure shapes share the one schedule so a failing control plane
    /// produces a single recognizable cadence rather than two.
    private func backOff(after failure: PollFailure) async {
        switch failure {
        case .transport(let error):
            logger.warning(
                "Desired-state poll failed; retrying",
                metadata: [
                    "error": .string("\(error)"),
                    "retryIn": .stringConvertible(backoff.components.seconds),
                ])
        case .unusable(let reason):
            unusableResponses += 1
            consecutiveUnusableResponses += 1
            // The first occurrence in a streak is the page. Repeats are
            // already paced to the backoff cadence, and demoting them keeps a
            // long control-plane outage from flooding error-level alerting —
            // the fix must not relocate the hot loop into the log pipeline.
            let level: Logger.Level = consecutiveUnusableResponses == 1 ? .error : .warning
            logger.log(
                level: level,
                "Desired-state poll returned an unusable response; backing off",
                metadata: [
                    "reason": .string(reason),
                    "consecutive": .stringConvertible(consecutiveUnusableResponses),
                    "retryIn": .stringConvertible(backoff.components.seconds),
                ])
        }
        try? await clock.sleep(until: clock.now.advanced(by: backoff), tolerance: nil)
        backoff = min(backoff * 2, Self.maximumBackoff)
    }

    /// A usable response — a delivered `200`, or a `304` answering a
    /// conditional request — is the only thing that resets the backoff.
    /// Resetting on any *completed* round trip (as this loop once did, before
    /// the status was even examined) let a failure alternating between a
    /// transport error and an unusable `200` retry at the initial backoff
    /// forever.
    private func noteUsableResponse() {
        backoff = Self.initialBackoff
        consecutiveUnusableResponses = 0
    }

    /// Sleep out whatever remains of `minimumConditionalPollInterval` since
    /// the attempt began. See that constant for why.
    private func enforceConditionalPollFloor(since attemptStart: PollClock.Instant) async {
        guard attemptStart.duration(to: clock.now) < Self.minimumConditionalPollInterval else { return }
        try? await clock.sleep(
            until: attemptStart.advanced(by: Self.minimumConditionalPollInterval), tolerance: nil)
    }
}
