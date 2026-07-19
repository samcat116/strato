import Testing
import Foundation
@testable import StratoAgentCore
import StratoShared
import Logging

/// Regression coverage for issue #516: one hypervisor call that never returns
/// took the whole agent offline — it stopped processing control-plane messages
/// and stopped heartbeating, with no timeout, no watchdog and no error log.
///
/// The call that hung lived in SwiftQEMU (a QMP continuation that was never
/// resumed) and is fixed there. These tests cover the agent-side containment:
/// hypervisor work is bounded, and a step that hangs anyway must not take
/// unrelated work down with it.
@Suite("Hypervisor Hang Resilience")
struct HypervisorHangResilienceTests {

    // MARK: - Stage budgets

    @Test("A hypervisor call that never returns is bounded by its stage budget")
    func budgetBoundsAHangingCall() async throws {
        let gate = Gate()

        var thrown: (any Error)?
        do {
            _ = try await StageBudget.run(seconds: 1, stage: "qmp-adopt") {
                // Stands in for the QMP greeting that never arrived.
                await gate.wait()
                return "unreachable"
            }
        } catch {
            thrown = error
        }
        await gate.release()

        let budgetError = thrown as? StageBudgetError
        #expect(budgetError != nil, "expected the stage budget to fire, got \(String(describing: thrown))")
        if case .exceeded(let stage, _) = budgetError {
            #expect(stage == "qmp-adopt")
        }
    }

    @Test("A stage that ignores cancellation still stops blocking the caller")
    func budgetEscapesNonCancellableWork() async throws {
        // The failure this guards is subtle: a task group awaits every child
        // before it rethrows, so cancelling a child parked on a
        // non-cancellation-aware continuation left the budget itself hung —
        // in exactly the scenario it exists to bound. A QMP round-trip that
        // never gets answered is precisely such a continuation.
        let stuck = UncancellableWork()

        var thrown: (any Error)?
        do {
            _ = try await StageBudget.run(seconds: 1, stage: "qmp-status") {
                try await stuck.run()
            }
        } catch {
            thrown = error
        }

        let budgetError = thrown as? StageBudgetError
        #expect(budgetError != nil, "the budget must return even though the stage ignores cancellation")
        stuck.finish()
    }

    @Test("A responsive call passes its value straight through the budget")
    func budgetPassesThroughFastCalls() async throws {
        let value = try await StageBudget.run(seconds: 30, stage: "qmp-status") { "running" }
        #expect(value == "running")
    }

    @Test("Adoption and control budgets are bounded and ordered sensibly")
    func budgetsAreConfigured() {
        // The reported hang was an unbounded re-adoption, so this must have a
        // deadline at all. Observation (heartbeat reporting) has to be the
        // tightest: liveness cannot wait on hypervisor progress.
        #expect(StageBudget.adoptionSeconds > 0)
        #expect(StageBudget.hypervisorControlSeconds > 0)
        #expect(StageBudget.observationSeconds > 0)
        #expect(StageBudget.observationSeconds < StageBudget.adoptionSeconds)
        #expect(StageBudget.observationSeconds < StageBudget.hypervisorControlSeconds)
    }

    // MARK: - Reconcile lane isolation

    @Test("A VM whose step hangs does not stop another VM from converging")
    func hungWorkloadDoesNotBlockOtherWorkloads() async {
        let stuckVM = UUID()
        let healthyVM = UUID()

        let actuator = HangingActuator(hangFor: stuckVM.uuidString)
        let reconciler = Reconciler(
            actuator: actuator, queue: SerialTaskQueue(), logger: Logger(label: "test"))

        await reconciler.apply(
            DesiredStateMessage(vms: [
                Self.desired(stuckVM),
                Self.desired(healthyVM),
            ]))

        // The healthy VM must converge on its own lane while the other is
        // wedged. Before the per-resource lanes this would have been a single
        // ordered pipeline and the hang would have starved everything behind it.
        let converged = await actuator.waitForCompletion(of: healthyVM.uuidString)
        #expect(converged, "the healthy VM should converge while another VM's step is hung")

        let stuckIsStillHung = await actuator.isStillRunning(stuckVM.uuidString)
        #expect(stuckIsStillHung, "the stuck VM's step should still be in flight")

        await actuator.release()
    }

    // MARK: - Fixtures

    private static func desired(_ vmId: UUID) -> DesiredVMState {
        DesiredVMState(
            vmId: vmId,
            hypervisorType: .qemu,
            spec: VMSpec(cpus: 1, memoryBytes: 1 << 30, boot: .disk(firmware: nil)),
            desiredStatus: .running,
            generation: 1
        )
    }

    /// A releasable block. Models a call parked on something that only an
    /// external event can complete — which is what a QMP continuation waiting
    /// on a greeting is.
    private actor Gate {
        private var released = false

        func release() {
            released = true
        }

        /// Cancellation-aware on purpose: the budget cancels the operation task
        /// it gives up on, and a loop that swallowed that would spin hot rather
        /// than stop.
        func wait() async {
            while !released && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// Work parked on a continuation that cancellation cannot touch — the
    /// shape of an unanswered QMP round-trip. Only `finish()` releases it.
    private final class UncancellableWork: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, any Error>?
        private var finished = false

        func run() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }

        func finish() {
            lock.lock()
            finished = true
            let waiter = continuation
            continuation = nil
            lock.unlock()
            waiter?.resume()
        }
    }

    /// Actuator that hangs indefinitely on one VM and converges every other.
    private actor HangingActuator: ReconcileActuator {
        private let hangFor: String
        private let gate = Gate()
        private var completed: Set<String> = []
        private var running: Set<String> = []

        init(hangFor: String) {
            self.hangFor = hangFor
        }

        func observedPresence() -> [String: VMPresence] { [:] }

        func adoptVM(_ item: ReconcileWorkItem) throws -> VMStatus { .running }

        func perform(_ step: ReconcileStep, item: ReconcileWorkItem) async throws {
            if item.vmId == hangFor {
                running.insert(item.vmId)
                await gate.wait()
                return
            }
            if step == .boot {
                completed.insert(item.vmId)
            }
        }

        func convergenceDidChange() {}

        func isStillRunning(_ vmId: String) -> Bool {
            running.contains(vmId) && !completed.contains(vmId)
        }

        func release() async {
            await gate.release()
        }

        func waitForCompletion(of vmId: String, timeoutMillis: Int = 5000) async -> Bool {
            var waited = 0
            while !completed.contains(vmId) && waited < timeoutMillis {
                try? await Task.sleep(for: .milliseconds(5))
                waited += 5
            }
            return completed.contains(vmId)
        }
    }
}
