import Foundation
import StratoShared
import Testing
@testable import StratoAgentCore

@Suite("Idle v5 adapter and monotonic sampling")
struct SandboxIdleWireTests {
    enum Failure: Error { case lost, revoked }
    actor Peer {
        var state: SandboxIdleGuestResponse.State = .absent
        var lostPrepare = true
        var valid = true
        var probes = 0
        var prepares = 0
        var guestCalls = 0
        var staleNonce = false
        let monitor = UUID()
        func revoke() { valid = false }
        func stale() { staleNonce = true }
        func validate(_ context: SandboxSuspensionFenceContext) throws {
            if !valid { throw Failure.revoked }
        }
        func exchange(_ context: SandboxSuspensionFenceContext, request: SandboxIdleGuestRequest) throws
            -> SandboxIdleGuestResponse
        {
            guestCalls += 1
            let fence = context.fence.request
            let nonce = staleNonce ? "stale" : context.fence.identityNonce
            if request.type == .activity {
                probes += 1
                return SandboxIdleGuestResponse(
                    type: .activity, sandboxId: context.sandboxId.uuidString, nonce: nonce,
                    activity: SandboxIdleWireTests.guest(
                        id: context.sandboxId.uuidString, nonce: nonce,
                        probe: request.probeId!, monitor: monitor))
            }
            #expect(request.operationId == fence.operationId && request.admissionToken == fence.admissionToken)
            if request.type == .prepare {
                #expect(request.expectedActivityEpoch == 1 && request.minimumQuietMilliseconds == 300_000)
                prepares += 1; state = .prepared
                if lostPrepare { lostPrepare = false; throw Failure.lost }
            }
            if request.type == .release { state = .released }
            return SandboxIdleGuestResponse(
                type: .fence, sandboxId: context.sandboxId.uuidString, nonce: nonce,
                operationId: fence.operationId, admissionToken: fence.admissionToken, state: state)
        }
        func counts() -> (Int, Int, Int) { (probes, prepares, guestCalls) }
    }
    static func guest(
        id: String = "sandbox", nonce: String = "nonce", probe: UUID = UUID(),
        monitor: UUID, sequence: UInt64 = 1, epoch: UInt64 = 1, cpu: UInt64? = 0,
        sessions: [UUID]? = []
    ) -> SandboxGuestIdleActivity {
        SandboxGuestIdleActivity(
            sandboxId: id, nonce: nonce, probeId: probe, monitorIncarnation: monitor,
            sampleSequence: sequence, activityEpoch: epoch, quietForMilliseconds: 600_000,
            coverage: .complete, trusted: true, activeExecSessionIds: sessions, anonymousExecCount: 0,
            pendingExecCount: 0, workloadCpuMicroseconds: cpu, workloadReadBytes: 0,
            workloadWriteBytes: 0, externalSocketCount: 0, nicCount: 0)
    }
    @Test func realAdapterRecoversLostPrepareAndValidatesPausedGuestThroughCPOnly() async throws {
        let fixture = try SandboxAutomaticSuspensionTests.Fixture(); defer { fixture.cleanup() }
        let peer = Peer()
        let adapter = SandboxIdleFenceTransport(
            minimumQuietMilliseconds: 300_000,
            exchange: { try await peer.exchange($0, request: $1) }, validate: { try await peer.validate($0) })
        let lifecycle = SandboxAutomaticSuspensionLifecycle(store: fixture.store, transport: adapter)
        await #expect(throws: Failure.self) { try await lifecycle.prepare(fixture.record) }
        let pending = try #require(try fixture.store.load(sandboxId: fixture.record.sandboxId))
        let restarted = SandboxAutomaticSuspensionLifecycle(store: fixture.store, transport: adapter)
        let prepared = try await restarted.prepare(pending)
        let before = await peer.counts()
        #expect(before.0 == 1 && before.1 == 1)
        try await restarted.validateDestruction(prepared)
        #expect(await peer.counts().2 == before.2)
        await peer.revoke()
        await #expect(throws: Failure.self) { try await restarted.validateDestruction(prepared) }
        let released = try await restarted.release(prepared)
        #expect(released.guestFence?.state == .released)
    }
    @Test func wrongIdentityRefusesAdapterBeforePrepare() async throws {
        let fixture = try SandboxAutomaticSuspensionTests.Fixture(); defer { fixture.cleanup() }
        let peer = Peer(); await peer.stale()
        let adapter = SandboxIdleFenceTransport(
            minimumQuietMilliseconds: 300_000,
            exchange: { try await peer.exchange($0, request: $1) }, validate: { try await peer.validate($0) })
        await #expect(throws: SandboxSuspensionGuard.GateError.self) {
            try await adapter.prepare(SandboxSuspensionFenceContext(record: fixture.record))
        }
        #expect(await peer.counts().1 == 0)
    }
    @Test func replayRestartCountersAndUnknownResetMonotonicQuietWindow() {
        let start = ContinuousClock.now, monitor = UUID()
        var sampler = SandboxIdleSampler(at: start)
        #expect(!sampler.sample(Self.guest(monitor: monitor), at: start).known)
        let quiet = sampler.sample(Self.guest(monitor: monitor, sequence: 2), at: start + .seconds(300))
        #expect(quiet.known && quiet.quietMilliseconds == 300_000 && quiet.residentMilliseconds == 300_000)
        let replay = sampler.sample(Self.guest(monitor: monitor, sequence: 2), at: start + .seconds(301))
        #expect(!replay.known && replay.quietMilliseconds == 0)
        #expect(!sampler.sample(Self.guest(monitor: monitor, sequence: 1), at: start + .seconds(302)).known)
        #expect(!sampler.sample(Self.guest(monitor: monitor, sequence: 2), at: start + .seconds(303)).known)
        let busy = sampler.sample(Self.guest(monitor: monitor, sequence: 3, cpu: 1), at: start + .seconds(400))
        #expect(!busy.known && busy.quietMilliseconds == 0)
        #expect(!sampler.sample(nil, at: start + .seconds(500)).known)
        #expect(!sampler.sample(Self.guest(monitor: UUID()), at: start + .seconds(600)).known)
        var restarted = SandboxIdleSampler(at: start + .seconds(700))
        #expect(restarted.residencyEpoch != sampler.residencyEpoch)
        #expect(
            restarted.sample(Self.guest(monitor: monitor, sequence: 100), at: start + .seconds(701)).quietMilliseconds
                == 0)
        #expect(!Self.guest(monitor: monitor, cpu: nil).hasCompleteQuiescentCoverage)
        #expect(!Self.guest(monitor: monitor, sessions: [UUID()]).hasCompleteQuiescentCoverage)
    }
    @Test func publishedV4ExecEncodingOmitsV5SessionAndGuestVersionRemainsFour() throws {
        #expect(SandboxGuestControlProtocol.currentVersion == 4)
        let old = GuestControlProtocol.Request.exec(.init(argv: ["true"]))
        #expect(!String(decoding: old.encodedLine(), as: UTF8.self).contains("session_id"))
        let new = GuestControlProtocol.Request.exec(.init(argv: ["true"], sessionId: UUID()))
        #expect(String(decoding: new.encodedLine(), as: UTF8.self).contains("session_id"))
        #expect(SandboxGuestControlProtocol.supports(4) && SandboxGuestControlProtocol.supports(5))
        #expect(!SandboxGuestControlProtocol.supports(6))
    }
}
