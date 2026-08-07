import Foundation
import StratoShared

/// Why a VM's metadata was withdrawn. The two differ in what evidence they
/// carry, and therefore in how much of the generation guard applies.
public enum MetadataWithdrawal: Sendable, Equatable {
    /// The sync says the VM should not exist on this host. A claim from the
    /// control plane, so it is generation guarded like any other sync content.
    case desiredAbsent
    /// The VM has left this host — its delete converged. A fact about the host
    /// rather than a claim from a sync, so no generation guards it.
    case tornDown
}

/// What a write to the store did.
public enum MetadataWriteOutcome: Sendable, Equatable {
    case applied
    /// Refused: what is already recorded outranks the write. Carries the
    /// standing generation so a caller can say which two generations
    /// disagreed.
    case stale(recorded: Int64)
}

/// What this host's link-local metadata service serves, one entry per VM,
/// written by the reconciler from `DesiredVMState.metadata` as syncs arrive
/// (STR-52).
///
/// ## Why the agent holds it at all
///
/// Reads are served entirely from here, with no control-plane round trip. That
/// is the same fail-static posture as the rest of the reconciler and it is
/// deliberate: a guest that cannot read its metadata may fail to boot, so the
/// IMDS must keep answering across a control-plane outage exactly as a running
/// VM keeps running. The cost is that what this store holds is the last thing
/// the control plane said, not the current truth — which is the whole reason
/// the payload rides the level-triggered sync, where the next one corrects it.
///
/// **The guarantee is scoped to this process, not to this host.** The store is
/// in memory only, while the VM manifest is durable, so a restarted agent
/// re-adopts running VMs it can serve nothing for until the first sync lands —
/// and if the control plane is unreachable at that moment, for as long as that
/// lasts. That is the same outage this design claims immunity to, arriving
/// through the other door. It is survivable only because nothing serves reads
/// yet; the listener (STR-56) has to close it, by persisting alongside the
/// manifest or by refusing to answer until the first sync has been applied.
/// Serving a guest a confidently empty document would be worse than making it
/// wait.
///
/// ## Generations
///
/// Each record carries the generation it was written at, and a strictly older
/// write is refused: syncs may be replayed or reordered, and metadata must not
/// roll backward any more than a VM's desired status may. An *equal* generation
/// is applied, matching the reconciler's reading of a repeated generation as
/// drift correction — and that is load-bearing here rather than merely
/// consistent, because editing only what metadata carries (a hostname, an SSH
/// key) changes nothing about how the VM is realized and so bumps no
/// generation. A strict `>` would freeze such an edit out forever, which is the
/// mutability the IMDS exists to provide.
///
/// A withdrawal is the exception to that: it seals its generation, so only a
/// strictly newer sync may serve the VM again. The premise that one generation
/// can carry different content is exactly what makes this necessary — a
/// same-generation replay is otherwise indistinguishable from an edit, and for
/// a VM that is leaving the host the replay is the likelier of the two.
///
/// A withdrawn VM keeps its record with a nil payload rather than losing it:
/// the generation is what refuses a late replay of the sync that still listed
/// the VM, and a resurrected entry is not a harmless stale read — the IMDS
/// identifies its caller by source address, and an address outlives the VM it
/// was allocated to. The retained records grow with the VMs this process has
/// ever been told about, which is the same growth `Reconciler.lastApplied` has
/// for the same reason: a generation and a `Bool` against a guard that cannot
/// be reconstructed once dropped.
public actor MetadataStore {
    /// One VM's metadata and the generation it arrived on. `metadata` is nil
    /// for a VM whose metadata has been withdrawn — the record then exists
    /// only to carry the generation and the seal.
    private struct Record {
        var generation: Int64
        var metadata: InstanceMetadata?
        /// Set when the payload was withdrawn because the VM is leaving this
        /// host, or already has. Distinct from a nil payload the control plane
        /// itself sent, which means "nothing to serve right now" and stays
        /// reversible at the same generation.
        var withdrawn = false

        /// Why a payload write at `generation` must be refused, or nil to let
        /// it through.
        func refusal(of generation: Int64) -> MetadataWriteOutcome? {
            if generation < self.generation { return .stale(recorded: self.generation) }
            // The one case where an equal generation is a replay rather than
            // drift correction: this VM was withdrawn, so a sync that still
            // serves it describes a host state that no longer holds. A strictly
            // newer sync still wins, since level-triggering must stay able to
            // correct even this.
            if withdrawn, generation == self.generation { return .stale(recorded: self.generation) }
            return nil
        }
    }

    private var records: [UUID: Record] = [:]

    public init() {}

    /// Record what the metadata service should serve for `vmId`. A nil
    /// `metadata` is the control plane saying it has nothing to serve, which is
    /// reversible by the next sync; use `withdraw` for a VM that is leaving.
    @discardableResult
    public func apply(_ metadata: InstanceMetadata?, generation: Int64, for vmId: UUID) -> MetadataWriteOutcome {
        if let refusal = records[vmId]?.refusal(of: generation) { return refusal }
        records[vmId] = Record(generation: generation, metadata: metadata)
        return .applied
    }

    /// Stop serving `vmId`, and seal the generation so no replay resurrects the
    /// payload.
    ///
    /// `.tornDown` is unguarded, unlike every other write, because it reports a
    /// fact about the host rather than relaying a claim from a sync — and the
    /// two disagree about generations by construction: a teardown is authorized
    /// from the *observed* generation the agent reported, which lags the sync
    /// generations this store records whenever a VM's convergence is failing.
    /// Refusing the withdrawal there would leave a deleted VM's metadata
    /// servable, which is the one direction that is not merely stale: the IMDS
    /// identifies its caller by source address, and an address outlives the VM
    /// it was allocated to. The record's generation still only moves forward.
    ///
    /// `.desiredAbsent` is guarded like any sync content, since a replayed old
    /// "this VM should be gone" must not undo a newer sync that says otherwise.
    /// Re-withdrawing at the same generation is a no-op rather than a refusal —
    /// an absent VM is re-listed on every sync until it is gone, and that is
    /// not a disagreement worth reporting.
    @discardableResult
    public func withdraw(
        _ vmId: UUID, generation: Int64, because reason: MetadataWithdrawal
    ) -> MetadataWriteOutcome {
        let existing = records[vmId]
        if reason == .desiredAbsent, let existing, generation < existing.generation {
            return .stale(recorded: existing.generation)
        }
        records[vmId] = Record(
            generation: max(existing?.generation ?? generation, generation), metadata: nil, withdrawn: true)
        return .applied
    }

    /// What to serve a guest that identified itself as `vmId`, or nil when
    /// this host has nothing for it — never heard of it, or told to stop
    /// serving it.
    public func metadata(for vmId: UUID) -> InstanceMetadata? {
        records[vmId]?.metadata
    }

    /// The generation `vmId`'s metadata was last written at, nil if this host
    /// has never been told about the VM. Distinguishes "no record" from "a
    /// record that withdrew the metadata", which `metadata(for:)` cannot.
    public func appliedGeneration(for vmId: UUID) -> Int64? {
        records[vmId]?.generation
    }

    /// Everything currently servable, for a listener that indexes it by
    /// something other than VM id (the IMDS resolves its caller by source
    /// address). Withdrawn entries are omitted — their records exist only for
    /// the generation guard.
    public func snapshot() -> [UUID: InstanceMetadata] {
        records.compactMapValues(\.metadata)
    }
}
