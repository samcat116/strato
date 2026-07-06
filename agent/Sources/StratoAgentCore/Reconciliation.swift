import Foundation
import Logging
import StratoShared

// Reconciliation phase 2 (issue #260): the agent-side reconcile loop.
//
// `Reconciler.plan` is the pure diff engine: it compares the control plane's
// authoritative desired set against what is actually present on this host and
// yields per-VM work items. The `Reconciler` actor drives those items onto the
// shared `SerialTaskQueue` VM lanes and tracks per-VM generations so replayed
// or reordered syncs cannot roll state backward. All hypervisor side effects
// go through `ReconcileActuator`, implemented by the Agent — this file stays
// free of SwiftQEMU so the whole engine is unit-testable.

// MARK: - Observed presence

/// What this agent knows about one VM when a sync arrives.
public enum VMPresence: Equatable, Sendable {
    /// Actively managed by a hypervisor service, with its last observed status.
    case managed(VMStatus)
    /// Recorded in the manifest by a previous incarnation of the agent; its
    /// hypervisor process may still be running but is not attached.
    case orphaned
}

// MARK: - Work items

/// A single convergence action. Items are executed in order within one
/// `ReconcileWorkItem`; the steps after `.adopt` are recomputed from the
/// adopted VM's actual status, which is unknowable until the QMP socket is
/// reconnected.
public enum ReconcileStep: Equatable, Sendable {
    /// Materialize disks and define the VM (ends "exists, not running").
    case create
    /// Reconnect an orphan's hypervisor session and move it back to managed.
    case adopt
    case boot
    case pause
    case resume
    case shutdown
    /// Gracefully stop (best effort) and remove the VM from this host.
    case delete
}

/// The planned convergence for one VM out of one sync.
public struct ReconcileWorkItem: Sendable {
    /// Canonical (uppercase) UUID string, matching the manifest keys and the
    /// per-VM serialization lanes.
    public let vmId: String
    /// The desired-state generation this item converges toward. 0 for VMs the
    /// control plane no longer lists (full-list semantics: undesired).
    public let generation: Int64
    public let steps: [ReconcileStep]
    /// The desired entry driving this item; nil only for undesired VMs (whose
    /// single step is `.delete`).
    public let desired: DesiredVMState?

    public init(vmId: String, generation: Int64, steps: [ReconcileStep], desired: DesiredVMState?) {
        self.vmId = vmId
        self.generation = generation
        self.steps = steps
        self.desired = desired
    }
}

// MARK: - Actuator

/// Hypervisor side effects the reconciler needs, implemented by the Agent.
/// Every method must be idempotent at the "already satisfied" level — e.g.
/// creating a VM that exists is a no-op — because level-triggered syncs will
/// re-drive any step whose effect was not yet observed.
public protocol ReconcileActuator: Sendable {
    /// Snapshot of everything present on this host (managed + orphaned).
    func observedPresence() async -> [String: VMPresence]
    /// Re-adopt an orphan and return its observed status, so the reconciler
    /// can plan the remaining convergence steps toward the desired status.
    func adoptVM(_ item: ReconcileWorkItem) async throws -> VMStatus
    /// Execute one non-adopt step.
    func perform(_ step: ReconcileStep, item: ReconcileWorkItem) async throws
    /// Called after every work item finishes (success or failure) so the agent
    /// can push a fresh `ObservedStateReport` to the control plane.
    func convergenceDidChange() async
}

// MARK: - Reconciler

public actor Reconciler {
    /// Attempts per (vmId, generation) before the reconciler stops re-driving
    /// a failing convergence. A new generation resets the count, so operator
    /// action (retry, spec fix) always re-arms the loop; without a cap, a
    /// permanently failing create (e.g. bad image) would re-run on every
    /// periodic sync forever.
    public static let maxAttemptsPerGeneration = 3

    private struct ConvergenceFailure {
        var generation: Int64
        var attempts: Int
        var lastError: String
    }

    private let actuator: any ReconcileActuator
    private let queue: SerialTaskQueue
    private let logger: Logger

    /// Last generation fully applied per VM. Rejects older syncs (the
    /// generation guard) and feeds `observed_generation` in reports.
    private var lastApplied: [String: Int64] = [:]
    /// Generation currently being converged per VM, so the periodic sync
    /// doesn't stack duplicate work behind a long-running item (e.g. a
    /// multi-GB image download).
    private var inFlight: [String: Int64] = [:]
    /// Human-readable current step per in-flight VM, surfaced as
    /// `convergencePhase` in observed reports.
    private var currentPhase: [String: String] = [:]
    private var failures: [String: ConvergenceFailure] = [:]

    public init(actuator: any ReconcileActuator, queue: SerialTaskQueue, logger: Logger) {
        self.actuator = actuator
        self.queue = queue
        self.logger = logger
    }

    // MARK: Report accessors

    public func observedGeneration(for vmId: String) -> Int64 {
        lastApplied[vmId] ?? 0
    }

    public func convergencePhase(for vmId: String) -> String? {
        currentPhase[vmId]
    }

    public func lastError(for vmId: String) -> String? {
        failures[vmId]?.lastError
    }

    /// The generation whose convergence produced `lastError(for:)`. Reported
    /// alongside the error so the control plane can tell a failure of the
    /// *current* generation from a stale one still carried on heartbeats.
    public func failedGeneration(for vmId: String) -> Int64? {
        failures[vmId]?.generation
    }

    /// VMs currently converging that may not exist on the hypervisor yet
    /// (mid-create), so report assembly can still surface their progress.
    public func inFlightVMs() -> [String: Int64] {
        inFlight
    }

    /// VMs whose last convergence attempt failed, with the failing generation
    /// and error. Report assembly includes these even when the VM has no
    /// hypervisor presence at all (e.g. a create that never got off the
    /// ground) — otherwise the control plane could never learn why and would
    /// wait out the operation's full completion budget.
    public func failedConvergences() -> [String: (generation: Int64, error: String)] {
        failures.mapValues { ($0.generation, $0.lastError) }
    }

    // MARK: Applying a sync

    /// Diff a desired-state sync against reality and enqueue the work. Returns
    /// quickly — long convergence actions run on the per-VM lanes.
    public func apply(_ message: DesiredStateMessage) async {
        let present = await actuator.observedPresence()
        let items = Self.plan(desired: message.vms, present: present, lastApplied: lastApplied)

        logger.debug(
            "Applying desired-state sync",
            metadata: [
                "syncId": .string(message.syncId),
                "desiredVMs": .stringConvertible(message.vms.count),
                "presentVMs": .stringConvertible(present.count),
                "workItems": .stringConvertible(items.count),
            ])

        var advancedWithoutWork = false
        for item in items {
            guard shouldExecute(item) else { continue }

            // Converged-but-newer-generation items (no steps) just advance the
            // applied generation; no need to occupy the VM lane.
            if item.steps.isEmpty {
                lastApplied[item.vmId] = item.generation
                failures.removeValue(forKey: item.vmId)
                advancedWithoutWork = true
                continue
            }

            inFlight[item.vmId] = item.generation
            currentPhase[item.vmId] = "queued"
            await queue.enqueue(key: item.vmId) { [weak self] in
                await self?.execute(item)
            }
        }

        // Generations that advanced with no hypervisor work still need a fresh
        // report, or the control plane would wait a full heartbeat interval to
        // learn `observed_generation` caught up (and to complete operations).
        if advancedWithoutWork {
            await actuator.convergenceDidChange()
        }
    }

    private func shouldExecute(_ item: ReconcileWorkItem) -> Bool {
        if let running = inFlight[item.vmId], running >= item.generation {
            // The same (or a newer) generation is already converging; the
            // level-triggered timer will pick up any residual drift afterward.
            return false
        }
        // Undesired-VM deletes (no control-plane row, generation 0) are exempt
        // from the attempt cap: nothing can ever mint a new generation for
        // them, so a cap would permanently leak the stray process. They are
        // level-triggered and cheap, so retrying on every sync is fine.
        if let failure = failures[item.vmId],
            item.desired != nil,
            failure.generation == item.generation,
            failure.attempts >= Self.maxAttemptsPerGeneration
        {
            logger.debug(
                "Skipping convergence retry; attempt cap reached for this generation",
                metadata: [
                    "vmId": .string(item.vmId),
                    "generation": .stringConvertible(item.generation),
                    "lastError": .string(failure.lastError),
                ])
            return false
        }
        return true
    }

    private func execute(_ item: ReconcileWorkItem) async {
        do {
            var steps = item.steps
            var index = 0
            while index < steps.count {
                let step = steps[index]
                currentPhase[item.vmId] = phaseDescription(step)
                if step == .adopt {
                    // The remaining plan depends on the orphan's actual state,
                    // unknowable before the hypervisor session is reconnected.
                    let observed = try await actuator.adoptVM(item)
                    if let desired = item.desired {
                        let remaining = Self.statusSteps(desired: desired.desiredStatus, observed: observed)
                        steps = Array(steps[...index]) + remaining
                    }
                } else {
                    try await actuator.perform(step, item: item)
                }
                index += 1
            }
            lastApplied[item.vmId] = item.generation
            failures.removeValue(forKey: item.vmId)
            logger.info(
                "VM converged to desired state",
                metadata: [
                    "vmId": .string(item.vmId),
                    "generation": .stringConvertible(item.generation),
                ])
        } catch {
            var failure =
                failures[item.vmId]
                ?? ConvergenceFailure(generation: item.generation, attempts: 0, lastError: "")
            if failure.generation != item.generation {
                failure = ConvergenceFailure(generation: item.generation, attempts: 0, lastError: "")
            }
            failure.attempts += 1
            failure.lastError = error.localizedDescription
            failures[item.vmId] = failure
            logger.error(
                "VM convergence failed",
                metadata: [
                    "vmId": .string(item.vmId),
                    "generation": .stringConvertible(item.generation),
                    "attempt": .stringConvertible(failure.attempts),
                    "error": .string(error.localizedDescription),
                ])
        }
        // Only clear the marker this item owns: a newer-generation item may
        // already be queued behind this one (shouldExecute admits it and
        // apply() re-keyed the entry), and clearing unconditionally would both
        // re-admit duplicate work for that generation and hide a mid-create VM
        // from the observed-state report's in-flight section.
        if inFlight[item.vmId] == item.generation {
            inFlight.removeValue(forKey: item.vmId)
            currentPhase.removeValue(forKey: item.vmId)
        }
        await actuator.convergenceDidChange()
    }

    private func phaseDescription(_ step: ReconcileStep) -> String {
        switch step {
        case .create: return "creating"
        case .adopt: return "re-adopting"
        case .boot: return "booting"
        case .pause: return "pausing"
        case .resume: return "resuming"
        case .shutdown: return "shutting down"
        case .delete: return "deleting"
        }
    }

    // MARK: Pure diff engine

    /// Compute the convergence plan for one sync. Pure: no side effects, fully
    /// unit-testable.
    ///
    /// * Entries older than the last applied generation are dropped (replays
    ///   and reordered syncs cannot roll state backward). An *equal*
    ///   generation is still re-planned — that is drift correction: if the VM
    ///   regressed out of band, the same generation converges it again.
    /// * Present VMs missing from the desired set are deleted (full-list
    ///   semantics: omission means "should not exist here").
    /// * Desired-and-satisfied VMs whose generation advanced yield an
    ///   empty-step item so the applied generation still catches up.
    public static func plan(
        desired: [DesiredVMState],
        present: [String: VMPresence],
        lastApplied: [String: Int64]
    ) -> [ReconcileWorkItem] {
        var items: [ReconcileWorkItem] = []
        var desiredIds = Set<String>()

        for entry in desired {
            let vmId = entry.vmId.uuidString
            desiredIds.insert(vmId)

            if let applied = lastApplied[vmId], entry.generation < applied {
                continue  // stale: an older sync must never undo a newer one
            }

            let steps: [ReconcileStep]
            switch present[vmId] {
            case .managed(let observed):
                if entry.desiredStatus == .absent {
                    steps = [.delete]
                } else {
                    steps = statusSteps(desired: entry.desiredStatus, observed: observed)
                }
            case .orphaned:
                // Deleting an orphan also goes through adopt-first so the
                // surviving hypervisor process is actually torn down; the
                // actuator falls back to manifest-only removal if the
                // session cannot be reconnected.
                steps = entry.desiredStatus == .absent ? [.delete] : [.adopt]
            case nil:
                if entry.desiredStatus == .absent {
                    steps = []  // already absent; just record the generation
                } else {
                    steps = [.create] + statusSteps(desired: entry.desiredStatus, observed: .created)
                }
            }

            // Nothing to do and nothing to record — skip entirely.
            if steps.isEmpty, let applied = lastApplied[vmId], applied >= entry.generation {
                continue
            }
            items.append(ReconcileWorkItem(vmId: vmId, generation: entry.generation, steps: steps, desired: entry))
        }

        // Full-list semantics: anything on this host the control plane did not
        // list should not exist here.
        for (vmId, _) in present where !desiredIds.contains(vmId) {
            items.append(ReconcileWorkItem(vmId: vmId, generation: 0, steps: [.delete], desired: nil))
        }

        return items
    }

    /// The steps that take a VM from `observed` to `desired`. Empty when the
    /// observed status already satisfies the goal.
    public static func statusSteps(desired: DesiredVMStatus, observed: VMStatus) -> [ReconcileStep] {
        if desired.isSatisfied(by: observed) {
            return []
        }
        switch desired {
        case .running:
            return observed == .paused ? [.resume] : [.boot]
        case .paused:
            switch observed {
            case .running:
                return [.pause]
            case .created, .shutdown:
                return [.boot, .pause]
            default:
                return [.pause]
            }
        case .shutdown:
            return [.shutdown]
        case .absent:
            return [.delete]
        }
    }
}
