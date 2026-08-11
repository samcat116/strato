import Foundation
import Logging
import StratoShared
import Synchronization
import Testing

@testable import StratoAgentCore

/// The resolver's lifecycle state machine (STR-40).
///
/// Everything here was unassertable while the supervisor forked processes and
/// wrote files directly — which is how the failure-counter bug below survived
/// review the first time. `ResolverHosting` is injected for
/// `MetadataServerSpawning`'s reason, and these are the questions it buys: does
/// the backoff ever escalate, does adoption avoid a second child, and does a
/// stop that races a reconcile reap the wrong one.
@Suite("Resolver Supervisor")
struct ResolverSupervisorTests {

    private let a = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    private func request(
        _ networkIds: [UUID] = [], upstreams: [String] = ["1.1.1.1"]
    ) -> ResolverRenderRequest {
        ResolverRenderRequest(
            networks: networkIds.enumerated().map { index, id in
                CoreDNSZoneRenderer.Network(
                    networkId: id, bindAddresses: ["169.254.1.\(index)"], zones: [],
                    upstreams: upstreams, searchDomain: nil)
            })
    }

    /// A one-network request carrying `zone`.
    private func zoned(_ zone: DesiredDNSZone) -> ResolverRenderRequest {
        ResolverRenderRequest(networks: [
            CoreDNSZoneRenderer.Network(
                networkId: a, bindAddresses: ["169.254.1.0"], zones: [zone],
                upstreams: ["1.1.1.1"], searchDomain: nil)
        ])
    }

    private func supervisor(
        host: FakeResolverHost, clock: TestClock = TestClock()
    ) -> ResolverSupervisor {
        host.setClock(clock)
        return ResolverSupervisor(
            root: "/tmp/resolver-tests", host: host, now: { clock.now },
            restartScheduler: clock.restartScheduler,
            logger: Logger(label: "test"))
    }

    // MARK: - Start and stop

    @Test("A wanted network is written and started")
    func startsFromNothing() async {
        let host = FakeResolverHost()
        let supervisor = supervisor(host: host)
        await supervisor.reconcile(request([a]))

        #expect(await host.written() == 1)
        #expect(await host.spawned() == 1)
        #expect(await supervisor.isServing())
    }

    @Test("A converged network is left alone on the next sync")
    func convergedIsIdempotent() async {
        let host = FakeResolverHost()
        let supervisor = supervisor(host: host)
        await supervisor.reconcile(request([a]))
        await supervisor.reconcile(request([a]))

        #expect(await host.spawned() == 1, "a running resolver must not be restarted")
        #expect(await host.written() == 1, "unchanged configuration must not be rewritten")
    }

    @Test("A network no longer wanted is stopped and its directory removed")
    func unwantedIsStopped() async {
        let host = FakeResolverHost()
        let supervisor = supervisor(host: host)
        await supervisor.reconcile(request([a]))
        await supervisor.reconcile(request([]))

        #expect(await host.terminatedHandles() == 1)
        #expect(await host.removed() == 1)
        #expect(await !supervisor.isServing())
    }

    @Test("A nil request list stops nothing")
    func nilStopsNothing() async {
        // The contract that matters most here: a control plane that cannot
        // describe this host must not take DNS away from every network on it.
        let host = FakeResolverHost()
        let supervisor = supervisor(host: host)
        await supervisor.reconcile(request([a]))
        await supervisor.reconcile(nil)

        #expect(await host.terminatedHandles() == 0)
        #expect(await supervisor.isServing())
    }

    @Test("A failed write blocks the start rather than running against a half-written Corefile")
    func failedWriteBlocksStart() async {
        let host = FakeResolverHost()
        await host.failWrites(true)
        let supervisor = supervisor(host: host)
        await supervisor.reconcile(request([a]))

        #expect(await host.spawned() == 0)
        // And it retries: the digest was left unset, so the next pass rewrites.
        await host.failWrites(false)
        await supervisor.reconcile(request([a]))
        #expect(await host.spawned() == 1)
    }

    // MARK: - The failure counter

    @Test("A child that dies immediately escalates the backoff and reports a crash loop")
    func immediateDeathEscalates() async {
        // The bug this suite exists for. Every failure the backoff protects
        // against — an unparseable Corefile, `:53` already held — spawns
        // cleanly and exits a moment later. Resetting the counter on a
        // successful *spawn* pinned the delay at its first step forever, so
        // `crashLoopThreshold` was unreachable and most of the policy was dead
        // code as wired.
        let host = FakeResolverHost()
        let clock = TestClock()
        let supervisor = supervisor(host: host, clock: clock)

        await supervisor.reconcile(request([a]))
        // Each reconciliation notices an instant exit and installs one wakeup.
        // Advancing the clock runs that wakeup without another reconciliation,
        // which exercises the production crash-loop path rather than manually
        // driving every replacement from desired state.
        for failure in 1...8 {
            host.kill()
            await supervisor.reconcile(request([a]))
            #expect(clock.scheduledCount() == 1)
            let delay = ResolverSupervisionPolicy.restartDelay(consecutiveFailures: failure)
            await clock.advance(by: TimeInterval(delay.components.seconds))
            #expect(await host.spawned() == failure + 1)
        }

        let failures = await supervisor.failures()
        #expect(
            failures >= ResolverSupervisionPolicy.crashLoopThreshold,
            "the backoff must escalate on repeated instant deaths; got \(failures)")
        #expect(await host.overlappingSpawns() == 0)
    }

    @Test("A child that ran a healthy stretch clears the counter when it exits")
    func healthyRunClearsTheCounter() async {
        // The other half: a resolver restarted by a config change days later
        // must not inherit a stale count and start at the backoff cap.
        let host = FakeResolverHost()
        let clock = TestClock()
        let supervisor = supervisor(host: host, clock: clock)

        // One instant death: the counter goes to 1.
        await supervisor.reconcile(request([a]))
        host.kill()
        await supervisor.reconcile(request([a]))
        #expect(await supervisor.failures() == 1)

        // Then a replacement that runs a healthy stretch before exiting.
        let delay = ResolverSupervisionPolicy.restartDelay(consecutiveFailures: 1)
        await clock.advance(by: TimeInterval(delay.components.seconds))
        await clock.advance(by: ResolverSupervisionPolicy.healthyRuntimeSeconds + 1)
        host.kill()
        await supervisor.reconcile(request([a]))
        // Cleared by the healthy run, then incremented by this exit: 1, not 2.
        #expect(await supervisor.failures() == 1)
        await supervisor.shutdown()
    }

    @Test("Backoff suppresses a restart until its window passes")
    func backoffSuppressesRestart() async {
        let host = FakeResolverHost()
        let clock = TestClock()
        let supervisor = supervisor(host: host, clock: clock)

        await supervisor.reconcile(request([a]))
        host.kill()
        // The reconcile that notices the exit also imposes the window, so it
        // must not restart in the same pass.
        await supervisor.reconcile(request([a]))
        #expect(await host.spawned() == 1, "restart must wait for the backoff window")

        // Repeated syncs inside the window must reuse the same wakeup rather
        // than create a fleet of tasks that all try to spawn at its boundary.
        await supervisor.reconcile(request([a]))
        await supervisor.reconcile(request([a]))
        #expect(clock.scheduledCount() == 1)

        let delay = ResolverSupervisionPolicy.restartDelay(consecutiveFailures: 1)
        await clock.advance(by: TimeInterval(delay.components.seconds) - 0.5)
        #expect(await host.spawned() == 1, "restart must not run before the deadline")

        // No control-plane or DNS mutation after the exit: crossing the
        // supervisor's own deadline is sufficient to start the replacement.
        await clock.advance(by: 0.5)
        #expect(await host.spawned() == 2)
        #expect(clock.scheduledCount() == 0)
        #expect(await host.overlappingSpawns() == 0)
    }

    @Test("A resolver disabled during backoff is not restarted")
    func disablingCancelsRestart() async {
        let host = FakeResolverHost()
        let clock = TestClock()
        let supervisor = supervisor(host: host, clock: clock)

        await supervisor.reconcile(request([a]))
        host.kill()
        await supervisor.reconcile(request([a]))
        #expect(clock.scheduledCount() == 1)

        await supervisor.reconcile(request([]))
        #expect(clock.scheduledCount() == 0)

        await clock.advance(by: 300)
        #expect(host.spawned() == 1)
    }

    // MARK: - Adoption

    @Test("A resolver a previous agent left running is adopted, not duplicated")
    func adoptionAvoidsASecondChild() async {
        // Starting a second CoreDNS into the same namespace would fail to bind
        // :53 and crash-loop beside a perfectly healthy one.
        let host = FakeResolverHost()
        await host.setAdoptable(AdoptableResolver(pid: 4242))
        let supervisor = supervisor(host: host)

        await supervisor.reconcile(request([a]))
        #expect(await host.spawned() == 0, "an adopted resolver must not be respawned")
        // Its configuration is rewritten, because what the previous agent wrote
        // is not known to match current desired state.
        #expect(await host.written() == 1)
    }

    @Test("Stopping an adopted resolver signals it by pid")
    func adoptedIsStoppedByPID() async {
        let host = FakeResolverHost()
        await host.setAdoptable(AdoptableResolver(pid: 4242))
        let supervisor = supervisor(host: host)

        await supervisor.reconcile(request([a]))
        await supervisor.reconcile(request([]))
        #expect(await host.terminatedPIDs() == [4242])
        #expect(await host.removed() == 1)
    }

    @Test("An adopted pid that has since died is restarted")
    func deadAdoptedIsRestarted() async {
        let host = FakeResolverHost()
        await host.setAdoptable(AdoptableResolver(pid: 4242))
        await host.setDead(pids: [4242])
        let supervisor = supervisor(host: host)

        await supervisor.reconcile(request([a]))
        #expect(await host.spawned() == 1)
    }

    // MARK: - Rendering

    @Test("An unchanged network is not re-rendered on every sync")
    func renderIsSkippedWhenInputsAreUnchanged() async {
        // A zone's records span every VM on every attached network fleet-wide,
        // so the render's cost grows with the cluster rather than with this
        // host — and the overwhelmingly common outcome is a result thrown away.
        let host = FakeResolverHost()
        let supervisor = supervisor(host: host)
        let zone = DesiredDNSZone(
            zoneId: UUID(), zoneName: "corp.example.com", networkIds: [a],
            records: [DesiredDNSRecord(name: "vm.corp.example.com", type: "A", values: ["10.0.0.5"])],
            recordsHash: "hash-one")
        let request = zoned(zone)

        await supervisor.reconcile(request)
        await supervisor.reconcile(request)
        #expect(await host.written() == 1, "an unchanged rendering must not be rewritten")
    }

    @Test("A record edit is re-rendered and written through")
    func renderFollowsTheRecordsHash() async {
        let host = FakeResolverHost()
        let supervisor = supervisor(host: host)
        func request(address: String, hash: String) -> ResolverRenderRequest {
            let zone = DesiredDNSZone(
                zoneId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                zoneName: "corp.example.com", networkIds: [a],
                records: [
                    DesiredDNSRecord(name: "vm.corp.example.com", type: "A", values: [address])
                ],
                recordsHash: hash)
            return zoned(zone)
        }
        await supervisor.reconcile(request(address: "10.0.0.5", hash: "one"))
        await supervisor.reconcile(request(address: "10.0.0.6", hash: "two"))
        #expect(await host.written() == 2)
    }

    @Test("A moved hash whose records render identically costs a render but no write")
    func identicalRenderingIsNotRewritten() async {
        // The two skips are layered and independent: `renderKey` decides whether
        // to *build* the files, `configurationDigest` whether to *write* them. A
        // hash that moved without changing what this backend emits — a TTL-only
        // edit on a record type the zone file does not carry, say — should still
        // reach neither the disk nor CoreDNS's file watch.
        let host = FakeResolverHost()
        let supervisor = supervisor(host: host)
        func request(hash: String) -> ResolverRenderRequest {
            let zone = DesiredDNSZone(
                zoneId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                zoneName: "corp.example.com", networkIds: [a],
                records: [
                    DesiredDNSRecord(name: "vm.corp.example.com", type: "A", values: ["10.0.0.5"])
                ],
                recordsHash: hash)
            return zoned(zone)
        }
        await supervisor.reconcile(request(hash: "one"))
        await supervisor.reconcile(request(hash: "two"))
        #expect(await host.written() == 1)
    }

    @Test("An upstream change moves the key even with identical zones")
    func renderFollowsUpstreams() async {
        let host = FakeResolverHost()
        let supervisor = supervisor(host: host)
        await supervisor.reconcile(request([a], upstreams: ["1.1.1.1"]))
        await supervisor.reconcile(request([a], upstreams: ["9.9.9.9"]))
        #expect(await host.written() == 2)
    }

    // MARK: - Shutdown

    @Test("Shutdown stops every resolver")
    func shutdownStopsEverything() async {
        // A draining host must not keep answering for networks it no longer
        // converges.
        let host = FakeResolverHost()
        let supervisor = supervisor(host: host)
        await supervisor.reconcile(request([a, b]))
        await supervisor.shutdown()

        #expect(await host.terminatedHandles() == 1)
        #expect(await !supervisor.isServing())
    }
}

// MARK: - Test doubles

/// A clock the supervisor reads instead of the wall, so backoff and the
/// healthy-runtime floor can be crossed without sleeping.
private final class TestClock: Sendable {
    private struct ScheduledRestart: Sendable {
        let deadline: Date
        let sequence: Int
        let operation: ResolverRestartScheduler.Operation
    }

    private struct State: Sendable {
        var current = Date(timeIntervalSince1970: 1_000_000)
        var nextSequence = 0
        var scheduled: [UUID: ScheduledRestart] = [:]
    }

    private let state = Mutex(State())

    var now: Date {
        state.withLock(\.current)
    }

    var restartScheduler: ResolverRestartScheduler {
        ResolverRestartScheduler { [self] deadline, operation in
            let id = UUID()
            self.state.withLock { state in
                state.nextSequence += 1
                state.scheduled[id] = ScheduledRestart(
                    deadline: deadline, sequence: state.nextSequence, operation: operation)
            }
            return { [weak self] in self?.cancel(id) }
        }
    }

    func scheduledCount() -> Int {
        state.withLock { $0.scheduled.count }
    }

    /// Move time, then await every restart whose fixed deadline was crossed.
    /// Running the callbacks inline makes the post-advance assertions exact.
    func advance(by seconds: TimeInterval) async {
        let due = state.withLock { state -> [ScheduledRestart] in
            state.current = state.current.addingTimeInterval(seconds)
            let due = state.scheduled.filter { $0.value.deadline <= state.current }
            for id in due.keys { state.scheduled.removeValue(forKey: id) }
            return due.values.sorted { $0.sequence < $1.sequence }
        }
        for restart in due { await restart.operation() }
    }

    private func cancel(_ id: UUID) {
        state.withLock { $0.scheduled[id] = nil }
    }
}

private struct FakeHandle: ResolverHandle {
    let processIdentifier: Int32
    let host: FakeResolverHost

    var isRunning: Bool { host.processIsRunning() }
    var exitedAt: Date? { host.processExitedAt() }
    func terminate() async { host.terminateHandle() }
}

private struct WriteRefused: Error {}

/// A `ResolverHosting` that records what it was asked to do.
///
/// A lock-guarded class rather than an actor: the protocol's `spawn` and
/// `isAlive` are synchronous, and an actor would have to bounce every one of
/// them through a `Task`, which reorders exactly the sequence these tests are
/// asserting.
private final class FakeResolverHost: ResolverHosting, Sendable {
    private struct State {
        var writes = 0
        var spawns = 0
        var removals = 0
        var terminatedByHandle = 0
        var terminatedByPID: [Int32] = []
        var adoptableResolver: AdoptableResolver?
        var deadPIDs: Set<Int32> = []
        var refuseWrites = false
        var running = false
        var overlappingSpawns = 0
        var exitedAt: Date?
        var nextPID: Int32 = 1000
        var clock: TestClock?
    }

    private let state = Mutex(State())

    /// The clock the supervisor reads, so a killed child's exit is stamped at
    /// the instant the test says it died rather than when it is noticed.
    // MARK: Observations

    func written() -> Int { state.withLock { $0.writes } }
    func spawned() -> Int { state.withLock { $0.spawns } }
    func removed() -> Int { state.withLock { $0.removals } }
    func terminatedHandles() -> Int { state.withLock { $0.terminatedByHandle } }
    func terminatedPIDs() -> [Int32] { state.withLock { $0.terminatedByPID } }
    func overlappingSpawns() -> Int { state.withLock { $0.overlappingSpawns } }
    func setClock(_ clock: TestClock) { state.withLock { $0.clock = clock } }

    // MARK: Arrangement

    func failWrites(_ refuse: Bool) { state.withLock { $0.refuseWrites = refuse } }
    func setAdoptable(_ resolver: AdoptableResolver?) { state.withLock { $0.adoptableResolver = resolver } }
    func setDead(pids: Set<Int32>) { state.withLock { $0.deadPIDs = pids } }

    /// Kill the child, the way a CoreDNS that refuses its Corefile dies:
    /// cleanly forked, then gone a moment later. The supervisor notices on its
    /// next reconcile.
    func kill() {
        state.withLock { state in
            state.running = false
            state.exitedAt = state.clock?.now ?? Date()
        }
    }

    func processIsRunning() -> Bool { state.withLock { $0.running } }
    func processExitedAt() -> Date? { state.withLock { $0.exitedAt } }

    func terminateHandle() {
        state.withLock { state in
            state.running = false
            state.terminatedByHandle += 1
        }
    }

    // MARK: ResolverHosting

    func writeConfiguration(_ resolver: DesiredResolver, root: String) throws {
        try state.withLock { state in
            if state.refuseWrites { throw WriteRefused() }
            state.writes += 1
        }
    }

    func removeConfiguration(root: String) { state.withLock { $0.removals += 1 } }

    func spawn(root: String) throws -> any ResolverHandle {
        let pid: Int32 = state.withLock { state in
            state.nextPID += 1
            state.spawns += 1
            if state.running { state.overlappingSpawns += 1 }
            state.running = true
            state.exitedAt = nil
            return state.nextPID
        }
        return FakeHandle(processIdentifier: pid, host: self)
    }

    func adoptable(root: String) -> AdoptableResolver? { state.withLock { $0.adoptableResolver } }

    func isAlive(pid: Int32) -> Bool { state.withLock { !$0.deadPIDs.contains(pid) } }

    func terminate(pid: Int32) async { state.withLock { $0.terminatedByPID.append(pid) } }
}
