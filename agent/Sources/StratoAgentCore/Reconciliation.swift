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
// stays free of hypervisor SDKs so the whole engine is unit-testable.
//
// Issue #417 generalized the engine over `WorkloadKind`: the diff, generation
// guard, retry policy, and failure classification are shared between VMs and
// sandboxes (deliberately not forked — two copies would drift); only the step
// vocabulary and the actuator routing differ per kind.
//
// STR-52 hung one more job off the same sync: each VM's `InstanceMetadata` is
// projected onto the `MetadataStore` the guest-facing IMDS reads. It is not
// actuation — no work item carries it — because a VM already in its desired
// status plans no steps. Mutable tags/keys do bump the generation (STR-66),
// while the hostname and service kill switch can still change at an equal one.
//
// STR-98 took omission out of the destructive path. A workload present here
// that a sync does not list is *held* and reported as unrecognized; it is torn
// down only when the control plane answers with an explicit tombstone (or an
// ordinary `.absent` entry). A blast-radius guard bounds how much of a host one
// sync's tombstones may remove.

// MARK: - Reconciler

/// One actor-isolated snapshot of the convergence fields carried together in
/// an observed-state record. Reading these as a unit prevents a heartbeat from
/// pairing an error from one transition with the generation of another.
public struct ConvergenceFacts: Equatable, Sendable {
    public let observedGeneration: Int64
    public let phase: String?
    public let lastError: String?
    public let failedGeneration: Int64?
    public let failureClassification: ObservedFailureClassification?
}

public actor Reconciler {
    /// Backoff after each transient failure at one generation. Once the fourth
    /// attempt fails, the reconciler keeps trying hourly until the workload
    /// converges or a newer generation replaces it.
    static func transientRetryDelay(afterAttempt attempt: Int) -> TimeInterval {
        switch attempt {
        case ...1: 60
        case 2: 5 * 60
        case 3: 15 * 60
        default: 60 * 60
        }
    }

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
        var classification: FailureClassification
        var retryNotBefore: Date?
        /// Whether the warning and process-local counter for a terminal
        /// permanent failure have already been emitted for this generation.
        var terminalSuppressionReported = false
        /// How many times a `blocked` item has now re-reported the same reason.
        ///
        /// Blocked items burn no attempt, so `attempts` cannot say how long one
        /// has been stuck — it reads 0 forever. This is what a periodic re-log
        /// counts, so an operator who starts tailing after the first refusal
        /// still learns, at error level, that a volume has been waiting hours
        /// on a guest nobody stopped.
        var blockedRepeats: Int = 0
    }

    private let actuator: any ReconcileActuator
    private let queue: SerialTaskQueue
    private let logger: Logger
    private let teardownGuard: TeardownGuard
    /// What this host's metadata service serves, projected from each sync's
    /// `DesiredVMState.metadata` (STR-52).
    private let metadataStore: MetadataStore
    /// Injectable wall clock for deterministic backoff tests.
    private let now: @Sendable () -> Date

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
    /// Number of permanent failures that have suppressed their first retry.
    /// Process-local by design; it resets when the agent restarts.
    public private(set) var retryCapSuppressions = 0
    /// Workloads this host holds that the last sync neither listed nor
    /// tombstoned, re-derived wholesale on every sync and reported to the
    /// control plane until it decides what they are.
    private var unrecognized: [UnrecognizedWorkload] = []
    /// Set while the most recent sync's teardowns were refused by the
    /// blast-radius guard; cleared by the first sync that passes it.
    private var teardownRefusal: ObservedTeardownRefusal?

    /// `metadataStore` is passed in rather than owned, because the reconciler
    /// only writes it — the guest-facing listener reads the same instance. It
    /// is required rather than defaulted for exactly that reason: a reconciler
    /// handed its own private store would write metadata nobody can serve, and
    /// nothing about that failure is visible from either side.
    public init(
        actuator: any ReconcileActuator,
        queue: SerialTaskQueue,
        logger: Logger,
        teardownGuard: TeardownGuard = TeardownGuard(),
        metadataStore: MetadataStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.actuator = actuator
        self.queue = queue
        self.logger = logger
        self.teardownGuard = teardownGuard
        self.metadataStore = metadataStore
        self.now = now
    }

    // MARK: Report accessors

    public func facts(for id: String, kind: WorkloadKind = .vm) -> ConvergenceFacts {
        let ref = WorkloadRef(kind: kind, id: id)
        let failure = failures[ref]
        let classification: ObservedFailureClassification? =
            switch failure?.classification {
            case .transient: .transient
            case .permanent: .permanent
            case .blocked: .blocked
            case .waitingOnDependency, nil: nil
            }
        return ConvergenceFacts(
            observedGeneration: lastApplied[ref] ?? 0,
            phase: currentPhase[ref],
            lastError: failure?.lastError,
            failedGeneration: failure?.generation,
            failureClassification: classification)
    }

    public func observedGeneration(for id: String, kind: WorkloadKind = .vm) -> Int64 {
        facts(for: id, kind: kind).observedGeneration
    }

    public func convergencePhase(for id: String, kind: WorkloadKind = .vm) -> String? {
        facts(for: id, kind: kind).phase
    }

    public func lastError(for id: String, kind: WorkloadKind = .vm) -> String? {
        facts(for: id, kind: kind).lastError
    }

    /// The generation whose convergence produced `lastError(for:kind:)`.
    /// Reported alongside the error so the control plane can tell a failure
    /// of the *current* generation from a stale one still carried on
    /// heartbeats.
    public func failedGeneration(for id: String, kind: WorkloadKind = .vm) -> Int64? {
        facts(for: id, kind: kind).failedGeneration
    }

    /// The retry contract accompanying the reported failure. A dependency wait
    /// is never stored as a failure and therefore never reaches this accessor.
    public func failureClassification(
        for id: String, kind: WorkloadKind = .vm
    ) -> ObservedFailureClassification? {
        facts(for: id, kind: kind).failureClassification
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
    public func failedConvergences(
        kind: WorkloadKind
    ) -> [String: (generation: Int64, error: String, classification: ObservedFailureClassification)] {
        var result: [String: (generation: Int64, error: String, classification: ObservedFailureClassification)] = [:]
        for (ref, failure) in failures where ref.kind == kind {
            guard let classification = failureClassification(for: ref.id, kind: ref.kind) else { continue }
            result[ref.id] = (failure.generation, failure.lastError, classification)
        }
        return result
    }

    // MARK: Applying a sync

    /// Diff a desired-state sync against reality and enqueue the work. Returns
    /// quickly — long convergence actions run on the per-workload lanes.
    ///
    /// Volume and snapshot desired lists are authoritative in the current wire
    /// schema. Local observations remain optional: a backend that cannot
    /// enumerate its store must skip that family rather than treating unknown
    /// presence as empty.
    public func apply(_ message: DesiredStateMessage) async {
        let tombstones = message.tombstones

        // Instance metadata is recorded before anything else this sync does,
        // and deliberately outside the presence guard below: the store is a
        // projection of what the control plane said, not of what this host
        // holds, so an agent that cannot enumerate its own workloads can still
        // serve their guests fresh metadata — which is the fail-static posture
        // the whole IMDS design rests on.
        //
        // It is not carried on a work item either. A VM already in its desired
        // status plans no steps at all; mutable tag/key edits advance the
        // generation without inventing a hypervisor action, while hostname and
        // service-switch edits can still arrive at an equal generation. Routing
        // the document through actuation would drop both shapes of edit.
        await recordMetadata(message.vms)

        // An agent that cannot enumerate its own workloads converges nothing
        // (STR-138). Every item this sync could plan rests on the presence
        // snapshot being an account of the host: absence would read as
        // "create it", and a create against a workload that is in fact still
        // running opens a second writer on its disk image. Refusing to
        // converge is strictly safer than converging against a host we can't
        // see, and it is not silent — the report carries the condition and the
        // host advertises no capacity, so nothing new lands here either.
        //
        // Volumes fall under the same refusal even though their *presence*
        // comes from the storage backend rather than the manifest, and so is
        // readable while it is not (STR-148). Their attachments are not: the
        // agent's record of what is plugged into which VM rides the VM's
        // manifest entry, so a blind host would report every volume detached
        // and plan an attach for each one against a guest that already has it.
        guard await actuator.presenceIsComplete() else {
            logger.error(
                "Ignoring desired-state sync: this host's workloads are unknown, so nothing can be converged against them",
                metadata: [
                    "syncId": .string(message.syncId),
                    "desiredVMs": .stringConvertible(message.vms.count),
                ])
            // Nothing can be held against a host we cannot see, and last
            // sync's held set describes a reality we no longer observe.
            if !unrecognized.isEmpty {
                unrecognized = []
                await actuator.convergenceDidChange()
            }
            return
        }

        await actuator.prepareManagedVolumeInventory(
            from: message.vms, desiredVolumes: message.volumes)

        let presentVMs = await actuator.observedPresence()
        // The durable half of the reconciler's memory (STR-151). `lastApplied`
        // is in-process and resets with the agent, which is exactly right for a
        // generation — an idempotent state converges again for free — and
        // exactly wrong for an edge, which would replay. Read once per sync and
        // shared by both planners.
        let appliedEdges = await actuator.observedEdgeNonces()
        let vmPlan = Self.plan(
            desired: message.vms, present: presentVMs, lastApplied: appliedGenerations(kind: .vm),
            presentSizing: await actuator.observedSizing(), tombstones: tombstones,
            appliedEdges: appliedEdges,
            presentNetworks: await actuator.observedNetworkSpecs(),
            presentFirecrackerMMDSInterfaces: await actuator.observedFirecrackerMMDSInterfaces())
        var plan = ReconcilePlan(items: [], unrecognized: vmPlan.unrecognized)

        var volumePlan = ReconcilePlan()
        var presentVolumeCount = 0
        // Nil is the storage backend saying it cannot enumerate the store —
        // not that the store is empty. Planning against `[:]` would create
        // every desired volume afresh over bytes that are probably still there.
        if let presentVolumes = await actuator.observedVolumePresence() {
            presentVolumeCount = presentVolumes.count
            volumePlan = Self.planVolumes(
                desired: message.volumes, present: presentVolumes,
                lastApplied: appliedGenerations(kind: .volume), tombstones: tombstones)
            plan.unrecognized += volumePlan.unrecognized
        } else {
            logger.error(
                "Skipping the volume half of this sync: this host cannot enumerate its volume store",
                metadata: [
                    "syncId": .string(message.syncId),
                    "desiredVolumes": .stringConvertible(message.volumes.count),
                ])
        }

        var snapshotPlan = ReconcilePlan()
        var presentSnapshotCounts: [WorkloadKind: Int] = [:]
        // Nil is the record store saying it cannot enumerate what this host
        // holds — not that it holds nothing. Planning against `[:]` would
        // re-capture every desired artifact over bytes that are probably still
        // there.
        if let presentSnapshots = await actuator.observedSnapshotPresence() {
            for presence in presentSnapshots.values {
                guard case .managed(let artifact) = presence else { continue }
                presentSnapshotCounts[artifact.kind.workloadKind, default: 0] += 1
            }
            snapshotPlan = Self.planSnapshots(
                desired: message.snapshots, present: presentSnapshots,
                lastApplied: appliedSnapshotGenerations(), tombstones: tombstones)
            plan.unrecognized += snapshotPlan.unrecognized
        } else {
            logger.error(
                "Skipping the snapshot half of this sync: this host cannot enumerate the artifacts it holds",
                metadata: [
                    "syncId": .string(message.syncId),
                    "desiredSnapshots": .stringConvertible(message.snapshots.count),
                ])
        }

        var presentSandboxCount = 0
        var sandboxPlan = ReconcilePlan()
        do {
            let presentSandboxes = await actuator.observedSandboxPresence()
            presentSandboxCount = presentSandboxes.count
            sandboxPlan = Self.planSandboxes(
                desired: message.sandboxes, present: presentSandboxes,
                lastApplied: appliedGenerations(kind: .sandbox), tombstones: tombstones,
                appliedEdges: appliedEdges)
            plan.unrecognized += sandboxPlan.unrecognized
        }

        // Enqueue order matters even though multi-lane items already give
        // mutual exclusion: holding two lanes guarantees isolation, not
        // sequence. Volume data-plane work goes first so a volume exists before
        // a VM that references it is built. A newly created attached volume is
        // one item (`create`, then `attach`) that already holds the VM lane, so
        // it must join that first group too; otherwise its VM runs first and
        // cannot resolve the volume's local path. A resize of the boot volume
        // for a VM that is about to boot is data-plane work too, even though the
        // volume already carries an attachment and therefore holds the VM lane.
        // It must queue before that boot; putting it with attachment work lets
        // the boot win and makes the grow refuse itself against the now-running
        // guest (STR-242). Other attached resize work remains after VM items so
        // a shutdown requested in the same sync can run first. Remaining
        // attachment work goes there for the same reason: it queues behind that
        // VM's create/boot on the VM's own lane instead of racing it and burning
        // a dependency wait.
        //
        // Snapshot work goes last for the same reason volume attachment does:
        // a capture holds its parent's lane, so enqueuing it after the parent's
        // own items is what makes it queue *behind* that parent's create/boot
        // instead of racing it — and a checkpoint of a guest that is still
        // being built is not a checkpoint of anything.
        let bootingVMIDs = Set(
            vmPlan.items.lazy.filter { $0.steps.contains(.boot) }.map(\.id))
        let bootVolumeIDs = Set(
            message.vms.lazy
                .filter { bootingVMIDs.contains($0.vmId.uuidString) }
                .flatMap { $0.spec.volumes.lazy.filter { $0.bootOrder == 0 }.map(\.volumeId.uuidString) }
        )
        let (volumeData, volumeAttachment) = volumePlan.items.partitioned {
            $0.laneKeys.count == 1 || $0.steps.contains(.create)
                || ($0.steps.contains(.resize) && bootVolumeIDs.contains($0.id))
        }
        plan.items =
            volumeData + vmPlan.items + volumeAttachment + sandboxPlan.items + snapshotPlan.items

        // Wholesale replacement, including the sandbox half's absence when the
        // control plane doesn't speak sandbox sync: the report must describe
        // what *this* sync failed to account for, never an older one's leftovers.
        let heldChanged = unrecognized != plan.unrecognized
        unrecognized = plan.unrecognized
        var items = plan.items
        var population: [WorkloadKind: Int] = [
            .vm: presentVMs.count,
            .sandbox: presentSandboxCount,
            .volume: presentVolumeCount,
        ]
        population.merge(presentSnapshotCounts) { _, new in new }
        let refusalChanged = applyTeardownGuard(
            to: &items, syncId: message.syncId, present: population)

        logger.debug(
            "Applying desired-state sync",
            metadata: [
                "syncId": .string(message.syncId),
                "desiredVMs": .stringConvertible(message.vms.count),
                "presentVMs": .stringConvertible(presentVMs.count),
                "desiredSandboxes": .stringConvertible(message.sandboxes.count),
                "presentSandboxes": .stringConvertible(presentSandboxCount),
                "desiredVolumes": .stringConvertible(message.volumes.count),
                "presentVolumes": .stringConvertible(presentVolumeCount),
                "desiredSnapshots": .stringConvertible(message.snapshots.count),
                "presentSnapshots": .stringConvertible(presentSnapshotCounts.values.reduce(0, +)),
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
            // applied generation; no need to occupy the workload lane. Their
            // edges are still consumed — an entry that planned no work is the
            // superseded case (a reboot the control plane has since stopped
            // wanting), and leaving the nonce unrecorded is what would fire it
            // weeks later.
            if item.steps.isEmpty {
                lastApplied[ref] = item.generation
                failures.removeValue(forKey: ref)
                if let edges = item.appliedEdges { await actuator.recordAppliedEdges(item, edges) }
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
    /// Evaluated **per kind**, against that kind's own population.
    ///
    /// A single mixed denominator silently dilutes the protection for the kind
    /// that matters most: a host with 4 VMs and 40 volumes would let all 4 VMs
    /// be torn down (`400 > 1100` is false) where the VM-only denominator
    /// refuses it (`400 > 100`). Volumes are cheap and numerous relative to
    /// guests, so the dilution gets worse exactly as hosts get denser. Each
    /// kind is bounded by its own count instead, which is also what the guard's
    /// percentage means to an operator reading it.
    private func applyTeardownGuard(
        to items: inout [ReconcileWorkItem], syncId: String, present: [WorkloadKind: Int]
    ) -> Bool {
        var refusedKinds: Set<WorkloadKind> = []
        var reasons: [String] = []
        var refusedTeardowns = 0
        var refusedPresent = 0

        for kind in WorkloadKind.allCases {
            let teardowns = items.filter { $0.isTombstone && $0.kind == kind }.count
            guard teardowns > 0 else { continue }
            let population = present[kind] ?? 0
            guard let reason = teardownGuard.refusal(teardowns: teardowns, present: population) else {
                continue
            }
            refusedKinds.insert(kind)
            reasons.append("\(kind.rawValue): \(reason)")
            refusedTeardowns += teardowns
            refusedPresent += population
        }

        let previous = teardownRefusal
        guard !refusedKinds.isEmpty else {
            teardownRefusal = nil
            return previous != nil
        }
        // Only the refused kinds lose their teardowns; a kind that passed its
        // own guard still converges, for the same reason the guard never stops
        // boots and creates.
        items.removeAll { $0.isTombstone && refusedKinds.contains($0.kind) }
        let reason = reasons.joined(separator: " ")
        let refusal = ObservedTeardownRefusal(
            syncId: syncId, requestedTeardowns: refusedTeardowns, presentWorkloads: refusedPresent,
            reason: reason)
        teardownRefusal = refusal
        logger.error(
            "Refusing this sync's workload teardowns; blast-radius guard tripped",
            metadata: [
                "syncId": .string(syncId),
                "kinds": .string(refusedKinds.map(\.rawValue).sorted().joined(separator: ",")),
                "requestedTeardowns": .stringConvertible(refusedTeardowns),
                "presentWorkloads": .stringConvertible(refusedPresent),
                "reason": .string(reason),
            ])
        return previous != refusal
    }

    /// Applied generations across all three artifact families in one map.
    /// `planSnapshots` partitions its *desired* list by kind but shares this,
    /// which is safe because ids are UUIDs: an id can only ever belong to one
    /// family, so no two families can read each other's entries.
    private func appliedSnapshotGenerations() -> [String: Int64] {
        var result: [String: Int64] = [:]
        for (ref, generation) in lastApplied where ref.kind.isSnapshotArtifact {
            result[ref.id] = generation
        }
        return result
    }

    /// Project this sync's per-VM metadata onto the store the guest-facing
    /// metadata service reads (STR-52).
    ///
    /// Two rules cover explicit absence and the current desired payload:
    ///
    /// * An entry that wants the VM **absent** withdraws its metadata.
    ///   Having nothing to serve is the safe state for a VM
    ///   leaving this host: the IMDS identifies its caller by source address,
    ///   and an address outlives the VM it was allocated to. This also covers
    ///   the VM that was already gone when the sync arrived, for which the
    ///   planner has no work to do and therefore no teardown to hook — and it
    ///   is why this withdrawal *leads* the VM off the host while the
    ///   tombstoned one trails it. The consequence is deliberate: a VM whose
    ///   delete keeps failing is still running with its metadata already gone,
    ///   which is the safe end of a trade whose other end serves a released
    ///   VM's SSH keys and user data to whoever next holds its address.
    /// * Otherwise the payload is applied as-is. Nil authoritatively withdraws
    ///   metadata for a VM that should remain present.
    ///
    /// Staleness is the store's own guard rather than `lastApplied`, which
    /// tracks convergence and so lags behind: a VM whose create keeps failing
    /// holds `lastApplied` still while generations advance, and every one of
    /// those syncs would look equally current to a guard reading it. A refused
    /// write is logged rather than swallowed — "the metadata the operator
    /// edited never took" is otherwise invisible in a service with no request
    /// log of its own.
    private func recordMetadata(_ desired: [DesiredVMState]) async {
        // Readiness first, and once for the whole sync rather than once per VM
        // (STR-56). A host that legitimately runs no VMs still becomes ready:
        // its listener must be able to answer "I do not serve that address"
        // rather than "I do not know anything yet", and looping over an empty
        // list would never say so.
        await metadataStore.markSyncApplied()
        for entry in desired {
            let outcome: MetadataWriteOutcome
            if entry.wantsAbsent {
                outcome = await metadataStore.withdraw(
                    entry.vmId, generation: entry.generation, because: .desiredAbsent)
            } else {
                outcome = await metadataStore.apply(entry.metadata, generation: entry.generation, for: entry.vmId)
            }
            guard case .stale(let recorded) = outcome else { continue }
            logger.debug(
                "Ignoring stale instance metadata; a newer sync is already recorded for this VM",
                metadata: [
                    "strato.vm.id": .string(entry.vmId.uuidString),
                    "generation": .stringConvertible(entry.generation),
                    "recordedGeneration": .stringConvertible(recorded),
                ])
        }

        // Arbitrate what was restored from disk against this authoritative
        // snapshot (STR-56). A VM deleted while this agent was down appears in
        // no sync at all — not even as `wantsAbsent` — so nothing above would
        // ever reach it, and the restored payload would stay servable for the
        // life of the host. Runs after the loop so this sync's own writes have
        // already cleared their records' provisional mark.
        let retired = await metadataStore.confirmRestored(namedBy: Set(desired.map(\.vmId)))
        guard !retired.isEmpty else { return }
        logger.info(
            "Retired restored instance metadata the control plane no longer knows about",
            metadata: [
                "count": .stringConvertible(retired.count),
                "strato.vm.ids": .array(retired.map { .string($0.uuidString) }),
            ])
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
        // Tombstoned teardowns bypass both terminal suppression and transient
        // backoff. Their control-plane row is already gone, so retaining the
        // stray until an hourly retry would unnecessarily prolong the leak.
        if var failure = failures[ref], !item.isTombstone,
            failure.generation == item.generation
        {
            let metadata: Logger.Metadata = [
                "kind": .string(item.kind.rawValue),
                "workloadId": .string(item.id),
                "generation": .stringConvertible(item.generation),
                "lastError": .string(failure.lastError),
            ]
            switch failure.classification {
            case .permanent:
                if !failure.terminalSuppressionReported {
                    failure.terminalSuppressionReported = true
                    failures[ref] = failure
                    retryCapSuppressions += 1
                    logger.warning(
                        "Suppressing convergence retry after a permanent failure",
                        metadata: metadata)
                }
                return false
            case .transient:
                if let retryNotBefore = failure.retryNotBefore, now() < retryNotBefore {
                    var backoffMetadata = metadata
                    backoffMetadata["retryNotBefore"] = .stringConvertible(retryNotBefore)
                    logger.debug(
                        "Skipping convergence retry during transient backoff",
                        metadata: backoffMetadata)
                    return false
                }
            case .blocked, .waitingOnDependency:
                break
            }
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
        case .volume, .snapshot:
            // Volumes and snapshot artifacts are files: there is no runtime
            // session to lose, so the planner never marks one orphaned and
            // never emits `.adopt`.
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
                let phase = phaseDescription(step, kind: item.kind)
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
            // A VM that just left this host takes its metadata with it
            // (STR-52). The `.absent` entries already withdrew theirs at sync
            // time; what this reaches is the tombstoned teardown, which has no
            // desired entry to carry a withdrawal. Doing it here rather than
            // when the tombstone is planned is what keeps a teardown the
            // blast-radius guard refused from silently blinding a VM this agent
            // deliberately kept running.
            //
            // Reading `.delete` as "the VM is gone" rests on it never sharing
            // an item with the steps that would put it back: every planner site
            // emits `[.delete]` alone, because there is no recreate flow. A
            // future one — say a resize that cannot happen in place planning
            // `delete` then `create` — must withdraw from the delete's own
            // completion instead, or it would blind a VM that is still here,
            // and the withdrawal's seal would hold until the generation moves.
            if item.kind == .vm, item.steps.contains(.delete), let vmId = UUID(uuidString: item.id) {
                await metadataStore.withdraw(vmId, generation: item.generation, because: .tornDown)
            }
            lastApplied[ref] = item.generation
            failures.removeValue(forKey: ref)
            // Every edge this entry asked for has now been applied — performed
            // if it was planned as a step, superseded if it was not. Recorded
            // only after the whole item succeeded, so a failed reboot retries
            // on the next sync instead of being silently swallowed.
            if let edges = item.appliedEdges { await actuator.recordAppliedEdges(item, edges) }
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
                ?? ConvergenceFailure(
                    generation: item.generation,
                    attempts: 0,
                    lastError: "",
                    classification: classification,
                    retryNotBefore: nil)
            if failure.generation != item.generation {
                failure = ConvergenceFailure(
                    generation: item.generation,
                    attempts: 0,
                    lastError: "",
                    classification: classification,
                    retryNotBefore: nil)
            }
            // A blocked failure burns no attempt (STR-199). It is recorded like
            // any other — the reason names a remedy, and an operator who never
            // sees it cannot apply one — but the precondition it names clears
            // without anyone minting a new generation, so the cap must not be
            // what decides whether the remedy works. Consuming the budget here
            // is exactly how a grow refused against a running guest stayed
            // refused after the guest was stopped.
            if classification != .blocked {
                failure.attempts += 1
            }
            failure.classification = classification
            failure.terminalSuppressionReported = false
            if classification == .transient {
                failure.retryNotBefore = now().addingTimeInterval(
                    Self.transientRetryDelay(afterAttempt: failure.attempts))
            } else {
                failure.retryNotBefore = nil
            }
            let reason = error.localizedDescription
            // A blocked item is re-driven on every sync for as long as the
            // block holds, so an error line per sync would bury the failures
            // that are actually new. It logs on the transition and then every
            // `blockedRelogInterval` repeats after that — often enough that an
            // operator who starts tailing mid-block still sees it at error
            // level, rarely enough to stay readable. Everything else logs each
            // attempt. Transient failures are rate-limited by backoff rather
            // than terminated after a fixed budget.
            let repeating = classification == .blocked && failure.lastError == reason
            failure.blockedRepeats = repeating ? failure.blockedRepeats + 1 : 0
            failure.lastError = reason
            failures[ref] = failure
            var metadata: Logger.Metadata = [
                "kind": .string(item.kind.rawValue),
                "workloadId": .string(item.id),
                "generation": .stringConvertible(item.generation),
                "attempt": .stringConvertible(failure.attempts),
                "error": .string(reason),
            ]
            if classification == .blocked {
                // `attempt` reads 0 for these by design; this is the field that
                // says how long the block has held.
                metadata["blockedRepeats"] = .stringConvertible(failure.blockedRepeats)
            }
            let message = Self.failureLogMessage(classification)
            if repeating, failure.blockedRepeats % Self.blockedRelogInterval != 0 {
                logger.debug(message, metadata: metadata)
            } else {
                logger.error(message, metadata: metadata)
            }
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

    /// How many repeats of an unchanged `blocked` reason pass between error
    /// lines. Roughly a quarter-hour at the full-refetch floor, sooner when
    /// desired state changes — the point is that a stuck volume keeps saying so
    /// rather than falling silent after its first refusal.
    static let blockedRelogInterval = 20

    /// What a failed convergence says in the log, by classification.
    private static func failureLogMessage(_ classification: FailureClassification) -> Logger.Message {
        switch classification {
        case .permanent:
            return "Workload convergence failed permanently; request cannot succeed on this agent"
        case .blocked:
            return "Workload convergence is blocked; retrying every sync until the block clears"
        case .transient, .waitingOnDependency:
            return "Workload convergence failed"
        }
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

    private func phaseDescription(_ step: ReconcileStep, kind: WorkloadKind) -> String {
        switch step {
        // A snapshot's `.create` is a capture, and the phase string is what an
        // operator reads while it runs — "creating" would describe the wrong
        // thing entirely for a step that pauses a live guest.
        case .create: return kind.isSnapshotArtifact ? "capturing" : "creating"
        case .adopt: return "re-adopting"
        case .boot: return "booting"
        case .pause: return "pausing"
        case .resume: return "resuming"
        case .resize: return "resizing"
        case .reconfigureNetworks: return "reconfiguring network interfaces"
        case .shutdown: return "shutting down"
        case .delete: return "deleting"
        case .attach: return "attaching"
        case .detach: return "detaching"
        case .throttle: return "applying I/O limits"
        case .export: return "exporting"
        case .reboot: return "restarting"
        case .restore: return "restoring"
        }
    }

}
