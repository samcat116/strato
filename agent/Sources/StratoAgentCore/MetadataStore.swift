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
/// **The guarantee was once scoped to this process rather than to this host**:
/// the store is in memory while the VM manifest is durable, so a restarted agent
/// re-adopted running VMs it could serve nothing for until the first sync landed
/// — and if the control plane was unreachable at that moment, for as long as
/// that lasted. That is the same outage this design claims immunity to, arriving
/// through the other door.
///
/// STR-56 closes it from both ends, because the two halves answer different
/// failures. `exportRecords`/`restore` give the agent a durable copy
/// (`MetadataSnapshotStore`, written beside the VM manifest), so a restart
/// keeps serving what the last sync said even with the control plane down. And
/// `origin()` reports whether anything is known at all, so a host with no sync
/// *and* no restorable file answers 503 rather than a confidently empty
/// document — the state where waiting is strictly better than answering.
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
        /// Restored from the durable copy and not yet confirmed by an
        /// authoritative sync. Cleared by any write, so only records this
        /// process has not heard about since starting carry it.
        var provisional = false

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
    /// Whether a durable copy was read at startup. True even when that copy held
    /// nothing: "this host served nothing when it last ran" is knowledge, and a
    /// listener may answer 404 on it. Not having looked is not.
    private var restoredFromDisk = false
    /// Whether a desired-state sync has been applied in this process.
    private var syncApplied = false

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

    /// Everything currently servable, for a listener that indexes it by
    /// something other than VM id (the IMDS resolves its caller by source
    /// address). Withdrawn entries are omitted — their records exist only for
    /// the generation guard.
    public func snapshot() -> [UUID: InstanceMetadata] {
        records.compactMapValues(\.metadata)
    }

    // MARK: - Readiness (STR-56)

    /// Record that a sync has been applied, whatever it contained.
    ///
    /// Called once per sync rather than once per VM, so a host that legitimately
    /// runs no VMs still becomes ready — otherwise its listener would answer
    /// "not available yet" forever, which is exactly the wrong answer for the
    /// host that most confidently serves nothing.
    public func markSyncApplied() {
        syncApplied = true
    }

    /// How much this store's contents can be trusted to mean anything, which is
    /// what separates a listener's 404 from its 503.
    public func origin() -> MetadataSnapshotOrigin {
        if syncApplied { return .live }
        return restoredFromDisk ? .restored : .cold
    }

    // MARK: - Durability (STR-56)

    /// The full record set, generations and seals included, for the durable
    /// copy.
    ///
    /// Withdrawn records are exported too. They carry no payload, but they carry
    /// the generation that refuses a late replay of the sync which still listed
    /// the VM — dropping them at the file boundary would reintroduce, once per
    /// agent restart, exactly the resurrection `withdraw` exists to prevent.
    public func exportRecords() -> [UUID: PersistedMetadataRecord] {
        records.mapValues {
            PersistedMetadataRecord(generation: $0.generation, metadata: $0.metadata, withdrawn: $0.withdrawn)
        }
    }

    /// Adopt a durable copy read at startup.
    ///
    /// Merged under the same forward-only rule as everything else rather than
    /// assigned wholesale: a restore racing the first sync must not roll a VM
    /// backward just because the file is older than the message. In the ordinary
    /// case the store is empty and every record is taken.
    ///
    /// Everything restored is **provisional** until `confirmRestored` runs. The
    /// file is a snapshot of what the control plane said last time this agent
    /// ran, and the agent may have been down while a VM was deleted and reaped
    /// — in which case no sync will ever carry the `wantsAbsent` entry that
    /// would withdraw it, and no teardown will run. Without the confirmation
    /// step such a record would stay servable forever, and hand the deleted VM's
    /// metadata to whatever next holds its address.
    public func restore(_ persisted: [UUID: PersistedMetadataRecord]) {
        for (vmId, record) in persisted {
            if let existing = records[vmId], existing.generation >= record.generation { continue }
            records[vmId] = Record(
                generation: record.generation, metadata: record.metadata, withdrawn: record.withdrawn,
                provisional: true)
        }
        restoredFromDisk = true
    }

    /// Arbitrate the restored records against the first authoritative sync:
    /// anything it does not name is retired. Returns what was retired, for the
    /// log.
    ///
    /// A sync is a full snapshot of what this host should hold, so a restored
    /// record it does not mention describes a VM the control plane no longer
    /// has. That is the one case the durable copy can be *wrong* rather than
    /// merely stale, and it is not self-correcting: nothing else in the store
    /// ever removes a record, deliberately (a VM the sync merely omits keeps its
    /// metadata — STR-98, omission is not an instruction). That rule protects
    /// records this process learned from a sync; it must not be extended to
    /// records it inherited from a file, which no sync has vouched for.
    ///
    /// Retired records are **withdrawn, not deleted**. A tombstone stops the
    /// payload being served — which is the whole point — while keeping the
    /// generation that refuses a late replay of the sync that still listed the
    /// VM. Deleting outright would fix the disclosure and reopen the
    /// resurrection it was sealed against.
    ///
    /// Idempotent, and free after the first sync: nothing is provisional once
    /// this has run.
    @discardableResult
    public func confirmRestored(namedBy named: Set<UUID>) -> [UUID] {
        var retired: [UUID] = []
        for (vmId, record) in records where record.provisional {
            guard !named.contains(vmId) else {
                records[vmId]?.provisional = false
                continue
            }
            records[vmId] = Record(
                generation: record.generation, metadata: nil, withdrawn: true, provisional: false)
            // Only a record that was actually serving something is worth
            // reporting: a restored tombstone the sync does not name is the
            // ordinary end state of a VM that left cleanly.
            if record.metadata != nil { retired.append(vmId) }
        }
        return retired.sorted { $0.uuidString < $1.uuidString }
    }
}

/// One store record as it is written to disk.
///
/// A separate type from the actor's private `Record` on purpose: this one is a
/// wire format with a compatibility obligation, and coupling it to the in-memory
/// shape would make every future field on the latter a migration.
public struct PersistedMetadataRecord: Codable, Sendable, Equatable {
    public let generation: Int64
    public let metadata: InstanceMetadata?
    public let withdrawn: Bool

    public init(generation: Int64, metadata: InstanceMetadata?, withdrawn: Bool) {
        self.generation = generation
        self.metadata = metadata
        self.withdrawn = withdrawn
    }
}
