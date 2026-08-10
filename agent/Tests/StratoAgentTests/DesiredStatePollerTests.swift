import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

/// Tests for the agent's desired-state long-poll loop (STR-146).
///
/// The fetcher is injected, so these drive the loop's decisions — when to send
/// a validator, what to do with each status — without a socket, a control
/// plane, or any TLS.
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

    private func makePoller(
        controlPlane: FakeControlPlane,
        log: DeliveryLog,
        fullRefetchInterval: Duration = .seconds(300)
    ) -> DesiredStatePoller {
        DesiredStatePoller(
            fetch: { ifNoneMatch in try await controlPlane.answer(ifNoneMatch: ifNoneMatch) },
            deliver: { envelope in await log.append(envelope) },
            logger: Logger(label: "test"),
            fullRefetchInterval: fullRefetchInterval)
    }

    // MARK: Validators

    /// An agent that has just registered has no ETag worth trusting, and
    /// starting from a full payload means the loop's first act is always to
    /// establish ground truth.
    @Test("The first fetch carries no validator")
    func firstFetchIsUnconditional() async throws {
        let cp = FakeControlPlane(responses: [], fallback: .success(try Self.ok(etag: "\"a\"")))
        let log = DeliveryLog()
        let poller = makePoller(controlPlane: cp, log: log)

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
        let poller = makePoller(controlPlane: cp, log: log)

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
        let poller = makePoller(controlPlane: cp, log: log, fullRefetchInterval: .milliseconds(1))

        await poller.runOnce()  // unconditional, delivers
        try await Task.sleep(for: .milliseconds(5))
        await poller.runOnce()  // interval elapsed → unconditional again

        #expect(await cp.validators == [nil, nil])
    }

    @Test("The refetch interval is measured from the last unconditional fetch")
    func conditionalUntilIntervalElapses() async throws {
        let cp = FakeControlPlane(
            responses: [.success(try Self.ok(etag: "\"a\""))],
            fallback: .success(Self.notModified(etag: "\"a\"")))
        let log = DeliveryLog()
        let poller = makePoller(controlPlane: cp, log: log, fullRefetchInterval: .seconds(300))

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
        let poller = makePoller(controlPlane: cp, log: log)

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
        let poller = makePoller(controlPlane: cp, log: DeliveryLog())

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
        let garbage = DesiredStatePollResponse(
            status: 200, etag: "\"bad\"", body: Data("not json".utf8))
        let cp = FakeControlPlane(
            responses: [.success(garbage)],
            fallback: .success(try Self.ok(etag: "\"good\"")))
        let log = DeliveryLog()
        let poller = makePoller(controlPlane: cp, log: log)

        await poller.runOnce()
        #expect(await poller.lastSuccessfulFullRefetchAt == nil)
        await poller.runOnce()

        #expect(await cp.validators == [nil, nil])
        #expect(await log.envelopes.isEmpty == false)
        #expect(await log.envelopes.count == 1)
    }

    @Test("A message of the wrong type is not delivered to the reconciler")
    func wrongMessageTypeIgnored() async throws {
        let envelope = try MessageEnvelope(
            message: AgentHeartbeatMessage(
                agentId: "a",
                resources: AgentResources(
                    totalCPU: 1, availableCPU: 1,
                    totalMemory: 1 << 30, availableMemory: 1 << 30,
                    totalDisk: 1 << 34, availableDisk: 1 << 34)))
        let body = try WireProtocol.makeEncoder().encode(envelope)
        let cp = FakeControlPlane(
            responses: [
                .success(DesiredStatePollResponse(status: 200, etag: "\"x\"", body: body))
            ],
            fallback: .success(Self.notModified(etag: "\"x\"")))
        let log = DeliveryLog()
        let poller = makePoller(controlPlane: cp, log: log)

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
        let poller = makePoller(controlPlane: cp, log: log, fullRefetchInterval: .seconds(300))

        await poller.runOnce()  // throws, sleeps out the initial backoff
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
        let poller = makePoller(controlPlane: cp, log: log, fullRefetchInterval: .milliseconds(1))

        await poller.runOnce()  // unconditional 200 → adopts "a"
        let afterSuccessfulResponse = await poller.lastSuccessfulFullRefetchAt
        try await Task.sleep(for: .milliseconds(5))
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
        let poller = makePoller(controlPlane: cp, log: DeliveryLog())

        await poller.runOnce()

        #expect(await cp.validators == [nil])
        #expect(await poller.lastSuccessfulFullRefetchAt == nil)
    }

    // MARK: Lifecycle

    @Test("start is idempotent and stop unwinds the loop")
    func lifecycleIsIdempotent() async throws {
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
