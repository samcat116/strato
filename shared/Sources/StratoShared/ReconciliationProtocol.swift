import Foundation

// MARK: - Desired VM State

/// The state the control plane wants a VM to be in. Distinct from `VMStatus`,
/// which is purely *observed*: desired state is a goal ("be running"), never a
/// report ("is starting"), so it has no transitional or diagnostic cases.
///
/// Decoding is deliberately strict (no tolerant fallback like `VMStatus`):
/// misinterpreting a desired status could stop or delete a running VM, so an
/// unknown value fails the whole sync and the agent keeps its current state.
/// Adding a case here therefore requires a `WireProtocol` version bump and a
/// dual-mode rollout.
public enum DesiredVMStatus: String, Codable, CaseIterable, Sendable {
    case running = "Running"
    case shutdown = "Shutdown"
    case paused = "Paused"
    /// The VM should not exist on the agent at all (deletion in progress).
    /// Rows are removed from the control-plane database only after an agent
    /// confirms absence, so deletes survive restarts on both sides.
    case absent = "Absent"

    /// Whether an observed status already satisfies this goal, i.e. the
    /// reconciler has nothing to do. `.created` satisfies `.shutdown` because
    /// a defined-but-never-booted VM and a shut-down VM are the same resting
    /// state ("exists, not running") — they differ only in history.
    public func isSatisfied(by observed: VMStatus) -> Bool {
        switch self {
        case .running:
            return observed == .running
        case .paused:
            return observed == .paused
        case .shutdown:
            return observed == .shutdown || observed == .created
        case .absent:
            return false  // absence is confirmed by omission from the observed set, never by a status
        }
    }
}

// MARK: - Edge nonces

/// The restore the control plane wants a workload to have performed, carried on
/// its desired entry as a monotonic nonce (ADR 0001 stage 9, STR-151).
///
/// A restore is an *edge*, not a state: "the VM should be at checkpoint C" is
/// not something an agent can re-converge on, because the guest starts writing
/// the moment it resumes. The `kubectl rollout restart` answer to that shape is
/// to put **how many times it was asked** in the desired state — the edge
/// becomes a state the moment it is counted. The agent keeps a durable record of
/// the last nonce it applied per workload and acts only when this one outranks
/// it, so a replayed or re-driven sync cannot rewind a live guest a second time.
///
/// Absent means "no restore has ever been asked for", never "undo one".
public struct DesiredRestore: Codable, Sendable, Equatable {
    /// Monotonic per-workload counter, bumped once per accepted restore request.
    /// The agent acts when this exceeds the nonce it last applied and recorded.
    public let generation: Int64
    /// The artifact to load. Travels with the nonce rather than beside it so a
    /// nonce can never be attributed to the wrong point in time: two restores of
    /// different checkpoints are two different values of one field.
    public let snapshotId: UUID
    /// Download descriptors for an exported snapshot, present only when the
    /// workload does not live on the agent that captured it (issue #428).
    /// Resolved fresh at sync assembly, like `ImageInfo`, so a long-desired
    /// restore never carries a stale locator.
    ///
    /// Sandbox-only: a VM checkpoint lives *inside* the VM's own disks, so it
    /// cannot move between hosts and a VM restore never carries one. The field
    /// is shared rather than forked for `DesiredSnapshotState`'s reason — the
    /// nonce, the guard and the durable record are the same three times over,
    /// and only the payload differs.
    public let artifacts: [SandboxSnapshotArtifactDescriptor]?

    public init(
        generation: Int64,
        snapshotId: UUID,
        artifacts: [SandboxSnapshotArtifactDescriptor]? = nil
    ) {
        self.generation = generation
        self.snapshotId = snapshotId
        self.artifacts = artifacts
    }
}

/// One VM's authoritative desired state, as assembled by the control plane.
public struct DesiredVMState: Codable, Sendable {
    public let vmId: UUID
    /// Which backend should realize this VM. Pinned at scheduling time.
    public let hypervisorType: HypervisorType
    public let spec: VMSpec
    public let desiredStatus: DesiredVMStatus
    /// Monotonic per-VM counter, bumped by the control plane on every desired
    /// status or spec change. The agent records the generation it last applied
    /// and rejects older ones, so replayed or reordered syncs cannot roll a VM
    /// backward.
    public let generation: Int64
    /// Download info for the VM's boot image, so an agent that does not yet
    /// have the VM can materialize it. Download URLs are control-plane-relative
    /// paths fetched over SVID mTLS — no signature, so nothing here expires.
    public let imageInfo: ImageInfo?
    /// What the VM's link-local metadata service should tell the guest about
    /// itself (STR-48). Riding the sync is what makes the metadata store
    /// level-triggered, generation-guarded, and replay-safe without a second
    /// control loop or transport: an operator's edit lands on the next sync
    /// instead of requiring the guest to be rebuilt around a new seed ISO.
    ///
    /// Nil is authoritative: there is nothing to serve, and an agent holding
    /// stale metadata must drop it.
    public let metadata: InstanceMetadata?
    /// How many times this VM has been asked to reboot (ADR 0001 stage 9,
    /// STR-151) — the `kubectl rollout restart` nonce, applied to the one VM
    /// verb that is an edge rather than a state.
    ///
    /// A reboot starts and ends `.running`, so `desiredStatus` cannot express
    /// it and the old `vm_reboot` RPC was fire-and-forget: a socket dropped
    /// mid-flight lost the reboot silently. Counting it makes it level-triggered
    /// like everything else — the agent acts when this outranks the nonce it
    /// durably recorded, and a lost sync costs latency rather than the reboot.
    ///
    /// Nil means no reboot has ever been requested and, being a count of
    /// requests, is never an instruction to undo one.
    public let rebootGeneration: Int64?
    /// The checkpoint this VM should have been restored to, as a nonce
    /// (STR-151). Nil means no restore has ever been requested.
    public let restore: DesiredRestore?

    public init(
        vmId: UUID,
        hypervisorType: HypervisorType,
        spec: VMSpec,
        desiredStatus: DesiredVMStatus,
        generation: Int64,
        imageInfo: ImageInfo? = nil,
        metadata: InstanceMetadata? = nil,
        rebootGeneration: Int64? = nil,
        restore: DesiredRestore? = nil
    ) {
        self.vmId = vmId
        self.hypervisorType = hypervisorType
        self.spec = spec
        self.desiredStatus = desiredStatus
        self.generation = generation
        self.imageInfo = imageInfo
        self.metadata = metadata
        self.rebootGeneration = rebootGeneration
        self.restore = restore
    }
}

// MARK: - Desired Sandbox State

/// One sandbox's authoritative desired state, as assembled by the control
/// plane. Mirrors `DesiredVMState` semantics exactly: level-triggered,
/// generation-guarded, safe to drop or replay.
public struct DesiredSandboxState: Codable, Sendable {
    public let sandboxId: UUID
    public let spec: SandboxSpec
    public let desiredStatus: DesiredSandboxStatus
    /// Monotonic per-sandbox counter, bumped by the control plane on every
    /// desired status or spec change. The agent records the generation it last
    /// applied and rejects older ones, so replayed or reordered syncs cannot
    /// roll a sandbox backward.
    public let generation: Int64
    /// Pull credential for the spec's image when it lives in a private
    /// registry, minted fresh at sync assembly (see `RegistryCredential`).
    /// Nil for public images — zero-configuration public pulls must work.
    public let registryCredential: RegistryCredential?
    /// Duplicated at the desired-entry level as an explicit create-strategy
    /// discriminator (issue #427). `spec.restoreFrom` carries the same value so
    /// runtimes that operate only on the spec still have the artifact locator.
    public let restoreFrom: SandboxSnapshotRef?
    /// The snapshot this sandbox should have been restored **into itself** from,
    /// as a nonce (ADR 0001 stage 9, STR-151).
    ///
    /// Not to be confused with `restoreFrom` above, which they are easy to read
    /// as one thing and are not: `restoreFrom` is a *create strategy* for a
    /// sandbox that does not exist yet (a fork gets a new identity from someone
    /// else's checkpoint), and is consulted only while the sandbox is absent.
    /// This is an edge applied to a sandbox that already exists — same id, same
    /// addresses, rewound — and is consulted only while it is present.
    public let restore: DesiredRestore?

    public init(
        sandboxId: UUID,
        spec: SandboxSpec,
        desiredStatus: DesiredSandboxStatus,
        generation: Int64,
        registryCredential: RegistryCredential? = nil,
        restoreFrom: SandboxSnapshotRef? = nil,
        restore: DesiredRestore? = nil
    ) {
        self.sandboxId = sandboxId
        self.spec = spec
        self.desiredStatus = desiredStatus
        self.generation = generation
        self.registryCredential = registryCredential
        self.restoreFrom = restoreFrom
        self.restore = restore
    }
}

// MARK: - Desired Volume State

/// The state the control plane wants a volume's *data* to be in.
///
/// Two cases, deliberately: a volume has no run state, so attachment is a
/// *field* of the entry rather than a status. Modelling attach as a status
/// would make "present, but the attach failed" unrepresentable, and it would
/// collide with size, which moves independently of where the volume is
/// plugged in.
///
/// Decoded strictly, like `DesiredVMStatus` and for a sharper version of the
/// same reason: misreading a desired volume status destroys the only copy of
/// user data. An unknown value fails the whole sync and the agent keeps what
/// it has.
public enum DesiredVolumeStatus: String, Codable, CaseIterable, Sendable {
    case present = "Present"
    /// The volume should not exist on the agent at all (deletion in progress).
    /// Rows are removed from the control-plane database only after an agent
    /// confirms absence by omitting the volume from its observed report.
    case absent = "Absent"
}

/// How a volume that does not yet exist on this host gets its initial bytes: a
/// create *strategy*, not an operation — the `DesiredSandboxState.restoreFrom`
/// pattern (issue #427) applied to what used to be `volume_clone`.
///
/// Consulted only when the volume is absent from the host. A volume that
/// already exists ignores this field forever, which is what makes a replayed
/// or re-driven sync unable to re-clone over live data.
///
/// A `String` discriminator rather than a Swift enum with associated values:
/// an unrecognized `kind` must fail *this volume* — surfacing as its
/// `lastError` — never the whole `DesiredStateMessage`.
public struct DesiredVolumeSource: Codable, Sendable {
    /// Allocate an empty disk of `DesiredVolumeState.sizeBytes`.
    public static let blank = "blank"
    /// Materialize from an image artifact; `imageInfo` carries the locator.
    public static let image = "image"
    /// Copy another volume on this same agent; `sourceVolumeId` names it.
    public static let clone = "clone"

    public let kind: String
    /// Present for `image`. Download URLs are control-plane-relative paths
    /// fetched over SVID mTLS — no signature, so nothing here expires and the
    /// entry stays safe to sit in a sync indefinitely.
    public let imageInfo: ImageInfo?
    /// The typed image artifact whose bytes initialize this volume. Required
    /// for `image`: QEMU boot/data volumes use `.diskImage`, while a
    /// Firecracker boot volume uses `.rootfs`.
    public let artifactKind: ArtifactKind?
    /// Present for `clone`. The volume/VM co-location constraint guarantees the
    /// source lives on this same agent, and the agent derives the source path
    /// from its own layout — no path travels on the wire (STR-180).
    public let sourceVolumeId: UUID?
    /// The VM that currently owns an attached clone source. The agent holds
    /// this VM's reconciliation lane for the complete copy, so a later desired
    /// state cannot start the source guest while its bytes are being read. Nil
    /// for a detached clone source.
    public let sourceVMId: UUID?
    /// The source volume's format, when known, so the agent can pick a copy
    /// strategy without probing. Advisory: the backend detects rather than
    /// assumes.
    public let sourceFormat: String?

    public init(
        kind: String,
        imageInfo: ImageInfo? = nil,
        artifactKind: ArtifactKind? = nil,
        sourceVolumeId: UUID? = nil,
        sourceVMId: UUID? = nil,
        sourceFormat: String? = nil
    ) {
        self.kind = kind
        self.imageInfo = imageInfo
        self.artifactKind = artifactKind
        self.sourceVolumeId = sourceVolumeId
        self.sourceVMId = sourceVMId
        self.sourceFormat = sourceFormat
    }

    public static func image(_ info: ImageInfo, artifactKind: ArtifactKind) -> DesiredVolumeSource {
        DesiredVolumeSource(kind: Self.image, imageInfo: info, artifactKind: artifactKind)
    }

    public static func clone(
        from volumeId: UUID, sourceVMId: UUID? = nil, format: String? = nil
    ) -> DesiredVolumeSource {
        DesiredVolumeSource(
            kind: Self.clone, sourceVolumeId: volumeId, sourceVMId: sourceVMId,
            sourceFormat: format)
    }
}

/// Absolute per-volume I/O ceilings (STR-19).
///
/// Total-only, deliberately. QEMU and libvirt can both express read/write
/// splits, burst allowances and bucket sizes; none of them has a caller here
/// yet, and one knob per dimension is the version that can be explained in a
/// UI. Optional members can be added later without a version bump.
///
/// **The all-nil value and `nil` are two spellings of one fact, and the two
/// sides of the wire resolve that ambiguity in opposite directions.** Get this
/// backwards and the bug is invisible until a mixed-version fleet:
///
/// - On a **desired** entry, always normalize: an all-nil value must travel as
///   an absent field, or an agent comparing present-but-empty against nil
///   re-plans a throttle that is already applied, forever. `normalized(_:_:)`
///   is the single door every desired producer goes through.
/// - On an **observed** entry, never normalize. Nil there means *"this agent
///   does not report applied limits"*; a present-but-empty value means
///   *"applied, and the answer is uncapped"*. Collapse the two and an agent
///   that has never heard of ceilings has its silence read as a deliberate
///   clear — which, with no capability gate on this feature, is the one
///   misreading that matters.
public struct VolumeIOLimits: Codable, Sendable, Equatable {
    /// Total (read + write) IOPS ceiling. Nil means uncapped in that dimension.
    public let iopsTotal: Int64?
    /// Total (read + write) throughput ceiling in bytes per second. Nil means
    /// uncapped in that dimension.
    public let bpsTotal: Int64?

    /// Whether this carries no cap at all. Equal *in effect* to nil, but not
    /// `==` to it, which is exactly why `normalized(_:_:)` exists.
    public var isEmpty: Bool { iopsTotal == nil && bpsTotal == nil }

    public init(iopsTotal: Int64? = nil, bpsTotal: Int64? = nil) {
        self.iopsTotal = iopsTotal
        self.bpsTotal = bpsTotal
    }

    /// Nil for an all-nil pair, so "uncapped" has exactly one spelling on the
    /// desired side. Every desired producer builds through this rather than
    /// calling the initializer directly.
    public static func normalized(iopsTotal: Int64?, bpsTotal: Int64?) -> VolumeIOLimits? {
        guard iopsTotal != nil || bpsTotal != nil else { return nil }
        return VolumeIOLimits(iopsTotal: iopsTotal, bpsTotal: bpsTotal)
    }
}

/// Where a volume should be plugged in. Nil on the desired entry means
/// "detached"; a value means the agent should have this volume presented to
/// `vmId` as `deviceName`.
public struct DesiredVolumeAttachment: Codable, Sendable, Equatable {
    public let vmId: UUID
    /// The control-plane-assigned slot ("disk1", ...). Stable across power
    /// cycles so a re-realized attachment lands where the guest's fstab
    /// expects it, unique within its VM, and validated by its type — the slot
    /// becomes a hypervisor object id, so a sync cannot carry one a hypervisor
    /// would refuse (STR-129).
    public let deviceName: VolumeDeviceName
    public let readonly: Bool
    /// Explicit boot priority; informational to the agent, which receives
    /// `VMSpec.volumes` pre-sorted.
    public let bootOrder: Int?

    public init(vmId: UUID, deviceName: VolumeDeviceName, readonly: Bool = false, bootOrder: Int? = nil) {
        self.vmId = vmId
        self.deviceName = deviceName
        self.readonly = readonly
        self.bootOrder = bootOrder
    }
}

/// One volume's authoritative desired state (ADR 0001 stage 5, STR-148).
/// Mirrors `DesiredVMState` semantics exactly: level-triggered,
/// generation-guarded, safe to drop or replay.
///
/// Two fields are deliberately absent. There is no `poolId`, because nothing
/// on the agent consumes a pool — placement is expressed by *which agent's
/// sync the entry appears in*, and a second encoding of it is a thing that can
/// drift. There is no `storagePath`, because the agent owns path layout; the
/// path travels the other way, on the observed report.
public struct DesiredVolumeState: Codable, Sendable {
    public let volumeId: UUID
    public let desiredStatus: DesiredVolumeStatus
    /// Monotonic per-volume counter, bumped by the control plane on every
    /// desired change. The agent records the generation it last applied and
    /// rejects older ones, so replayed or reordered syncs cannot roll a volume
    /// backward.
    public let generation: Int64
    /// Desired virtual size in bytes. Growth plans a `.resize`; a *shrink* is a
    /// permanent failure the agent refuses rather than a truncation it
    /// performs.
    public let sizeBytes: Int64
    /// "qcow2" or "raw", parsed by the agent with `DiskFormat(rawValue:)` and
    /// rejected there. A `String` at the boundary for the same reason
    /// `VolumeCreateMessage.format` was one: an unknown format must fail this
    /// volume, not the sync. Immutable after create — a mismatch is a
    /// permanent failure, never a silent conversion.
    public let format: String
    /// How to fill a volume that does not exist yet. Nil means blank.
    public let source: DesiredVolumeSource?
    /// Nil means the volume should be detached.
    public let attachment: DesiredVolumeAttachment?
    /// Absolute I/O ceilings for this volume (STR-19). Nil means uncapped, and
    /// is what every volume created before this field existed means.
    ///
    /// Emitted whether or not the volume is attached: a ceiling is a property
    /// of the volume, latent while it is detached and realized by the attach.
    /// Always built through `VolumeIOLimits.normalized(iopsTotal:bpsTotal:)`,
    /// so an all-nil pair travels as an absent field — see the type's note on
    /// why the desired and observed sides normalize in opposite directions.
    public let ioLimits: VolumeIOLimits?

    public init(
        volumeId: UUID,
        desiredStatus: DesiredVolumeStatus,
        generation: Int64,
        sizeBytes: Int64,
        format: String,
        source: DesiredVolumeSource? = nil,
        attachment: DesiredVolumeAttachment? = nil,
        ioLimits: VolumeIOLimits? = nil
    ) {
        self.volumeId = volumeId
        self.desiredStatus = desiredStatus
        self.generation = generation
        self.sizeBytes = sizeBytes
        self.format = format
        self.source = source
        self.attachment = attachment
        self.ioLimits = ioLimits
    }
}

// MARK: - Workload tombstones

/// The control plane's explicit instruction to remove a workload an agent
/// holds but no database row describes (STR-98).
///
/// Absence from a sync is deliberately *not* this. The agent holds anything it
/// has that a sync omits and reports it back as an `UnrecognizedWorkload`; only
/// after the control plane confirms no row exists does a tombstone authorize
/// the teardown. That collapses the destructive path into the one that already
/// exists — a `.absent` desired entry — and makes every teardown traceable to a
/// control-plane decision rather than to a silence.
///
/// `generation` outranks whatever the agent last applied for the workload, so
/// the reconciler's staleness guard admits it exactly like any other desired
/// entry.
public struct DesiredWorkloadTombstone: Codable, Sendable, Equatable {
    public let kind: WorkloadKind
    public let workloadId: UUID
    public let generation: Int64

    public init(kind: WorkloadKind, workloadId: UUID, generation: Int64) {
        self.kind = kind
        self.workloadId = workloadId
        self.generation = generation
    }
}

// MARK: - Desired Agent Update

/// The agent build the control plane wants this agent to be running, carried
/// on the desired-state sync (issue #434). Since v28 this is the *only* way an
/// agent is updated: the imperative `agent_update` message is gone and the
/// operator's "update now" assigns this field too (ADR 0001 stage 6). Artifact
/// URL and checksum are resolved fresh at sync assembly, so a long-desired
/// update never carries a stale link.
///
/// Level-triggered and idempotent: an agent already running `targetVersion`
/// diffs this to nothing, and absence of the field means "no opinion" — never
/// "downgrade". The agent converges through download/verify/swap/restart, but
/// only when its local preconditions hold (not containerized, no in-flight
/// reconcile work); otherwise it reports why via
/// `ObservedStateReport.agentUpdateStatus` and retries on later syncs.
public struct DesiredAgentUpdate: Codable, Sendable {
    /// The version the agent should be running. Informational to the updater
    /// (the artifact decides what is installed) but the agent uses it to
    /// no-op when already converged and to label its status reports.
    public let targetVersion: String
    /// Where to download the artifact. May be presigned — treat the query
    /// string as a credential (see `redactURL`).
    public let artifactURL: String
    /// Hex SHA-256 the downloaded artifact must match.
    public let sha256: String
    /// Shape of the artifact (tarball to extract vs. bare binary).
    public let artifactKind: AgentUpdateArtifactKind
    /// Member to extract when `artifactKind == .tarball`.
    public let tarballMember: String?

    public init(
        targetVersion: String,
        artifactURL: String,
        sha256: String,
        artifactKind: AgentUpdateArtifactKind,
        tarballMember: String? = nil
    ) {
        self.targetVersion = targetVersion
        self.artifactURL = artifactURL
        self.sha256 = sha256
        self.artifactKind = artifactKind
        self.tarballMember = tarballMember
    }

    /// `artifactURL` with query and userinfo stripped, safe for logs.
    public var redactedArtifactURL: String {
        Self.redactURL(artifactURL)
    }

    /// Artifact URLs may carry credentials — presigned query tokens or
    /// userinfo are often the only way to authenticate a private mirror
    /// download. Log this form, never the raw value, on both sides of the
    /// wire.
    public static func redactURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return "<unparseable-url>" }
        let hadQuery = components.query != nil
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let base = components.string else { return "<unparseable-url>" }
        return hadQuery ? base + "?[redacted]" : base
    }
}

/// Control plane → agent: the full authoritative set of VMs that should exist
/// on the receiving agent.
///
/// Full-list semantics make the message level-triggered and idempotent:
/// identical syncs diff to nothing, and the message is safe to drop, replay, or
/// reorder (per-VM `generation` guards handle reordering). Fetched on agent
/// registration, nudged on any desired-state change, and fetched
/// unconditionally on an agent-owned interval as the correctness backstop.
///
/// Omission is **not** teardown (STR-98). A workload the agent holds that this
/// message does not list is held, untouched, and reported back as an
/// `UnrecognizedWorkload`; it is removed only once the control plane answers
/// with a `DesiredWorkloadTombstone` (or an ordinary `.absent` entry). Before
/// that, the whole safety of a host's workloads rested on the assembler's
/// `WHERE` clause returning a complete list.
public struct DesiredStateMessage: WebSocketMessage {
    public var type: MessageType { .desiredState }
    public let requestId: String
    public let timestamp: Date
    /// Correlation id for logging/tracing a sync end to end. No semantics.
    public let syncId: String
    public let vms: [DesiredVMState]
    /// The full authoritative set of sandboxes that should exist on the
    /// receiving agent (full-list, same semantics as `vms`: a sandbox omitted
    /// here should not exist — and, like a VM, is held and reported rather
    /// than destroyed until a tombstone says otherwise).
    public let sandboxes: [DesiredSandboxState]
    /// The full authoritative set of logical networks that should exist on the
    /// receiving agent (full-list, same semantics as `vms`: a network omitted
    /// here should be torn down). An empty list authoritatively means this agent
    /// should realize no logical-network topology.
    public let networks: [DesiredNetworkState]
    /// Whether the receiving agent is the topology authority for its OVN
    /// northbound database. The authority reconciles `networks` — creating and
    /// tearing down switches, routers, and NAT. A non-authoritative agent shares
    /// its site's NB with peers and must leave topology alone (it still binds
    /// its own VMs' ports); exactly one agent per site is authoritative, so the
    /// shared NB has a single topology writer. Site-less agents own their local
    /// NB outright and are always authoritative.
    public let networksAuthoritative: Bool
    /// The agent build this agent should be running (issue #434), with a
    /// freshly resolved artifact. Nil means "no opinion" — deployments without
    /// a meaningful target (dev builds), agents with auto-update off, and agents
    /// the fleet rollout has not reached yet. Never an instruction to downgrade
    /// or tear anything down, so absence is always safe.
    public let desiredAgentUpdate: DesiredAgentUpdate?
    /// The security groups the receiving agent needs realized as OVN port
    /// groups + ACLs: every group attached to a NIC of a VM in this sync's
    /// scope, plus the transitive closure of groups referenced by their rules
    /// (so `$pg_…` address-set references always resolve). Only the topology
    /// authority acts on this list; other agents consume just the per-NIC
    /// `NetworkSpec.securityGroupIds` for port membership. Nil means this agent
    /// is not authoritative for security-group topology — never "tear down all
    /// port groups": the agent skips security-group reconciliation entirely.
    public let securityGroups: [DesiredSecurityGroup]?
    /// Workloads the receiving agent holds that the control plane has
    /// confirmed have no row, and which it therefore authorizes the agent to
    /// tear down (STR-98). Each entry is the answer to an
    /// `UnrecognizedWorkload` the agent reported, so a tombstone is always the
    /// second half of a round trip — never something the control plane
    /// volunteers. An empty list means no teardown is authorized.
    public let tombstones: [DesiredWorkloadTombstone]
    /// The full authoritative set of volumes that should exist on the receiving
    /// agent (ADR 0001 stage 5, STR-148), with the same full-list semantics as
    /// `vms`. An empty list authoritatively means this host should hold no
    /// volumes.
    public let volumes: [DesiredVolumeState]
    /// The full authoritative set of snapshot artifacts — volume snapshots, VM
    /// checkpoints and sandbox snapshots, in one kind-tagged list — that should
    /// exist on the receiving agent (ADR 0001 stage 8, STR-150).
    /// One list rather than three because the diff, the generation guard and
    /// the absent-then-confirm dance are identical across the families; only
    /// the backend that captures the bytes differs, and the entry's own `kind`
    /// says which. An empty list authoritatively means this host should retain
    /// no snapshot artifacts.
    public let snapshots: [DesiredSnapshotState]
    /// The DNS zones the receiving agent should realize into the OVN `DNS`
    /// table (STR-39): every zone attached to a network whose topology this
    /// agent authors, with the zone's full effective record set.
    ///
    /// Nil is "the sender has no opinion about DNS" and the agent leaves every
    /// managed row alone — what a *non-authority* agent gets, since realizing
    /// switch-scoped rows from two writers would have them fight over teardown.
    /// `[]` is an opinion and means "no
    /// zone reaches any network you author": managed rows are removed, which
    /// is what makes detaching the last zone from a network take effect.
    public let dnsZones: [DesiredDNSZone]?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        syncId: String = UUID().uuidString,
        vms: [DesiredVMState],
        sandboxes: [DesiredSandboxState] = [],
        networks: [DesiredNetworkState] = [],
        networksAuthoritative: Bool = true,
        desiredAgentUpdate: DesiredAgentUpdate? = nil,
        securityGroups: [DesiredSecurityGroup]? = nil,
        tombstones: [DesiredWorkloadTombstone] = [],
        volumes: [DesiredVolumeState] = [],
        snapshots: [DesiredSnapshotState] = [],
        dnsZones: [DesiredDNSZone]? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.syncId = syncId
        self.vms = vms
        self.sandboxes = sandboxes
        self.networks = networks
        self.networksAuthoritative = networksAuthoritative
        self.desiredAgentUpdate = desiredAgentUpdate
        self.securityGroups = securityGroups
        self.tombstones = tombstones
        self.volumes = volumes
        self.snapshots = snapshots
        self.dnsZones = dnsZones
    }

}

// MARK: - Desired Security Groups

/// One rule of a security group, realized by the topology-authority agent as
/// a single OVN ACL on the group's port group (issue: security groups).
///
/// The peer is at most one of `remoteCIDR` / `remoteGroupId`; both nil means
/// "any". A group peer is carried as the group's id — the agent derives the
/// port-group name (and thus the OVN-generated `$<pg>_ip4`/`_ip6` address-set
/// reference) itself via `OVNNaming`, so naming stays a single-owner concern
/// exactly like floating-IP port names.
public struct DesiredSecurityGroupRule: Codable, Sendable, Equatable {
    /// The control-plane rule row's id, stamped into the ACL's `external_ids`
    /// so operators can trace an OVN ACL back to the rule that produced it.
    public let id: UUID
    /// "ingress" (traffic to the VM, `to-lport`) or "egress" (traffic from
    /// the VM, `from-lport`).
    public let direction: String
    /// "ipv4" or "ipv6" — which address family the rule matches.
    public let ethertype: String
    /// "tcp", "udp", or "icmp"; nil matches any protocol of the ethertype.
    public let protocolName: String?
    /// For tcp/udp: the destination port range (min == max for one port).
    /// For icmp: `portRangeMin` is the ICMP type and `portRangeMax` the code.
    /// Nil means all ports/types.
    public let portRangeMin: Int?
    public let portRangeMax: Int?
    /// CIDR peer (source for ingress, destination for egress).
    public let remoteCIDR: String?
    /// Security-group peer: matches the addresses of the referenced group's
    /// member ports via its auto-generated address set.
    public let remoteGroupId: UUID?
    /// Whether the ACL should log the packets it matches (wire v24). Nil — an
    /// older control plane — means "off": logging is observability, so the
    /// safe reading of silence is the quiet one, and enforcement is identical
    /// either way. The synthesized `Codable` decodes a missing key to nil.
    public let log: Bool?

    public init(
        id: UUID,
        direction: String,
        ethertype: String,
        protocolName: String? = nil,
        portRangeMin: Int? = nil,
        portRangeMax: Int? = nil,
        remoteCIDR: String? = nil,
        remoteGroupId: UUID? = nil,
        log: Bool? = nil
    ) {
        self.id = id
        self.direction = direction
        self.ethertype = ethertype
        self.protocolName = protocolName
        self.portRangeMin = portRangeMin
        self.portRangeMax = portRangeMax
        self.remoteCIDR = remoteCIDR
        self.remoteGroupId = remoteGroupId
        self.log = log
    }
}

/// The state the control plane wants one security group to be in: an OVN port
/// group carrying one ACL per rule. `generation` is bumped on every rule
/// mutation; the agent replaces the port group's ACL set only when the stored
/// generation differs, so replayed or reordered syncs can never resurrect old
/// rules (the `LogicalNetwork.generation` pattern).
public struct DesiredSecurityGroup: Codable, Sendable, Equatable {
    public let id: UUID
    public let generation: Int64
    public let rules: [DesiredSecurityGroupRule]

    public init(id: UUID, generation: Int64, rules: [DesiredSecurityGroupRule]) {
        self.id = id
        self.generation = generation
        self.rules = rules
    }
}

// MARK: - Desired Network ACLs

/// One ordered, stateless rule in a network-level ACL (STR-33).
///
/// Rules are evaluated independently for ingress and egress in ascending
/// `ruleNumber` order. The topology-authority agent owns the mapping from that
/// stable API ordering to OVN tiers and priorities; the wire deliberately does
/// not expose backend-specific priority values.
public struct DesiredNetworkACLRule: Codable, Sendable, Equatable {
    public let id: UUID
    public let ruleNumber: Int
    /// "ingress" (`to-lport`) or "egress" (`from-lport`).
    public let direction: String
    /// "ipv4" or "ipv6".
    public let ethertype: String
    /// "allow" or "deny". These are policy verdicts, not raw OVN actions.
    public let action: String
    /// "tcp", "udp", or "icmp"; nil matches any IP protocol.
    public let protocolName: String?
    /// Destination ports for TCP/UDP, or ICMP type/code.
    public let portRangeMin: Int?
    public let portRangeMax: Int?
    /// Source CIDR for ingress, destination CIDR for egress.
    public let remoteCIDR: String

    public init(
        id: UUID,
        ruleNumber: Int,
        direction: String,
        ethertype: String,
        action: String,
        protocolName: String? = nil,
        portRangeMin: Int? = nil,
        portRangeMax: Int? = nil,
        remoteCIDR: String
    ) {
        self.id = id
        self.ruleNumber = ruleNumber
        self.direction = direction
        self.ethertype = ethertype
        self.action = action
        self.protocolName = protocolName
        self.portRangeMin = portRangeMin
        self.portRangeMax = portRangeMax
        self.remoteCIDR = remoteCIDR
    }
}

/// The one network ACL attached to a logical network.
///
/// The control plane bumps `generation` for every rule mutation. The agent
/// realizes the whole ordered rule set as one fail-closed replacement, never as
/// an imperative per-rule edit.
public struct DesiredNetworkACL: Codable, Sendable, Equatable {
    public let id: UUID
    public let generation: Int64
    public let rules: [DesiredNetworkACLRule]

    public init(id: UUID, generation: Int64, rules: [DesiredNetworkACLRule]) {
        self.id = id
        self.generation = generation
        self.rules = rules
    }
}

// MARK: - Desired Network State

/// One floating IP the agent should realize as a `dnat_and_snat` NAT rule on
/// the network's logical router (issue #344): traffic to `externalIP` is
/// DNAT'd to the VM's fixed `logicalIP`, and the VM's outbound traffic is
/// SNAT'd to `externalIP` (overriding the router's subnet-wide SNAT).
///
/// `vmId`/`nicIndex` identify the NIC's logical switch port so the agent can
/// program *distributed* NAT (`logical_port` + `external_mac`): the FIP is
/// then handled on the chassis hosting the VM rather than hairpinning through
/// the gateway chassis. The port name is derived agent-side (`OVNNaming`), not
/// carried on the wire, so naming stays a single-owner concern.
public struct DesiredFloatingIP: Codable, Sendable, Equatable {
    /// The floating (external) IPv4 address, from a control-plane floating IP
    /// pool. Used as the NAT rule's `external_ip`.
    public let externalIP: String
    /// The attached NIC's fixed IPv4 address on the tenant network. Used as
    /// the NAT rule's `logical_ip`.
    public let logicalIP: String
    /// The VM owning the attached NIC.
    public let vmId: UUID?
    /// The NIC's position in the VM's interface list (orderIndex), matching
    /// the index the agent used when naming the NIC's logical switch port.
    public let nicIndex: Int?

    public init(
        externalIP: String, logicalIP: String, vmId: UUID? = nil, nicIndex: Int? = nil
    ) {
        self.externalIP = externalIP
        self.logicalIP = logicalIP
        self.vmId = vmId
        self.nicIndex = nicIndex
    }
}

/// One listener on an OVN-native L4 load balancer (STR-28). The control plane
/// keeps listeners separate so high-churn backend membership never requires a
/// read-modify-write of this stable port mapping.
public struct DesiredLoadBalancerListener: Codable, Sendable, Equatable {
    public let id: UUID
    public let port: Int
    public let backendPort: Int

    public init(id: UUID, port: Int, backendPort: Int) {
        self.id = id
        self.port = port
        self.backendPort = backendPort
    }
}

/// One backend address for a desired load balancer. VM identity is carried
/// only for on-platform NICs, allowing the agent to derive the stable OVN LSP
/// name used by health-check `ip_port_mappings`. Off-platform targets have an
/// address but no VM, NIC, or member switch.
public struct DesiredLoadBalancerBackend: Codable, Sendable, Equatable {
    public let id: UUID
    public let ipAddress: String
    public let vmId: UUID?
    public let nicIndex: Int?
    public let networkId: UUID?
    /// Router-port address on the backend's subnet, used as OVN's probe source
    /// in `ip_port_mappings`. Nil for off-platform targets.
    public let healthCheckSourceIP: String?

    public init(
        id: UUID,
        ipAddress: String,
        vmId: UUID? = nil,
        nicIndex: Int? = nil,
        networkId: UUID? = nil,
        healthCheckSourceIP: String? = nil
    ) {
        self.id = id
        self.ipAddress = ipAddress
        self.vmId = vmId
        self.nicIndex = nicIndex
        self.networkId = networkId
        self.healthCheckSourceIP = healthCheckSourceIP
    }
}

public struct DesiredLoadBalancerHealthCheck: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let intervalSeconds: Int
    public let timeoutSeconds: Int
    public let successThreshold: Int
    public let failureThreshold: Int

    public init(
        enabled: Bool,
        intervalSeconds: Int,
        timeoutSeconds: Int,
        successThreshold: Int,
        failureThreshold: Int
    ) {
        self.enabled = enabled
        self.intervalSeconds = intervalSeconds
        self.timeoutSeconds = timeoutSeconds
        self.successThreshold = successThreshold
        self.failureThreshold = failureThreshold
    }
}

/// A first-class Strato L4 load balancer, keyed by its resource UUID rather
/// than its mutable display name. Omission from an authoritative network sync
/// means the owner-tagged OVN row must be removed.
public struct DesiredLoadBalancer: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let vip: String
    public let protocolName: String
    public let generation: Int64
    public let healthCheck: DesiredLoadBalancerHealthCheck
    public let listeners: [DesiredLoadBalancerListener]
    public let backends: [DesiredLoadBalancerBackend]

    public init(
        id: UUID,
        name: String,
        vip: String,
        protocolName: String,
        generation: Int64,
        healthCheck: DesiredLoadBalancerHealthCheck,
        listeners: [DesiredLoadBalancerListener],
        backends: [DesiredLoadBalancerBackend]
    ) {
        self.id = id
        self.name = name
        self.vip = vip
        self.protocolName = protocolName
        self.generation = generation
        self.healthCheck = healthCheck
        self.listeners = listeners
        self.backends = backends
    }
}

/// The state the control plane wants a logical network to be in on an agent.
///
/// Networking used to reach the agent only as a side effect of `VMSpec.networks`
/// during VM create, so routers/NAT had nowhere to live. This makes the network
/// (and its L3 router + uplink) a first-class entry in the desired-state sync,
/// reconciled level-triggered just like VMs: a network omitted from the list
/// should not exist on the agent.
///
/// Router scope is per-project: every network in the same project shares one
/// logical router (giving cross-switch east-west), keyed by `routerKey`. Two
/// projects never share a router, which is what makes it safe for them to use
/// the same subnet (issue #765).
public struct DesiredNetworkState: Codable, Sendable {
    public let networkId: UUID
    /// Human label for logs and external-ids. **Not** the OVN switch name — the
    /// agent derives that from `networkId` (issue #342) — and not unique:
    /// names are scoped per project, so two entries in one sync may share one
    /// (issue #765).
    public let name: String
    /// The network's subnet in CIDR form, e.g. `192.168.1.0/24`. Used as the
    /// SNAT `logical_ip` and to size the router port's address.
    public let subnet: String
    /// The L3 gateway address the router presents on this network (the router
    /// port's IP). Already reserved by control-plane IPAM as a non-allocatable
    /// host address. Nil disables L3 for the network (switch only).
    public let gateway: String?
    /// The network's IPv6 subnet in CIDR form (a /64, e.g.
    /// `fd12:3456:789a::/64`), when the network is dual-stack. Nil on
    /// v4-only networks and from control planes that predate IPv6 support —
    /// optional, so old payloads decode and old agents ignore it.
    public let subnet6: String?
    /// The IPv6 gateway (router-port address) inside `subnet6`, when
    /// dual-stack. The agent adds it to the router port and announces it via
    /// Router Advertisements (dhcpv6_stateful mode) — DHCPv6 itself cannot
    /// convey a default route.
    public let gateway6: String?
    /// Identity of the logical router this network attaches to. Networks sharing
    /// a `routerKey` share one router. Opaque to the agent — do not parse it.
    public let routerKey: String
    /// Whether the agent should program outbound SNAT to the site uplink for
    /// this network. The uplink IP is auto-detected on the agent. IPv4-only:
    /// IPv6 stays internal (no NAT66, no default route) in this phase.
    public let externalAccess: Bool
    /// Whether the network's guests are addressed by OVN's DHCP responder.
    /// Carried here — not only on per-NIC specs — because DHCP edits don't
    /// bump VM generations, so converged VMs never re-realize their NICs; the
    /// level-triggered network reconcile is what converges the DHCP_Options
    /// rows (including deleting them when DHCP is turned off). Nil from
    /// control planes that predate the field: the agent then leaves DHCP rows
    /// alone, preserving the old NIC-driven behavior.
    public let dhcpEnabled: Bool?
    /// The network's DNS resolvers; may be mixed-family (the agent splits per
    /// DHCP family). Nil ≙ pre-field control plane, like `dhcpEnabled`.
    ///
    /// **What this list is depends on `resolverEnabled`** (wire v37, STR-40).
    /// With the resolver off it is what the guest is told over DHCP, which is
    /// all it ever was. With the resolver on, the guest is told
    /// `NetworkResolverEndpoint.address` instead and this becomes the
    /// *upstream forwarders* the network's CoreDNS sends misses to. The field
    /// did not change shape or validation, only its consumer — and the two
    /// readings agree on the values that matter, because a resolver list was
    /// already a list of recursive resolvers.
    public let dnsServers: [String]?
    /// DNS search domain advertised over DHCP.
    public let domainName: String?
    /// DHCPv4 lease time in seconds; agents default it when nil.
    public let leaseTime: Int?
    /// Whether this network's guests can reach the instance metadata service at
    /// `InstanceMetadataEndpoint`. Realized as an OVN `localport` on the
    /// network's logical switch — instantiated on every chassis, never
    /// forwarded across tunnels — converged level-triggered by the network
    /// reconcile, including deletion when turned off.
    ///
    /// Carried here rather than only on per-NIC specs for `dhcpEnabled`'s
    /// reason: network-level metadata settings don't bump each attached VM's
    /// generation, so a converged VM never re-realizes its NICs and the network
    /// reconcile is the only path that reaches a live network whose setting
    /// changed.
    ///
    /// Nil ≙ a control plane that predates the field: the agent neither creates
    /// nor *deletes* the port. The deletion half is load-bearing in a way it is
    /// not for `dhcpEnabled`, because network teardown is `observed − desired`:
    /// a nil that merely planned no port would read as "remove it", so a
    /// rollback would sweep every live metadata port. `false` is an opinion and
    /// *is* honored — that is what makes turning the feature off work. See
    /// `NetworkReconciler.serviceLocalPortProtection(for:)`.
    public let metadataEnabled: Bool?
    /// Whether this network's guests get a resolver at the addresses in
    /// `resolverAddresses` (STR-40, wire v37): the host-wide CoreDNS each agent
    /// runs in its *host* namespace, which serves the network's zones in full —
    /// including the CNAME/TXT/SRV the OVN `DNS` table cannot express — and
    /// forwards everything else to `dnsServers`.
    ///
    /// Realized on a **second** `localport` of its own, not the one
    /// `metadataEnabled` authors, because the two services terminate in
    /// different namespaces and one OVS interface claims one `iface-id` (ADR
    /// 0008). It is still a second flag on one carrier rather than a second
    /// carrier, because both are properties of the same network row.
    ///
    /// Everything said about `metadataEnabled`'s absence applies here word for
    /// word — nil neither creates nor deletes, `false` is an opinion and is
    /// honored, and the deletion half is what keeps a rollback from sweeping
    /// live ports. What differs is that this flag also decides what the DHCP
    /// `dns_server` option contains, so a network flipping it changes what
    /// guests are told at their next lease.
    ///
    /// The control plane withholds `true` unless *every* agent in the site
    /// reports `AgentRegisterMessage.resolverCapable`.
    public let resolverEnabled: Bool?
    /// This network's own resolver addresses, v4 first (STR-40).
    ///
    /// **Distinct per network**, which is what lets every resolver on a host
    /// share one namespace — the host's — and so forward upstream through the
    /// hypervisor's own egress. A single well-known address could not: the
    /// listener would have no way to tell which network asked, and the host no
    /// way to route a reply back to a `10.0.0.5` that exists on three switches.
    ///
    /// Non-nil exactly when `resolverEnabled` is true. Two fields rather than
    /// one derived from an index on the wire, because the agent should realize
    /// what it was told rather than re-derive an allocation scheme the control
    /// plane owns.
    public let resolverAddresses: [String]?
    /// Monotonic per-network counter, bumped by the control plane on any change
    /// that alters realization (subnet, gateway, router membership, external
    /// access). Lets the agent reject replayed or reordered syncs. DHCP-only
    /// edits deliberately don't bump it — the network reconcile is
    /// level-triggered, so same-generation networks still converge DHCP.
    public let generation: Int64
    /// Floating IPs attached to this network's NICs, realized as
    /// `dnat_and_snat` rules on the network's router (issue #344). Nil from
    /// control planes that predate the field — optional, so old payloads
    /// decode and old agents ignore it. Only meaningful on `externalAccess`
    /// networks (the NAT needs the router's uplink).
    public let floatingIPs: [DesiredFloatingIP]?
    /// Native OVN load balancers whose VIP belongs to this network. Nil means
    /// a pre-v43 control plane has no opinion; an empty array is authoritative.
    public let loadBalancers: [DesiredLoadBalancer]?
    /// The network-level ACL attached to this switch (STR-33). The schema
    /// permits at most one entry, while the collection shape preserves the
    /// desired-state distinction between no opinion (`nil`) and authoritative
    /// absence (`[]`), which tells the agent to remove managed switch ACLs.
    public let networkACLs: [DesiredNetworkACL]?

    public init(
        networkId: UUID,
        name: String,
        subnet: String,
        gateway: String?,
        subnet6: String? = nil,
        gateway6: String? = nil,
        routerKey: String,
        externalAccess: Bool,
        dhcpEnabled: Bool? = nil,
        dnsServers: [String]? = nil,
        domainName: String? = nil,
        leaseTime: Int? = nil,
        metadataEnabled: Bool? = nil,
        resolverEnabled: Bool? = nil,
        resolverAddresses: [String]? = nil,
        generation: Int64,
        floatingIPs: [DesiredFloatingIP]? = nil,
        loadBalancers: [DesiredLoadBalancer]? = nil,
        networkACLs: [DesiredNetworkACL]? = nil
    ) {
        self.networkId = networkId
        self.name = name
        self.subnet = subnet
        self.gateway = gateway
        self.subnet6 = subnet6
        self.gateway6 = gateway6
        self.routerKey = routerKey
        self.externalAccess = externalAccess
        self.dhcpEnabled = dhcpEnabled
        self.dnsServers = dnsServers
        self.domainName = domainName
        self.leaseTime = leaseTime
        self.metadataEnabled = metadataEnabled
        self.resolverEnabled = resolverEnabled
        self.resolverAddresses = resolverAddresses
        self.generation = generation
        self.floatingIPs = floatingIPs
        self.loadBalancers = loadBalancers
        self.networkACLs = networkACLs
    }
}

// MARK: - Desired DNS zones

/// One resource record set inside a zone: an owner name, a type, and every
/// value published at that name for that type (STR-39).
///
/// Typed rather than pre-flattened into the `name → addresses` map OVN's `DNS`
/// table takes, for two reasons. Realization is meant to be a swappable driver
/// — the OVN writer joins a name's A and AAAA values into one space-separated
/// string, while a zone file keeps them apart — and only the *receiver* can say
/// which types its backend can express, which is what lets the agent report the
/// ones it had to skip instead of the control plane silently dropping them.
///
/// `type` is a string, not an enum, on the `DesiredSecurityGroupRule.direction`
/// precedent: a record type from a newer control plane must decode into an
/// entry this agent ignores, never fail the whole sync.
public struct DesiredDNSRecord: Codable, Sendable, Equatable {
    /// Fully-qualified owner name, lowercased and without a trailing dot. For
    /// a `PTR` this is the `in-addr.arpa` / `ip6.arpa` name.
    public let name: String
    /// `A`, `AAAA`, `PTR`, `CNAME`, `TXT`, `SRV` — uppercase, as zone files
    /// spell them.
    public let type: String
    /// The RRset's values, deduplicated and sorted by the control plane so two
    /// assemblies of the same data compare (and hash) equal.
    public let values: [String]
    /// The RRset's TTL in seconds (wire v37, STR-40).
    ///
    /// v36 deliberately left this off: an OVN `DNS` row has nowhere to put a
    /// TTL, so carrying one would have been dead weight on every sync. A zone
    /// file has to write one, and it writes **one per RRset** — which is why
    /// the control plane enforces a single TTL across an RRset (RFC 2181 §5.2)
    /// rather than storing it per value.
    ///
    /// Optional so a pre-v37 control plane's payload still decodes; a receiver
    /// that gets nil renders the record at its zone's default TTL.
    public let ttl: Int?

    public init(name: String, type: String, values: [String], ttl: Int? = nil) {
        self.name = name
        self.type = type
        self.values = values
        self.ttl = ttl
    }
}

/// A DNS zone the receiving agent should realize (STR-39, roadmap #769).
///
/// This rides the **network-level carrier, not `NetworkSpec`**: DNS and DHCP
/// edits deliberately don't bump VM generations, so a converged VM never
/// re-realizes its NICs and would never see a record change. The
/// level-triggered network reconcile is what converges these rows, exactly as
/// it does `DHCP_Options`.
///
/// A zone's contents span every VM on every attached network across *all*
/// agents, so `records` is assembled from the whole fleet rather than from the
/// receiving agent's own workloads. That has been true since v36 and is what
/// makes the two realizations below able to share one payload.
///
/// ## Two backends, two audiences
///
/// The **OVN `DNS` table** (v36) is switch-scoped topology written into the
/// shared northbound database, so only the site's topology authority may write
/// it — two level-triggered writers would fight over one row. `networkIds`
/// carries the networks that agent authors.
///
/// The **per-network resolver** (v37, STR-40) is not topology: a CoreDNS runs
/// in the host namespace of every host with a local NIC on the network, serving
/// the zones attached to that network from a server block bound to its own
/// address pair (ADR 0008). So from v37 a zone is sent
/// to any agent that either authors an attached network *or* runs a workload
/// on one, and `networkIds` is the union of both. An agent realizes the OVN
/// half only for the networks it actually authors, which it already knows from
/// `DesiredStateMessage.networksAuthoritative`.
public struct DesiredDNSZone: Codable, Sendable, Equatable {
    public let zoneId: UUID
    /// The zone's fully-qualified name, lowercased with no trailing dot. Not
    /// an identifier — zone names are unique only within a project — and used
    /// only as a human label on the realized row.
    public let zoneName: String
    /// The networks that should answer from this zone, restricted to the ones
    /// this agent has something to do with — those it authors topology for,
    /// plus (from v37) those it runs a local NIC on. The agent derives switch
    /// and namespace names from the ids (`OVNNaming.switchName`,
    /// `ChassisServicePlan.netnsName`), so user-chosen names never enter the
    /// OVN or host namespace.
    public let networkIds: [UUID]
    /// The zone's effective contents, derived ∪ authored, in a stable order.
    public let records: [DesiredDNSRecord]
    /// A digest of the `records` carried here — which is the zone minus its
    /// `.external`-view entries, since those are for publication elsewhere and
    /// never reach an agent. Computed by the control plane. The agent stamps it
    /// on the realized row's `external_ids` and compares it on the next sync,
    /// so an unchanged zone costs no OVSDB transaction: records are
    /// O(VMs on the network) and ship on every sync, and rewriting the whole
    /// map every cycle is what level-triggering must not degenerate into.
    ///
    /// Never load-bearing for correctness — a stamp that disagrees with the
    /// row's actual contents (a hand-edited row, an agent whose realization
    /// changed across an upgrade) still heals, because the agent also compares
    /// the records it would write against the ones the row carries.
    public let recordsHash: String

    public init(
        zoneId: UUID, zoneName: String, networkIds: [UUID], records: [DesiredDNSRecord],
        recordsHash: String
    ) {
        self.zoneId = zoneId
        self.zoneName = zoneName
        self.networkIds = networkIds
        self.records = records
        self.recordsHash = recordsHash
    }
}

// MARK: - Observed VM State

/// How the agent will treat a reported convergence failure on later syncs.
///
/// Optional on observed resource entries for wire compatibility: an older
/// agent does not send it, and the control plane must keep its historical
/// terminal-failure behavior in that case. `waitingOnDependency` never reaches
/// an observed error at all, so it has no wire case.
public enum ObservedFailureClassification: String, Codable, Sendable {
    case transient
    case permanent
    case blocked
}

/// One VM's state as actually observed on an agent.
public struct ObservedVMState: Codable, Sendable {
    public let vmId: UUID
    public let status: VMStatus
    /// The desired-state generation this observation reflects: the last
    /// generation the agent finished converging toward (0 if none yet). The
    /// control plane records it as `observed_generation` and completes pending
    /// operations only once the observed generation has caught up.
    public let observedGeneration: Int64
    /// Set while the agent is still converging this VM toward a newer
    /// generation — a human-readable stage like "downloading image". Progress
    /// only: the control plane surfaces it but must not treat the entry as a
    /// settled observation for operation completion.
    public let convergencePhase: String?
    /// The most recent convergence failure for this VM, if the last attempt
    /// failed. Lets the control plane fail a pending operation with a real
    /// error instead of waiting for its completion budget to expire.
    public let lastError: String?
    /// The generation whose convergence produced `lastError`. The control
    /// plane fails a pending operation on `lastError` only when this matches
    /// the VM's current generation — otherwise a stale error from a previous
    /// generation (still carried on heartbeat reports until the new
    /// generation's work item runs) would fail a brand-new operation before
    /// the agent ever attempted it.
    public let failedGeneration: Int64?
    /// The agent-side retry category for this failure. Only `.blocked` tells
    /// the control plane to retain the desired state while surfacing the error;
    /// nil is the legacy terminal behavior for reports from older agents.
    public let failureClassification: ObservedFailureClassification?
    /// What the QEMU guest agent reported about this VM's guest OS, if the
    /// agent has a recent successful probe (issue #563). Nil for VMs without
    /// qga, still booting, hung, or on agents/hypervisors that don't probe it —
    /// so `Optional` keeps this backward-decodable both ways (an older control
    /// plane ignores the key; an older agent never sends it, which synthesized
    /// `Codable` decodes to nil, not a failure). Purely informational: it never
    /// participates in convergence.
    public let guestInfo: GuestInfo?
    /// Guest memory usage from the VM's virtio-balloon device (issue #567).
    /// Nil for guests without the virtio_balloon driver, still booting, or on
    /// agents/hypervisors that don't poll it — the same tolerant-both-ways
    /// `Optional` contract as `guestInfo`. Purely informational: it never
    /// participates in convergence.
    public let memoryStats: VMMemoryStats?
    /// Interface ids present in the agent's durable VM manifest (wire v40).
    /// Nil means the reporting agent predates per-NIC reconciliation; an empty
    /// array is an authoritative networkless VM.
    public let appliedNetworkInterfaceIds: [UUID]?

    public init(
        vmId: UUID,
        status: VMStatus,
        observedGeneration: Int64,
        convergencePhase: String? = nil,
        lastError: String? = nil,
        failedGeneration: Int64? = nil,
        failureClassification: ObservedFailureClassification? = nil,
        guestInfo: GuestInfo? = nil,
        memoryStats: VMMemoryStats? = nil,
        appliedNetworkInterfaceIds: [UUID]? = nil
    ) {
        self.vmId = vmId
        self.status = status
        self.observedGeneration = observedGeneration
        self.convergencePhase = convergencePhase
        self.lastError = lastError
        self.failedGeneration = failedGeneration
        self.failureClassification = failureClassification
        self.guestInfo = guestInfo
        self.memoryStats = memoryStats
        self.appliedNetworkInterfaceIds = appliedNetworkInterfaceIds
    }
}

// MARK: - Observed Sandbox State

/// One sandbox's state as actually observed on an agent. Field semantics match
/// `ObservedVMState` (see the doc comments there for the generation/error
/// contract); `exitCode` is the sandbox-specific addition.
public struct ObservedSandboxState: Codable, Sendable {
    public let sandboxId: UUID
    public let status: SandboxStatus
    /// The desired-state generation this observation reflects (0 if none yet).
    public let observedGeneration: Int64
    /// Human-readable convergence stage (e.g. "pulling image") while the agent
    /// is still working toward a newer generation. Progress only.
    public let convergencePhase: String?
    /// The most recent convergence failure, if the last attempt failed.
    public let lastError: String?
    /// The generation whose convergence produced `lastError` (see
    /// `ObservedVMState.failedGeneration` for why the control plane needs it).
    public let failedGeneration: Int64?
    /// Retry semantics for `lastError`; see
    /// `ObservedVMState.failureClassification`.
    public let failureClassification: ObservedFailureClassification?
    /// Exit code of the workload once it has ended (`status == .exited`), as
    /// reported by the guest agent over vsock. Nil while running, when the
    /// sandbox was stopped by request rather than by the workload ending, or
    /// when the guest could not report one.
    public let exitCode: Int?

    public init(
        sandboxId: UUID,
        status: SandboxStatus,
        observedGeneration: Int64,
        convergencePhase: String? = nil,
        lastError: String? = nil,
        failedGeneration: Int64? = nil,
        failureClassification: ObservedFailureClassification? = nil,
        exitCode: Int? = nil
    ) {
        self.sandboxId = sandboxId
        self.status = status
        self.observedGeneration = observedGeneration
        self.convergencePhase = convergencePhase
        self.lastError = lastError
        self.failedGeneration = failedGeneration
        self.failureClassification = failureClassification
        self.exitCode = exitCode
    }
}

// MARK: - Observed Volume State

/// One volume's state as actually observed on an agent (ADR 0001 stage 5,
/// STR-148). Field semantics for the convergence metadata match
/// `ObservedVMState` — see the doc comments there.
///
/// `sizeBytes` was deliberately absent until STR-199, on the grounds that
/// reading a volume's virtual size meant a `qemu-img info` subprocess per
/// volume per report. That cost is no longer hypothetical *or* avoidable: the
/// agent's planner needs the same number to decide whether a grow is
/// outstanding, so it already computes and caches one per volume — every write
/// path records the size it produced, and the probe fires only for a volume
/// this process has not seen written. Reporting it adds no work at all.
///
/// ADR stage 7 (STR-149) settled the same question for the rest of what
/// `volume_info` used to return, and settled it the same way: nothing was
/// added. Format, disk attachment and VM attachment were already here; allocated bytes, the
/// dirty flag and the encryption flag have no reader, and allocation in
/// particular moves with every guest write, so it cannot be cached the way
/// virtual size can and would cost a subprocess per volume per report. A
/// per-volume usage surface — sampled on its own cadence, off the convergence
/// path — is the right home for those if a reader ever appears.
public struct ObservedVolumeState: Codable, Sendable {
    public let volumeId: UUID
    /// Whether the volume's data exists on this host. A `false` entry is a
    /// volume the agent is listing because it is mid-create or failed with no
    /// bytes yet — the mirror of the VM report's in-flight and
    /// failed-convergence sections. *Absence from the list* is what confirms a
    /// deletion; `present: false` explicitly does not.
    public let present: Bool
    /// How the agent exposes the disk. The agent owns storage layout, so this
    /// is the only direction the descriptor originates: the control plane
    /// stores what it is told and never derives one.
    public let attachment: DiskAttachment?
    /// The volume's **virtual size on disk** (STR-199) — what `qemu-img info`
    /// reports, not what anyone asked for.
    ///
    /// It exists because the two can disagree for a long time and nothing said
    /// so. A grow refused while the guest holding the image is running leaves
    /// the desired size persisted and the file untouched; before this field the
    /// API answered that volume's size with the number it had failed to reach,
    /// which reads exactly like a grow that worked.
    ///
    /// Nil means **this agent did not say** — a pre-v38 agent, or a volume
    /// whose size probe failed. Never "zero bytes", and never a licence to
    /// clear what a previous report recorded.
    public let sizeBytes: Int64?
    /// The VM this volume is attached to, from the agent's *durable attachment
    /// record* rather than a live hypervisor query. A powered-off guest has no
    /// live device list, and reporting "detached" for it would plan an attach
    /// against a dead control channel on every sync and degrade the volume for
    /// the crime of having a stopped VM.
    public let attachedVMId: UUID?
    /// The desired-state generation this observation reflects (0 if none yet).
    public let observedGeneration: Int64
    /// Human-readable convergence stage ("creating", "cloning", ...) while the
    /// agent is still working toward a newer generation. Progress only.
    public let convergencePhase: String?
    /// The most recent convergence failure, if the last attempt failed.
    public let lastError: String?
    /// The generation whose convergence produced `lastError` (see
    /// `ObservedVMState.failedGeneration` for why the control plane needs it).
    public let failedGeneration: Int64?
    /// Retry semantics for `lastError`; see
    /// `ObservedVMState.failureClassification`.
    public let failureClassification: ObservedFailureClassification?
    /// The I/O ceilings this agent has actually applied (STR-19) — an *echo*,
    /// not a derivation, and the only thing that distinguishes "capped" from
    /// "ignored".
    ///
    /// STR-19 ships no capability gate, so an agent that has never heard of
    /// ceilings drops `DesiredVolumeState.ioLimits` on the floor and still
    /// advances `observedGeneration`. The generation pair alone would call that
    /// mutation converged. This field is what makes the disagreement visible.
    ///
    /// Nil means **this agent does not report applied limits** — which is every
    /// agent until the online-throttling work lands. It must never be written
    /// through as a clear. "Applied, and the answer is uncapped" is spelled
    /// `VolumeIOLimits(iopsTotal: nil, bpsTotal: nil)`: present but empty. So
    /// unlike the desired side, this one is deliberately *not* normalized.
    public let ioLimits: VolumeIOLimits?

    public init(
        volumeId: UUID,
        present: Bool,
        attachment: DiskAttachment? = nil,
        sizeBytes: Int64? = nil,
        attachedVMId: UUID? = nil,
        observedGeneration: Int64,
        convergencePhase: String? = nil,
        lastError: String? = nil,
        failedGeneration: Int64? = nil,
        failureClassification: ObservedFailureClassification? = nil,
        ioLimits: VolumeIOLimits? = nil
    ) {
        self.volumeId = volumeId
        self.present = present
        self.attachment = attachment
        self.sizeBytes = sizeBytes
        self.attachedVMId = attachedVMId
        self.observedGeneration = observedGeneration
        self.convergencePhase = convergencePhase
        self.lastError = lastError
        self.failedGeneration = failedGeneration
        self.failureClassification = failureClassification
        self.ioLimits = ioLimits
    }
}

// MARK: - Observed Agent Update Status

/// Why an agent is not converging on the sync's `DesiredAgentUpdate`
/// (issue #434), reported back on the observed-state report so the control
/// plane's rollout can distinguish "waiting on a precondition" from "the
/// update itself failed" instead of timing both out identically.
public struct ObservedAgentUpdateStatus: Codable, Sendable {
    /// A precondition currently prevents the attempt (containerized install,
    /// in-flight reconcile work). Transient from the rollout's perspective:
    /// the agent re-evaluates on every sync.
    public static let dispositionBlocked = "blocked"
    /// The update was attempted and did not take (download, checksum, probe,
    /// or swap failure — or the installed artifact did not change the
    /// version). The agent will not retry this artifact within the current
    /// process lifetime, so the rollout should halt rather than wait.
    public static let dispositionFailed = "failed"

    /// The `DesiredAgentUpdate.targetVersion` this status is about, so a
    /// stale report can never be attributed to a newer rollout target.
    public let targetVersion: String
    /// One of the `disposition*` constants. A string rather than an enum so
    /// a disposition added later still decodes on older control planes
    /// (unknown values are treated as `blocked`, the conservative reading).
    public let disposition: String
    /// Human-readable explanation, surfaced on the agent's API resource.
    public let reason: String

    public init(targetVersion: String, disposition: String, reason: String) {
        self.targetVersion = targetVersion
        self.disposition = disposition
        self.reason = reason
    }
}

// MARK: - Unrecognized workloads

/// A workload an agent holds that the last desired-state sync did not list
/// (STR-98).
///
/// The agent **holds** it — running, untouched, adopted into no desired
/// generation — and reports it here so the control plane can decide. A row
/// that still exists means an assembler or scoping bug and must never
/// authorize teardown; no row at all earns a `DesiredWorkloadTombstone` on a
/// later sync.
public struct UnrecognizedWorkload: Codable, Sendable, Equatable {
    public let kind: WorkloadKind
    public let workloadId: UUID
    /// The last desired-state generation the agent applied for this workload
    /// (0 if it never applied one), so the control plane can mint a tombstone
    /// generation that outranks it rather than one the agent would drop as
    /// stale.
    public let observedGeneration: Int64
    /// The workload's observed status, persisted onto the control plane's
    /// `AgentWorkloadClaim` and logged — "holding a *running* VM nothing
    /// describes" reads very differently from holding a stopped one.
    public let status: String?

    public init(kind: WorkloadKind, workloadId: UUID, observedGeneration: Int64, status: String? = nil) {
        self.kind = kind
        self.workloadId = workloadId
        self.observedGeneration = observedGeneration
        self.status = status
    }
}

/// Why an agent refused to converge the teardowns a sync authorized (STR-98
/// phase 2): the blast-radius guard tripped.
///
/// Reported so the refusal reaches operators through the plumbing that already
/// exists, rather than living only in an agent log nobody is watching. The
/// agent keeps converging everything else in the sync.
public struct ObservedTeardownRefusal: Codable, Sendable, Equatable {
    /// The sync whose teardowns were refused, so the refusal can be correlated
    /// with the control-plane side of the same exchange.
    public let syncId: String
    /// How many tombstoned workloads that sync would have destroyed.
    public let requestedTeardowns: Int
    /// How many workloads the host holds in total, the denominator of the
    /// percentage half of the guard.
    public let presentWorkloads: Int
    /// Human-readable explanation, surfaced on the agent's API resource.
    public let reason: String

    public init(syncId: String, requestedTeardowns: Int, presentWorkloads: Int, reason: String) {
        self.syncId = syncId
        self.requestedTeardowns = requestedTeardowns
        self.presentWorkloads = presentWorkloads
        self.reason = reason
    }
}

/// Agent → control plane: what the agent's durable workload manifest — its
/// only memory of what it is running — was able to tell it at startup
/// (STR-138).
///
/// Sent only when there is something wrong to say; nil is the steady state.
public struct ObservedManifestStatus: Codable, Sendable, Equatable {
    /// Whether the `vms`/`sandboxes` lists on this report are a complete
    /// inventory of the host.
    ///
    /// **False changes the meaning of the whole report.** The manifest could
    /// not be read at all, so the agent cannot enumerate its own workloads:
    /// the lists are empty because it doesn't know, not because the host is
    /// empty. Absence confirms nothing — not a deletion, not a loss — and the
    /// control plane must apply none of the report's workload half.
    public let inventoryComplete: Bool
    /// Entries that decoded far enough to prove a workload exists under that
    /// id, but not far enough to route operations to it (an unrecognized
    /// hypervisor type, a spec this build cannot read). They keep reserving
    /// capacity and are reported as present, but nothing can be done to them
    /// until an agent that understands them runs here.
    public let quarantinedEntries: Int
    /// Operator-facing explanation, surfaced on the agent's API resource.
    /// (The unreadable manifest itself is preserved beside the original on
    /// the host for post-mortem; the agent logs where.)
    public let reason: String

    public init(
        inventoryComplete: Bool,
        quarantinedEntries: Int,
        reason: String
    ) {
        self.inventoryComplete = inventoryComplete
        self.quarantinedEntries = quarantinedEntries
        self.reason = reason
    }
}

// MARK: - Observed Load Balancer State

public enum ObservedLoadBalancerStatus: String, Codable, Sendable {
    case pending
    case active
    case error
}

public enum ObservedLoadBalancerBackendHealth: String, Codable, Sendable {
    case unknown
    case online
    case offline
    case error
}

public struct ObservedLoadBalancerBackend: Codable, Sendable, Equatable {
    public let id: UUID
    public let healthStatus: ObservedLoadBalancerBackendHealth
    public let lastCheckedAt: Date?

    public init(
        id: UUID,
        healthStatus: ObservedLoadBalancerBackendHealth,
        lastCheckedAt: Date? = nil
    ) {
        self.id = id
        self.healthStatus = healthStatus
        self.lastCheckedAt = lastCheckedAt
    }
}

/// What the site's single OVN author observed after reconciling one native
/// load balancer. Optional at the report level because non-authoritative and
/// pre-v43 agents have no opinion about these project-scoped rows.
public struct ObservedLoadBalancerState: Codable, Sendable, Equatable {
    public let id: UUID
    public let observedGeneration: Int64
    public let status: ObservedLoadBalancerStatus
    public let lastError: String?
    public let backends: [ObservedLoadBalancerBackend]

    public init(
        id: UUID,
        observedGeneration: Int64,
        status: ObservedLoadBalancerStatus,
        lastError: String? = nil,
        backends: [ObservedLoadBalancerBackend] = []
    ) {
        self.id = id
        self.observedGeneration = observedGeneration
        self.status = status
        self.lastError = lastError
        self.backends = backends
    }
}

/// Agent → control plane: everything the agent actually has, with resources.
///
/// Full-list semantics mirror `DesiredStateMessage`: a VM missing from `vms`
/// does not exist on this agent, which is how deletions are confirmed. Sent
/// immediately after any convergence action and piggybacked on the heartbeat
/// cadence, so state converges quickly after changes but is also periodically
/// re-asserted.
///
/// `manifestStatus` is the one thing that suspends those semantics: an agent
/// that cannot read its manifest sends the report to carry the condition and
/// its resource snapshot, and the lists mean nothing (STR-138).
public struct ObservedStateReport: WebSocketMessage {
    public var type: MessageType { .observedState }
    public let requestId: String
    public let timestamp: Date
    public let agentId: String
    public let vms: [ObservedVMState]
    /// Sandboxes actually present on this agent. Full-list, like `vms`: a
    /// sandbox missing from the list does not exist, which is how sandbox
    /// deletions are confirmed. The key is required even when the list is
    /// empty.
    public let sandboxes: [ObservedSandboxState]
    public let resources: AgentResources
    /// Why the agent is not converging on its `DesiredAgentUpdate`, when one
    /// is desired and something is in the way (issue #434). Nil when no update
    /// is desired or convergence is proceeding (the agent restarts into the new
    /// build rather than reporting progress).
    public let agentUpdateStatus: ObservedAgentUpdateStatus?
    /// Workloads this agent holds that its last sync did not list (STR-98).
    /// They also appear in `vms`/`sandboxes` above — the agent really is
    /// running them — so this list is the agent asking "should these exist?",
    /// not a second inventory.
    public let unrecognized: [UnrecognizedWorkload]
    /// Set when the blast-radius guard refused a sync's teardowns. Nil in the
    /// steady state.
    public let teardownRefusal: ObservedTeardownRefusal?
    /// Set when the agent's durable workload manifest could not be read in full
    /// (STR-138). Nil in the steady state. `inventoryComplete == false`
    /// suspends this report's full-list semantics — see
    /// `ObservedManifestStatus`.
    public let manifestStatus: ObservedManifestStatus?
    /// Volumes actually present on this agent (STR-148). Full-list, like
    /// `vms`: a volume missing from the list does not exist here, which is how
    /// volume deletions are confirmed.
    ///
    /// Optional rather than `[]`-defaulted because nil means the current agent
    /// could not enumerate its volume store. The control plane must read that as
    /// "unknown", not "every volume on this agent is gone" — which would reap
    /// terminating volume rows and error live ones.
    public let volumes: [ObservedVolumeState]?
    /// Snapshot artifacts actually present on this agent (STR-150). Full-list
    /// and kind-tagged, like the desired counterpart: an artifact missing from
    /// this list does not exist here, which is how snapshot deletions are
    /// confirmed and how the finalizer reap learns a checkpoint's bytes are
    /// really gone.
    ///
    /// `Optional` for `volumes`' reason. Nil means the current agent could not
    /// enumerate one of its artifact stores, so the control plane must do
    /// nothing rather than read the absence as "every checkpoint is gone".
    public let snapshots: [ObservedSnapshotState]?
    /// Native LB programming and backend health observed by the site's
    /// topology author. Nil means no opinion, not an empty authoritative set.
    public let loadBalancers: [ObservedLoadBalancerState]?
    /// Whole physical disks observed by this agent. A non-nil value is the
    /// complete current inventory, including an authoritative empty list.
    /// Nil means enumeration failed or is unsupported and must not be read as
    /// device absence.
    public let storageDevices: [ObservedStorageDevice]?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        agentId: String,
        vms: [ObservedVMState],
        sandboxes: [ObservedSandboxState] = [],
        resources: AgentResources,
        agentUpdateStatus: ObservedAgentUpdateStatus? = nil,
        unrecognized: [UnrecognizedWorkload] = [],
        teardownRefusal: ObservedTeardownRefusal? = nil,
        manifestStatus: ObservedManifestStatus? = nil,
        volumes: [ObservedVolumeState]? = nil,
        snapshots: [ObservedSnapshotState]? = nil,
        loadBalancers: [ObservedLoadBalancerState]? = nil,
        storageDevices: [ObservedStorageDevice]? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.agentId = agentId
        self.vms = vms
        self.sandboxes = sandboxes
        self.resources = resources
        self.agentUpdateStatus = agentUpdateStatus
        self.unrecognized = unrecognized
        self.teardownRefusal = teardownRefusal
        self.manifestStatus = manifestStatus
        self.volumes = volumes
        self.snapshots = snapshots
        self.loadBalancers = loadBalancers
        self.storageDevices = storageDevices
    }

}
