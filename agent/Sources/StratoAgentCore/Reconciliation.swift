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
//
// STR-98 took omission out of the destructive path. A workload present here
// that a sync does not list is *held* and reported as unrecognized; it is torn
// down only when the control plane answers with an explicit tombstone (or an
// ordinary `.absent` entry). A blast-radius guard bounds how much of a host one
// sync's tombstones may remove.

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
public typealias VolumePresence = WorkloadPresence<ObservedVolumeFacts>

/// What this agent can see about one volume it holds, and the `ObservedStatus`
/// the generic diff engine converges (STR-148).
///
/// A struct rather than a status enum because a volume has no run state: the
/// facts that can diverge from desire are where its bytes are, how big they
/// are, and what it is plugged into. `sizeBytes` is the *virtual* size the
/// backend last reported, nil when the agent has not probed it — a nil never
/// plans a resize, so an unprobeable volume is left alone rather than
/// repeatedly grown.
public struct ObservedVolumeFacts: Equatable, Sendable {
    public let path: String
    public let format: DiskFormat
    public let sizeBytes: Int64?
    /// Canonical uppercase UUID string of the VM this volume is attached to,
    /// from the agent's durable attachment record.
    public let attachedVMId: String?
    public let deviceName: String?

    public init(
        path: String,
        format: DiskFormat,
        sizeBytes: Int64? = nil,
        attachedVMId: String? = nil,
        deviceName: String? = nil
    ) {
        self.path = path
        self.format = format
        self.sizeBytes = sizeBytes
        self.attachedVMId = attachedVMId
        self.deviceName = deviceName
    }
}

/// The sizing a VM on this host is actually running with, as opposed to the
/// sizing its desired spec asks for. Only the dimensions that can move on a
/// live guest: the two hot-addable ones (issue #568) plus its balloon target
/// (issue #567 phase 2) — everything else in a spec still needs a recreate.
public struct VMSizing: Equatable, Sendable {
    public let cpus: Int
    public let memoryBytes: Int64
    /// The balloon target last applied to this VM, or nil when none has been
    /// (the balloon is deflated and the guest holds its whole grant).
    public let balloonTargetBytes: Int64?

    public init(cpus: Int, memoryBytes: Int64, balloonTargetBytes: Int64? = nil) {
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.balloonTargetBytes = balloonTargetBytes
    }

    /// Whether `spec` asks for a different size than this.
    public func differs(from spec: VMSpec) -> Bool {
        cpus != spec.cpus || memoryBytes != spec.memoryBytes
            || balloonTargetBytes != spec.balloonTargetBytes
    }
}

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
    /// Converge a *running* VM's vCPU/memory sizing on the desired spec
    /// (issue #568), or grow a volume to its desired size (STR-148). Sandboxes
    /// are not resizable in place.
    case resize
    case shutdown
    /// Gracefully stop (best effort) and remove the workload from this host.
    case delete
    /// Present a volume to its desired VM (STR-148). Volume-only.
    case attach
    /// Remove a volume from the VM it is presented to (STR-148). Volume-only.
    case detach
}

/// The control-plane instruction driving a work item, tagged by workload kind.
///
/// Every item has one: there is no "the control plane said nothing about this"
/// case. Teardown of a workload no row describes arrives as an explicit
/// `.tombstone` (STR-98), not as an absence.
public enum ReconcileTarget: Sendable {
    case vm(DesiredVMState)
    case sandbox(DesiredSandboxState)
    case volume(DesiredVolumeState)
    /// Confirmed teardown of a workload the control plane has no row for.
    case tombstone(DesiredWorkloadTombstone)
}

/// The planned convergence for one workload out of one sync.
public struct ReconcileWorkItem: Sendable {
    public let kind: WorkloadKind
    /// Canonical (uppercase) UUID string, matching the manifest keys.
    public let id: String
    /// The desired-state generation this item converges toward — a tombstone's
    /// generation for a confirmed teardown, otherwise the desired entry's.
    public let generation: Int64
    public let steps: [ReconcileStep]
    /// What the control plane asked for.
    public let target: ReconcileTarget

    /// The workload id under its historical name from the VM-only reconciler.
    /// VM actuation and the existing tests read this; new kind-aware code
    /// should prefer `id`.
    public var vmId: String { id }

    /// The VM desired entry, when this is a VM-kind item driven by one.
    public var desired: DesiredVMState? {
        if case .vm(let entry) = target { return entry }
        return nil
    }

    /// The sandbox desired entry, when this is a sandbox-kind item driven by
    /// one.
    public var desiredSandbox: DesiredSandboxState? {
        if case .sandbox(let entry) = target { return entry }
        return nil
    }

    /// The volume desired entry, when this is a volume-kind item driven by one.
    public var desiredVolume: DesiredVolumeState? {
        if case .volume(let entry) = target { return entry }
        return nil
    }

    /// Whether this item is a confirmed teardown of a workload with no
    /// control-plane row. These are the only items the blast-radius guard
    /// counts, and the only ones exempt from the attempt cap.
    public var isTombstone: Bool {
        if case .tombstone = target { return true }
        return false
    }

    /// Every serial lane this item must hold while it runs. VM items share
    /// their lane with the imperative per-VM message handlers (the bare vmId),
    /// so the two modes can never interleave operations on one VM; sandbox and
    /// volume items get their own namespaces ("sandbox/" and "volume/" cannot
    /// collide with a UUID string).
    ///
    /// A volume item that carries an attachment also holds the *VM's* lane,
    /// because realizing it drives that VM's hypervisor session. This is the
    /// same two-lane guarantee `MessageEnvelope.serializationKeys` gave the
    /// imperative `volume_attach` frame, carried over rather than reinvented.
    public var laneKeys: [String] {
        switch kind {
        case .vm: return [id]
        case .sandbox: return ["sandbox/" + id]
        case .volume:
            guard let vmId = desiredVolume?.attachment?.vmId.uuidString else { return ["volume/" + id] }
            return ["volume/" + id, vmId]
        }
    }

    /// The item's primary lane. Retained for call sites and tests that predate
    /// multi-lane items; scheduling reads `laneKeys`.
    public var laneKey: String { laneKeys[0] }

    public init(kind: WorkloadKind, id: String, generation: Int64, steps: [ReconcileStep], target: ReconcileTarget) {
        self.kind = kind
        self.id = id
        self.generation = generation
        self.steps = steps
        self.target = target
    }
}

// MARK: - Plan output

/// What one sync diffs to: the work to run, plus the workloads this host holds
/// that the sync did not account for (STR-98).
///
/// The second half used to be the first half's `.delete` items. Splitting them
/// is the whole point: the reconciler converges what the control plane asked
/// for and *reports* what it did not mention, instead of reading silence as an
/// instruction.
public struct ReconcilePlan: Sendable {
    public var items: [ReconcileWorkItem]
    public var unrecognized: [UnrecognizedWorkload]

    public init(items: [ReconcileWorkItem] = [], unrecognized: [UnrecognizedWorkload] = []) {
        self.items = items
        self.unrecognized = unrecognized
    }
}

extension Array {
    /// Split into (elements satisfying `predicate`, the rest), preserving order
    /// in both halves.
    func partitioned(_ predicate: (Element) -> Bool) -> ([Element], [Element]) {
        var matching: [Element] = []
        var rest: [Element] = []
        for element in self {
            if predicate(element) {
                matching.append(element)
            } else {
                rest.append(element)
            }
        }
        return (matching, rest)
    }
}

// MARK: - Blast-radius guard

/// How much of a host one sync may tear down (STR-98 phase 2) — defense in
/// depth for the tombstone path itself.
///
/// A legitimate host drain is a rare, operator-initiated event and can afford
/// the override flag; a bug or a stale database cannot afford the fleet. The
/// guard trips only when *both* halves are exceeded, so a small host losing its
/// two stray workloads is unremarkable while a host losing all forty is not.
///
/// Scoped to tombstoned teardowns on purpose. An explicit `.absent` entry is a
/// per-workload API decision with a `ResourceOperation` row and an audit trail
/// behind it — capping those would refuse an ordinary "delete these twelve
/// VMs" and push operators into leaving the override on permanently, which
/// would disarm the guard for the machine-driven path it exists to bound.
public struct TeardownGuard: Sendable, Equatable {
    public static let defaultMinimumWorkloads = 3
    public static let defaultPercentOfPresent = 25

    /// Absolute floor: this many tombstoned teardowns in one sync are always
    /// allowed, whatever the percentage says.
    public let minimumWorkloads: Int
    /// Percentage of the host's present workloads above which a teardown batch
    /// is refused.
    public let percentOfPresent: Int
    /// Operator override, for a real drain.
    public let allowBulkTeardown: Bool

    public init(
        minimumWorkloads: Int = defaultMinimumWorkloads,
        percentOfPresent: Int = defaultPercentOfPresent,
        allowBulkTeardown: Bool = false
    ) {
        self.minimumWorkloads = max(0, minimumWorkloads)
        self.percentOfPresent = max(0, percentOfPresent)
        self.allowBulkTeardown = allowBulkTeardown
    }

    /// Why this batch is refused, or nil to let it through.
    public func refusal(teardowns: Int, present: Int) -> String? {
        guard !allowBulkTeardown, teardowns > minimumWorkloads else { return nil }
        guard teardowns * 100 > present * percentOfPresent else { return nil }
        return
            "refusing to tear down \(teardowns) of \(present) workloads on this host in one sync: "
            + "more than \(minimumWorkloads) and more than \(percentOfPresent)% of what is present. "
            + "Set allow_bulk_teardown in the agent config to override for a deliberate drain."
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
    /// The sizing each managed VM is actually running with, so the planner
    /// can spot a spec whose vCPU/memory changed under a running VM
    /// (issue #568).
    func observedSizing() async -> [String: VMSizing]
    /// Re-adopt an orphaned VM and return its observed status, so the
    /// reconciler can plan the remaining convergence steps toward the desired
    /// status.
    func adoptVM(_ item: ReconcileWorkItem) async throws -> VMStatus
    /// Snapshot of every sandbox present on this host (managed + orphaned).
    func observedSandboxPresence() async -> [String: SandboxPresence]
    /// Re-adopt an orphaned sandbox and return its observed status.
    func adoptSandbox(_ item: ReconcileWorkItem) async throws -> SandboxStatus
    /// Snapshot of every volume whose data this host holds (STR-148). Always
    /// `.managed`: a volume is a file, so there is no session to lose and
    /// nothing to re-adopt — the storage backend's directory listing is the
    /// whole truth.
    func observedVolumePresence() async -> [String: VolumePresence]
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
/// Why a volume could not be converged (STR-148). Both cases carry a
/// classification rather than being plain errors, because the difference
/// decides whether an operator ever sees them.
public enum VolumeConvergenceError: ClassifiableError, LocalizedError, Sendable {
    /// Something the agent cannot do however many times it is asked: a shrink,
    /// an unknown format, a host with no storage backend. Permanent, so the
    /// attempt cap short-circuits and the control plane degrades the volume
    /// with the reason instead of waiting out a completion budget.
    case unsupported(String)
    /// Something this volume depends on has not converged yet — its clone
    /// source, or the VM it attaches to, either of which may be mid-flight in
    /// the very same sync. Classified as a dependency wait, so it burns no
    /// attempt, records no error, and simply retries on the next
    /// level-triggered sync.
    case sourceNotReady(String)

    public var failureClassification: FailureClassification {
        switch self {
        case .unsupported: return .permanent
        case .sourceNotReady: return .waitingOnDependency
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unsupported(let reason), .sourceNotReady(let reason): return reason
        }
    }
}

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

    /// Actuators without a storage backend hold no volumes; the reconciler
    /// then plans creates for anything the sync desires and the actuator's
    /// `perform` decides what to do about it.
    public func observedVolumePresence() async -> [String: VolumePresence] { [:] }

    /// Actuators that cannot report per-VM sizing simply never have a resize
    /// planned for them; the change still lands at the VM's next boot.
    public func observedSizing() async -> [String: VMSizing] { [:] }

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
    /// from which the remaining convergence steps are planned. An instance
    /// requirement, not a static one, because for some kinds it depends on the
    /// entry: a created volume's facts are the size and format *this* entry
    /// asked for.
    var statusAfterCreate: ObservedStatus { get }
    var workloadId: UUID { get }
    var generation: Int64 { get }
    /// True when the entry asks for the workload to not exist on this host.
    var wantsAbsent: Bool { get }
    /// Steps converging `observed` toward this entry's desired status; empty
    /// when the observation already satisfies it.
    func convergenceSteps(from observed: ObservedStatus) -> [ReconcileStep]
    var asTarget: ReconcileTarget { get }
    /// The observed status as a wire-friendly string, for the diagnostic half
    /// of an `UnrecognizedWorkload` report.
    static func describe(_ observed: ObservedStatus) -> String
}

extension DesiredVMState: ReconcilableDesired {
    static var workloadKind: WorkloadKind { .vm }
    var statusAfterCreate: VMStatus { .created }
    var workloadId: UUID { vmId }
    var wantsAbsent: Bool { desiredStatus == .absent }
    func convergenceSteps(from observed: VMStatus) -> [ReconcileStep] {
        Reconciler.statusSteps(desired: desiredStatus, observed: observed)
    }
    var asTarget: ReconcileTarget { .vm(self) }
    static func describe(_ observed: VMStatus) -> String { observed.rawValue }
}

extension DesiredSandboxState: ReconcilableDesired {
    static var workloadKind: WorkloadKind { .sandbox }
    var statusAfterCreate: SandboxStatus { .stopped }
    var workloadId: UUID { sandboxId }
    var wantsAbsent: Bool { desiredStatus == .absent }
    func convergenceSteps(from observed: SandboxStatus) -> [ReconcileStep] {
        Reconciler.sandboxStatusSteps(desired: desiredStatus, observed: observed)
    }
    var asTarget: ReconcileTarget { .sandbox(self) }
    static func describe(_ observed: SandboxStatus) -> String { observed.rawValue }
}

extension DesiredVolumeState: ReconcilableDesired {
    static var workloadKind: WorkloadKind { .volume }
    var workloadId: UUID { volumeId }
    var wantsAbsent: Bool { desiredStatus == .absent }
    var asTarget: ReconcileTarget { .volume(self) }

    /// A freshly created volume has the size and format this entry asked for
    /// and is attached to nothing, so the only step that can remain after a
    /// `.create` is the attach.
    var statusAfterCreate: ObservedVolumeFacts {
        ObservedVolumeFacts(path: "", format: DiskFormat(rawValue: format) ?? .qcow2, sizeBytes: sizeBytes)
    }

    func convergenceSteps(from observed: ObservedVolumeFacts) -> [ReconcileStep] {
        Reconciler.volumeSteps(desired: self, observed: observed)
    }

    static func describe(_ observed: ObservedVolumeFacts) -> String {
        observed.attachedVMId.map { "attached to \($0)" } ?? "detached"
    }
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
    private let teardownGuard: TeardownGuard

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
    /// Workloads this host holds that the last sync neither listed nor
    /// tombstoned, re-derived wholesale on every sync and reported to the
    /// control plane until it decides what they are.
    private var unrecognized: [UnrecognizedWorkload] = []
    /// Set while the most recent sync's teardowns were refused by the
    /// blast-radius guard; cleared by the first sync that passes it.
    private var teardownRefusal: ObservedTeardownRefusal?

    public init(
        actuator: any ReconcileActuator,
        queue: SerialTaskQueue,
        logger: Logger,
        teardownGuard: TeardownGuard = TeardownGuard()
    ) {
        self.actuator = actuator
        self.queue = queue
        self.logger = logger
        self.teardownGuard = teardownGuard
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

    /// Workloads this host holds that the control plane has not accounted for
    /// (STR-98), for the observed-state report. The agent keeps running them
    /// meanwhile; only a tombstone in a later sync removes one.
    public func unrecognizedWorkloads() -> [UnrecognizedWorkload] {
        unrecognized
    }

    /// The blast-radius guard's refusal of the most recent sync's teardowns,
    /// if it tripped, for the observed-state report.
    public func lastTeardownRefusal() -> ObservedTeardownRefusal? {
        teardownRefusal
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
    /// older than the sandbox protocol omits `sandboxes` (decoded as `[]`).
    /// Since STR-98 that is no longer a teardown hazard — an unlisted sandbox
    /// is held, not destroyed — but it would still report every sandbox on the
    /// host as unaccounted for, which is false: the sender simply doesn't speak
    /// that half of the protocol. The caller passes
    /// `WireProtocol.supportsSandboxSync(senderVersion)`.
    ///
    /// `includeVolumes` gates the volume half the same way, but the message's
    /// own `volumes` field is the primary signal and the stricter one: nil
    /// there means the sender said nothing about volumes, and the half is
    /// skipped whatever the version claims (STR-148). Planning against an
    /// empty desired list instead would report every volume on the host as
    /// unaccounted for and invite a future reading of that silence as
    /// teardown — of the only copy of a user's data.
    public func apply(
        _ message: DesiredStateMessage, includeSandboxes: Bool = false, includeVolumes: Bool = false
    ) async {
        let tombstones = message.tombstones ?? []
        let presentVMs = await actuator.observedPresence()
        let vmPlan = Self.plan(
            desired: message.vms, present: presentVMs, lastApplied: appliedGenerations(kind: .vm),
            presentSizing: await actuator.observedSizing(), tombstones: tombstones)
        var plan = ReconcilePlan(items: [], unrecognized: vmPlan.unrecognized)

        var volumePlan = ReconcilePlan()
        var presentVolumeCount = 0
        if includeVolumes, let desiredVolumes = message.volumes {
            let presentVolumes = await actuator.observedVolumePresence()
            presentVolumeCount = presentVolumes.count
            volumePlan = Self.planVolumes(
                desired: desiredVolumes, present: presentVolumes,
                lastApplied: appliedGenerations(kind: .volume), tombstones: tombstones)
            plan.unrecognized += volumePlan.unrecognized
        }

        var presentSandboxCount = 0
        var sandboxPlan = ReconcilePlan()
        if includeSandboxes {
            let presentSandboxes = await actuator.observedSandboxPresence()
            presentSandboxCount = presentSandboxes.count
            sandboxPlan = Self.planSandboxes(
                desired: message.sandboxes, present: presentSandboxes,
                lastApplied: appliedGenerations(kind: .sandbox), tombstones: tombstones)
            plan.unrecognized += sandboxPlan.unrecognized
        }

        // Enqueue order matters even though multi-lane items already give
        // mutual exclusion: holding two lanes guarantees isolation, not
        // sequence. Volume data-plane work goes first so a volume exists before
        // a VM that references it is built, and volume *attachment* work goes
        // after the VM items so it queues behind that VM's create/boot on the
        // VM's own lane instead of racing it and burning a dependency wait.
        let (volumeData, volumeAttachment) = volumePlan.items.partitioned { $0.laneKeys.count == 1 }
        plan.items = volumeData + vmPlan.items + volumeAttachment + sandboxPlan.items

        // Wholesale replacement, including the sandbox half's absence when the
        // control plane doesn't speak sandbox sync: the report must describe
        // what *this* sync failed to account for, never an older one's leftovers.
        let heldChanged = unrecognized != plan.unrecognized
        unrecognized = plan.unrecognized
        var items = plan.items
        let refusalChanged = applyTeardownGuard(
            to: &items, syncId: message.syncId,
            present: presentVMs.count + presentSandboxCount + presentVolumeCount)

        logger.debug(
            "Applying desired-state sync",
            metadata: [
                "syncId": .string(message.syncId),
                "desiredVMs": .stringConvertible(message.vms.count),
                "presentVMs": .stringConvertible(presentVMs.count),
                "desiredSandboxes": .stringConvertible(includeSandboxes ? message.sandboxes.count : 0),
                "presentSandboxes": .stringConvertible(presentSandboxCount),
                "desiredVolumes": .stringConvertible(includeVolumes ? (message.volumes?.count ?? 0) : 0),
                "presentVolumes": .stringConvertible(presentVolumeCount),
                "unrecognized": .stringConvertible(plan.unrecognized.count),
                "workItems": .stringConvertible(items.count),
            ])
        if !plan.unrecognized.isEmpty {
            logger.warning(
                "Holding workloads the control plane did not account for; awaiting its decision",
                metadata: [
                    "syncId": .string(message.syncId),
                    "count": .stringConvertible(plan.unrecognized.count),
                    "workloadIds": .string(
                        plan.unrecognized.map { "\($0.kind.rawValue):\($0.workloadId.uuidString)" }
                            .joined(separator: ",")),
                ])
        }

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
            await queue.enqueue(keys: item.laneKeys) { [weak self] in
                await self?.execute(item)
            }
        }

        // Generations that advanced with no runtime work still need a fresh
        // report, or the control plane would wait a full heartbeat interval to
        // learn `observed_generation` caught up (and to complete operations).
        // Newly held workloads and teardown refusals report immediately for the
        // same reason: the held set is one half of a round trip the control
        // plane can only finish once it has seen it.
        if advancedWithoutWork || heldChanged || refusalChanged {
            await actuator.convergenceDidChange()
        }
    }

    /// Drop a sync's tombstoned teardowns when they would take out more of the
    /// host than the guard allows, and record why. Returns whether the recorded
    /// refusal changed, so `apply` can report it right away.
    ///
    /// Everything else in the sync still converges: a guard that also stopped
    /// boots and creates would turn a suspicious teardown batch into a total
    /// convergence outage, which is the failure it exists to prevent.
    private func applyTeardownGuard(
        to items: inout [ReconcileWorkItem], syncId: String, present: Int
    ) -> Bool {
        let teardowns = items.filter(\.isTombstone).count
        let previous = teardownRefusal
        guard let reason = teardownGuard.refusal(teardowns: teardowns, present: present) else {
            teardownRefusal = nil
            return previous != nil
        }
        items.removeAll(where: \.isTombstone)
        let refusal = ObservedTeardownRefusal(
            syncId: syncId, requestedTeardowns: teardowns, presentWorkloads: present, reason: reason)
        teardownRefusal = refusal
        logger.error(
            "Refusing this sync's workload teardowns; blast-radius guard tripped",
            metadata: [
                "syncId": .string(syncId),
                "requestedTeardowns": .stringConvertible(teardowns),
                "presentWorkloads": .stringConvertible(present),
                "reason": .string(reason),
            ])
        return previous != refusal
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
        // Tombstoned teardowns are exempt from the attempt cap: the workload
        // has no control-plane row, so nothing can ever mint a new generation
        // to re-arm a capped failure and the stray would leak until restart.
        // They are level-triggered and cheap, so retrying on every sync is fine.
        if let failure = failures[ref],
            !item.isTombstone,
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
        case .volume:
            // Volumes are files: there is no runtime session to lose, so the
            // planner never marks one orphaned and never emits `.adopt`.
            return []
        case .tombstone:
            // The planner never emits `.adopt` for a tombstone (its single
            // step is `.delete`).
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
        case .resize: return "resizing"
        case .shutdown: return "shutting down"
        case .delete: return "deleting"
        case .attach: return "attaching"
        case .detach: return "detaching"
        }
    }

    // MARK: Pure diff engine

    /// Compute the VM convergence plan for one sync. Pure: no side effects,
    /// fully unit-testable.
    public static func plan(
        desired: [DesiredVMState],
        present: [String: VMPresence],
        lastApplied: [String: Int64],
        presentSizing: [String: VMSizing] = [:],
        tombstones: [DesiredWorkloadTombstone] = []
    ) -> ReconcilePlan {
        var plan = planCore(desired: desired, tombstones: tombstones, present: present, lastApplied: lastApplied)
        addResizes(
            to: &plan.items, desired: desired, present: present, lastApplied: lastApplied, sizing: presentSizing)
        return plan
    }

    /// Plans `.resize` for VMs that are already running the status the
    /// control plane wants but at a different size than its spec asks for
    /// (issue #568) — the declarative alternative to an imperative resize
    /// RPC: it survives dropped syncs by construction, since the next
    /// level-triggered sync re-derives the same diff.
    ///
    /// A VM with other steps planned is left alone: `.create`/`.boot` build
    /// the process from the new spec wholesale, so resizing on top would be
    /// redundant at best. Likewise for a VM that isn't running — a stopped
    /// VM picks the new size up at its next boot.
    private static func addResizes(
        to items: inout [ReconcileWorkItem],
        desired: [DesiredVMState],
        present: [String: VMPresence],
        lastApplied: [String: Int64],
        sizing: [String: VMSizing]
    ) {
        guard !sizing.isEmpty else { return }
        for entry in desired where !entry.wantsAbsent {
            let id = entry.vmId.uuidString
            guard case .managed(.running)? = present[id],
                entry.desiredStatus == .running,
                let observed = sizing[id],
                observed.differs(from: entry.spec)
            else { continue }
            // Same staleness rule as the core diff: an older sync must never
            // undo a newer one, and an equal generation is drift correction.
            if let applied = lastApplied[id], entry.generation < applied { continue }

            if let index = items.firstIndex(where: { $0.kind == .vm && $0.id == id }) {
                guard items[index].steps.isEmpty else { continue }
                items[index] = ReconcileWorkItem(
                    kind: .vm, id: id, generation: entry.generation, steps: [.resize], target: entry.asTarget)
            } else {
                items.append(
                    ReconcileWorkItem(
                        kind: .vm, id: id, generation: entry.generation, steps: [.resize], target: entry.asTarget))
            }
        }
    }

    /// Compute the volume convergence plan for one sync (STR-148). Same engine,
    /// same semantics as the VM `plan`.
    public static func planVolumes(
        desired: [DesiredVolumeState],
        present: [String: VolumePresence],
        lastApplied: [String: Int64],
        tombstones: [DesiredWorkloadTombstone] = []
    ) -> ReconcilePlan {
        planCore(desired: desired, tombstones: tombstones, present: present, lastApplied: lastApplied)
    }

    /// Compute the sandbox convergence plan for one sync. Same engine, same
    /// semantics as the VM `plan`. Named (not an overload) so the VM call
    /// sites' unqualified `.running`-style literals stay unambiguous.
    public static func planSandboxes(
        desired: [DesiredSandboxState],
        present: [String: SandboxPresence],
        lastApplied: [String: Int64],
        tombstones: [DesiredWorkloadTombstone] = []
    ) -> ReconcilePlan {
        planCore(desired: desired, tombstones: tombstones, present: present, lastApplied: lastApplied)
    }

    /// The kind-neutral diff. Rules, identical for every workload kind:
    ///
    /// * Entries older than the last applied generation are dropped (replays
    ///   and reordered syncs cannot roll state backward). An *equal*
    ///   generation is still re-planned — that is drift correction: if the
    ///   workload regressed out of band, the same generation converges it
    ///   again.
    /// * A present workload the sync tombstones is deleted, at the tombstone's
    ///   generation and under the same staleness rule as any desired entry.
    /// * A present workload the sync neither lists nor tombstones is **held**
    ///   and reported as unrecognized (STR-98). It keeps running: omission is
    ///   the control plane failing to mention something, which is what a
    ///   restored database, a re-enrolled agent, or a scoping bug all look
    ///   like, and none of those is an instruction to destroy a guest.
    /// * Desired-and-satisfied workloads whose generation advanced yield an
    ///   empty-step item so the applied generation still catches up.
    private static func planCore<Desired: ReconcilableDesired>(
        desired: [Desired],
        tombstones: [DesiredWorkloadTombstone],
        present: [String: WorkloadPresence<Desired.ObservedStatus>],
        lastApplied: [String: Int64]
    ) -> ReconcilePlan {
        var items: [ReconcileWorkItem] = []
        var desiredIds = Set<String>()
        let kind = Desired.workloadKind
        let tombstonesById = Dictionary(
            tombstones.lazy.filter { $0.kind == kind }.map { ($0.workloadId.uuidString, $0) },
            uniquingKeysWith: { first, second in first.generation >= second.generation ? first : second }
        )

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
                    steps = [.create] + entry.convergenceSteps(from: entry.statusAfterCreate)
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

        // Everything on this host the sync did not list: torn down only where
        // the control plane said so explicitly, held and reported otherwise.
        var unrecognized: [UnrecognizedWorkload] = []
        for (id, presence) in present where !desiredIds.contains(id) {
            let applied = lastApplied[id] ?? 0
            guard let tombstone = tombstonesById[id] else {
                // Held. A workload whose id isn't a UUID cannot be named on
                // the wire, so it can never be reported — and therefore never
                // authorized for teardown either, which is the safe end of
                // that trade.
                guard let workloadId = UUID(uuidString: id) else { continue }
                let status: String
                switch presence {
                case .managed(let observed): status = Desired.describe(observed)
                case .orphaned: status = "orphaned"
                }
                unrecognized.append(
                    UnrecognizedWorkload(
                        kind: kind,
                        workloadId: workloadId,
                        observedGeneration: applied,
                        status: status))
                continue
            }
            // Same staleness rule as a desired entry: a replayed tombstone
            // must not undo a newer sync that re-adopted the workload.
            guard tombstone.generation >= applied else { continue }
            items.append(
                ReconcileWorkItem(
                    kind: kind, id: id, generation: tombstone.generation, steps: [.delete],
                    target: .tombstone(tombstone)))
        }

        // Tombstones for workloads this host does not have need no work: the
        // control plane retires them once the agent stops reporting the id.

        return ReconcilePlan(
            items: items, unrecognized: unrecognized.sorted { $0.workloadId.uuidString < $1.workloadId.uuidString })
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
    /// The steps that take an existing volume from `observed` to `desired`
    /// (STR-148). Empty when it already matches.
    ///
    /// At most one step is ever planned, and the order below is the reason:
    /// a grow must land before the attachment moves (the resize path wants the
    /// volume detached), and an attachment that is merely *wrong* has to be
    /// unplugged before it can be re-plugged elsewhere. The next
    /// level-triggered sync plans the following step, which is exactly how the
    /// VM planner sequences a boot behind a create.
    ///
    /// A shrink and a format change are deliberately *not* steps. Neither is
    /// something the agent can converge — one destroys data, the other is a
    /// conversion the control plane never asks for — so they surface as
    /// permanent failures from the actuator rather than as work that silently
    /// never completes.
    public static func volumeSteps(desired: DesiredVolumeState, observed: ObservedVolumeFacts) -> [ReconcileStep] {
        if let size = observed.sizeBytes, desired.sizeBytes > size {
            return [.resize]
        }
        let desiredVM = desired.attachment?.vmId.uuidString
        let desiredDevice = desired.attachment?.deviceName
        if observed.attachedVMId == desiredVM && observed.deviceName == desiredDevice {
            return []
        }
        // Attached to the wrong VM or in the wrong slot: unplug first, and let
        // the next sync plan the attach against the observation that follows.
        if observed.attachedVMId != nil {
            return [.detach]
        }
        return [.attach]
    }

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
