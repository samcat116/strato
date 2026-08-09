import Fluent
import Vapor
import Foundation
import StratoShared

/// Represents the format of a volume disk image
public enum VolumeFormat: String, Codable, CaseIterable, Sendable {
    case qcow2 = "qcow2"
    case raw = "raw"
}

/// Represents the type of volume
public enum VolumeType: String, Codable, CaseIterable, Sendable {
    case boot = "boot"  // Boot disk for VM
    case data = "data"  // Additional data disk
}

/// Represents the status of a volume during its lifecycle
public enum VolumeStatus: String, Codable, CaseIterable, Sendable {
    case creating = "creating"  // Volume is being created
    case available = "available"  // Volume is ready and not attached
    case attaching = "attaching"  // Volume is being attached to a VM
    case attached = "attached"  // Volume is attached to a VM
    case detaching = "detaching"  // Volume is being detached from a VM
    case resizing = "resizing"  // Volume is being resized
    case snapshotting = "snapshotting"  // Snapshot is being created
    case cloning = "cloning"  // Volume is being cloned
    case deleting = "deleting"  // Volume is being deleted
    case error = "error"  // An error occurred
}

final class Volume: Model, @unchecked Sendable {
    static let schema = "volumes"

    /// Upper bound on a caller-requested volume size, in whole gibibytes.
    /// Requests above this are rejected with `400 Bad Request`; the ceiling is
    /// generous (256 TiB) but far below the point where the GiB→bytes
    /// conversion would overflow `Int64`.
    static let maxSizeGB = 262_144

    /// Upper bounds on a caller-requested I/O ceiling (STR-19). Sanity rails
    /// rather than hardware limits: they exist so a typo cannot persist a value
    /// no device could ever reach, which would read as a cap while behaving as
    /// none.
    ///
    /// Zero is *not* accepted at the API boundary even though QEMU spells
    /// "unlimited" that way — see `VolumeController.validateIOLimits`.
    static let maxIOPSTotal: Int64 = 10_000_000
    static let maxBPSTotal: Int64 = 1 << 40  // 1 TiB/s

    @ID(key: .id)
    var id: UUID?

    // Basic metadata
    @Field(key: "name")
    var name: String

    @Field(key: "description")
    var description: String

    // Project ownership
    @Parent(key: "project_id")
    var project: Project

    /// The deployment environment this volume's bytes are attributed to
    /// (STR-181), resolved from the creating request against its project the way
    /// a VM's is.
    ///
    /// Here for one reason: a resource quota is scoped by `(project,
    /// environment?)` and `QuotaScope.predicate` filters every workload table on
    /// both columns. Without it a volume could not be measured at all, which is
    /// why its bytes were free. Immutable after create, like a VM's.
    @Field(key: "environment")
    var environment: String

    // Volume specifications. `size` is **desired** — what the last accepted
    // create or resize asked for — and the agent's report of what the image
    // actually is lands in `observedSizeBytes` below.
    @Field(key: "size")
    var size: Int64  // Size in bytes

    @Enum(key: "format")
    var format: VolumeFormat

    @Enum(key: "type")
    var volumeType: VolumeType

    // Status tracking. `status` is purely *observed* since STR-148 — the
    // control plane no longer writes a transitional status before dispatching
    // an RPC, because there is no RPC; `ObservedStateApplier` derives it from
    // what the owning agent reports.
    @Enum(key: "status")
    var status: VolumeStatus

    // Desired/observed state split (ADR 0001 stage 5, STR-148), mirroring the
    // VM columns exactly: `desiredStatus` is the goal written by API
    // mutations, `generation` bumps on every desired change, and
    // `observedGeneration` records the last generation the owning agent
    // confirmed converging to.
    @Enum(key: "desired_status")
    var desiredStatus: DesiredVolumeStatus

    @Field(key: "generation")
    var generation: Int64

    @Field(key: "observed_generation")
    var observedGeneration: Int64

    /// The virtual size the owning agent last reported the image actually has
    /// (STR-199), as opposed to the `size` someone asked for.
    ///
    /// NULL means **no agent has said** — a volume whose bytes are not on a
    /// host yet, one owned by a pre-v38 agent, or one whose size probe failed.
    /// It never means zero, and `ObservedStateApplier` never writes an agent's
    /// silence through as a clear.
    @OptionalField(key: "observed_size_bytes")
    var observedSizeBytes: Int64?

    // Convergence progress mirrored from the agent's observed-state report.
    // `errorMessage` doubles as `lastError` — one column, because a volume has
    // never had a second error to report and two would only invite them to
    // disagree in the API response.
    @OptionalField(key: "convergence_phase")
    var convergencePhase: String?

    @OptionalField(key: "error_message")
    var errorMessage: String?

    @OptionalField(key: "failed_generation")
    var failedGeneration: Int64?

    /// When the stuck-convergence sweep gives up on this volume's outstanding
    /// mutations and marks it degraded. Written by the mutation path as
    /// `max(existing, now + budget)`; nil means nothing is outstanding.
    @OptionalField(key: "convergence_deadline")
    var convergenceDeadline: Date?

    /// Outstanding cleanup participants blocking this volume's removal.
    /// Empty for a live volume; stamped when a `DELETE` marks
    /// `desiredStatus = .absent`, and drained a token at a time until the row
    /// is reaped. See `ResourceFinalizer`.
    @Field(key: "finalizers")
    var finalizers: [String]

    // Placement: the pool whose agents hold this volume's replicas. Nullable
    // at the schema level only; the backfill migration and the create path
    // guarantee it is always set.
    @OptionalParent(key: "pool_id")
    var pool: StoragePool?

    // Where the attachment currently runs (set while attached to a VM).
    // Replaces hypervisor_id's "single owner" role.
    @OptionalField(key: "attached_agent_id")
    var attachedAgentId: String?

    // Legacy storage location, dual-written alongside the volume's
    // VolumeReplica row until nothing reads these columns anymore.
    @OptionalField(key: "storage_path")
    var storagePath: String?

    @OptionalField(key: "hypervisor_id")
    var hypervisorId: String?

    // VM attachment (null when detached)
    @OptionalParent(key: "vm_id")
    var vm: VM?

    @OptionalField(key: "device_name")
    var deviceName: String?  // disk0, disk1, etc.

    @OptionalField(key: "boot_order")
    var bootOrder: Int?

    /// Whether the attachment presents the volume read-only. Persisted since
    /// STR-148: it used to be passed straight to the attach RPC and forgotten,
    /// so nothing could re-derive the attachment after the fact — which a
    /// level-triggered desired entry has to do on every sync.
    @Field(key: "readonly")
    var readonly: Bool

    // Absolute per-volume I/O ceilings (STR-19). The requested pair is desired
    // state and travels on the sync; the applied pair is the agent's echo of
    // what it actually put in place.
    //
    // Two pairs rather than one column plus a boolean, because STR-19 ships no
    // wire capability gate: an agent that has never heard of ceilings drops the
    // field and still advances `observed_generation`, so the generation pair
    // alone would call an ignored mutation converged. NULL on the applied pair
    // means *the agent said nothing* — never that the caps were cleared. It
    // will read NULL for every row until the agent-side work lands.

    @OptionalField(key: "iops_total")
    var iopsTotal: Int64?

    @OptionalField(key: "bps_total")
    var bpsTotal: Int64?

    @OptionalField(key: "applied_iops_total")
    var appliedIOPSTotal: Int64?

    @OptionalField(key: "applied_bps_total")
    var appliedBPSTotal: Int64?

    // Source tracking (for clones/volumes created from images)
    @OptionalParent(key: "source_image_id")
    var sourceImage: Image?

    @OptionalParent(key: "source_volume_id")
    var sourceVolume: Volume?

    // Owner tracking
    @Parent(key: "created_by_id")
    var createdBy: User

    // Timestamps
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        description: String,
        projectID: UUID,
        environment: String,
        size: Int64,
        format: VolumeFormat = .qcow2,
        volumeType: VolumeType = .data,
        status: VolumeStatus = .creating,
        createdByID: UUID,
        poolID: UUID? = nil,
        sourceImageID: UUID? = nil,
        sourceVolumeID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.$project.id = projectID
        self.environment = environment
        self.size = size
        self.format = format
        self.volumeType = volumeType
        self.status = status
        self.desiredStatus = .present
        self.generation = 0
        self.observedGeneration = 0
        self.readonly = false
        self.finalizers = []
        self.$createdBy.id = createdByID
        self.$pool.id = poolID
        if let sourceImageID = sourceImageID {
            self.$sourceImage.id = sourceImageID
        }
        if let sourceVolumeID = sourceVolumeID {
            self.$sourceVolume.id = sourceVolumeID
        }
    }
}

extension Volume: Content {}

// MARK: - Public DTO

extension Volume {
    struct Public: Content {
        let id: UUID?
        let name: String
        let description: String
        let projectId: UUID?
        let size: Int64
        let sizeGB: Double
        let format: VolumeFormat
        let volumeType: VolumeType
        let status: VolumeStatus
        let errorMessage: String?
        let poolId: UUID?
        let attachedAgentId: String?
        let storagePath: String?
        let hypervisorId: String?
        let vmId: UUID?
        let deviceName: String?
        let bootOrder: Int?
        let readonly: Bool
        let conditions: ResourceConditions
        let sourceImageId: UUID?
        let sourceVolumeId: UUID?
        let createdById: UUID?
        let createdAt: Date?
        let updatedAt: Date?
    }

    func asPublic() -> Public {
        return Public(
            id: self.id,
            name: self.name,
            description: self.description,
            projectId: self.$project.id,
            size: self.size,
            sizeGB: self.sizeGB,
            format: self.format,
            volumeType: self.volumeType,
            status: self.status,
            errorMessage: self.errorMessage,
            poolId: self.$pool.id,
            attachedAgentId: self.attachedAgentId,
            storagePath: self.storagePath,
            hypervisorId: self.hypervisorId,
            vmId: self.$vm.id,
            deviceName: self.deviceName,
            bootOrder: self.bootOrder,
            readonly: self.readonly,
            conditions: self.conditions,
            sourceImageId: self.$sourceImage.id,
            sourceVolumeId: self.$sourceVolume.id,
            createdById: self.$createdBy.id,
            createdAt: self.createdAt,
            updatedAt: self.updatedAt
        )
    }
}

// MARK: - Computed Properties

extension Volume {
    var sizeGB: Double {
        return Double(size) / 1024.0 / 1024.0 / 1024.0
    }

    /// Records a new desired state and bumps the generation so the owning agent
    /// treats it as newer than whatever it last applied.
    func setDesiredStatus(_ newDesired: DesiredVolumeStatus) {
        desiredStatus = newDesired
        generation += 1
    }

    /// Bumps the generation without changing the desired status, for a change
    /// to the volume's *shape* — its size, or where it is attached. The agent
    /// drops any entry not newer than the one it last applied, so a mutation
    /// that skipped this would be silently ignored.
    func bumpGeneration() {
        generation += 1
    }

    /// The agent has confirmed the current generation and the volume is sitting
    /// at a resting status — nothing is mid-write, so its bytes can be read.
    ///
    /// This is what `isConverged` was before STR-191, and it is deliberately
    /// *not* `isConverged` any more: that predicate now also excludes a failure
    /// recorded at the current generation, which is the wrong question for the
    /// verbs below. `applyObservedVolumeState` derives `.creating` for absent
    /// bytes and `.error` for absent bytes with an error, so a torn or
    /// half-written volume can never reach a resting status — the status clause
    /// alone already says everything a reader needs.
    ///
    /// **This is the predicate a future relaxation may move; `desiredSatisfied`
    /// is not.** They are the same question today, and stating that by
    /// delegation rather than by repeating the clauses is the point: a
    /// live-snapshot path (issue #747) relaxing what the *reading verbs* accept
    /// has to break this delegation to do it, which is a visible edit here
    /// rather than a silent loosening of what every volume in the fleet reports
    /// as converged.
    var bytesAtRest: Bool {
        observedGeneration >= generation && desiredSatisfied
    }

    /// Whether this volume is on its way out — a `DELETE` has been accepted and
    /// the row survives only until its finalizers drain.
    var isTerminating: Bool {
        desiredStatus == .absent
    }

    // The guards below are expressed against *desired* attachment rather than
    // observed status, which is what makes them stable under a level-triggered
    // loop: the answer to "can this be attached?" must not flip while an agent
    // is mid-convergence. The transitional escape hatches issue #644 added are
    // gone with the transitional statuses that made them necessary.

    var canAttach: Bool {
        return $vm.id == nil && desiredStatus == .present
    }

    var canDetach: Bool {
        return $vm.id != nil
    }

    /// Resize is grow-only, and no longer detach-only (STR-19).
    ///
    /// The old rule refused an attached volume because the only path the agent
    /// had was `qemu-img resize`, which the image lock refuses on a file a
    /// running hypervisor holds open. Choosing between that and an online grow
    /// is the *agent's* call — only it knows whether a process holds the image —
    /// so the API stops pre-judging it and lets the desired size converge.
    ///
    /// What stays refused is a **shrink**, at both ends: the endpoint answers
    /// `400` and the agent answers a permanent convergence failure, because
    /// truncating a guest's filesystem is not something a retry makes safe.
    /// That single grow-only rule is also what refuses an *attached* shrink, so
    /// there is no separate guard for it.
    ///
    /// Two caveats that belong to the caller, not to this predicate. No agent
    /// has an online grow path yet, so a volume attached to a *running* guest
    /// is accepted here and then refused by the agent — which is the decision
    /// working, not a gap: growing an image a live guest holds open would
    /// corrupt it on any pool whose file locking is unreliable. A volume
    /// attached to a stopped VM grows normally. And growing the block device
    /// never grows what is on it: guest-side rescan and filesystem expansion
    /// stay the user's job.
    var canResize: Bool {
        return desiredStatus == .present
    }

    /// Snapshots require a detached volume (issue #747). The filesystem
    /// backend's snapshot is a qcow2 overlay whose backing file is the volume,
    /// and nothing redirects a running QEMU's active layer onto that overlay —
    /// the guest keeps writing to the same base the overlay points at, so the
    /// "snapshot" never diverges from the live volume and captures no
    /// point-in-time state. Rather than return a silently-wrong snapshot for
    /// the case operators most rely on, an attached volume is refused until a
    /// real live-snapshot path (QMP `blockdev-snapshot-sync` plus the layer
    /// bookkeeping it implies) exists.
    var canSnapshot: Bool {
        return $vm.id == nil && desiredStatus == .present && bytesAtRest
    }

    /// Cloning is `qemu-img convert` of the volume's file, so it has the same
    /// requirement as a snapshot: a guest writing the source mid-copy yields a
    /// torn image. Its own property rather than a reuse of `canSnapshot`, so
    /// the two rules can move independently — a live-snapshot path (issue #747)
    /// would relax one without relaxing the other.
    /// Cloning and snapshotting both read the source's bytes, so both keep a
    /// `bytesAtRest` requirement even though the other guards dropped theirs.
    /// This is the one place a mutex is genuinely load-bearing rather than
    /// incidental: copying a volume whose create is still writing it yields a
    /// torn image, and unlike a resize it cannot be re-driven into correctness.
    ///
    /// `bytesAtRest` rather than `isConverged` (STR-191). A resize that fails
    /// leaves `failedGeneration == generation` with nothing to clear it —
    /// `resolveForStuckOperation` bumps the generation only for a failed attach
    /// — so gating on convergence would make such a volume permanently
    /// un-snapshottable and un-clonable with no escape the user could find. It
    /// would also be answering the wrong question: a failed *change* does not
    /// tear the bytes, and a copy of the pre-resize volume is a perfectly good
    /// point-in-time copy.
    var canClone: Bool {
        return $vm.id == nil && desiredStatus == .present && bytesAtRest
    }

    /// A volume is deletable unless it is attached to a VM (detach it first).
    ///
    /// Every other state is fair game, including a create that never finished:
    /// deletion is level-triggered and the agent's teardown is idempotent, so
    /// re-issuing it is always safe. Under the old imperative path this needed
    /// issue #644's explicit escape hatches for each transitional status; with
    /// desired state there are no transitional statuses to be stranded in.
    var canDelete: Bool {
        return $vm.id == nil
    }

    /// The ceilings asked for, as the sync carries them. Normalized, so an
    /// all-null pair travels as an absent field — see `VolumeIOLimits` for why
    /// the desired side must and the observed side must not.
    var ioLimits: VolumeIOLimits? {
        .normalized(iopsTotal: iopsTotal, bpsTotal: bpsTotal)
    }

    /// The ceilings the owning agent last reported applied. Nil until the
    /// agent-side work lands, for every volume.
    ///
    /// The wire distinguishes "said nothing" (nil) from "applied, and the
    /// answer is uncapped" (present but empty); these two columns cannot, and
    /// deliberately do not try. Both readings of a null pair answer the only
    /// question a caller asks — *are my requested caps in effect?* — with "no",
    /// so a third column to tell them apart would carry no decision.
    ///
    /// Where the distinction *is* load-bearing is one layer up, in
    /// `ObservedStateApplier`: a nil echo must leave these columns alone rather
    /// than clear them, or an agent that has never heard of ceilings has its
    /// silence recorded as "the caps were removed".
    var appliedIOLimits: VolumeIOLimits? {
        guard appliedIOPSTotal != nil || appliedBPSTotal != nil else { return nil }
        return VolumeIOLimits(iopsTotal: appliedIOPSTotal, bpsTotal: appliedBPSTotal)
    }
}

// MARK: - Request/Response DTOs

struct CreateVolumeRequest: Content, ValidatedRequestBody {
    var name: String
    let description: String?
    /// Required: there is no default project (issue #1059). Optional here so
    /// the refusal is `Request.projectIsRequired`'s, which names the remedy,
    /// rather than a `Codable` decode failure that names neither.
    let projectId: UUID?
    /// Which of the project's environments the volume's bytes are charged to
    /// (STR-181). Omitted takes the project's default, exactly as VM and sandbox
    /// create do.
    let environment: String?
    let sizeGB: Int  // Size in GB for user convenience
    let format: String?  // "qcow2" or "raw", defaults to qcow2
    let volumeType: String?  // "boot" or "data", defaults to data
    let sourceImageId: UUID?  // Create volume from image
    /// Absolute I/O ceilings (STR-19). Omit for uncapped.
    let iopsTotal: Int64?
    let bpsTotal: Int64?

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
    }
}

struct UpdateVolumeRequest: Content, ValidatedRequestBody {
    var name: String?
    let description: String?

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
    }
}

struct AttachVolumeRequest: Content {
    let vmId: UUID
    let deviceName: String?  // e.g., "disk1", auto-generated if not provided
    let bootOrder: Int?  // Boot priority (lower = higher priority)
    let readonly: Bool?  // Mount as read-only
}

struct ResizeVolumeRequest: Content {
    let sizeGB: Int  // New size in GB (must be larger than current)
}

/// A **full replacement** of a volume's I/O ceilings (STR-19): omitting a field
/// clears that cap.
///
/// Replacing rather than patching because Swift's synthesized decoding cannot
/// tell an absent key from an explicit null, so a partial-update shape would
/// have no way to express "remove this cap" at all — and an endpoint that
/// silently cannot clear is worse than one that clears by omission, which at
/// least does what it says.
struct SetVolumeIOLimitsRequest: Content {
    let iopsTotal: Int64?
    let bpsTotal: Int64?
}

struct CloneVolumeRequest: Content, ValidatedRequestBody {
    var name: String
    let description: String?

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
    }
}

struct VolumeResponse: Content {
    let id: UUID?
    let name: String
    let description: String
    let projectId: UUID?
    /// The project environment this volume's bytes are charged to (STR-181).
    let environment: String
    /// The size **asked for** — the last create or resize the API accepted.
    /// A resize answers `202` and converges, so this moves the moment the
    /// mutation is accepted, well before any bytes do.
    let size: Int64
    let sizeFormatted: String
    /// The size the owning agent reports the image **actually has** (STR-199).
    ///
    /// Null means no agent has said — the bytes are not on a host yet, or the
    /// agent predates wire v38. Where it disagrees with `size`, a grow is still
    /// outstanding, and `conditions` says whether it is in flight or degraded:
    /// a grow refused because the volume's guest is running holds this at the
    /// old size for as long as the guest keeps running. Reporting only `size`
    /// is how a refused grow read as a completed one.
    let observedSize: Int64?
    let observedSizeFormatted: String?
    let format: VolumeFormat
    let volumeType: VolumeType
    let status: VolumeStatus
    let errorMessage: String?
    let poolId: UUID?
    let attachedAgentId: String?
    let hypervisorId: String?
    let vmId: UUID?
    let deviceName: String?
    let bootOrder: Int?
    let readonly: Bool
    /// The client-facing answer to "is my mutation done?" (ADR 0001 stage 1),
    /// derived on read from the generation pair and the agent's report. Volumes
    /// join the same 202-and-converge flow as VMs in STR-148, so this is what
    /// clients poll rather than the status string.
    let conditions: ResourceConditions
    /// The I/O ceilings asked for (STR-19); null when uncapped.
    let ioLimits: VolumeIOLimits?
    /// The ceilings the owning agent reports it has actually applied. Null
    /// means they are **not in effect** — either the agent has not reported, or
    /// it reported no caps. No agent applies ceilings yet, so this is null for
    /// every volume until the agent-side work lands; a non-null `ioLimits` with
    /// a null `appliedIOLimits` is the expected reading, not a fault.
    let appliedIOLimits: VolumeIOLimits?
    let sourceImageId: UUID?
    let sourceVolumeId: UUID?
    let createdById: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    init(from volume: Volume) {
        self.id = volume.id
        self.name = volume.name
        self.description = volume.description
        self.projectId = volume.$project.id
        self.environment = volume.environment
        self.size = volume.size
        self.sizeFormatted = volume.size.formattedByteSize
        self.observedSize = volume.observedSizeBytes
        self.observedSizeFormatted = volume.observedSizeBytes?.formattedByteSize
        self.format = volume.format
        self.volumeType = volume.volumeType
        self.status = volume.status
        self.errorMessage = volume.errorMessage
        self.poolId = volume.$pool.id
        self.attachedAgentId = volume.attachedAgentId
        self.hypervisorId = volume.hypervisorId
        self.vmId = volume.$vm.id
        self.deviceName = volume.deviceName
        self.bootOrder = volume.bootOrder
        self.readonly = volume.readonly
        self.conditions = volume.conditions
        self.ioLimits = volume.ioLimits
        self.appliedIOLimits = volume.appliedIOLimits
        self.sourceImageId = volume.$sourceImage.id
        self.sourceVolumeId = volume.$sourceVolume.id
        self.createdById = volume.$createdBy.id
        self.createdAt = volume.createdAt
        self.updatedAt = volume.updatedAt
    }
}
