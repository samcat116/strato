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
        sandboxes: [DesiredSandboxState] = []
    ) -> DesiredStateMessage {
        DesiredStateMessage(vms: vms, sandboxes: sandboxes)
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
                case .adopt, .resize: break
                }
            case .sandbox:
                switch step {
                case .create: sandboxPresence[item.id] = .managed(.stopped)
                case .boot: sandboxPresence[item.id] = .managed(.running)
                case .shutdown: sandboxPresence[item.id] = .managed(.stopped)
                case .delete: sandboxPresence.removeValue(forKey: item.id)
                case .adopt, .pause, .resume, .resize: break
                }
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

    private func makeReconciler(_ actuator: MockActuator) -> Reconciler {
        Reconciler(actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"))
    }

    // MARK: - Pure diff engine

    @Test("Desired-but-absent sandbox plans create plus boot steps")
    func planCreatesAbsentSandbox() {
        let sandboxId = UUID()
        let items = Reconciler.planSandboxes(
            desired: [Self.desiredSandbox(sandboxId, status: .running)],
            present: [String: SandboxPresence](),
            lastApplied: [:]
        )
        #expect(items.count == 1)
        #expect(items[0].kind == .sandbox)
        #expect(items[0].id == sandboxId.uuidString)
        #expect(items[0].steps == [.create, .boot])
        #expect(items[0].desiredSandbox != nil)
        #expect(items[0].desired == nil)
    }

    @Test("Present-but-undesired sandbox plans deletion (full-list semantics)")
    func planDeletesUndesiredSandbox() {
        let sandboxId = UUID().uuidString
        let items = Reconciler.planSandboxes(
            desired: [DesiredSandboxState](),
            present: [sandboxId: SandboxPresence.managed(.running)],
            lastApplied: [:]
        )
        #expect(items.count == 1)
        #expect(items[0].kind == .sandbox)
        #expect(items[0].id == sandboxId)
        #expect(items[0].steps == [.delete])
        #expect(items[0].target == nil)
    }

    @Test("Stale sandbox generation is rejected by the generation guard")
    func planRejectsStaleGeneration() {
        let sandboxId = UUID()
        let items = Reconciler.planSandboxes(
            desired: [Self.desiredSandbox(sandboxId, status: .stopped, generation: 2)],
            present: [sandboxId.uuidString: SandboxPresence.managed(.running)],
            lastApplied: [sandboxId.uuidString: 5]
        )
        #expect(items.isEmpty)
    }

    @Test("Orphan matching a desired sandbox plans re-adoption")
    func planAdoptsMatchingOrphan() {
        let sandboxId = UUID()
        let items = Reconciler.planSandboxes(
            desired: [Self.desiredSandbox(sandboxId, status: .running)],
            present: [sandboxId.uuidString: SandboxPresence.orphaned],
            lastApplied: [:]
        )
        #expect(items.count == 1)
        #expect(items[0].steps == [.adopt])
    }

    @Test("Exited sandbox satisfies desired-running: generation advances with no steps")
    func planLeavesExitedSandboxAlone() {
        // Phase 1 has no restart policy: a one-shot workload that ran to
        // completion must not be relaunched, even by a newer generation.
        let sandboxId = UUID()
        let items = Reconciler.planSandboxes(
            desired: [Self.desiredSandbox(sandboxId, status: .running, generation: 4)],
            present: [sandboxId.uuidString: SandboxPresence.managed(.exited)],
            lastApplied: [sandboxId.uuidString: 3]
        )
        #expect(items.count == 1)
        #expect(items[0].steps.isEmpty)
        #expect(items[0].generation == 4)
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
        let vmItem = ReconcileWorkItem(kind: .vm, id: id, generation: 1, steps: [.boot], target: nil)
        let sandboxItem = ReconcileWorkItem(kind: .sandbox, id: id, generation: 1, steps: [.boot], target: nil)
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

        await reconciler.apply(message, includeSandboxes: true)
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

    @Test("Sandboxes are not reconciled when the sync's sender predates the sandbox protocol")
    func sandboxHalfGatedOnSenderVersion() async {
        // A pre-sandbox control plane omits `sandboxes` (decoded []); reading
        // that as authoritative would tear down every present sandbox.
        let sandboxId = UUID().uuidString
        let actuator = MockActuator(sandboxPresence: [sandboxId: .managed(.running)])
        let reconciler = makeReconciler(actuator)

        await reconciler.apply(Self.sync(), includeSandboxes: false)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let performed = await actuator.performed
        #expect(performed.isEmpty)
        let presence = await actuator.sandboxPresence
        #expect(presence.count == 1)

        // The same empty sync from a sandbox-aware control plane IS
        // authoritative: full-list semantics delete the stray sandbox.
        await reconciler.apply(Self.sync(), includeSandboxes: true)
        _ = await actuator.waitForReports(1)
        let afterAuthoritative = await actuator.sandboxPresence
        #expect(afterAuthoritative.isEmpty)
    }

    @Test("Orphaned sandbox is re-adopted and then converged toward the desired status")
    func orphanReadoptedAndConverged() async {
        let sandboxId = UUID()
        let actuator = MockActuator(sandboxPresence: [sandboxId.uuidString: .orphaned])
        await actuator.setAdoptedSandboxStatus(.stopped)
        let reconciler = makeReconciler(actuator)

        await reconciler.apply(
            Self.sync(sandboxes: [Self.desiredSandbox(sandboxId, status: .running, generation: 1)]),
            includeSandboxes: true)
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
                sandboxes: [Self.desiredSandbox(sandboxId, status: .running, generation: 1)]),
            includeSandboxes: true)
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

    @Test("Failing sandbox convergence is tracked under the sandbox kind, with the attempt cap")
    func sandboxFailureTracking() async {
        struct Boom: Error {}
        let sandboxId = UUID()
        let actuator = MockActuator()
        await actuator.setFailure(Boom())
        let reconciler = makeReconciler(actuator)
        let message = Self.sync(sandboxes: [Self.desiredSandbox(sandboxId, status: .running, generation: 1)])

        for attempt in 1...(Reconciler.maxAttemptsPerGeneration + 2) {
            await reconciler.apply(message, includeSandboxes: true)
            _ = await actuator.waitForReports(min(attempt, Reconciler.maxAttemptsPerGeneration))
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        let reports = await actuator.reportCount
        #expect(reports == Reconciler.maxAttemptsPerGeneration)
        let lastError = await reconciler.lastError(for: sandboxId.uuidString, kind: .sandbox)
        #expect(lastError != nil)
        let failedGeneration = await reconciler.failedGeneration(for: sandboxId.uuidString, kind: .sandbox)
        #expect(failedGeneration == 1)
        // Kind isolation again: nothing is recorded against a VM of that id.
        let vmError = await reconciler.lastError(for: sandboxId.uuidString)
        #expect(vmError == nil)
        let failed = await reconciler.failedConvergences(kind: .sandbox)
        #expect(failed[sandboxId.uuidString]?.generation == 1)

        // A new generation re-arms the loop.
        await actuator.setFailure(nil)
        await reconciler.apply(
            Self.sync(sandboxes: [Self.desiredSandbox(sandboxId, status: .running, generation: 2)]),
            includeSandboxes: true)
        _ = await actuator.waitForReports(Reconciler.maxAttemptsPerGeneration + 1)
        let performed = await actuator.performed
        #expect(performed.map(\.step) == [.create, .boot])
        let clearedError = await reconciler.lastError(for: sandboxId.uuidString, kind: .sandbox)
        #expect(clearedError == nil)
    }
}
