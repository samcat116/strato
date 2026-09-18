import Foundation
import StratoShared

extension Reconciler {
    // MARK: Pure diff engine

    /// Compute the VM convergence plan for one sync. Pure: no side effects,
    /// fully unit-testable.
    public static func plan(
        desired: [DesiredVMState],
        present: [String: VMPresence],
        lastApplied: [String: Int64],
        presentSizing: [String: VMSizing] = [:],
        tombstones: [DesiredWorkloadTombstone] = [],
        appliedEdges: [String: AppliedEdgeNonces] = [:],
        presentNetworks: [String: [NetworkSpec]] = [:],
        presentFirecrackerMMDSInterfaces: [String: [String]] = [:]
    ) -> ReconcilePlan {
        var plan = planCore(
            desired: desired, tombstones: tombstones, present: present, lastApplied: lastApplied,
            appliedEdges: appliedEdges)
        addResizes(
            to: &plan.items, desired: desired, present: present, lastApplied: lastApplied,
            sizing: presentSizing, appliedEdges: appliedEdges)
        addNetworkChanges(
            to: &plan.items, desired: desired, present: present, lastApplied: lastApplied,
            presentNetworks: presentNetworks,
            presentFirecrackerMMDSInterfaces: presentFirecrackerMMDSInterfaces,
            appliedEdges: appliedEdges)
        return plan
    }

    private static func addNetworkChanges(
        to items: inout [ReconcileWorkItem],
        desired: [DesiredVMState],
        present: [String: VMPresence],
        lastApplied: [String: Int64],
        presentNetworks: [String: [NetworkSpec]],
        presentFirecrackerMMDSInterfaces: [String: [String]],
        appliedEdges: [String: AppliedEdgeNonces]
    ) {
        for entry in desired where !entry.wantsAbsent {
            let id = entry.vmId.uuidString
            // Same staleness rule as the core diff and resize pass: equal
            // generations may correct drift, but an older replay must never
            // restore an obsolete NIC or MMDS policy.
            if let applied = lastApplied[id], entry.generation < applied { continue }
            guard case .managed? = present[id], let observed = presentNetworks[id] else { continue }

            let needsReconfiguration: Bool
            switch entry.hypervisorType {
            case .qemu:
                needsReconfiguration = observed != entry.spec.networks
            case .firecracker:
                // Firecracker cannot change MMDS's interface allow-list after
                // boot. Other NIC edits remain unsupported post-create, but a
                // metadata policy edit must rebuild the VMM so a disabled NIC
                // does not retain access until the VM is manually recreated.
                let observedInterfaces =
                    presentFirecrackerMMDSInterfaces[id]
                    ?? FirecrackerMMDSInterfacePlan.interfaceIDs(for: observed)
                let desiredInterfaces = FirecrackerMMDSInterfacePlan.interfaceIDs(
                    for: entry.spec.networks,
                    metadataServiceEnabled: entry.metadata?.isServiceEnabled ?? false)
                needsReconfiguration = observedInterfaces != desiredInterfaces
            }
            guard needsReconfiguration else { continue }

            if let index = items.firstIndex(where: { $0.kind == .vm && $0.id == id }) {
                guard !items[index].steps.contains(.create),
                    !items[index].steps.contains(.delete),
                    !items[index].steps.contains(.adopt)
                else { continue }

                if entry.hypervisorType == .firecracker {
                    let steps = Self.firecrackerMetadataReconfigurationSteps(
                        entry, appliedEdges: appliedEdges[id])
                    items[index] = ReconcileWorkItem(
                        kind: .vm, id: id, generation: entry.generation, steps: steps,
                        target: entry.asTarget,
                        appliedEdges: Self.edgesAfter(
                            entry.edges, applied: appliedEdges[id], planning: steps))
                    continue
                }

                var steps = items[index].steps
                if let shutdown = steps.firstIndex(of: .shutdown) {
                    steps.insert(.reconfigureNetworks, at: shutdown + 1)
                } else if let boot = steps.firstIndex(of: .boot) {
                    steps.insert(.reconfigureNetworks, at: boot)
                } else {
                    steps.insert(.reconfigureNetworks, at: 0)
                }
                items[index] = ReconcileWorkItem(
                    kind: .vm, id: id, generation: entry.generation, steps: steps,
                    target: entry.asTarget, appliedEdges: items[index].appliedEdges)
            } else {
                let steps: [ReconcileStep]
                if entry.hypervisorType == .firecracker {
                    steps = Self.firecrackerMetadataReconfigurationSteps(
                        entry, appliedEdges: appliedEdges[id])
                } else {
                    steps = [.reconfigureNetworks]
                }
                items.append(
                    ReconcileWorkItem(
                        kind: .vm, id: id, generation: entry.generation, steps: steps,
                        target: entry.asTarget,
                        appliedEdges: Self.edgesAfter(
                            entry.edges, applied: appliedEdges[id], planning: steps)))
            }
        }
    }

    /// A Firecracker metadata-policy change replaces its process and therefore
    /// resets observed power state to `.created`. Re-plan from that fact so a
    /// running VM boots again, a paused VM boots then pauses, and a shutdown VM
    /// remains stopped. A boot supersedes a pending reboot; restores retain the
    /// same ordering and nonce semantics as the ordinary status planner.
    private static func firecrackerMetadataReconfigurationSteps(
        _ entry: DesiredVMState, appliedEdges: AppliedEdgeNonces?
    ) -> [ReconcileStep] {
        let status = Self.statusSteps(desired: entry.desiredStatus, observed: .created)
        return [.reconfigureNetworks] + status
            + Self.edgeSteps(
                entry.edges, applied: appliedEdges, after: status,
                wantsRunning: entry.wantsRunning)
    }

    /// Plans `.resize` for VMs that are already running the status the control
    /// plane wants but at a different size than its spec asks for (issue #568),
    /// and for a stopped QEMU VM whose persistent vCPU count must shrink before
    /// its next boot (STR-248). This is the declarative alternative to an
    /// imperative resize RPC: it survives dropped syncs by construction, since
    /// the next level-triggered sync re-derives the same diff.
    ///
    /// A running VM with other steps planned is left alone: `.create` builds
    /// the process from the new spec wholesale, so resizing on top would be
    /// redundant at best. A stopped vCPU shrink is the exception. `.boot`
    /// starts the persistent definition **the host already holds** (`bootVM`
    /// takes no spec), and `DomainRedefinition` only widens vCPU ceilings. The
    /// offline `.resize` is therefore inserted before `.boot`, or becomes the
    /// sole step while shutdown remains desired. That ordering also keeps the
    /// generation unapplied if libvirt fails to update the definition.
    ///
    /// Equal-generation planning remains drift correction rather than a no-op.
    /// A boot may have applied a generation before a running-size probe exposes
    /// work still left to do; if that later resize fails, this agent can report
    /// `observedGeneration` and `failedGeneration` at the same value (STR-191).
    /// Nothing here compensates for it — `lastApplied` is honest and must stay
    /// honest. The control plane resolves the pair on read, by treating a
    /// failure at the current generation as not converged.
    private static func addResizes(
        to items: inout [ReconcileWorkItem],
        desired: [DesiredVMState],
        present: [String: VMPresence],
        lastApplied: [String: Int64],
        sizing: [String: VMSizing],
        appliedEdges: [String: AppliedEdgeNonces]
    ) {
        guard !sizing.isEmpty else { return }
        for entry in desired where !entry.wantsAbsent {
            let id = entry.vmId.uuidString
            guard case .managed(let status)? = present[id],
                let observed = sizing[id]
            else { continue }
            let runningResize =
                status == .running && entry.desiredStatus == .running
                && observed.differs(from: entry.spec)
            let stoppedVCPUShrink =
                entry.hypervisorType == .qemu
                && (status == .shutdown || status == .created)
                && entry.spec.cpus < observed.cpus
            guard runningResize || stoppedVCPUShrink else { continue }
            // Same staleness rule as the core diff: an older sync must never
            // undo a newer one, and an equal generation is drift correction —
            // which is deliberately *not* "already done". See the note above
            // for what an equal-generation retry means to the control plane.
            if let applied = lastApplied[id], entry.generation < applied { continue }

            if let index = items.firstIndex(where: { $0.kind == .vm && $0.id == id }) {
                var steps = items[index].steps
                if steps.isEmpty {
                    steps = [.resize]
                } else if stoppedVCPUShrink, let boot = steps.firstIndex(of: .boot) {
                    steps.insert(.resize, at: boot)
                } else {
                    continue
                }
                // The item this replaces may exist *only* to write the edge
                // record (`planCore`'s adoption case), so carry that decision
                // over rather than losing it to a resize.
                items[index] = ReconcileWorkItem(
                    kind: .vm, id: id, generation: entry.generation, steps: steps,
                    target: entry.asTarget, appliedEdges: items[index].appliedEdges)
            } else {
                items.append(
                    ReconcileWorkItem(
                        kind: .vm, id: id, generation: entry.generation, steps: [.resize],
                        target: entry.asTarget,
                        appliedEdges: Self.edgesAfter(
                            entry.edges, applied: appliedEdges[id], planning: [.resize])))
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

    /// Compute the snapshot-artifact convergence plan for one sync (STR-150).
    ///
    /// The desired list is mixed-kind, so it is split by family and each slice
    /// runs through the same engine as VMs, sandboxes and volumes — including
    /// the staleness guard, the held set, and the tombstone round trip. An
    /// artifact whose presence is not `.managed` is dropped rather than planned:
    /// artifacts have no runtime session, so the record store only ever yields
    /// `.managed`, and inventing an orphan for one would plan an `.adopt` no
    /// backend can perform.
    public static func planSnapshots(
        desired: [DesiredSnapshotState],
        present: [String: SnapshotPresence],
        lastApplied: [String: Int64],
        tombstones: [DesiredWorkloadTombstone] = []
    ) -> ReconcilePlan {
        var plan = ReconcilePlan()
        for family in SnapshotArtifactKind.allCases {
            let familyDesired = desired.filter { $0.kind == family }
            let familyPresent = present.filter { _, presence in
                guard case .managed(let artifact) = presence else { return false }
                return artifact.kind == family
            }
            guard !familyDesired.isEmpty || !familyPresent.isEmpty else { continue }
            let familyPlan = planFamily(
                family, desired: familyDesired, present: familyPresent,
                lastApplied: lastApplied, tombstones: tombstones)
            plan.items += familyPlan.items
            plan.unrecognized += familyPlan.unrecognized
        }
        return plan
    }

    private static func planFamily(
        _ family: SnapshotArtifactKind,
        desired: [DesiredSnapshotState],
        present: [String: SnapshotPresence],
        lastApplied: [String: Int64],
        tombstones: [DesiredWorkloadTombstone]
    ) -> ReconcilePlan {
        func planned<F: SnapshotArtifactFamily>(_: F.Type) -> ReconcilePlan {
            planCore(
                desired: desired.map { FamilyScopedSnapshot<F>(entry: $0) },
                tombstones: tombstones, present: present, lastApplied: lastApplied)
        }
        switch family {
        case .volumeSnapshot: return planned(VolumeSnapshotFamily.self)
        case .vmCheckpoint: return planned(VMCheckpointFamily.self)
        case .sandboxSnapshot: return planned(SandboxSnapshotFamily.self)
        }
    }

    /// The steps that take an existing snapshot artifact from `observed` to
    /// `desired` (STR-150). Empty when it already matches.
    ///
    /// An artifact's bytes are immutable, so there is exactly one thing that can
    /// still be wrong about one that exists: whether the copy the control plane
    /// asked for exists too. Nothing here ever re-captures — that is the whole
    /// safety property of modelling a capture as a create *strategy*
    /// (`DesiredSnapshotCapture`), which is read only while the artifact is
    /// absent. Without it a replayed sync would checkpoint a running guest again
    /// over the point in time the user is holding.
    ///
    /// A desired export that this host has already satisfied plans nothing, and
    /// an export field that goes *away* plans nothing either: withdrawing an
    /// exported copy is the control plane's own object-store bookkeeping, not a
    /// teardown the agent can perform.
    public static func snapshotSteps(
        desired: DesiredSnapshotState, observed: ObservedSnapshotArtifact
    ) -> [ReconcileStep] {
        guard desired.export != nil, !observed.exported else { return [] }
        return [.export]
    }

    /// Compute the sandbox convergence plan for one sync. Same engine, same
    /// semantics as the VM `plan`. Named (not an overload) so the VM call
    /// sites' unqualified `.running`-style literals stay unambiguous.
    public static func planSandboxes(
        desired: [DesiredSandboxState],
        present: [String: SandboxPresence],
        lastApplied: [String: Int64],
        tombstones: [DesiredWorkloadTombstone] = [],
        appliedEdges: [String: AppliedEdgeNonces] = [:]
    ) -> ReconcilePlan {
        planCore(
            desired: desired, tombstones: tombstones, present: present, lastApplied: lastApplied,
            appliedEdges: appliedEdges)
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
        lastApplied: [String: Int64],
        appliedEdges: [String: AppliedEdgeNonces] = [:]
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

            let presence = present[id]
            let steps: [ReconcileStep]
            switch presence {
            case .managed(let observed):
                if entry.wantsAbsent {
                    steps = [.delete]
                } else {
                    // Edges are planned only here, on a workload this host is
                    // actually managing, and only after the status steps. An
                    // orphan's state is unknown until it is re-adopted, and a
                    // workload that does not exist yet is about to be built
                    // from scratch — a boot supersedes a reboot, and a
                    // checkpoint of a VM that was never here cannot be here
                    // either.
                    let status = entry.convergenceSteps(from: observed)
                    steps =
                        status
                        + edgeSteps(
                            entry.edges, applied: appliedEdges[id], after: status,
                            wantsRunning: entry.wantsRunning)
                }
            case .orphaned:
                // Deleting an orphan also goes through adopt-first so the
                // surviving runtime process is actually torn down; the
                // actuator falls back to manifest-only removal if the
                // session cannot be reconnected.
                steps = entry.wantsAbsent ? [.delete] : [.adopt]
            case .quarantined:
                // Nothing routes here — not a create (it exists), not a
                // delete (there is no backend to ask), not an adopt. The
                // generation is deliberately not recorded either: this agent
                // has not converged the entry and must not claim it has, so a
                // build that *can* route it picks the work up where it is.
                continue
            case nil:
                if entry.wantsAbsent {
                    // Host-owned bytes are already absent. A namespaced RBD
                    // snapshot is cluster-owned, however, so a replacement
                    // client must issue the deterministic idempotent delete
                    // even though its local SnapshotRecord inventory is empty.
                    steps = entry.requiresDeleteWhenUnobserved ? [.delete] : []
                } else {
                    steps = [.create] + entry.convergenceSteps(from: entry.statusAfterCreate)
                }
            }

            // What this item will have applied for the workload's edges once it
            // finishes — nil when there is nothing to record. Computed here,
            // where the entry's nonces, the existing record and the steps
            // actually planned are all in hand.
            let itemEdges: AppliedEdgeNonces? =
                kind.carriesEdgeNonces && !steps.contains(.adopt) && !steps.contains(.delete)
                ? Self.edgesAfter(entry.edges, applied: appliedEdges[id], planning: steps)
                : nil

            // Nothing to do and nothing to record — skip entirely.
            //
            // "Nothing to record" is not the same as "no work", and that
            // distinction is what closes a window this stage would otherwise
            // leave open for the life of a workload. A host whose manifest
            // predates the nonce record adopts on its first *item*; without the
            // second clause a converged, idle VM never produces one, so the
            // record stays absent until something else bumps its generation —
            // and the thing that finally does is usually the very restart the
            // absent record then swallows. Emitting the empty-step item instead
            // costs one manifest write per workload, once, and makes the
            // adoption window exactly one sync (STR-151).
            let owesEdgeRecord =
                presence?.isManaged == true && kind.carriesEdgeNonces && appliedEdges[id] == nil
            if steps.isEmpty, let applied = lastApplied[id], applied >= entry.generation,
                !owesEdgeRecord
            {
                continue
            }
            items.append(
                ReconcileWorkItem(
                    kind: kind, id: id, generation: entry.generation, steps: steps,
                    target: entry.asTarget, appliedEdges: itemEdges))
        }

        // Everything on this host the sync did not list: torn down only where
        // the control plane said so explicitly, held and reported otherwise.
        var unrecognized: [UnrecognizedWorkload] = []
        for (id, presence) in present where !desiredIds.contains(id) {
            let applied = lastApplied[id] ?? 0
            if presence == .quarantined {
                // Reported, never torn down — not even under a tombstone. A
                // teardown needs a backend to perform it, and the whole reason
                // this entry is quarantined is that this build cannot name
                // one. Reporting it is what lets an operator see that the host
                // is holding something no agent here can act on.
                guard let workloadId = UUID(uuidString: id) else { continue }
                unrecognized.append(
                    UnrecognizedWorkload(
                        kind: kind, workloadId: workloadId, observedGeneration: applied,
                        status: "quarantined"))
                continue
            }
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
                case .quarantined: status = "quarantined"
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

    /// The steps for the edge nonces a desired entry carries (ADR 0001 stage 9,
    /// STR-151), appended after the status steps.
    ///
    /// Three rules, and each of them is a safety property rather than a
    /// convenience:
    ///
    /// * **No record, no edge.** A nil `applied` means this host has no memory
    ///   of what it has applied for the workload — a manifest from a build that
    ///   predates the field, or a workload it has never converged. Reading that
    ///   as zero would make a re-registered agent replay every reboot and
    ///   restore in the workload's history, rewinding a live guest to a
    ///   checkpoint from weeks ago. The record is written instead, unperformed,
    ///   by the first item the workload produces — which `planCore` makes sure
    ///   is the very next sync rather than whenever its generation happens to
    ///   move next, so the adoption window is one sync and not the life of an
    ///   idle VM.
    /// * **A boot supersedes a reboot**, and so does anything that leaves the
    ///   workload stopped. A guest built from scratch this sync is at least as
    ///   restarted as a reboot would make it, and rebooting a VM the control
    ///   plane wants shut down is not a smaller version of anything the user
    ///   asked for. Superseded is not deferred: the nonce is consumed either
    ///   way (see `edgesAfter`), or a stop-then-start weeks later would surprise
    ///   the guest with an ancient reboot.
    /// * **Nothing supersedes a restore — it waits.** A boot does not, because
    ///   loading a checkpoint needs a process to load it into: `[.boot,
    ///   .restore]` is the correct sequence for a stopped VM, and it is what
    ///   makes "restore after an agent restart" work with no extra message. Nor
    ///   does a stop, for the same reason read the other way — a restore is
    ///   about *state*, not power, so a power decision cannot answer it. It
    ///   stays outstanding until the workload is next wanted running.
    ///
    /// Both steps are emitted together when both nonces outrank, reboot first:
    /// restoring last is what leaves the guest in the state the checkpoint
    /// holds.
    static func edgeSteps(
        _ edges: DesiredEdges,
        applied: AppliedEdgeNonces?,
        after statusSteps: [ReconcileStep],
        wantsRunning: Bool
    ) -> [ReconcileStep] {
        guard let applied else { return [] }
        var steps: [ReconcileStep] = []
        if wantsRunning, let wanted = edges.rebootGeneration, wanted > (applied.reboot ?? 0),
            !statusSteps.contains(.boot)
        {
            steps.append(.reboot)
        }
        // A restore is guarded by `wantsRunning` too, but *only* as a wait: see
        // `edgesAfter`, which does not consume a restore it did not plan.
        if wantsRunning, let restore = edges.restore, restore.generation > (applied.restore ?? 0) {
            steps.append(.restore)
        }
        return steps
    }

    /// What the host will have applied once an item planning `steps` completes.
    ///
    /// This is where "superseded" and "deferred" are told apart, and the two
    /// edges answer differently — which is the point, because they are different
    /// kinds of intent:
    ///
    /// * **A reboot is always consumed.** Whatever the sync planned, the request
    ///   has been answered: performed if `.reboot` was planned, superseded
    ///   otherwise (by a boot that restarts the guest more thoroughly, or by a
    ///   desired status that wants it stopped, where rebooting is not a smaller
    ///   version of anything the user asked for). Leaving it outstanding is what
    ///   would surprise a guest with an ancient restart the next time it starts.
    /// * **A restore is consumed only when it is performed.** A restore is about
    ///   *state*, not power — which is exactly why a `.boot` does not supersede
    ///   one — so a stop landing between the request and the next sync cannot
    ///   answer it either. It waits instead, and lands as `[.boot, .restore]`
    ///   whenever the workload is next wanted running. Consuming it there would
    ///   silently discard a data-integrity request the API had already reported
    ///   converged.
    ///
    /// The one case that consumes everything is **adoption** (`applied == nil`):
    /// a host with no record cannot tell a request made a moment ago from one
    /// made months ago, so it writes down what the entry asks for and performs
    /// none of it. That asymmetry is the no-replay invariant; see
    /// `AppliedEdgeNonces`.
    static func edgesAfter(
        _ edges: DesiredEdges, applied: AppliedEdgeNonces?, planning steps: [ReconcileStep]
    ) -> AppliedEdgeNonces {
        guard let applied else { return AppliedEdgeNonces(applying: edges) }
        return AppliedEdgeNonces(
            reboot: edges.rebootGeneration ?? applied.reboot,
            restore: steps.contains(.restore) ? edges.restore?.generation : applied.restore)
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
    /// a grow must land before the attachment *moves* (the resize path wants
    /// the volume detached), and an attachment that is merely *wrong* has to be
    /// unplugged before it can be re-plugged elsewhere. The next
    /// level-triggered sync plans the following step, which is exactly how the
    /// VM planner sequences a boot behind a create.
    ///
    /// A desired *removal* of the attachment is the one inversion, and it
    /// inverts because the detach is what makes the grow possible (STR-199) —
    /// see the clause below.
    ///
    /// A shrink and a format change are deliberately *not* steps. Neither is
    /// something the agent can converge — one destroys data, the other is a
    /// conversion the control plane never asks for — so they surface as
    /// permanent failures from the actuator rather than as work that silently
    /// never completes.
    public static func volumeSteps(desired: DesiredVolumeState, observed: ObservedVolumeFacts) -> [ReconcileStep] {
        // Unplug before growing when the attachment is being *removed*, not
        // moved. The agent refuses to grow an image a guest may still hold
        // open and names two remedies — stop the guest, or detach — and with
        // the grow planned first only the *first* of them could ever run: the
        // refused resize was the only step planned, so the detach that would
        // lift the refusal was never reached and the volume retried a doomed
        // grow on every sync. Growing first still holds for an attachment that
        // is merely moving, where the resize is the thing that has to land
        // before the slot changes underneath it.
        if desired.attachment == nil, observed.attachedVMId != nil {
            return [.detach]
        }
        // Once the disk is attached in the right slot, a limit change outranks
        // a grow. A live grow may remain blocked while the guest runs; that
        // must not starve an independently enforceable fairness policy.
        if let attachment = desired.attachment,
            observed.attachedVMId == attachment.vmId.uuidString,
            observed.deviceName == attachment.deviceName.rawValue,
            !ioLimitsMatch(desired: desired.ioLimits, observed: observed.ioLimits)
        {
            return [.throttle]
        }
        if let size = observed.sizeBytes, desired.sizeBytes > size {
            return [.resize]
        }
        // Detachment is decided on `attachedVMId` alone, before the slot is
        // compared. Pairing the two in one equality check let a volume with no
        // desired attachment but a stale `deviceName` fall through to `.attach`
        // with nothing to attach to — which the actuator answers with a
        // *permanent* failure, degrading a volume whose only problem was a
        // leftover field.
        guard let attachment = desired.attachment else {
            // Detached and desired detached — the clause above already handled
            // the case where it is still plugged in.
            return unconfirmedSizeSteps(observed)
        }
        if observed.attachedVMId == attachment.vmId.uuidString,
            observed.deviceName == attachment.deviceName.rawValue
        {
            return unconfirmedSizeSteps(observed)
        }
        // Attached to the wrong VM or in the wrong slot: unplug first, and let
        // the next sync plan the attach against the observation that follows.
        if observed.attachedVMId != nil {
            return [.detach]
        }
        return [.attach]
    }

    /// Desired nil and an observed present-but-empty value are both uncapped.
    /// Observed nil is different: it means the agent could not read the
    /// backend, so even a clear must be re-driven rather than called applied.
    private static func ioLimitsMatch(
        desired: VolumeIOLimits?, observed: VolumeIOLimits?
    ) -> Bool {
        guard let observed else { return false }
        return desired?.iopsTotal == observed.iopsTotal
            && desired?.bpsTotal == observed.bpsTotal
    }

    /// What to do about a volume whose size the agent could not read, once
    /// every other difference is settled.
    ///
    /// A nil `sizeBytes` used to plan nothing at all. That was right about never
    /// growing on a guess and wrong about what planning nothing *means*: the
    /// item is still emitted whenever the generation is newer, and an item that
    /// runs no steps records its generation as applied. So a resize whose
    /// current size was never successfully read reported as converged — the
    /// exact "a grow that never happened reads as one that did" failure STR-199
    /// exists to remove, surviving on the probe-failure path.
    ///
    /// Planning `.resize` hands the question to the actuator, which refuses it
    /// as `blocked` naming the unreadable image rather than growing anything,
    /// so the generation stays unapplied and every sync retries until the probe
    /// works. It sits *last* on purpose: an unreadable size must not starve the
    /// attach and detach work above it, which needs no size at all.
    private static func unconfirmedSizeSteps(_ observed: ObservedVolumeFacts) -> [ReconcileStep] {
        observed.sizeBytes == nil ? [.resize] : []
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
