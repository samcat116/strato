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
    /// have the VM can materialize it. Signed URLs are re-issued on every sync
    /// assembly, so a long-lived desired entry never carries an expired link.
    public let imageInfo: ImageInfo?

    public init(
        vmId: UUID,
        hypervisorType: HypervisorType,
        spec: VMSpec,
        desiredStatus: DesiredVMStatus,
        generation: Int64,
        imageInfo: ImageInfo? = nil
    ) {
        self.vmId = vmId
        self.hypervisorType = hypervisorType
        self.spec = spec
        self.desiredStatus = desiredStatus
        self.generation = generation
        self.imageInfo = imageInfo
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

// MARK: - Desired Agent Update

/// The agent build the control plane wants this agent to be running, carried
/// on the desired-state sync (issue #434) — the declarative complement to the
/// imperative `AgentUpdateMessage`. Artifact URL and checksum are resolved
/// fresh at sync assembly, like signed image URLs, so a long-desired update
/// never carries a stale link.
///
/// Level-triggered and idempotent: an agent already running `targetVersion`
/// diffs this to nothing, and absence of the field means "no opinion" — never
/// "downgrade". The agent converges through the same download/verify/swap/
/// restart path as the imperative update, but only when its local
/// preconditions hold (not containerized, no in-flight reconcile work);
/// otherwise it reports why via `ObservedStateReport.agentUpdateStatus` and
/// retries on later syncs.
public struct DesiredAgentUpdate: Codable, Sendable {
    /// The version the agent should be running. Informational to the updater
    /// (the artifact decides what is installed) but the agent uses it to
    /// no-op when already converged and to label its status reports.
    public let targetVersion: String
    /// Where to download the artifact. May be presigned — treat the query
    /// string as a credential (see `AgentUpdateMessage.redactURL`).
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
        AgentUpdateMessage.redactURL(artifactURL)
    }
}

/// Control plane → agent: the full authoritative set of VMs that should exist
/// on the receiving agent.
///
/// Full-list semantics make the message level-triggered and idempotent: a VM
/// omitted from the list should not exist on the agent, identical syncs diff
/// to nothing, and the message is safe to drop, replay, or reorder (per-VM
/// `generation` guards handle reordering). Sent on agent registration, nudged
/// on any desired-state change, and repeated on a timer as the correctness
/// backstop.
public struct DesiredStateMessage: WebSocketMessage {
    public var type: MessageType { .desiredState }
    public let requestId: String
    public let timestamp: Date
    /// Correlation id for logging/tracing a sync end to end. No semantics.
    public let syncId: String
    public let vms: [DesiredVMState]
    /// The full authoritative set of sandboxes that should exist on the
    /// receiving agent (full-list, same semantics as `vms`: a sandbox omitted
    /// here should not exist). Decodes to `[]` from control planes older than
    /// the sandbox protocol — which the agent must NOT read as "tear down all
    /// sandboxes": sandbox reconciliation is gated on
    /// `WireProtocol.supportsSandboxSync(envelope.senderVersion)`, exactly like
    /// the `networks` list before it.
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

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        syncId: String = UUID().uuidString,
        vms: [DesiredVMState],
        sandboxes: [DesiredSandboxState] = [],
        networks: [DesiredNetworkState] = [],
        networksAuthoritative: Bool = true,
        desiredAgentUpdate: DesiredAgentUpdate? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.syncId = syncId
        self.vms = vms
        self.sandboxes = sandboxes
        self.networks = networks
        self.networksAuthoritative = networksAuthoritative
        self.desiredAgentUpdate = desiredAgentUpdate
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
/// logical router (giving cross-switch east-west), keyed by `routerKey`. A
/// project-less (global) network keys its router on its own id, so it still gets
/// outbound SNAT without joining a shared router.
public struct DesiredNetworkState: Codable, Sendable {
    public let networkId: UUID
    /// OVN logical switch name (matches `NetworkSpec.network` on VM NICs).
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

    public init(
        vmId: UUID,
        status: VMStatus,
        observedGeneration: Int64,
        convergencePhase: String? = nil,
        lastError: String? = nil,
        failedGeneration: Int64? = nil
    ) {
        self.vmId = vmId
        self.status = status
        self.observedGeneration = observedGeneration
        self.convergencePhase = convergencePhase
        self.lastError = lastError
        self.failedGeneration = failedGeneration
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

/// Agent → control plane: everything the agent actually has, with resources.
///
/// Full-list semantics mirror `DesiredStateMessage`: a VM missing from `vms`
/// does not exist on this agent, which is how deletions are confirmed. Sent
/// immediately after any convergence action and piggybacked on the heartbeat
/// cadence, so state converges quickly after changes but is also periodically
/// re-asserted.
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

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        agentId: String,
        vms: [ObservedVMState],
        sandboxes: [ObservedSandboxState] = [],
        resources: AgentResources,
        agentUpdateStatus: ObservedAgentUpdateStatus? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.agentId = agentId
        self.vms = vms
        self.sandboxes = sandboxes
        self.resources = resources
        self.agentUpdateStatus = agentUpdateStatus
    }

    // Custom decode so `sandboxes` tolerates absence: a report produced by a
    // pre-sandbox agent decodes to [] rather than throwing. `encode(to:)`
    // stays synthesized; all other keys remain required.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        agentId = try c.decode(String.self, forKey: .agentId)
        vms = try c.decode([ObservedVMState].self, forKey: .vms)
        sandboxes = try c.decodeIfPresent([ObservedSandboxState].self, forKey: .sandboxes) ?? []
        resources = try c.decode(AgentResources.self, forKey: .resources)
        agentUpdateStatus = try c.decodeIfPresent(ObservedAgentUpdateStatus.self, forKey: .agentUpdateStatus)
    }
}
