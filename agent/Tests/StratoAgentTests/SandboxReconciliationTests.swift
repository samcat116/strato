import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

/// Sandbox-kind coverage for the generalized reconciler (issue #417): the
/// plan/generation-guard/orphan logic is shared with VMs, so these tests
/// assert the sandbox step vocabulary, the kind isolation of the engine's
/// bookkeeping, and the wire-version gating of the sandbox half of a sync.
@Suite("Sandbox Reconciliation Tests")
struct SandboxReconciliationTests {

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = Date(timeIntervalSince1970: 1_000)

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return instant
        }

        func advance(by interval: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            instant = instant.addingTimeInterval(interval)
        }
    }

    // MARK: - Fixtures

    private static func sandboxSpec(cpus: Int = 1) -> SandboxSpec {
        SandboxSpec(image: "ghcr.io/acme/worker:v3", cpus: cpus, memoryBytes: 1 << 29)
    }

    private static func desiredSandbox(
        _ sandboxId: UUID,
        status: DesiredSandboxStatus,
        generation: Int64 = 1
    ) -> DesiredSandboxState {
        DesiredSandboxState(
            sandboxId: sandboxId,
            spec: sandboxSpec(),
            desiredStatus: status,
            generation: generation
        )
    }

    private static func desiredVM(
        _ vmId: UUID,
        status: DesiredVMStatus,
        generation: Int64 = 1
    ) -> DesiredVMState {
        DesiredVMState(
            vmId: vmId,
            hypervisorType: .qemu,
            spec: VMSpec(cpus: 1, memoryBytes: 1 << 30, boot: .disk(firmware: nil)),
            desiredStatus: status,
            generation: generation
        )
    }

    private static func sync(
        vms: [DesiredVMState] = [],
        sandboxes: [DesiredSandboxState] = [],
        tombstones: [DesiredWorkloadTombstone] = []
    ) -> DesiredStateMessage {
        DesiredStateMessage(vms: vms, sandboxes: sandboxes, tombstones: tombstones)
    }

    /// Actuator double covering both workload kinds, simulating the runtimes
    /// by updating its own presence maps on each action.
    private actor MockActuator: ReconcileActuator {
        var vmPresence: [String: VMPresence]
        var sandboxPresence: [String: SandboxPresence]
        private(set) var performed: [(kind: WorkloadKind, step: ReconcileStep, id: String)] = []
        private(set) var reportCount = 0
        /// Status an adopted sandbox orphan turns out to have.
        var adoptedSandboxStatus: SandboxStatus = .stopped
        /// When set, every action throws this error.
        var failWith: (any Error)?

        init(vmPresence: [String: VMPresence] = [:], sandboxPresence: [String: SandboxPresence] = [:]) {
            self.vmPresence = vmPresence
            self.sandboxPresence = sandboxPresence
        }

        func setFailure(_ error: (any Error)?) {
            failWith = error
        }

        func setAdoptedSandboxStatus(_ status: SandboxStatus) {
            adoptedSandboxStatus = status
        }

        func observedPresence() -> [String: VMPresence] {
            vmPresence
        }

        func observedSandboxPresence() -> [String: SandboxPresence] {
            sandboxPresence
        }

        func adoptVM(_ item: ReconcileWorkItem) throws -> VMStatus {
            if let failWith { throw failWith }
            performed.append((.vm, .adopt, item.id))
            vmPresence[item.id] = .managed(.running)
            return .running
        }

        func adoptSandbox(_ item: ReconcileWorkItem) throws -> SandboxStatus {
            if let failWith { throw failWith }
            performed.append((.sandbox, .adopt, item.id))
            sandboxPresence[item.id] = .managed(adoptedSandboxStatus)
            return adoptedSandboxStatus
        }

        func perform(_ step: ReconcileStep, item: ReconcileWorkItem) throws {
            if let failWith { throw failWith }
            performed.append((item.kind, step, item.id))
            switch item.kind {
            case .vm:
                switch step {
                case .create: vmPresence[item.id] = .managed(.created)
                case .boot, .resume: vmPresence[item.id] = .managed(.running)
                case .pause: vmPresence[item.id] = .managed(.paused)
                case .shutdown: vmPresence[item.id] = .managed(.shutdown)
                case .delete: vmPresence.removeValue(forKey: item.id)
                case .reboot, .restore: vmPresence[item.id] = .managed(.running)
                case .adopt, .resize, .attach, .detach, .export: break
                }
            case .sandbox:
                switch step {
                case .create: sandboxPresence[item.id] = .managed(.stopped)
                case .boot: sandboxPresence[item.id] = .managed(.running)
                case .shutdown: sandboxPresence[item.id] = .managed(.stopped)
                case .delete: sandboxPresence.removeValue(forKey: item.id)
                case .restore: sandboxPresence[item.id] = .managed(.running)
                case .adopt, .pause, .resume, .resize, .reboot, .attach, .detach, .export: break
                }
            case .volume, .volumeSnapshot, .vmCheckpoint, .sandboxSnapshot:
                break  // this suite's actuator holds no volumes or artifacts
            }
        }

        func convergenceDidChange() {
            reportCount += 1
        }

        /// Wait until `reportCount` reaches `count` (one report per finished
        /// work item), or time out.
        func waitForReports(_ count: Int, timeoutMillis: Int = 5000) async -> Int {
            var waited = 0
            while reportCount < count && waited < timeoutMillis {
                try? await Task.sleep(nanoseconds: 5_000_000)
                waited += 5
            }
            return reportCount
        }
    }

    private func makeReconciler(
        _ actuator: MockActuator,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> Reconciler {
        Reconciler(
            actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"),
            metadataStore: MetadataStore(), now: now)
    }

    // MARK: - Pure diff engine

    @Test("Desired-but-absent sandbox plans create plus boot steps")
    func planCreatesAbsentSandbox() {
        let sandboxId = UUID()
        let plan = Reconciler.planSandboxes(
            desired: [Self.desiredSandbox(sandboxId, status: .running)],
            present: [String: SandboxPresence](),
            lastApplied: [:]
        )
        #expect(plan.items.count == 1)
        #expect(plan.items[0].kind == .sandbox)
        #expect(plan.items[0].id == sandboxId.uuidString)
        #expect(plan.items[0].steps == [.create, .boot])
        #expect(plan.items[0].desiredSandbox != nil)
        #expect(plan.items[0].desired == nil)
    }

    @Test("Present-but-unlisted sandbox is held and reported, not deleted")
    func planHoldsUnlistedSandbox() {
        let sandboxId = UUID()
        let plan = Reconciler.planSandboxes(
            desired: [DesiredSandboxState](),
            present: [sandboxId.uuidString: SandboxPresence.managed(.running)],
            lastApplied: [sandboxId.uuidString: 7]
        )
        #expect(plan.items.isEmpty)
        #expect(plan.unrecognized.count == 1)
        #expect(plan.unrecognized[0].kind == .sandbox)
        #expect(plan.unrecognized[0].workloadId == sandboxId)
        #expect(plan.unrecognized[0].observedGeneration == 7)
        #expect(plan.unrecognized[0].status == SandboxStatus.running.rawValue)
    }

    @Test("Tombstoned sandbox is deleted at the tombstone's generation")
    func planDeletesTombstonedSandbox() {
        let sandboxId = UUID()
        let plan = Reconciler.planSandboxes(
            desired: [DesiredSandboxState](),
            present: [sandboxId.uuidString: SandboxPresence.managed(.running)],
            lastApplied: [sandboxId.uuidString: 7],
            tombstones: [
                DesiredWorkloadTombstone(kind: .sandbox, workloadId: sandboxId, generation: 8)
            ]
        )
        #expect(plan.unrecognized.isEmpty)
        #expect(plan.items.count == 1)
        #expect(plan.items[0].kind == .sandbox)
        #expect(plan.items[0].steps == [.delete])
        #expect(plan.items[0].generation == 8)
        #expect(plan.items[0].isTombstone)
    }

    @Test("A VM tombstone never removes a sandbox that happens to share its id")
    func tombstonesAreKindScoped() {
        let id = UUID()
        let plan = Reconciler.planSandboxes(
            desired: [DesiredSandboxState](),
            present: [id.uuidString: SandboxPresence.managed(.running)],
            lastApplied: [:],
            tombstones: [DesiredWorkloadTombstone(kind: .vm, workloadId: id, generation: 3)]
        )
        #expect(plan.items.isEmpty)
        #expect(plan.unrecognized.count == 1)
    }

    @Test("Stale sandbox generation is rejected by the generation guard")
    func planRejectsStaleGeneration() {
        let sandboxId = UUID()
        let plan = Reconciler.planSandboxes(
            desired: [Self.desiredSandbox(sandboxId, status: .stopped, generation: 2)],
            present: [sandboxId.uuidString: SandboxPresence.managed(.running)],
            lastApplied: [sandboxId.uuidString: 5]
        )
        #expect(plan.items.isEmpty)
    }

    @Test("Orphan matching a desired sandbox plans re-adoption")
    func planAdoptsMatchingOrphan() {
        let sandboxId = UUID()
        let plan = Reconciler.planSandboxes(
            desired: [Self.desiredSandbox(sandboxId, status: .running)],
            present: [sandboxId.uuidString: SandboxPresence.orphaned],
            lastApplied: [:]
        )
        #expect(plan.items.count == 1)
        #expect(plan.items[0].steps == [.adopt])
    }

    @Test("Exited sandbox satisfies desired-running: generation advances with no steps")
    func planLeavesExitedSandboxAlone() {
        // Phase 1 has no restart policy: a one-shot workload that ran to
        // completion must not be relaunched, even by a newer generation.
        let sandboxId = UUID()
        let plan = Reconciler.planSandboxes(
            desired: [Self.desiredSandbox(sandboxId, status: .running, generation: 4)],
            present: [sandboxId.uuidString: SandboxPresence.managed(.exited)],
            lastApplied: [sandboxId.uuidString: 3]
        )
        #expect(plan.items.count == 1)
        #expect(plan.items[0].steps.isEmpty)
        #expect(plan.items[0].generation == 4)
    }

    @Test("Status mismatch maps to the sandbox convergence steps (no pause/resume)")
    func statusStepMappings() {
        #expect(Reconciler.sandboxStatusSteps(desired: .running, observed: SandboxStatus.stopped) == [.boot])
        #expect(Reconciler.sandboxStatusSteps(desired: .running, observed: SandboxStatus.running) == [])
        #expect(Reconciler.sandboxStatusSteps(desired: .running, observed: SandboxStatus.exited) == [])
        #expect(Reconciler.sandboxStatusSteps(desired: .stopped, observed: SandboxStatus.running) == [.shutdown])
        #expect(Reconciler.sandboxStatusSteps(desired: .stopped, observed: SandboxStatus.stopped) == [])
        #expect(Reconciler.sandboxStatusSteps(desired: .stopped, observed: SandboxStatus.exited) == [])
        #expect(Reconciler.sandboxStatusSteps(desired: .absent, observed: SandboxStatus.running) == [.delete])
    }

    @Test("Sandbox lanes are namespaced away from VM lanes")
    func laneKeyNamespacing() {
        let id = UUID().uuidString
        let uuid = UUID(uuidString: id)!
        let vmItem = ReconcileWorkItem(
            kind: .vm, id: id, generation: 1, steps: [.boot],
            target: .tombstone(DesiredWorkloadTombstone(kind: .vm, workloadId: uuid, generation: 1)))
        let sandboxItem = ReconcileWorkItem(
            kind: .sandbox, id: id, generation: 1, steps: [.boot],
            target: .tombstone(DesiredWorkloadTombstone(kind: .sandbox, workloadId: uuid, generation: 1)))
        #expect(vmItem.laneKey == id)
        #expect(sandboxItem.laneKey == "sandbox/" + id)
    }

    // MARK: - Reconciler end to end

    @Test("Sandbox sync converges create and boot; VM state is untouched")
    func sandboxSyncConverges() async {
        let sandboxId = UUID()
        let actuator = MockActuator()
        let reconciler = makeReconciler(actuator)
        let message = Self.sync(sandboxes: [Self.desiredSandbox(sandboxId, status: .running, generation: 1)])

        await reconciler.apply(message)
        _ = await actuator.waitForReports(1)

        let performed = await actuator.performed
        let allSandboxKind = performed.allSatisfy { $0.kind == .sandbox }
        #expect(performed.map(\.step) == [.create, .boot])
        #expect(allSandboxKind)
        let generation = await reconciler.observedGeneration(for: sandboxId.uuidString, kind: .sandbox)
        #expect(generation == 1)
        // The engine's bookkeeping is kind-scoped: the same id as a VM is a
        // different workload.
        let vmGeneration = await reconciler.observedGeneration(for: sandboxId.uuidString)
        #expect(vmGeneration == 0)
    }

    @Test("An empty sync holds an unaccounted sandbox until a tombstone authorizes teardown")
    func emptySyncHoldsSandboxUntilTombstone() async {
        let sandboxId = UUID()
        let actuator = MockActuator(sandboxPresence: [sandboxId.uuidString: .managed(.running)])
        let reconciler = makeReconciler(actuator)

        // An empty sync doesn't delete the sandbox — it reports it and waits
        // for a verdict.
        await reconciler.apply(Self.sync())
        _ = await actuator.waitForReports(1)
        let afterAuthoritative = await actuator.sandboxPresence
        #expect(afterAuthoritative.count == 1)
        let held = await reconciler.unrecognizedWorkloads()
        #expect(held.map(\.workloadId) == [sandboxId])

        // Only the tombstone removes it.
        await reconciler.apply(
            Self.sync(tombstones: [
                DesiredWorkloadTombstone(kind: .sandbox, workloadId: sandboxId, generation: 1)
            ]))
        // Two more reports: the held set emptying, and the delete finishing.
        _ = await actuator.waitForReports(3)
        let afterTombstone = await actuator.sandboxPresence
        #expect(afterTombstone.isEmpty)
    }

    @Test("Orphaned sandbox is re-adopted and then converged toward the desired status")
    func orphanReadoptedAndConverged() async {
        let sandboxId = UUID()
        let actuator = MockActuator(sandboxPresence: [sandboxId.uuidString: .orphaned])
        await actuator.setAdoptedSandboxStatus(.stopped)
        let reconciler = makeReconciler(actuator)

        await reconciler.apply(
            Self.sync(sandboxes: [Self.desiredSandbox(sandboxId, status: .running, generation: 1)]))
        _ = await actuator.waitForReports(1)

        // Adoption first, then the post-adoption plan (stopped → running = boot).
        let performed = await actuator.performed
        #expect(performed.map(\.step) == [.adopt, .boot])
        let generation = await reconciler.observedGeneration(for: sandboxId.uuidString, kind: .sandbox)
        #expect(generation == 1)
    }

    @Test("One sync converges VMs and sandboxes independently")
    func mixedSyncConvergesBothKinds() async {
        let vmId = UUID()
        let sandboxId = UUID()
        let actuator = MockActuator()
        let reconciler = makeReconciler(actuator)

        await reconciler.apply(
            Self.sync(
                vms: [Self.desiredVM(vmId, status: .running, generation: 1)],
                sandboxes: [Self.desiredSandbox(sandboxId, status: .running, generation: 1)]))
        _ = await actuator.waitForReports(2)

        let performed = await actuator.performed
        let vmSteps = performed.filter { $0.kind == .vm }.map(\.step)
        let sandboxSteps = performed.filter { $0.kind == .sandbox }.map(\.step)
        #expect(vmSteps == [.create, .boot])
        #expect(sandboxSteps == [.create, .boot])
        let vmGeneration = await reconciler.observedGeneration(for: vmId.uuidString)
        let sandboxGeneration = await reconciler.observedGeneration(for: sandboxId.uuidString, kind: .sandbox)
        #expect(vmGeneration == 1)
        #expect(sandboxGeneration == 1)
    }

    @Test("Failing sandbox convergence retries after backoff at the same generation")
    func sandboxFailureTracking() async {
        struct Boom: Error {}
        let sandboxId = UUID()
        let actuator = MockActuator()
        await actuator.setFailure(Boom())
        let clock = TestClock()
        let reconciler = makeReconciler(actuator, now: clock.now)
        let message = Self.sync(sandboxes: [Self.desiredSandbox(sandboxId, status: .running, generation: 1)])

        await reconciler.apply(message)
        _ = await actuator.waitForReports(1)
        await reconciler.apply(message)
        #expect(await actuator.reportCount == 1)
        clock.advance(by: 60)
        await reconciler.apply(message)
        _ = await actuator.waitForReports(2)

        let reports = await actuator.reportCount
        #expect(reports == 2)
        let lastError = await reconciler.lastError(for: sandboxId.uuidString, kind: .sandbox)
        #expect(lastError != nil)
        let failedGeneration = await reconciler.failedGeneration(for: sandboxId.uuidString, kind: .sandbox)
        #expect(failedGeneration == 1)
        // Kind isolation again: nothing is recorded against a VM of that id.
        let vmError = await reconciler.lastError(for: sandboxId.uuidString)
        #expect(vmError == nil)
        let failed = await reconciler.failedConvergences(kind: .sandbox)
        #expect(failed[sandboxId.uuidString]?.generation == 1)

        // The same generation can recover after the next backoff.
        await actuator.setFailure(nil)
        clock.advance(by: 5 * 60)
        await reconciler.apply(message)
        _ = await actuator.waitForReports(3)
        let performed = await actuator.performed
        #expect(performed.map(\.step) == [.create, .boot])
        let clearedError = await reconciler.lastError(for: sandboxId.uuidString, kind: .sandbox)
        #expect(clearedError == nil)
        let generation = await reconciler.observedGeneration(for: sandboxId.uuidString, kind: .sandbox)
        #expect(generation == 1)
    }
}
