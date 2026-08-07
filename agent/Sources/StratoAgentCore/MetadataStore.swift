import Foundation
import StratoShared

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
/// A withdrawn VM keeps its record with a nil payload rather than losing it:
/// the generation is what refuses a late replay of the sync that still listed
/// the VM, and a resurrected entry is not a harmless stale read — the IMDS
/// identifies its caller by source address, and an address outlives the VM it
/// was allocated to. The retained records grow with the VMs this process has
/// ever been told about, which is the same growth `Reconciler.lastApplied` has
/// for the same reason: a few tens of bytes against a generation guard that
/// cannot be reconstructed once dropped.
public actor MetadataStore {
    /// One VM's metadata and the generation it arrived on. `metadata` is nil
    /// for a VM whose metadata has been withdrawn — the record then exists
    /// only to carry the generation.
    private struct Record {
        var generation: Int64
        var metadata: InstanceMetadata?
        /// Set when the VM was torn down on this host, as opposed to merely
        /// having nothing to serve. The distinction costs one `Bool` and buys
        /// the last resurrection guard: a control plane's nil may be reversed
        /// by the next sync at the same generation, a teardown may not, because
        /// the VM is not coming back under this id.
        var tornDown = false
    }

    private var records: [UUID: Record] = [:]

    public init() {}

    /// Record what the metadata service should serve for `vmId`, or nil to
    /// withdraw it. Returns whether the write was applied — false means the
    /// caller's sync is older than what is already recorded.
    @discardableResult
    public func apply(_ metadata: InstanceMetadata?, generation: Int64, for vmId: UUID) -> Bool {
        if let existing = records[vmId] {
            if generation < existing.generation { return false }
            // A torn-down VM is the one case where an equal generation is not
            // drift correction but a replay: the VM left this host, so a sync
            // that still lists it describes a host state that no longer exists.
            // A strictly newer sync still wins, since level-triggering must
            // stay able to correct even this.
            if existing.tornDown, generation == existing.generation { return false }
        }
        records[vmId] = Record(generation: generation, metadata: metadata)
        return true
    }

    /// Stop serving `vmId` because the VM has left this host.
    ///
    /// Unguarded, unlike `apply`, because the caller is reporting a fact about
    /// the host rather than relaying a claim from a sync — and the two can
    /// disagree about generations: a teardown is authorized from the
    /// *observed* generation the agent reported, which lags the sync
    /// generations this store records whenever a VM's convergence is failing.
    /// Refusing the withdrawal there would leave a deleted VM's metadata
    /// servable, which is the one direction that is not merely stale: the IMDS
    /// identifies its caller by source address, and an address outlives the VM
    /// it was allocated to.
    ///
    /// The record's generation still only moves forward, and the teardown is
    /// remembered, so no replay of a sync that predates it — or matches it —
    /// can resurrect the payload.
    public func withdraw(_ vmId: UUID, generation: Int64) {
        records[vmId] = Record(
            generation: max(records[vmId]?.generation ?? generation, generation), metadata: nil,
            tornDown: true)
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
