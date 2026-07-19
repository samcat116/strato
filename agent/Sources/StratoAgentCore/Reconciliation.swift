import Foundation
import Logging
import StratoShared

// Reconciliation phase 2 (issue #260): the agent-side reconcile loop.
//
// `Reconciler.plan` is the pure diff engine: it compares the control plane's
// authoritative desired set against what is actually present on this host and
// yields per-workload work items. The `Reconciler` actor drives those items
// onto the shared `SerialTaskQueue` lanes and tracks per-workload generations
// so replayed or reordered syncs cannot roll state backward. All runtime side
// effects go through `ReconcileActuator`, implemented by the Agent — this file
// stays free of SwiftQEMU so the whole engine is unit-testable.
//
// Issue #417 generalized the engine over `WorkloadKind`: the diff, generation
// guard, attempt cap, and failure classification are shared between VMs and
// sandboxes (deliberately not forked — two copies would drift); only the step
// vocabulary and the actuator routing differ per kind.

// MARK: - Observed presence

/// What this agent knows about one workload when a sync arrives.
public enum WorkloadPresence<Status: Equatable & Sendable>: Equatable, Sendable {
    /// Actively managed by a runtime/hypervisor service, with its last
    /// observed status.
    case managed(Status)
    /// Recorded in the manifest by a previous incarnation of the agent; its
    /// backing process may still be running but is not attached.
    case orphaned
}

public typealias VMPresence = WorkloadPresence<VMStatus>
public typealias SandboxPresence = WorkloadPresence<SandboxStatus>

// MARK: - Work items

/// A single convergence action. Items are executed in order within one
/// `ReconcileWorkItem`; the steps after `.adopt` are recomputed from the
/// adopted workload's actual status, which is unknowable until the runtime
/// session is reconnected.
///
/// Sandboxes use a subset of the vocabulary (create/adopt/boot/shutdown/
/// delete): there is no pause/resume for sandboxes in v1, and the planner
/// never emits those steps for sandbox items.
public enum ReconcileStep: Equatable, Sendable {
    /// Materialize disks/rootfs and define the workload (ends "exists, not
    /// running").
    case create
    /// Reconnect an orphan's runtime session and move it back to managed.
    case adopt
    case boot
    case pause
    case resume
    case shutdown
    /// Gracefully stop (best effort) and remove the workload from this host.
    case delete
}

/// The desired entry driving a work item, tagged by workload kind.
public enum ReconcileTarget: Sendable {
    case vm(DesiredVMState)
    case sandbox(DesiredSandboxState)
}

/// The planned convergence for one workload out of one sync.
public struct ReconcileWorkItem: Sendable {
    public let kind: WorkloadKind
    /// Canonical (uppercase) UUID string, matching the manifest keys.
    public let id: String
    /// The desired-state generation this item converges toward. 0 for
    /// workloads the control plane no longer lists (full-list semantics:
    /// undesired).
    public let generation: Int64
    public let steps: [ReconcileStep]
    /// The desired entry driving this item; nil only for undesired workloads
    /// (whose single step is `.delete`).
    public let target: ReconcileTarget?

    /// The workload id under its historical name from the VM-only reconciler.
    /// VM actuation and the existing tests read this; new kind-aware code
    /// should prefer `id`.
    public var vmId: String { id }

    /// The VM desired entry, when this is a VM-kind item driven by one.
    public var desired: DesiredVMState? {
        if case .vm(let entry)? = target { return entry }
        return nil
    }

    /// The sandbox desired entry, when this is a sandbox-kind item driven by
    /// one.
    public var desiredSandbox: DesiredSandboxState? {
        if case .sandbox(let entry)? = target { return entry }
        return nil
    }

    /// Serial-lane key for this item. VM items share their lane with the
    /// imperative per-VM message handlers (the bare vmId), so the two modes
    /// can never interleave operations on one VM; sandbox items get their own
    /// namespace ("sandbox/" cannot collide with a UUID string).
    public var laneKey: String {
        switch kind {
        case .vm: return id
        case .sandbox: return "sandbox/" + id
        }
    }

    public init(kind: WorkloadKind, id: String, generation: Int64, steps: [ReconcileStep], target: ReconcileTarget?) {
        self.kind = kind
        self.id = id
        self.generation = generation
        self.steps = steps
        self.target = target
    }
}

// MARK: - Actuator

/// Runtime side effects the reconciler needs, implemented by the Agent, which
/// routes VM items to the hypervisor driver registry and sandbox items to the
/// sandbox runtime. Every method must be idempotent at the "already satisfied"
/// level — e.g. creating a workload that exists is a no-op — because
/// level-triggered syncs will re-drive any step whose effect was not yet
/// observed.
public protocol ReconcileActuator: Sendable {
    /// Snapshot of every VM present on this host (managed + orphaned).
    func observedPresence() async -> [String: VMPresence]
    /// Re-adopt an orphaned VM and return its observed status, so the
    /// reconciler can plan the remaining convergence steps toward the desired
    /// status.
    func adoptVM(_ item: ReconcileWorkItem) async throws -> VMStatus
    /// Snapshot of every sandbox present on this host (managed + orphaned).
    func observedSandboxPresence() async -> [String: SandboxPresence]
    /// Re-adopt an orphaned sandbox and return its observed status.
    func adoptSandbox(_ item: ReconcileWorkItem) async throws -> SandboxStatus
    /// Execute one non-adopt step; `item.kind` selects the runtime.
    func perform(_ step: ReconcileStep, item: ReconcileWorkItem) async throws
    /// Called after every work item finishes (success or failure) so the agent
    /// can push a fresh `ObservedStateReport` to the control plane.
    func convergenceDidChange() async
}

/// Thrown by the default sandbox hooks when an actuator without sandbox
/// support receives sandbox work. Should be unreachable: such agents never
/// advertise the sandbox capability, so the control plane never places
/// sandboxes on them — permanent, because retrying cannot grow a runtime.
public struct SandboxActuationUnsupportedError: ClassifiableError, LocalizedError {
    public var failureClassification: FailureClassification { .permanent }
    public var errorDescription: String? { "this actuator does not support sandbox workloads" }

    public init() {}
}

/// Sandbox defaults so VM-only actuators (including the pre-#417
/// conformances) stay source-compatible; the reconciler only calls these when
/// a sync plans sandbox work.
extension ReconcileActuator {
    public func observedSandboxPresence() async -> [String: SandboxPresence] { [:] }

    public func adoptSandbox(_ item: ReconcileWorkItem) async throws -> SandboxStatus {
        throw SandboxActuationUnsupportedError()
    }
}

// MARK: - Desired-state adapters

/// What the generic diff engine needs from a per-kind desired-state DTO. The
/// engine itself never mentions VMs or sandboxes — these adapters keep one
/// copy of the generation/orphan/full-list logic across kinds.
protocol ReconcilableDesired: Sendable {
    associatedtype ObservedStatus: Equatable & Sendable
    static var workloadKind: WorkloadKind { get }
    /// The observed status a completed `.create` step leaves the workload in,
    /// from which the remaining convergence steps are planned.
    static var statusAfterCreate: ObservedStatus { get }
    var workloadId: UUID { get }
    var generation: Int64 { get }
    /// True when the entry asks for the workload to not exist on this host.
    var wantsAbsent: Bool { get }
    /// Steps converging `observed` toward this entry's desired status; empty
    /// when the observation already satisfies it.
    func convergenceSteps(from observed: ObservedStatus) -> [ReconcileStep]
    var asTarget: ReconcileTarget { get }
}

extension DesiredVMState: ReconcilableDesired {
    static var workloadKind: WorkloadKind { .vm }
    static var statusAfterCreate: VMStatus { .created }
    var workloadId: UUID { vmId }
    var wantsAbsent: Bool { desiredStatus == .absent }
    func convergenceSteps(from observed: VMStatus) -> [ReconcileStep] {
        Reconciler.statusSteps(desired: desiredStatus, observed: observed)
    }
    var asTarget: ReconcileTarget { .vm(self) }
}

extension DesiredSandboxState: ReconcilableDesired {
    static var workloadKind: WorkloadKind { .sandbox }
    static var statusAfterCreate: SandboxStatus { .stopped }
    var workloadId: UUID { sandboxId }
    var wantsAbsent: Bool { desiredStatus == .absent }
    func convergenceSteps(from observed: SandboxStatus) -> [ReconcileStep] {
        Reconciler.sandboxStatusSteps(desired: desiredStatus, observed: observed)
    }
    var asTarget: ReconcileTarget { .sandbox(self) }
}

// MARK: - Reconciler

public actor Reconciler {
    /// Attempts per (workload, generation) before the reconciler stops
    /// re-driving a failing convergence. A new generation resets the count, so
    /// operator action (retry, spec fix) always re-arms the loop; without a
    /// cap, a permanently failing create (e.g. bad image) would re-run on
    /// every periodic sync forever.
    public static let maxAttemptsPerGeneration = 3

    /// Identity of one workload across the reconciler's bookkeeping: ids only
    /// collide across kinds by UUID accident, but the kind is what routes
    /// actuation, so generations/failures/phases must never be shared between
    /// a VM and a sandbox that happen to reuse an id.
    private struct WorkloadRef: Hashable {
        let kind: WorkloadKind
        let id: String

        init(_ item: ReconcileWorkItem) {
            self.kind = item.kind
            self.id = item.id
        }

        init(kind: WorkloadKind, id: String) {
            self.kind = kind
            self.id = id
        }
    }

    private struct ConvergenceFailure {
        var generation: Int64
        var attempts: Int
        var lastError: String
    }

    private let actuator: any ReconcileActuator
    private let queue: SerialTaskQueue
    private let logger: Logger

    /// Last generation fully applied per workload. Rejects older syncs (the
    /// generation guard) and feeds `observed_generation` in reports.
    private var lastApplied: [WorkloadRef: Int64] = [:]
    /// Generation currently being converged per workload, so the periodic
    /// sync doesn't stack duplicate work behind a long-running item (e.g. a
    /// multi-GB image download).
    private var inFlight: [WorkloadRef: Int64] = [:]
    /// Human-readable current step per in-flight workload, surfaced as
    /// `convergencePhase` in observed reports.
    private var currentPhase: [WorkloadRef: String] = [:]
    private var failures: [WorkloadRef: ConvergenceFailure] = [:]

    public init(actuator: any ReconcileActuator, queue: SerialTaskQueue, logger: Logger) {
        self.actuator = actuator
        self.queue = queue
        self.logger = logger
    }

    // MARK: Report accessors

    public func observedGeneration(for id: String, kind: WorkloadKind = .vm) -> Int64 {
        lastApplied[WorkloadRef(kind: kind, id: id)] ?? 0
    }

    public func convergencePhase(for id: String, kind: WorkloadKind = .vm) -> String? {
        currentPhase[WorkloadRef(kind: kind, id: id)]
    }

    public func lastError(for id: String, kind: WorkloadKind = .vm) -> String? {
        failures[WorkloadRef(kind: kind, id: id)]?.lastError
    }

    /// The generation whose convergence produced `lastError(for:kind:)`.
    /// Reported alongside the error so the control plane can tell a failure
    /// of the *current* generation from a stale one still carried on
    /// heartbeats.
    public func failedGeneration(for id: String, kind: WorkloadKind = .vm) -> Int64? {
        failures[WorkloadRef(kind: kind, id: id)]?.generation
    }

    /// Workloads of `kind` currently converging that may not exist on their
    /// runtime yet (mid-create), so report assembly can still surface their
    /// progress.
    public func inFlightWorkloads(kind: WorkloadKind) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for (ref, generation) in inFlight where ref.kind == kind {
            result[ref.id] = generation
        }
        return result
    }

    /// Workloads of `kind` whose last convergence attempt failed, with the
    /// failing generation and error. Report assembly includes these even when
    /// the workload has no runtime presence at all (e.g. a create that never
    /// got off the ground) — otherwise the control plane could never learn
    /// why and would wait out the operation's full completion budget.
    public func failedConvergences(kind: WorkloadKind) -> [String: (generation: Int64, error: String)] {
        var result: [String: (generation: Int64, error: String)] = [:]
        for (ref, failure) in failures where ref.kind == kind {
            result[ref.id] = (failure.generation, failure.lastError)
        }
        return result
    }

    // MARK: Applying a sync

    /// Diff a desired-state sync against reality and enqueue the work. Returns
    /// quickly — long convergence actions run on the per-workload lanes.
    ///
    /// `includeSandboxes` gates the sandbox half of the sync: a control plane
    /// older than the sandbox protocol omits `sandboxes` (decoded as `[]`),
    /// and full-list semantics would read that as "tear down every sandbox".
    /// The caller passes `WireProtocol.supportsSandboxSync(senderVersion)`.
    public func apply(_ message: DesiredStateMessage, includeSandboxes: Bool = false) async {
        let presentVMs = await actuator.observedPresence()
        var items = Self.plan(
            desired: message.vms, present: presentVMs, lastApplied: appliedGenerations(kind: .vm))

        var presentSandboxCount = 0
        if includeSandboxes {
            let presentSandboxes = await actuator.observedSandboxPresence()
            presentSandboxCount = presentSandboxes.count
            items += Self.planSandboxes(
                desired: message.sandboxes, present: presentSandboxes,
                lastApplied: appliedGenerations(kind: .sandbox))
        }

        logger.debug(
            "Applying desired-state sync",
            metadata: [
                "syncId": .string(message.syncId),
                "desiredVMs": .stringConvertible(message.vms.count),
                "presentVMs": .stringConvertible(presentVMs.count),
                "desiredSandboxes": .stringConvertible(includeSandboxes ? message.sandboxes.count : 0),
                "presentSandboxes": .stringConvertible(presentSandboxCount),
                "workItems": .stringConvertible(items.count),
            ])

        var advancedWithoutWork = false
        for item in items {
            guard shouldExecute(item) else { continue }
            let ref = WorkloadRef(item)

            // Converged-but-newer-generation items (no steps) just advance the
            // applied generation; no need to occupy the workload lane.
            if item.steps.isEmpty {
                lastApplied[ref] = item.generation
                failures.removeValue(forKey: ref)
                advancedWithoutWork = true
                continue
            }

            inFlight[ref] = item.generation
            currentPhase[ref] = "queued"
            await queue.enqueue(key: item.laneKey) { [weak self] in
                await self?.execute(item)
            }
        }

        // Generations that advanced with no runtime work still need a fresh
        // report, or the control plane would wait a full heartbeat interval to
        // learn `observed_generation` caught up (and to complete operations).
        if advancedWithoutWork {
            await actuator.convergenceDidChange()
        }
    }

    private func appliedGenerations(kind: WorkloadKind) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for (ref, generation) in lastApplied where ref.kind == kind {
            result[ref.id] = generation
        }
        return result
    }

    private func shouldExecute(_ item: ReconcileWorkItem) -> Bool {
        let ref = WorkloadRef(item)
        if let running = inFlight[ref], running >= item.generation {
            // The same (or a newer) generation is already converging; the
            // level-triggered timer will pick up any residual drift afterward.
            return false
        }
        // Undesired-workload deletes (no control-plane row, generation 0) are
        // exempt from the attempt cap: nothing can ever mint a new generation
        // for them, so a cap would permanently leak the stray process. They
        // are level-triggered and cheap, so retrying on every sync is fine.
        if let failure = failures[ref],
            item.target != nil,
            failure.generation == item.generation,
            failure.attempts >= Self.maxAttemptsPerGeneration
        {
            logger.debug(
                "Skipping convergence retry; attempt cap reached for this generation",
                metadata: [
                    "kind": .string(item.kind.rawValue),
                    "workloadId": .string(item.id),
                    "generation": .stringConvertible(item.generation),
                    "lastError": .string(failure.lastError),
                ])
            return false
        }
        return true
    }

    /// Adopt an orphan and return the steps that remain after adoption, which
    /// depend on the orphan's actual state — unknowable before the runtime
    /// session is reconnected.
    private func adoptAndReplan(_ item: ReconcileWorkItem) async throws -> [ReconcileStep] {
        switch item.target {
        case .vm(let desired):
            let observed = try await actuator.adoptVM(item)
            return Self.statusSteps(desired: desired.desiredStatus, observed: observed)
        case .sandbox(let desired):
            let observed = try await actuator.adoptSandbox(item)
            return Self.sandboxStatusSteps(desired: desired.desiredStatus, observed: observed)
        case nil:
            // The planner never emits `.adopt` without a desired entry
            // (undesired workloads plan `.delete` instead).
            return []
        }
    }

    private func execute(_ item: ReconcileWorkItem) async {
        let ref = WorkloadRef(item)
        do {
            var steps = item.steps
            var index = 0
            while index < steps.count {
                let step = steps[index]
                let phase = phaseDescription(step)
                currentPhase[ref] = phase
                if step == .adopt {
                    steps =
                        Array(steps[...index])
                        + (try await watched(phase, item) {
                            try await self.adoptAndReplan(item)
                        })
                } else {
                    try await watched(phase, item) {
                        try await self.actuator.perform(step, item: item)
                    }
                }
                index += 1
            }
            lastApplied[ref] = item.generation
            failures.removeValue(forKey: ref)
            logger.info(
                "Workload converged to desired state",
                metadata: [
                    "kind": .string(item.kind.rawValue),
                    "workloadId": .string(item.id),
                    "generation": .stringConvertible(item.generation),
                ])
        } catch {
            let classification = (error as? ClassifiableError)?.failureClassification ?? .transient

            // Waiting on another component (e.g. the site network controller
            // hasn't realized this workload's switch in the shared NB yet) is
            // not a failure: recording it would report `lastError` and fail
            // the pending operation on the control plane before the dependency
            // has a chance to land. Record nothing and burn no attempts — the
            // periodic level-triggered sync re-drives the item, and the
            // operation's completion budget backstops a dependency that never
            // arrives.
            if classification == .waitingOnDependency {
                logger.info(
                    "Workload convergence waiting on a dependency; will retry on the next sync",
                    metadata: [
                        "kind": .string(item.kind.rawValue),
                        "workloadId": .string(item.id),
                        "generation": .stringConvertible(item.generation),
                        "waitingOn": .string(error.localizedDescription),
                    ])
                if inFlight[ref] == item.generation {
                    inFlight.removeValue(forKey: ref)
                    currentPhase.removeValue(forKey: ref)
                }
                await actuator.convergenceDidChange()
                return
            }

            var failure =
                failures[ref]
                ?? ConvergenceFailure(generation: item.generation, attempts: 0, lastError: "")
            if failure.generation != item.generation {
                failure = ConvergenceFailure(generation: item.generation, attempts: 0, lastError: "")
            }
            failure.attempts += 1
            // A permanent failure (host misconfiguration: missing binary,
            // permissions, disk full) cannot succeed on retry — exhaust the
            // budget now so the remaining attempts aren't burned re-running a
            // doomed convergence. A new generation (operator retry after
            // fixing the host) still re-arms the loop as usual.
            if classification == .permanent {
                failure.attempts = max(failure.attempts, Self.maxAttemptsPerGeneration)
            }
            failure.lastError = error.localizedDescription
            failures[ref] = failure
            logger.error(
                classification == .permanent
                    ? "Workload convergence failed permanently; not retrying this generation (operator action required)"
                    : "Workload convergence failed",
                metadata: [
                    "kind": .string(item.kind.rawValue),
                    "workloadId": .string(item.id),
                    "generation": .stringConvertible(item.generation),
                    "attempt": .stringConvertible(failure.attempts),
                    "error": .string(error.localizedDescription),
                ])
        }
        // Only clear the marker this item owns: a newer-generation item may
        // already be queued behind this one (shouldExecute admits it and
        // apply() re-keyed the entry), and clearing unconditionally would both
        // re-admit duplicate work for that generation and hide a mid-create
        // workload from the observed-state report's in-flight section.
        if inFlight[ref] == item.generation {
            inFlight.removeValue(forKey: ref)
            currentPhase.removeValue(forKey: ref)
        }
        await actuator.convergenceDidChange()
    }

    /// How long a single step may run before the agent starts saying so, and
    /// how often it repeats afterwards. Set above the longest legitimate stage
    /// (a multi-GB image materialization) so a healthy slow create stays quiet.
    private static let watchdogIntervalSeconds = 300

    /// Run one convergence step with a watchdog that logs while it is still
    /// running.
    ///
    /// This does not cancel anything — a step that ignores cancellation would
    /// not stop anyway. It exists so a step that never returns is *visible*.
    /// In issue #516 a step hung indefinitely and the agent went silent: no
    /// timeout, no error, no log line, and the only evidence was the absence of
    /// later messages. A periodic "still running" line makes that self-evident
    /// in the log instead of requiring a thread dump to infer.
    private func watched<T: Sendable>(
        _ phase: String,
        _ item: ReconcileWorkItem,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let logger = self.logger
        let interval = Self.watchdogIntervalSeconds
        // Detached on purpose: a `Task {}` here would inherit this actor's
        // executor, so it could not report a step that wedges the actor —
        // precisely the case it exists for.
        let watchdog = Task.detached {
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                elapsed += interval
                logger.warning(
                    "Reconcile step still running",
                    metadata: [
                        "kind": .string(item.kind.rawValue),
                        "workloadId": .string(item.id),
                        "generation": .stringConvertible(item.generation),
                        "phase": .string(phase),
                        "elapsedSeconds": .stringConvertible(elapsed),
                    ])
            }
        }
        defer { watchdog.cancel() }
        return try await operation()
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

    /// Compute the VM convergence plan for one sync. Pure: no side effects,
    /// fully unit-testable.
    public static func plan(
        desired: [DesiredVMState],
        present: [String: VMPresence],
        lastApplied: [String: Int64]
    ) -> [ReconcileWorkItem] {
        planCore(desired: desired, present: present, lastApplied: lastApplied)
    }

    /// Compute the sandbox convergence plan for one sync. Same engine, same
    /// semantics as the VM `plan`. Named (not an overload) so the VM call
    /// sites' unqualified `.running`-style literals stay unambiguous.
    public static func planSandboxes(
        desired: [DesiredSandboxState],
        present: [String: SandboxPresence],
        lastApplied: [String: Int64]
    ) -> [ReconcileWorkItem] {
        planCore(desired: desired, present: present, lastApplied: lastApplied)
    }

    /// The kind-neutral diff. Rules, identical for every workload kind:
    ///
    /// * Entries older than the last applied generation are dropped (replays
    ///   and reordered syncs cannot roll state backward). An *equal*
    ///   generation is still re-planned — that is drift correction: if the
    ///   workload regressed out of band, the same generation converges it
    ///   again.
    /// * Present workloads missing from the desired set are deleted
    ///   (full-list semantics: omission means "should not exist here").
    /// * Desired-and-satisfied workloads whose generation advanced yield an
    ///   empty-step item so the applied generation still catches up.
    private static func planCore<Desired: ReconcilableDesired>(
        desired: [Desired],
        present: [String: WorkloadPresence<Desired.ObservedStatus>],
        lastApplied: [String: Int64]
    ) -> [ReconcileWorkItem] {
        var items: [ReconcileWorkItem] = []
        var desiredIds = Set<String>()
        let kind = Desired.workloadKind

        for entry in desired {
            let id = entry.workloadId.uuidString
            desiredIds.insert(id)

            if let applied = lastApplied[id], entry.generation < applied {
                continue  // stale: an older sync must never undo a newer one
            }

            let steps: [ReconcileStep]
            switch present[id] {
            case .managed(let observed):
                if entry.wantsAbsent {
                    steps = [.delete]
                } else {
                    steps = entry.convergenceSteps(from: observed)
                }
            case .orphaned:
                // Deleting an orphan also goes through adopt-first so the
                // surviving runtime process is actually torn down; the
                // actuator falls back to manifest-only removal if the
                // session cannot be reconnected.
                steps = entry.wantsAbsent ? [.delete] : [.adopt]
            case nil:
                if entry.wantsAbsent {
                    steps = []  // already absent; just record the generation
                } else {
                    steps = [.create] + entry.convergenceSteps(from: Desired.statusAfterCreate)
                }
            }

            // Nothing to do and nothing to record — skip entirely.
            if steps.isEmpty, let applied = lastApplied[id], applied >= entry.generation {
                continue
            }
            items.append(
                ReconcileWorkItem(
                    kind: kind, id: id, generation: entry.generation, steps: steps, target: entry.asTarget))
        }

        // Full-list semantics: anything on this host the control plane did not
        // list should not exist here.
        for (id, _) in present where !desiredIds.contains(id) {
            items.append(ReconcileWorkItem(kind: kind, id: id, generation: 0, steps: [.delete], target: nil))
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

    /// The steps that take a sandbox from `observed` to `desired`. Empty when
    /// the observed status already satisfies the goal — including `.exited`
    /// for both `.running` and `.stopped` (see
    /// `DesiredSandboxStatus.isSatisfied(by:)`): phase 1 has no restart
    /// policy, so a finished one-shot workload is never relaunched. Named
    /// (not an overload of `statusSteps`) for the same ambiguity reason as
    /// `planSandboxes`.
    public static func sandboxStatusSteps(desired: DesiredSandboxStatus, observed: SandboxStatus) -> [ReconcileStep] {
        if desired.isSatisfied(by: observed) {
            return []
        }
        switch desired {
        case .running:
            return [.boot]
        case .stopped:
            return [.shutdown]
        case .absent:
            return [.delete]
        }
    }
}
