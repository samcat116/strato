import Foundation
import Logging
import StratoShared
import Synchronization
import Testing

@testable import StratoAgentCore

/// Tests for the agent's desired-state long-poll loop (STR-146).
///
/// The fetcher is injected, so these drive the loop's decisions — when to send
/// a validator, what to do with each status — without a socket, a control
/// plane, or any TLS. The clock is injected too (STR-291), so the backoff
/// schedule is asserted exactly instead of slept out for real.
@Suite("Desired state poller")
struct DesiredStatePollerTests {

    /// Records what validator each fetch carried and answers from a script.
    private actor FakeControlPlane {
        private(set) var validators: [String?] = []
        private var responses: [Result<DesiredStatePollResponse, any Error>]
        /// Answer used once the script runs out, so a loop can keep turning.
        private let fallback: Result<DesiredStatePollResponse, any Error>

        init(
            responses: [Result<DesiredStatePollResponse, any Error>],
            fallback: Result<DesiredStatePollResponse, any Error>
        ) {
            self.responses = responses
            self.fallback = fallback
        }

        func answer(ifNoneMatch: String?) throws -> DesiredStatePollResponse {
            validators.append(ifNoneMatch)
            guard !responses.isEmpty else { return try fallback.get() }
            return try responses.removeFirst().get()
        }
    }

    private actor DeliveryLog {
        private(set) var envelopes: [MessageEnvelope] = []
        func append(_ envelope: MessageEnvelope) { envelopes.append(envelope) }
    }

    private static func syncEnvelope(vmCount: Int = 0) throws -> Data {
        let vms = (0..<vmCount).map { _ in
            DesiredVMState(
                vmId: UUID(),
                hypervisorType: .qemu,
                spec: VMSpec(cpus: 1, memoryBytes: 1 << 30, boot: .disk(firmware: nil)),
                desiredStatus: .running,
                generation: 1)
        }
        let envelope = try MessageEnvelope(message: DesiredStateMessage(vms: vms))
        return try WireProtocol.makeEncoder().encode(envelope)
    }

    private static func ok(etag: String, vmCount: Int = 0) throws -> DesiredStatePollResponse {
        DesiredStatePollResponse(
            status: 200, etag: etag, body: try syncEnvelope(vmCount: vmCount))
    }

    private static func notModified(etag: String) -> DesiredStatePollResponse {
        DesiredStatePollResponse(status: 304, etag: etag, body: Data())
    }

    /// A `200` whose body will not decode — the shape a bad control-plane
    /// deploy hands every agent in the site at once.
    private static func garbage() -> DesiredStatePollResponse {
        DesiredStatePollResponse(status: 200, etag: "\"bad\"", body: Data("not json".utf8))
    }

    /// A `200` carrying a well-formed envelope of the wrong message type.
    private static func wrongType() throws -> DesiredStatePollResponse {
        let envelope = try MessageEnvelope(
            message: AgentHeartbeatMessage(
                agentId: "a",
                resources: AgentResources(
                    totalCPU: 1, availableCPU: 1,
                    totalMemory: 1 << 30, availableMemory: 1 << 30,
                    totalDisk: 1 << 34, availableDisk: 1 << 34)))
        let body = try WireProtocol.makeEncoder().encode(envelope)
        return DesiredStatePollResponse(status: 200, etag: "\"x\"", body: body)
    }

    private func makePoller<PollClock: Clock>(
        controlPlane: FakeControlPlane,
        log: DeliveryLog,
        fullRefetchInterval: Duration = .seconds(300),
        clock: PollClock = ContinuousClock()
    ) -> DesiredStatePoller<PollClock> where PollClock.Duration == Duration {
        DesiredStatePoller(
            fetch: { ifNoneMatch in try await controlPlane.answer(ifNoneMatch: ifNoneMatch) },
            deliver: { envelope in await log.append(envelope) },
            logger: Logger(label: "test"),
            fullRefetchInterval: fullRefetchInterval,
            clock: clock)
    }

    // MARK: Validators

    /// An agent that has just registered has no ETag worth trusting, and
    /// starting from a full payload means the loop's first act is always to
    /// establish ground truth.
    @Test("The first fetch carries no validator")
    func firstFetchIsUnconditional() async throws {
        let cp = FakeControlPlane(responses: [], fallback: .success(try Self.ok(etag: "\"a\"")))
        let log = DeliveryLog()
        let poller = makePoller(controlPlane: cp, log: log, clock: TestClock())

        await poller.runOnce()

        #expect(await cp.validators == [nil])
        #expect(await log.envelopes.count == 1)
        #expect(await poller.lastSuccessfulFullRefetchAt != nil)
    }

    @Test("Subsequent fetches echo the last ETag")
    func subsequentFetchesAreConditional() async throws {
        let cp = FakeControlPlane(
            responses: [.success(try Self.ok(etag: "\"a\""))],
            fallback: .success(Self.notModified(etag: "\"a\"")))
        let log = DeliveryLog()
        let poller = makePoller(controlPlane: cp, log: log, clock: TestClock())

        await poller.runOnce()
        await poller.runOnce()
        await poller.runOnce()

        #expect(await cp.validators == [nil, "\"a\"", "\"a\""])
        // Only the 200 delivered; the 304s are the loop's idle state.
        #expect(await log.envelopes.count == 1)
        #expect(await poller.notModifiedResponses == 2)
    }

    /// The correctness invariant of the pull transport. A server whose notion
    /// of "unchanged" is wrong would answer an always-conditional client `304`
    /// forever, and the agent would sit on stale desired state with no error
    /// anywhere. The unconditional re-fetch is what bounds that.
    @Test("A stuck ETag still yields a full payload within one refetch interval")
    func stuckETagRecoversOnUnconditionalFetch() async throws {
        // A control plane that answers 304 to everything conditional, forever —
        // including after the desired state has genuinely changed.
        let cp = FakeControlPlane(
            responses: [.success(try Self.ok(etag: "\"stuck\"", vmCount: 0))],
            fallback: .success(Self.notModified(etag: "\"stuck\"")))
        let log = DeliveryLog()
        let clock = TestClock()
        let poller = makePoller(
            controlPlane: cp, log: log, fullRefetchInterval: .seconds(300), clock: clock)

        await poller.runOnce()  // unconditional, delivers
        clock.advance(by: .seconds(300))
        await poller.runOnce()  // interval elapsed → unconditional again

        #expect(await cp.validators == [nil, nil])
    }

    @Test("The refetch interval is measured from the last unconditional fetch")
    func conditionalUntilIntervalElapses() async throws {
        let cp = FakeControlPlane(
            responses: [.success(try Self.ok(etag: "\"a\""))],
            fallback: .success(Self.notModified(etag: "\"a\"")))
        let log = DeliveryLog()
        let poller = makePoller(
            controlPlane: cp, log: log, fullRefetchInterval: .seconds(300), clock: TestClock())

        await poller.runOnce()
        await poller.runOnce()
        await poller.runOnce()

        #expect(await cp.validators == [nil, "\"a\"", "\"a\""])
    }

    // MARK: Payload handling

    @Test("A 200 delivers the envelope and adopts its ETag")
    func payloadDeliveredAndETagAdopted() async throws {
        let cp = FakeControlPlane(
            responses: [
                .success(try Self.ok(etag: "\"first\"", vmCount: 1)),
                .success(try Self.ok(etag: "\"second\"", vmCount: 2)),
            ],
            fallback: .success(Self.notModified(etag: "\"second\"")))
        let log = DeliveryLog()
        let poller = makePoller(controlPlane: cp, log: log, clock: TestClock())

        await poller.runOnce()
        await poller.runOnce()
        await poller.runOnce()

        #expect(await cp.validators == [nil, "\"first\"", "\"second\""])
        let envelopes = await log.envelopes
        #expect(envelopes.count == 2)
        #expect(envelopes.allSatisfy { $0.type == .desiredState })
        #expect(await poller.deliveredSyncs == 2)
    }

    @Test("A conditional 200 does not advance the full-refetch clock")
    func conditionalPayloadDoesNotAdvanceFullRefetchClock() async throws {
        let cp = FakeControlPlane(
            responses: [
                .success(try Self.ok(etag: "\"first\"")),
                .success(try Self.ok(etag: "\"second\"")),
            ],
            fallback: .success(Self.notModified(etag: "\"second\"")))
        let poller = makePoller(controlPlane: cp, log: DeliveryLog(), clock: TestClock())

        await poller.runOnce()
        let afterFullRefetch = await poller.lastSuccessfulFullRefetchAt
        await poller.runOnce()

        #expect(await cp.validators == [nil, "\"first\""])
        #expect(await poller.lastSuccessfulFullRefetchAt == afterFullRefetch)
    }

    /// Staying conditional after failing to apply a payload would mean never
    /// being told again: the control plane believes it has already delivered.
    @Test("An undecodable payload drops the ETag so the next fetch is not conditional")
    func undecodablePayloadDropsETag() async throws {
        let cp = FakeControlPlane(
            responses: [.success(Self.garbage())],
            fallback: .success(try Self.ok(etag: "\"good\"")))
        let log = DeliveryLog()
        let poller = makePoller(controlPlane: cp, log: log, clock: TestClock())

        await poller.runOnce()
        #expect(await poller.lastSuccessfulFullRefetchAt == nil)
        await poller.runOnce()

        #expect(await cp.validators == [nil, nil])
        #expect(await log.envelopes.isEmpty == false)
        #expect(await log.envelopes.count == 1)
    }

    @Test("A message of the wrong type is not delivered to the reconciler")
    func wrongMessageTypeIgnored() async throws {
        let cp = FakeControlPlane(
            responses: [.success(try Self.wrongType())],
            fallback: .success(Self.notModified(etag: "\"x\"")))
        let log = DeliveryLog()
        let poller = makePoller(controlPlane: cp, log: log, clock: TestClock())

        await poller.runOnce()

        #expect(await log.envelopes.isEmpty)
        #expect(await poller.lastSuccessfulFullRefetchAt == nil)
    }

    // MARK: Failures

    @Test("A failed fetch backs off and does not consume the refetch interval")
    func failedFetchDoesNotConsumeInterval() async throws {
        struct Boom: Error {}
        let cp = FakeControlPlane(
            responses: [.failure(Boom())],
            fallback: .success(try Self.ok(etag: "\"a\"")))
        let log = DeliveryLog()
        let clock = TestClock()
        let poller = makePoller(
            controlPlane: cp, log: log, fullRefetchInterval: .seconds(300), clock: clock)

        await poller.runOnce()  // throws, spends the initial backoff on the clock
        #expect(clock.sleeps == [.seconds(1)])
        #expect(await poller.lastSuccessfulFullRefetchAt == nil)
        await poller.runOnce()

        // The retry is still unconditional: the first attempt never got an
        // answer, so it cannot have started the refetch clock.
        #expect(await cp.validators == [nil, nil])
        #expect(await log.envelopes.count == 1)
    }

    /// A `304` to a request that carried no validator is not an answer to the
    /// question asked. Keeping the old ETag would let the confusion compound
    /// into a permanently stuck conditional loop.
    @Test("A 304 to an unconditional fetch clears the ETag")
    func unconditional304ClearsETag() async throws {
        let cp = FakeControlPlane(
            responses: [
                .success(try Self.ok(etag: "\"a\"")),
                .success(Self.notModified(etag: "\"a\"")),
            ],
            fallback: .success(Self.notModified(etag: "\"a\"")))
        let log = DeliveryLog()
        let clock = TestClock()
        let poller = makePoller(
            controlPlane: cp, log: log, fullRefetchInterval: .seconds(300), clock: clock)

        await poller.runOnce()  // unconditional 200 → adopts "a"
        let afterSuccessfulResponse = await poller.lastSuccessfulFullRefetchAt
        clock.advance(by: .seconds(300))
        await poller.runOnce()  // unconditional again, answered 304
        let afterInvalidResponse = await poller.lastSuccessfulFullRefetchAt
        await poller.runOnce()

        #expect(await cp.validators == [nil, nil, nil])
        #expect(afterInvalidResponse == afterSuccessfulResponse)
        #expect(await poller.lastSuccessfulFullRefetchAt == afterSuccessfulResponse)
    }

    @Test("An unexpected unconditional status does not advance the full-refetch clock")
    func unexpectedStatusDoesNotAdvanceFullRefetchClock() async throws {
        let unexpected = DesiredStatePollResponse(status: 503, etag: nil, body: Data())
        let cp = FakeControlPlane(
            responses: [.success(unexpected)],
            fallback: .success(try Self.ok(etag: "\"a\"")))
        let poller = makePoller(controlPlane: cp, log: DeliveryLog(), clock: TestClock())

        await poller.runOnce()

        #expect(await cp.validators == [nil])
        #expect(await poller.lastSuccessfulFullRefetchAt == nil)
    }

    // MARK: Pacing (STR-291)

    /// The metastable case: an undecodable payload clears the ETag, so every
    /// retry is an unconditional request the control plane must answer with a
    /// freshly assembled full payload. Unpaced, the pair hot-loops.
    @Test("An undecodable payload backs off, doubling across consecutive failures")
    func undecodablePayloadBacksOff() async throws {
        let cp = FakeControlPlane(responses: [], fallback: .success(Self.garbage()))
        let clock = TestClock()
        let poller = makePoller(controlPlane: cp, log: DeliveryLog(), clock: clock)

        await poller.runOnce()
        await poller.runOnce()
        await poller.runOnce()

        #expect(clock.sleeps == [.seconds(1), .seconds(2), .seconds(4)])
        #expect(await poller.unusableResponses == 3)
    }

    @Test("A wrong-type payload backs off before the next attempt")
    func wrongTypePayloadBacksOff() async throws {
        let cp = FakeControlPlane(responses: [], fallback: .success(try Self.wrongType()))
        let clock = TestClock()
        let poller = makePoller(controlPlane: cp, log: DeliveryLog(), clock: clock)

        await poller.runOnce()
        await poller.runOnce()

        #expect(clock.sleeps == [.seconds(1), .seconds(2)])
        #expect(await poller.unusableResponses == 2)
    }

    @Test("An unconditional 304 backs off instead of re-polling immediately")
    func unconditional304BacksOff() async throws {
        // The first fetch is always unconditional, so a fallback of 304s is a
        // server (or intermediary) answering every unconditional request with
        // "not modified".
        let cp = FakeControlPlane(responses: [], fallback: .success(Self.notModified(etag: "\"a\"")))
        let clock = TestClock()
        let poller = makePoller(controlPlane: cp, log: DeliveryLog(), clock: clock)

        await poller.runOnce()
        await poller.runOnce()

        #expect(clock.sleeps == [.seconds(1), .seconds(2)])
        #expect(await poller.unusableResponses == 2)
        // An unconditional 304 is a protocol violation, not the idle state.
        #expect(await poller.notModifiedResponses == 0)
    }

    @Test("An unexpected status backs off before the next attempt")
    func unexpectedStatusBacksOff() async throws {
        let unexpected = DesiredStatePollResponse(status: 503, etag: nil, body: Data())
        let cp = FakeControlPlane(responses: [], fallback: .success(unexpected))
        let clock = TestClock()
        let poller = makePoller(controlPlane: cp, log: DeliveryLog(), clock: clock)

        await poller.runOnce()
        await poller.runOnce()

        #expect(clock.sleeps == [.seconds(1), .seconds(2)])
        #expect(await poller.unusableResponses == 2)
    }

    /// The backoff used to reset after any *completed* round trip, before the
    /// status was even examined — so a failure alternating between a transport
    /// error and an unusable `200` retried at the initial backoff forever.
    @Test("Alternating transport and unusable failures keep accumulating backoff")
    func alternatingFailuresAccumulateBackoff() async throws {
        struct Boom: Error {}
        let cp = FakeControlPlane(
            responses: [.failure(Boom()), .success(Self.garbage()), .failure(Boom())],
            fallback: .success(try Self.ok(etag: "\"a\"")))
        let clock = TestClock()
        let poller = makePoller(controlPlane: cp, log: DeliveryLog(), clock: clock)

        await poller.runOnce()
        await poller.runOnce()
        await poller.runOnce()

        #expect(clock.sleeps == [.seconds(1), .seconds(2), .seconds(4)])
    }

    @Test("A delivered 200 resets the backoff")
    func deliveredPayloadResetsBackoff() async throws {
        let cp = FakeControlPlane(
            responses: [
                .success(Self.garbage()),
                .success(Self.garbage()),
                .success(try Self.ok(etag: "\"a\"")),
                .success(Self.garbage()),
            ],
            fallback: .success(try Self.ok(etag: "\"a\"")))
        let clock = TestClock()
        let poller = makePoller(controlPlane: cp, log: DeliveryLog(), clock: clock)

        await poller.runOnce()  // garbage → 1s
        await poller.runOnce()  // garbage → 2s
        await poller.runOnce()  // delivered → reset, no sleep
        await poller.runOnce()  // garbage → back to 1s, not 4s

        #expect(clock.sleeps == [.seconds(1), .seconds(2), .seconds(1)])
        #expect(await poller.deliveredSyncs == 1)
        #expect(await poller.unusableResponses == 3)
    }

    @Test("A conditional 304 resets the backoff")
    func conditional304ResetsBackoff() async throws {
        struct Boom: Error {}
        let cp = FakeControlPlane(
            responses: [
                .success(try Self.ok(etag: "\"a\"")),
                .failure(Boom()),
                .failure(Boom()),
                .success(Self.notModified(etag: "\"a\"")),
                .failure(Boom()),
            ],
            fallback: .success(try Self.ok(etag: "\"a\"")))
        let clock = TestClock()
        let poller = makePoller(controlPlane: cp, log: DeliveryLog(), clock: clock)

        await poller.runOnce()  // unconditional 200, no sleep
        await poller.runOnce()  // transport error → 1s
        await poller.runOnce()  // transport error → 2s
        await poller.runOnce()  // conditional 304 → reset; instant answer sleeps the 1s floor
        await poller.runOnce()  // transport error → back to 1s, not 4s

        #expect(clock.sleeps == [.seconds(1), .seconds(2), .seconds(1), .seconds(1)])
    }

    /// Re-polling immediately after a conditional `304` is safe only because
    /// the server spent its hold window parked. The floor makes a server that
    /// answers instantly non-catastrophic by construction.
    @Test("A conditional 304 answered instantly is floored")
    func instantConditional304IsFloored() async throws {
        let cp = FakeControlPlane(
            responses: [.success(try Self.ok(etag: "\"a\""))],
            fallback: .success(Self.notModified(etag: "\"a\"")))
        let clock = TestClock()
        let poller = makePoller(controlPlane: cp, log: DeliveryLog(), clock: clock)

        await poller.runOnce()
        await poller.runOnce()

        #expect(clock.sleeps == [DesiredStatePoller<TestClock>.minimumConditionalPollInterval])
        #expect(await poller.notModifiedResponses == 1)
    }

    @Test("A conditional 304 that consumed the server's hold window is not floored")
    func parkedConditional304IsNotFloored() async throws {
        let cp = FakeControlPlane(
            responses: [.success(try Self.ok(etag: "\"a\""))],
            fallback: .success(Self.notModified(etag: "\"a\"")))
        let clock = TestClock()
        let poller = DesiredStatePoller(
            fetch: { ifNoneMatch in
                let response = try await cp.answer(ifNoneMatch: ifNoneMatch)
                // The healthy server parks conditional polls for its hold
                // window before answering 304.
                if ifNoneMatch != nil { clock.advance(by: .seconds(25)) }
                return response
            },
            deliver: { _ in },
            logger: Logger(label: "test"),
            fullRefetchInterval: .seconds(300),
            clock: clock)

        await poller.runOnce()
        await poller.runOnce()

        #expect(clock.sleeps.isEmpty)
        #expect(await poller.notModifiedResponses == 1)
    }

    // MARK: Lifecycle

    @Test("start is idempotent and stop unwinds the loop")
    func lifecycleIsIdempotent() async throws {
        // Deliberately on the real clock: stop() must cancel a loop that is
        // genuinely parked in a backoff sleep, not one whose sleeps return
        // immediately.
        let cp = FakeControlPlane(responses: [], fallback: .success(Self.notModified(etag: "\"a\"")))
        let log = DeliveryLog()
        let poller = makePoller(controlPlane: cp, log: log)

        await poller.start()
        await poller.start()
        #expect(await poller.isRunning)

        await poller.stop()
        #expect(await poller.isRunning == false)
    }
}

// MARK: - Test doubles

/// A clock the poller reads and sleeps on instead of the wall. `sleep`
/// returns immediately, recording the requested delay and advancing `now`
/// past the deadline, so a backoff schedule is asserted exactly and without
/// wall time; `advance(by:)` elapses idle time (such as the full-refetch
/// interval) between polls.
private final class TestClock: Clock, Sendable {
    struct Instant: InstantProtocol, Hashable, Sendable {
        var offset: Duration = .zero
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct State {
        var now = Instant()
        var sleeps: [Duration] = []
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock(\.now) }
    var minimumResolution: Duration { .zero }
    /// Every delay the poller slept, in order.
    var sleeps: [Duration] { state.withLock(\.sleeps) }

    func advance(by duration: Duration) {
        state.withLock { $0.now = $0.now.advanced(by: duration) }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        state.withLock {
            $0.sleeps.append($0.now.duration(to: deadline))
            if deadline > $0.now { $0.now = deadline }
        }
    }
}
