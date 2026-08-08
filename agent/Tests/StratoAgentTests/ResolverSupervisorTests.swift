import Foundation
import Logging
import StratoShared
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

    private func request(_ networkId: UUID, upstreams: [String] = ["1.1.1.1"]) -> ResolverRenderRequest {
        ResolverRenderRequest(
            networkId: networkId, zones: [], upstreams: upstreams, searchDomain: nil,
            bindAddresses: [NetworkResolverEndpoint.address])
    }

    private func supervisor(
        host: FakeResolverHost, clock: TestClock = TestClock()
    ) -> ResolverSupervisor {
        host.clock = clock
        return ResolverSupervisor(
            root: "/tmp/resolver-tests", host: host, now: { clock.now },
            logger: Logger(label: "test"))
    }

    // MARK: - Start and stop

    @Test("A wanted network is written and started")
    func startsFromNothing() async {
        let host = FakeResolverHost()
        let supervisor = supervisor(host: host)
        await supervisor.reconcile([request(a)])

        #expect(await host.written() == [a])
        #expect(await host.spawned() == [a])
        #expect(await supervisor.servedNetworks() == [a])
    }

    @Test("A converged network is left alone on the next sync")
    func convergedIsIdempotent() async {
        let host = FakeResolverHost()
        let supervisor = supervisor(host: host)
        await supervisor.reconcile([request(a)])
        await supervisor.reconcile([request(a)])

        #expect(await host.spawned() == [a], "a running resolver must not be restarted")
        #expect(await host.written() == [a], "unchanged configuration must not be rewritten")
    }

    @Test("A network no longer wanted is stopped and its directory removed")
    func unwantedIsStopped() async {
        let host = FakeResolverHost()
        let supervisor = supervisor(host: host)
        await supervisor.reconcile([request(a)])
        await supervisor.reconcile([])

        #expect(await host.terminatedHandles() == [a])
        #expect(await host.removed() == [a])
        #expect(await supervisor.servedNetworks().isEmpty)
    }

    @Test("A nil request list stops nothing")
    func nilStopsNothing() async {
        // The contract that matters most here: a control plane that cannot
        // describe this host must not take DNS away from every network on it.
        let host = FakeResolverHost()
        let supervisor = supervisor(host: host)
        await supervisor.reconcile([request(a)])
        await supervisor.reconcile(nil)

        #expect(await host.terminatedHandles().isEmpty)
        #expect(await supervisor.servedNetworks() == [a])
    }

    @Test("A failed write blocks the start rather than running against a half-written Corefile")
    func failedWriteBlocksStart() async {
        let host = FakeResolverHost()
        await host.failWrites(for: [a])
        let supervisor = supervisor(host: host)
        await supervisor.reconcile([request(a)])

        #expect(await host.spawned().isEmpty)
        // And it retries: the digest was left unset, so the next pass rewrites.
        await host.failWrites(for: [])
        await supervisor.reconcile([request(a)])
        #expect(await host.spawned() == [a])
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

        // Each cycle lets the backoff lapse, reconciles — which notices the last
        // exit and starts a replacement — and kills that replacement at once.
        // The clock jump is applied *between* reconciles, never between a spawn
        // and its exit, so every run here lasts zero seconds. That is the point:
        // it is what a Corefile CoreDNS refuses to parse looks like.
        for _ in 0..<8 {
            clock.advance(by: 300)
            await supervisor.reconcile([request(a)])
            host.killLatest(networkId: a)
        }
        clock.advance(by: 300)
        await supervisor.reconcile([request(a)])

        let failures = await supervisor.failures(for: a)
        #expect(
            failures >= ResolverSupervisionPolicy.crashLoopThreshold,
            "the backoff must escalate on repeated instant deaths; got \(failures)")
    }

    @Test("A child that ran a healthy stretch clears the counter when it exits")
    func healthyRunClearsTheCounter() async {
        // The other half: a resolver restarted by a config change days later
        // must not inherit a stale count and start at the backoff cap.
        let host = FakeResolverHost()
        let clock = TestClock()
        let supervisor = supervisor(host: host, clock: clock)

        // One instant death: the counter goes to 1.
        await supervisor.reconcile([request(a)])
        host.killLatest(networkId: a)
        clock.advance(by: 300)
        await supervisor.reconcile([request(a)])
        #expect(await supervisor.failures(for: a) == 1)

        // Then a replacement that runs a healthy stretch before exiting.
        clock.advance(by: 300)
        await supervisor.reconcile([request(a)])
        clock.advance(by: ResolverSupervisionPolicy.healthyRuntimeSeconds + 1)
        host.killLatest(networkId: a)
        clock.advance(by: 300)
        await supervisor.reconcile([request(a)])
        // Cleared by the healthy run, then incremented by this exit: 1, not 2.
        #expect(await supervisor.failures(for: a) == 1)
    }

    @Test("Backoff suppresses a restart until its window passes")
    func backoffSuppressesRestart() async {
        let host = FakeResolverHost()
        let clock = TestClock()
        let supervisor = supervisor(host: host, clock: clock)

        await supervisor.reconcile([request(a)])
        host.killLatest(networkId: a)
        // The reconcile that notices the exit also imposes the window, so it
        // must not restart in the same pass.
        await supervisor.reconcile([request(a)])
        #expect(await host.spawned() == [a], "restart must wait for the backoff window")

        clock.advance(by: 300)
        await supervisor.reconcile([request(a)])
        #expect(await host.spawned() == [a, a])
    }

    // MARK: - Adoption

    @Test("A resolver a previous agent left running is adopted, not duplicated")
    func adoptionAvoidsASecondChild() async {
        // Starting a second CoreDNS into the same namespace would fail to bind
        // :53 and crash-loop beside a perfectly healthy one.
        let host = FakeResolverHost()
        await host.setAdoptable([AdoptableResolver(networkId: a, pid: 4242)])
        let supervisor = supervisor(host: host)

        await supervisor.reconcile([request(a)])
        #expect(await host.spawned().isEmpty, "an adopted resolver must not be respawned")
        // Its configuration is rewritten, because what the previous agent wrote
        // is not known to match current desired state.
        #expect(await host.written() == [a])
    }

    @Test("Stopping an adopted resolver signals it by pid")
    func adoptedIsStoppedByPID() async {
        let host = FakeResolverHost()
        await host.setAdoptable([AdoptableResolver(networkId: a, pid: 4242)])
        let supervisor = supervisor(host: host)

        await supervisor.reconcile([request(a)])
        await supervisor.reconcile([])
        #expect(await host.terminatedPIDs() == [4242])
        #expect(await host.removed() == [a])
    }

    @Test("An adopted pid that has since died is restarted")
    func deadAdoptedIsRestarted() async {
        let host = FakeResolverHost()
        await host.setAdoptable([AdoptableResolver(networkId: a, pid: 4242)])
        await host.setDead(pids: [4242])
        let supervisor = supervisor(host: host)

        await supervisor.reconcile([request(a)])
        #expect(await host.spawned() == [a])
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
        let request = ResolverRenderRequest(
            networkId: a, zones: [zone], upstreams: ["1.1.1.1"], searchDomain: nil,
            bindAddresses: [NetworkResolverEndpoint.address])

        await supervisor.reconcile([request])
        await supervisor.reconcile([request])
        #expect(await host.written() == [a], "an unchanged rendering must not be rewritten")
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
            return ResolverRenderRequest(
                networkId: a, zones: [zone], upstreams: ["1.1.1.1"], searchDomain: nil,
                bindAddresses: [NetworkResolverEndpoint.address])
        }
        await supervisor.reconcile([request(address: "10.0.0.5", hash: "one")])
        await supervisor.reconcile([request(address: "10.0.0.6", hash: "two")])
        #expect(await host.written() == [a, a])
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
            return ResolverRenderRequest(
                networkId: a, zones: [zone], upstreams: ["1.1.1.1"], searchDomain: nil,
                bindAddresses: [NetworkResolverEndpoint.address])
        }
        await supervisor.reconcile([request(hash: "one")])
        await supervisor.reconcile([request(hash: "two")])
        #expect(await host.written() == [a])
    }

    @Test("An upstream change moves the key even with identical zones")
    func renderFollowsUpstreams() async {
        let host = FakeResolverHost()
        let supervisor = supervisor(host: host)
        await supervisor.reconcile([request(a, upstreams: ["1.1.1.1"])])
        await supervisor.reconcile([request(a, upstreams: ["9.9.9.9"])])
        #expect(await host.written() == [a, a])
    }

    // MARK: - Shutdown

    @Test("Shutdown stops every resolver")
    func shutdownStopsEverything() async {
        // A draining host must not keep answering for networks it no longer
        // converges.
        let host = FakeResolverHost()
        let supervisor = supervisor(host: host)
        await supervisor.reconcile([request(a), request(b)])
        await supervisor.shutdown()

        #expect(await Set(host.terminatedHandles()) == [a, b])
        #expect(await supervisor.servedNetworks().isEmpty)
    }
}

// MARK: - Test doubles

/// A clock the supervisor reads instead of the wall, so backoff and the
/// healthy-runtime floor can be crossed without sleeping.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private struct FakeHandle: ResolverHandle {
    let networkId: UUID
    let processIdentifier: Int32
    let host: FakeResolverHost

    var isRunning: Bool { host.isRunning(networkId: networkId) }
    var exitedAt: Date? { host.exitedAt(networkId: networkId) }
    func terminate() async { host.terminateHandle(networkId: networkId) }
}

private struct WriteRefused: Error {}

/// A `ResolverHosting` that records what it was asked to do.
///
/// A lock-guarded class rather than an actor: the protocol's `spawn` and
/// `isAlive` are synchronous, and an actor would have to bounce every one of
/// them through a `Task`, which reorders exactly the sequence these tests are
/// asserting.
private final class FakeResolverHost: ResolverHosting, @unchecked Sendable {
    private let lock = NSLock()

    private var writes: [UUID] = []
    private var spawns: [UUID] = []
    private var removals: [UUID] = []
    private var terminatedByHandle: [UUID] = []
    private var terminatedByPID: [Int32] = []
    private var adoptableResolvers: [AdoptableResolver] = []
    private var deadPIDs: Set<Int32> = []
    private var refusedWrites: Set<UUID> = []
    private var running: [UUID: Bool] = [:]
    private var exits: [UUID: Date] = [:]
    /// The clock the supervisor reads, so a killed child's exit is stamped at
    /// the instant the test says it died rather than when it is noticed.
    var clock: TestClock?
    private var nextPID: Int32 = 1000

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: Observations

    func written() -> [UUID] { withLock { writes } }
    func spawned() -> [UUID] { withLock { spawns } }
    func removed() -> [UUID] { withLock { removals } }
    func terminatedHandles() -> [UUID] { withLock { terminatedByHandle } }
    func terminatedPIDs() -> [Int32] { withLock { terminatedByPID } }

    // MARK: Arrangement

    func failWrites(for networks: Set<UUID>) { withLock { refusedWrites = networks } }
    func setAdoptable(_ resolvers: [AdoptableResolver]) { withLock { adoptableResolvers = resolvers } }
    func setDead(pids: Set<Int32>) { withLock { deadPIDs = pids } }

    /// Kill the child most recently spawned for `networkId`, the way a CoreDNS
    /// that refuses its Corefile dies: cleanly forked, then gone a moment later.
    /// The supervisor notices on its next reconcile.
    func killLatest(networkId: UUID) {
        let at = clock?.now ?? Date()
        withLock {
            running[networkId] = false
            exits[networkId] = at
        }
    }

    func exitedAt(networkId: UUID) -> Date? { withLock { exits[networkId] } }

    func isRunning(networkId: UUID) -> Bool { withLock { running[networkId] ?? false } }

    func terminateHandle(networkId: UUID) {
        withLock {
            running[networkId] = false
            terminatedByHandle.append(networkId)
        }
    }

    // MARK: ResolverHosting

    func writeConfiguration(_ resolver: DesiredResolver, root: String) throws {
        let refused = withLock { refusedWrites.contains(resolver.networkId) }
        if refused { throw WriteRefused() }
        withLock { writes.append(resolver.networkId) }
    }

    func removeConfiguration(networkId: UUID, root: String) {
        withLock { removals.append(networkId) }
    }

    func spawn(networkId: UUID, root: String) throws -> any ResolverHandle {
        let pid: Int32 = withLock {
            nextPID += 1
            spawns.append(networkId)
            running[networkId] = true
            exits[networkId] = nil
            return nextPID
        }
        return FakeHandle(networkId: networkId, processIdentifier: pid, host: self)
    }

    func adoptable(root: String) -> [AdoptableResolver] { withLock { adoptableResolvers } }

    func isAlive(pid: Int32) -> Bool { withLock { !deadPIDs.contains(pid) } }

    func terminate(pid: Int32) async { withLock { terminatedByPID.append(pid) } }
}
