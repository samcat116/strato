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
    /// Optional so payloads from older control planes still decode and older
    /// agents ignore it, matching `subnet6`/`dhcpEnabled`. Absence is
    /// asymmetric, the `networks`/`sandboxes` hazard in miniature: from a
    /// control plane that speaks the field (`supportsInstanceMetadata` on the
    /// envelope's sender version) nil is authoritative — there is nothing to
    /// serve, and an agent holding stale metadata must drop it — while from an
    /// older one it means only "no opinion", and the agent leaves whatever it
    /// serves alone rather than reading silence as an instruction.
    public let metadata: InstanceMetadata?

    public init(
        vmId: UUID,
        hypervisorType: HypervisorType,
        spec: VMSpec,
        desiredStatus: DesiredVMStatus,
        generation: Int64,
        imageInfo: ImageInfo? = nil,
        metadata: InstanceMetadata? = nil
    ) {
        self.vmId = vmId
        self.hypervisorType = hypervisorType
        self.spec = spec
        self.desiredStatus = desiredStatus
        self.generation = generation
        self.imageInfo = imageInfo
        self.metadata = metadata
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

    public init(
        sandboxId: UUID,
        spec: SandboxSpec,
        desiredStatus: DesiredSandboxStatus,
        generation: Int64,
        registryCredential: RegistryCredential? = nil,
        restoreFrom: SandboxSnapshotRef? = nil
    ) {
        self.sandboxId = sandboxId
        self.spec = spec
        self.desiredStatus = desiredStatus
        self.generation = generation
        self.registryCredential = registryCredential
        self.restoreFrom = restoreFrom
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
    /// Present for `clone`. The volume/VM co-location constraint guarantees the
    /// source lives on this same agent, and the agent derives the source path
    /// from its own layout — no path travels on the wire (STR-180).
    public let sourceVolumeId: UUID?
    /// The source volume's format, when known, so the agent can pick a copy
    /// strategy without probing. Advisory: the backend detects rather than
    /// assumes.
    public let sourceFormat: String?

    public init(
        kind: String,
        imageInfo: ImageInfo? = nil,
        sourceVolumeId: UUID? = nil,
        sourceFormat: String? = nil
    ) {
        self.kind = kind
        self.imageInfo = imageInfo
        self.sourceVolumeId = sourceVolumeId
        self.sourceFormat = sourceFormat
    }

    public static func image(_ info: ImageInfo) -> DesiredVolumeSource {
        DesiredVolumeSource(kind: Self.image, imageInfo: info)
    }

    public static func clone(from volumeId: UUID, format: String? = nil) -> DesiredVolumeSource {
        DesiredVolumeSource(kind: Self.clone, sourceVolumeId: volumeId, sourceFormat: format)
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

    public init(
        volumeId: UUID,
        desiredStatus: DesiredVolumeStatus,
        generation: Int64,
        sizeBytes: Int64,
        format: String,
        source: DesiredVolumeSource? = nil,
        attachment: DesiredVolumeAttachment? = nil
    ) {
        self.volumeId = volumeId
        self.desiredStatus = desiredStatus
        self.generation = generation
        self.sizeBytes = sizeBytes
        self.format = format
        self.source = source
        self.attachment = attachment
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
/// reorder (per-VM `generation` guards handle reordering). Sent on agent
/// registration, nudged on any desired-state change, and repeated on a timer as
/// the correctness backstop.
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
    /// than destroyed until a tombstone says otherwise). Decodes to `[]` from
    /// control planes older than the sandbox protocol; sandbox reconciliation
    /// is gated on `WireProtocol.supportsSandboxSync(envelope.senderVersion)`
    /// so such a sync isn't mistaken for "this host should have no
    /// sandboxes", exactly like the `networks` list before it.
    public let sandboxes: [DesiredSandboxState]
    /// The full authoritative set of logical networks that should exist on the
    /// receiving agent (full-list, same semantics as `vms`: a network omitted
    /// here should be torn down). Empty when the control plane is older than the
    /// network-reconciliation protocol, in which case the agent falls back to
    /// realizing switches implicitly from `vms`.
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
    /// freshly resolved artifact. Nil means "no opinion" — from control planes
    /// that predate the field, deployments without a meaningful target (dev
    /// builds), agents with auto-update off, and agents the fleet rollout has
    /// not reached yet. Never an instruction to downgrade or tear anything
    /// down, so absence is always safe.
    public let desiredAgentUpdate: DesiredAgentUpdate?
    /// The security groups the receiving agent needs realized as OVN port
    /// groups + ACLs: every group attached to a NIC of a VM in this sync's
    /// scope, plus the transitive closure of groups referenced by their rules
    /// (so `$pg_…` address-set references always resolve). Only the topology
    /// authority acts on this list; other agents consume just the per-NIC
    /// `NetworkSpec.securityGroupIds` for port membership. Nil from control
    /// planes that predate security groups — never "tear down all port
    /// groups": the authority skips security-group reconciliation entirely
    /// when the field is absent, exactly like the `networks` list before it.
    public let securityGroups: [DesiredSecurityGroup]?
    /// Workloads the receiving agent holds that the control plane has
    /// confirmed have no row, and which it therefore authorizes the agent to
    /// tear down (STR-98). Each entry is the answer to an
    /// `UnrecognizedWorkload` the agent reported, so a tombstone is always the
    /// second half of a round trip — never something the control plane
    /// volunteers. Nil from control planes that predate the field, which is
    /// then simply "nothing authorized": such a control plane never confirms a
    /// teardown, so a stray workload leaks rather than a live one dying.
    public let tombstones: [DesiredWorkloadTombstone]?
    /// The full authoritative set of volumes that should exist on the receiving
    /// agent (ADR 0001 stage 5, STR-148), with the same full-list semantics as
    /// `vms`.
    ///
    /// Optional rather than `[]`-defaulted, unlike `sandboxes` and `networks`,
    /// and that difference is load-bearing: nil means "the sender has no
    /// opinion about volumes", never "delete every volume on this host". A
    /// control plane older than v31 omits the key entirely, and the cost of
    /// misreading its silence is destroyed user data, so the payload describes
    /// itself instead of relying on a `wireProtocolVersion` lookup being right.
    /// The agent skips its whole volume half when this is nil.
    public let volumes: [DesiredVolumeState]?

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
        tombstones: [DesiredWorkloadTombstone]? = nil,
        volumes: [DesiredVolumeState]? = nil
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
    }

    // Custom decode so `networks` and `sandboxes` tolerate absence: a sync
    // produced by an older control plane (before each became first-class)
    // decodes to [] rather than throwing, keeping agent↔control-plane
    // compatible across version skew. `networksAuthoritative` likewise defaults
    // to true, matching every control plane older than the site/shared-NB
    // protocol (agents owned their local NB).
    // `encode(to:)` stays synthesized; all other keys remain required.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        syncId = try c.decode(String.self, forKey: .syncId)
        vms = try c.decode([DesiredVMState].self, forKey: .vms)
        sandboxes = try c.decodeIfPresent([DesiredSandboxState].self, forKey: .sandboxes) ?? []
        networks = try c.decodeIfPresent([DesiredNetworkState].self, forKey: .networks) ?? []
        networksAuthoritative = try c.decodeIfPresent(Bool.self, forKey: .networksAuthoritative) ?? true
        desiredAgentUpdate = try c.decodeIfPresent(DesiredAgentUpdate.self, forKey: .desiredAgentUpdate)
        securityGroups = try c.decodeIfPresent([DesiredSecurityGroup].self, forKey: .securityGroups)
        tombstones = try c.decodeIfPresent([DesiredWorkloadTombstone].self, forKey: .tombstones)
        volumes = try c.decodeIfPresent([DesiredVolumeState].self, forKey: .volumes)
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
    public let vmId: UUID
    /// The NIC's position in the VM's interface list (orderIndex), matching
    /// the index the agent used when naming the NIC's logical switch port.
    public let nicIndex: Int

    public init(externalIP: String, logicalIP: String, vmId: UUID, nicIndex: Int) {
        self.externalIP = externalIP
        self.logicalIP = logicalIP
        self.vmId = vmId
        self.nicIndex = nicIndex
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
    /// DNS resolvers advertised over DHCP; may be mixed-family (the agent
    /// splits per DHCP family). Nil ≙ pre-field control plane, like
    /// `dhcpEnabled`.
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
    /// reason: metadata edits don't bump VM generations, so a converged VM
    /// never re-realizes its NICs and the network reconcile is the only path
    /// that reaches a live network whose setting changed.
    ///
    /// Nil ≙ a control plane that predates the field: the agent neither creates
    /// nor *deletes* the port. The deletion half is load-bearing in a way it is
    /// not for `dhcpEnabled`, because network teardown is `observed − desired`:
    /// a nil that merely planned no port would read as "remove it", so a
    /// rollback would sweep every live metadata port. `false` is an opinion and
    /// *is* honored — that is what makes turning the feature off work. See
    /// `NetworkReconciler.metadataProtection(for:)`.
    public let metadataEnabled: Bool?
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
        generation: Int64,
        floatingIPs: [DesiredFloatingIP]? = nil
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
        self.generation = generation
        self.floatingIPs = floatingIPs
    }
}

// MARK: - Observed VM State

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

    public init(
        vmId: UUID,
        status: VMStatus,
        observedGeneration: Int64,
        convergencePhase: String? = nil,
        lastError: String? = nil,
        failedGeneration: Int64? = nil,
        guestInfo: GuestInfo? = nil,
        memoryStats: VMMemoryStats? = nil
    ) {
        self.vmId = vmId
        self.status = status
        self.observedGeneration = observedGeneration
        self.convergencePhase = convergencePhase
        self.lastError = lastError
        self.failedGeneration = failedGeneration
        self.guestInfo = guestInfo
        self.memoryStats = memoryStats
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
        exitCode: Int? = nil
    ) {
        self.sandboxId = sandboxId
        self.status = status
        self.observedGeneration = observedGeneration
        self.convergencePhase = convergencePhase
        self.lastError = lastError
        self.failedGeneration = failedGeneration
        self.exitCode = exitCode
    }
}

// MARK: - Observed Volume State

/// One volume's state as actually observed on an agent (ADR 0001 stage 5,
/// STR-148). Field semantics for the convergence quartet match
/// `ObservedVMState` — see the doc comments there.
///
/// There is deliberately no `sizeBytes`. Reading a volume's virtual size means
/// a `qemu-img info` subprocess per volume, and this report is assembled on
/// every convergence action plus the heartbeat cadence; on a dense host that is
/// not affordable. A resize is confirmed the same way a VM resize is, by
/// `observedGeneration` catching up.
///
/// ADR stage 7 (STR-149) settled the same question for the rest of what
/// `volume_info` used to return, and settled it the same way: nothing was
/// added. Format, path and attachment were already here; allocated bytes, the
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
    /// Where the agent put it. The agent owns path layout, so this is the only
    /// direction a volume path travels: the control plane stores what it is
    /// told and never derives one.
    public let storagePath: String?
    /// The format the volume actually has on disk ("qcow2"/"raw"), as detected
    /// rather than assumed.
    public let format: String?
    /// The VM this volume is attached to, from the agent's *durable attachment
    /// record* rather than a live hypervisor query. A powered-off guest has no
    /// QMP device list, and reporting "detached" for it would plan an attach
    /// against a dead control channel on every sync and degrade the volume for
    /// the crime of having a stopped VM.
    public let attachedVMId: UUID?
    public let deviceName: String?
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

    public init(
        volumeId: UUID,
        present: Bool,
        storagePath: String? = nil,
        format: String? = nil,
        attachedVMId: UUID? = nil,
        deviceName: String? = nil,
        observedGeneration: Int64,
        convergencePhase: String? = nil,
        lastError: String? = nil,
        failedGeneration: Int64? = nil
    ) {
        self.volumeId = volumeId
        self.present = present
        self.storagePath = storagePath
        self.format = format
        self.attachedVMId = attachedVMId
        self.deviceName = deviceName
        self.observedGeneration = observedGeneration
        self.convergencePhase = convergencePhase
        self.lastError = lastError
        self.failedGeneration = failedGeneration
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
    /// The workload's observed status, for the operator-facing log on the
    /// control plane ("holding a *running* VM nothing describes" reads very
    /// differently from holding a stopped one). Purely diagnostic.
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
    public let reason: String
    /// Where the unreadable manifest was copied for post-mortem, when the copy
    /// succeeded. The original is left in place — the agent refuses to write
    /// over a manifest it could not read.
    public let preservedCopyPath: String?

    public init(
        inventoryComplete: Bool,
        quarantinedEntries: Int,
        reason: String,
        preservedCopyPath: String? = nil
    ) {
        self.inventoryComplete = inventoryComplete
        self.quarantinedEntries = quarantinedEntries
        self.reason = reason
        self.preservedCopyPath = preservedCopyPath
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
    /// deletions are confirmed. Decodes to `[]` from agents older than the
    /// sandbox protocol — safe, because the control plane never places
    /// sandboxes on such agents in the first place.
    public let sandboxes: [ObservedSandboxState]
    public let resources: AgentResources
    /// Why the agent is not converging on its `DesiredAgentUpdate`, when one
    /// is desired and something is in the way (issue #434). Nil when no
    /// update is desired, when convergence is proceeding (the agent restarts
    /// into the new build rather than reporting progress), and from agents
    /// older than the field.
    public let agentUpdateStatus: ObservedAgentUpdateStatus?
    /// Workloads this agent holds that its last sync did not list (STR-98).
    /// They also appear in `vms`/`sandboxes` above — the agent really is
    /// running them — so this list is the agent asking "should these exist?",
    /// not a second inventory. Empty from agents older than the field, which
    /// still read omission as teardown.
    public let unrecognized: [UnrecognizedWorkload]
    /// Set when the blast-radius guard refused a sync's teardowns. Nil in the
    /// steady state and from agents older than the field.
    public let teardownRefusal: ObservedTeardownRefusal?
    /// Set when the agent's durable workload manifest could not be read in
    /// full (STR-138). Nil in the steady state and from agents older than the
    /// field. `inventoryComplete == false` suspends this report's full-list
    /// semantics — see `ObservedManifestStatus`.
    public let manifestStatus: ObservedManifestStatus?
    /// Volumes actually present on this agent (STR-148). Full-list, like
    /// `vms`: a volume missing from the list does not exist here, which is how
    /// volume deletions are confirmed.
    ///
    /// Optional rather than `[]`-defaulted, and that difference is the safety
    /// property: the control plane must read a missing list as "this agent has
    /// no opinion about volumes" rather than "every volume on this agent is
    /// gone" — which would reap every terminating volume row it holds and error
    /// every live one. Making the payload self-describing means a stale
    /// `wireProtocolVersion` on the agent row cannot cause that.
    ///
    /// Nil has two causes, and the control plane treats them identically
    /// because the right response to both is to do nothing: an agent older than
    /// v31 does not speak the field at all, and a v31 agent that cannot
    /// enumerate its volume store says so this way rather than claiming an
    /// empty inventory. The second is the volume counterpart of
    /// `manifestStatus.inventoryComplete == false`.
    public let volumes: [ObservedVolumeState]?

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
        volumes: [ObservedVolumeState]? = nil
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
    }

    // Custom decode so `sandboxes` and `unrecognized` tolerate absence: a
    // report produced by a pre-sandbox (or pre-STR-98) agent decodes to []
    // rather than throwing. `encode(to:)` stays synthesized; all other keys
    // remain required.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        agentId = try c.decode(String.self, forKey: .agentId)
        vms = try c.decode([ObservedVMState].self, forKey: .vms)
        sandboxes = try c.decodeIfPresent([ObservedSandboxState].self, forKey: .sandboxes) ?? []
        resources = try c.decode(AgentResources.self, forKey: .resources)
        agentUpdateStatus = try c.decodeIfPresent(ObservedAgentUpdateStatus.self, forKey: .agentUpdateStatus)
        unrecognized = try c.decodeIfPresent([UnrecognizedWorkload].self, forKey: .unrecognized) ?? []
        teardownRefusal = try c.decodeIfPresent(ObservedTeardownRefusal.self, forKey: .teardownRefusal)
        manifestStatus = try c.decodeIfPresent(ObservedManifestStatus.self, forKey: .manifestStatus)
        volumes = try c.decodeIfPresent([ObservedVolumeState].self, forKey: .volumes)
    }
}
