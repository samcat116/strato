import ControlPlanePostgres
import Foundation
import StratoShared
import Vapor

/// Immutable application view of one registered agent. Persistence decoding is
/// private to the agent store; callers replace values instead of sharing Fluent
/// dirty-tracking state across tasks.
struct Agent: Content, Sendable {
    static let schema = "agents"

    let id: UUID?

    let name: String

    /// SPIFFE trust domain the agent's SVID is issued in. The platform domain
    /// for every agent until per-org trust domains are switched on (issue
    /// #613); `(trust_domain, name)` is the agent's unique identity, because
    /// two organizations may each enroll an `agent-1`.
    let trustDomain: String

    let hostname: String

    let version: String

    let status: AgentStatus

    let totalCPU: Int

    let totalMemory: Int64

    let totalDisk: Int64

    let availableCPU: Int

    let availableMemory: Int64

    let availableDisk: Int64

    let lastHeartbeat: Date?

    let createdAt: Date?

    let updatedAt: Date?

    /// Host CPU architecture, nil for agents that registered before it was reported
    let architecture: String?

    /// Host operating system ("linux"/"macos"), nil for agents that registered
    /// before it was reported. The update endpoint needs it to resolve the
    /// per-OS/arch release artifact and refuses to guess when absent.
    let operatingSystem: String?

    /// Every hypervisor on the host with probed availability and capabilities
    let hypervisors: [HypervisorSupport]

    /// Host networking capability, nil for agents that registered before it was reported
    let networkCapability: String?

    /// Descriptive hardware/platform/OS details (CPU model, kernel version,
    /// distribution, physical core count, boot time, ...) the agent reports at
    /// registration, for operator display. Purely informational — nothing in
    /// scheduling or reconciliation reads it. Nil for agents that registered
    /// before host-info reporting.
    let hostInfo: HostInfo?

    /// The site (availability zone) this agent belongs to. Enrollment assigns
    /// this immutable placement before the row is first persisted.
    let siteID: UUID

    /// Wire protocol version the agent last registered with; nil for rows that
    /// predate this column. Sync assembly keys site topology authority on it:
    /// a pre-v4 agent ignores `networksAuthoritative` and would misread a
    /// non-authoritative empty sync as a full L3 teardown, so it must stay on
    /// legacy per-node scoping even when assigned to a site.
    let wireProtocolVersion: Int?

    /// Whether the agent advertised the sandbox runtime at its last
    /// registration (issue #415): Firecracker + KVM usable and the sandbox
    /// guest base image present on its disk. The scheduler gates sandbox
    /// placement on this explicit signal (combined with a v5+ wire protocol) —
    /// never on the protocol version alone, which a runtime-less build also
    /// speaks.
    let sandboxCapable: Bool

    /// Whether the agent advertised that it can realize a **sandbox NIC** at
    /// its last registration (STR-103): OVN networking, the jailer barrier, and
    /// an installed guest image that brings the interface up from the config
    /// drive. Strictly stronger than `sandboxCapable`, and separately reported
    /// because the guest image is a separately distributed artifact — no wire
    /// version and no other capability implies it.
    ///
    /// Read twice: the scheduler refuses to place a sandbox that has a NIC on a
    /// host without it, and desired-state assembly withholds
    /// `SandboxSpec.network` from such a host — which is what makes a mixed
    /// fleet safe to upgrade, since every sandbox NIC ever allocated has been
    /// waiting control-plane-side for this flag to exist.
    let sandboxNetworkingCapable: Bool

    /// Whether the agent advertised a usable `swtpm` at its last registration
    /// (issue #565), which is what lets it give a guest a TPM 2.0. The
    /// scheduler gates vTPM placement on this signal combined with a v17+ wire
    /// protocol — a v17 build on a host without swtpm understands the field but
    /// cannot realize it.
    let tpmCapable: Bool

    /// Whether the agent advertised a usable CoreDNS at its last registration
    /// (STR-40), which is what lets it answer on a network's resolver address.
    ///
    /// Unlike `sandboxCapable` and `tpmCapable` this does not gate *placement*
    /// — a host without CoreDNS still runs VMs perfectly well. It gates whether
    /// a network's resolver may be enabled at all, and it does so **site-wide**:
    /// the DHCP option that points guests at the resolver is authored once per
    /// network by the topology authority, while the listener is per chassis, so
    /// one incapable host in a site would give that network DNS that works
    /// until a VM lands somewhere else. Defaults false, so a fleet stays on the
    /// old behavior until every agent has re-registered and proved otherwise.
    let resolverCapable: Bool

    /// Whether the agent initialized its guest-facing instance metadata
    /// service at its last registration. Independent of overlay networking:
    /// an OVN host may have the service disabled or lack a required host tool.
    /// Defaults false so agents that have not advertised the capability cannot
    /// receive an IMDS-backed VM.
    let metadataServiceCapable: Bool

    /// Latest dependency-health snapshot from registration or heartbeat.
    let dependencyObservations: [NodeDependencyObservation]

    /// Control-plane time at which the latest dependency snapshot arrived.
    /// Agent clocks are not authoritative for placement freshness.
    let dependencyObservationsReceivedAt: Date?

    /// Owning organization (exactly one of organization / organizational unit;
    /// see `organizationScope`). Agents are dedicated capacity: the scheduler
    /// only places a VM on an agent whose root organization matches the VM's.
    /// Assigned via the registration token, durable on the row afterwards.
    let organizationID: UUID?

    let organizationalUnitID: UUID?

    /// Whether this agent is enrolled in declarative auto-update (issue
    /// #434): the fleet rollout may assign it the deployment's target version
    /// and the agent converges on its own. Default off — an update restarts
    /// the agent, so enrollment is an explicit operator decision.
    let autoUpdate: Bool

    /// The version this agent has been assigned, carried on its desired-state
    /// syncs as `desiredAgentUpdate` until the agent re-registers at it. Nil
    /// when nobody has an opinion (not enrolled, not reached, or already
    /// converged). Assigned either by the fleet rollout sweep or by an
    /// operator's "update now" — `updateAssignmentSource` says which.
    let updateDesiredVersion: String?

    /// Who assigned `updateDesiredVersion` (STR-145). Nil exactly when there is
    /// no assignment; a row written before this column existed reads as
    /// `.rollout`, which is what it was. The distinction is load-bearing in one
    /// place: the sweep resets a *rollout* assignment the deployment target has
    /// moved past, and must not do that to an operator's explicitly chosen
    /// version.
    let updateAssignmentSourceRaw: String?

    var updateAssignmentSource: AgentUpdateAssignmentSource? {
        guard updateDesiredVersion != nil else { return nil }
        return updateAssignmentSourceRaw.flatMap(AgentUpdateAssignmentSource.init(rawValue:)) ?? .rollout
    }

    /// The artifact an operator pinned to a manual assignment (`artifactUrl` +
    /// `sha256`, system-admin only). Nil for the release path, which is
    /// re-resolved at every sync assembly instead of stored — an override has no
    /// release to re-resolve from, so it rides the row.
    ///
    /// **The URL may be a credential.** Everything else that touches an artifact
    /// URL redacts it (`DesiredAgentUpdate.redactURL`) precisely because a
    /// presigned query token or userinfo is often the only way to authenticate a
    /// private mirror — and none of that redaction reaches a database column, a
    /// backup, or a read replica. So the assignment is the credential's lifetime:
    /// `clearUpdateAssignment()` drops it on convergence and withdrawal, and a
    /// terminal failure drops it too, rather than leaving a live token on a row
    /// whose update is never going to finish.
    let updateArtifactOverride: ResolvedAgentArtifact?

    /// When `updateDesiredVersion` was assigned — the health-budget clock: an
    /// assigned agent that neither converges nor reports a blocker within the
    /// budget halts the rollout.
    let updateAttemptedAt: Date?

    /// The agent's most recent self-reported reason for not converging on
    /// its assigned update (running Firecracker VMs, containerized install,
    /// reconcile work in flight). Cleared when the agent reports clean.
    let updateBlockedReason: String?

    /// A terminal update failure for the assigned version — either reported
    /// by the agent (download/checksum/swap failure) or recorded by the sweep
    /// when the agent went silent past its health budget. Any non-nil value
    /// for the current target halts the fleet rollout until an operator
    /// intervenes (or the target moves on).
    let updateFailureReason: String?

    /// Why this agent last refused to converge a sync's workload teardowns
    /// (STR-98 phase 2), as reported. Non-nil means the host is holding
    /// workloads the control plane authorized it to remove, because removing
    /// them all at once looked more like a control-plane failure than an
    /// intention. Cleared by the first report that carries no refusal.
    let teardownRefusalReason: String?

    /// When that refusal was last reported.
    let teardownRefusedAt: Date?

    /// What the agent last said about its durable workload manifest — its only
    /// memory of what it is running (STR-138). Non-nil means either that the
    /// manifest is unreadable (see `manifestInventoryComplete`) or that some
    /// entries in it are unroutable by the running build. Cleared by the first
    /// report that carries no manifest status.
    let manifestStatusReason: String?

    /// When that status was last reported.
    let manifestStatusAt: Date?

    /// False while the agent cannot enumerate its own workloads, which makes
    /// its observed-state reports carry no inventory at all: nothing may be
    /// concluded from a workload's absence from them. Nil is the steady state
    /// (and every pre-STR-138 agent), meaning reports are complete as they
    /// always were.
    let manifestInventoryComplete: Bool?

    init(
        id: UUID? = UUID(),
        name: String,
        trustDomain: String = PlatformTrustDomain.current,
        hostname: String,
        version: String,
        status: AgentStatus = .offline,
        resources: AgentResources,
        architecture: CPUArchitecture? = nil,
        architectureRaw: String? = nil,
        operatingSystem: String? = nil,
        hypervisors: [HypervisorSupport] = [],
        networkCapability: NetworkCapability? = nil,
        networkCapabilityRaw: String? = nil,
        hostInfo: HostInfo? = nil,
        siteID: UUID = UUID(),
        wireProtocolVersion: Int? = nil,
        sandboxCapable: Bool = false,
        sandboxNetworkingCapable: Bool = false,
        tpmCapable: Bool = false,
        resolverCapable: Bool = false,
        metadataServiceCapable: Bool = false,
        dependencyObservations: [NodeDependencyObservation] = [],
        dependencyObservationsReceivedAt: Date? = nil,
        organizationID: UUID? = nil,
        organizationalUnitID: UUID? = nil,
        autoUpdate: Bool = false,
        updateDesiredVersion: String? = nil,
        updateAssignmentSource: AgentUpdateAssignmentSource? = nil,
        updateAssignmentSourceRaw: String? = nil,
        updateArtifactOverride: ResolvedAgentArtifact? = nil,
        updateAttemptedAt: Date? = nil,
        updateBlockedReason: String? = nil,
        updateFailureReason: String? = nil,
        teardownRefusalReason: String? = nil,
        teardownRefusedAt: Date? = nil,
        manifestStatusReason: String? = nil,
        manifestStatusAt: Date? = nil,
        manifestInventoryComplete: Bool? = nil,
        lastHeartbeat: Date? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.trustDomain = trustDomain
        self.hostname = hostname
        self.version = version
        self.status = status
        self.totalCPU = resources.totalCPU
        self.totalMemory = resources.totalMemory
        self.totalDisk = resources.totalDisk
        self.availableCPU = resources.availableCPU
        self.availableMemory = resources.availableMemory
        self.availableDisk = resources.availableDisk
        self.architecture = architecture?.rawValue ?? architectureRaw
        self.operatingSystem = operatingSystem
        self.hypervisors = hypervisors
        self.networkCapability = networkCapability?.rawValue ?? networkCapabilityRaw
        self.hostInfo = hostInfo
        self.siteID = siteID
        self.wireProtocolVersion = wireProtocolVersion
        self.sandboxCapable = sandboxCapable
        self.sandboxNetworkingCapable = sandboxNetworkingCapable
        self.tpmCapable = tpmCapable
        self.resolverCapable = resolverCapable
        self.metadataServiceCapable = metadataServiceCapable
        self.dependencyObservations = dependencyObservations
        self.dependencyObservationsReceivedAt = dependencyObservationsReceivedAt
        self.organizationID = organizationID
        self.organizationalUnitID = organizationalUnitID
        self.autoUpdate = autoUpdate
        self.updateDesiredVersion = updateDesiredVersion
        self.updateAssignmentSourceRaw = updateAssignmentSource?.rawValue ?? updateAssignmentSourceRaw
        self.updateArtifactOverride = updateArtifactOverride
        self.updateAttemptedAt = updateAttemptedAt
        self.updateBlockedReason = updateBlockedReason
        self.updateFailureReason = updateFailureReason
        self.teardownRefusalReason = teardownRefusalReason
        self.teardownRefusedAt = teardownRefusedAt
        self.manifestStatusReason = manifestStatusReason
        self.manifestStatusAt = manifestStatusAt
        self.manifestInventoryComplete = manifestInventoryComplete
        self.lastHeartbeat = lastHeartbeat
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func requireID() throws -> UUID {
        guard let id else { throw Abort(.internalServerError, reason: "Agent has no identifier") }
        return id
    }

    @discardableResult
    func persisted(on db: PostgresStoreContext) async throws -> Self {
        try await LegacyAgentStore.upsert(self, on: db)
    }

    func save(on db: PostgresStoreContext) async throws {
        _ = try await persisted(on: db)
    }

    func delete(on db: PostgresStoreContext) async throws {
        guard let id else { return }
        _ = try await LegacyAgentStore.delete(id: id, on: db)
    }

    static func find(_ id: UUID?, on db: PostgresStoreContext) async throws -> Self? {
        try await LegacyAgentStore.agent(id: id, on: db)
    }

    static func all(on db: PostgresStoreContext) async throws -> [Self] {
        try await LegacyAgentStore.agents(on: db)
    }

    static func count(on db: PostgresStoreContext) async throws -> Int {
        try await LegacyAgentStore.count(on: db)
    }

    func replacing(
        name: String? = nil,
        trustDomain: String? = nil,
        hostname: String? = nil,
        version: String? = nil,
        status: AgentStatus? = nil,
        resources: AgentResources? = nil,
        architecture: String?? = nil,
        operatingSystem: String?? = nil,
        hypervisors: [HypervisorSupport]? = nil,
        networkCapability: String?? = nil,
        hostInfo: HostInfo?? = nil,
        siteID: UUID? = nil,
        wireProtocolVersion: Int?? = nil,
        sandboxCapable: Bool? = nil,
        sandboxNetworkingCapable: Bool? = nil,
        tpmCapable: Bool? = nil,
        resolverCapable: Bool? = nil,
        metadataServiceCapable: Bool? = nil,
        dependencyObservations: [NodeDependencyObservation]? = nil,
        dependencyObservationsReceivedAt: Date?? = nil,
        organizationID: UUID?? = nil,
        organizationalUnitID: UUID?? = nil,
        autoUpdate: Bool? = nil,
        updateDesiredVersion: String?? = nil,
        updateAssignmentSource: AgentUpdateAssignmentSource?? = nil,
        updateArtifactOverride: ResolvedAgentArtifact?? = nil,
        updateAttemptedAt: Date?? = nil,
        updateBlockedReason: String?? = nil,
        updateFailureReason: String?? = nil,
        teardownRefusalReason: String?? = nil,
        teardownRefusedAt: Date?? = nil,
        manifestStatusReason: String?? = nil,
        manifestStatusAt: Date?? = nil,
        manifestInventoryComplete: Bool?? = nil,
        lastHeartbeat: Date?? = nil
    ) -> Self {
        let nextResources = resources ?? self.resources
        let nextDesiredVersion = updateDesiredVersion ?? self.updateDesiredVersion
        let nextAssignmentSource = updateAssignmentSource ?? self.updateAssignmentSource
        return Self(
            id: id,
            name: name ?? self.name,
            trustDomain: trustDomain ?? self.trustDomain,
            hostname: hostname ?? self.hostname,
            version: version ?? self.version,
            status: status ?? self.status,
            resources: nextResources,
            architectureRaw: architecture ?? self.architecture,
            operatingSystem: operatingSystem ?? self.operatingSystem,
            hypervisors: hypervisors ?? self.hypervisors,
            networkCapabilityRaw: networkCapability ?? self.networkCapability,
            hostInfo: hostInfo ?? self.hostInfo,
            siteID: siteID ?? self.siteID,
            wireProtocolVersion: wireProtocolVersion ?? self.wireProtocolVersion,
            sandboxCapable: sandboxCapable ?? self.sandboxCapable,
            sandboxNetworkingCapable: sandboxNetworkingCapable ?? self.sandboxNetworkingCapable,
            tpmCapable: tpmCapable ?? self.tpmCapable,
            resolverCapable: resolverCapable ?? self.resolverCapable,
            metadataServiceCapable: metadataServiceCapable ?? self.metadataServiceCapable,
            dependencyObservations: dependencyObservations ?? self.dependencyObservations,
            dependencyObservationsReceivedAt:
                dependencyObservationsReceivedAt ?? self.dependencyObservationsReceivedAt,
            organizationID: organizationID ?? self.organizationID,
            organizationalUnitID: organizationalUnitID ?? self.organizationalUnitID,
            autoUpdate: autoUpdate ?? self.autoUpdate,
            updateDesiredVersion: nextDesiredVersion,
            updateAssignmentSource: nextAssignmentSource,
            updateArtifactOverride: updateArtifactOverride ?? self.updateArtifactOverride,
            updateAttemptedAt: updateAttemptedAt ?? self.updateAttemptedAt,
            updateBlockedReason: updateBlockedReason ?? self.updateBlockedReason,
            updateFailureReason: updateFailureReason ?? self.updateFailureReason,
            teardownRefusalReason: teardownRefusalReason ?? self.teardownRefusalReason,
            teardownRefusedAt: teardownRefusedAt ?? self.teardownRefusedAt,
            manifestStatusReason: manifestStatusReason ?? self.manifestStatusReason,
            manifestStatusAt: manifestStatusAt ?? self.manifestStatusAt,
            manifestInventoryComplete: manifestInventoryComplete ?? self.manifestInventoryComplete,
            lastHeartbeat: lastHeartbeat ?? self.lastHeartbeat,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func replacingOrganizationScope(_ scope: OrganizationScope?) -> Self {
        replacing(
            organizationID: .some(scope?.organizationID),
            organizationalUnitID: .some(scope?.organizationalUnitID))
    }

    /// Applies the mutable capacity fields from a periodic report and returns
    /// whether the row actually changed. Liveness timestamp policy belongs to
    /// `AgentService`, which can coalesce the heartbeat and observed-state
    /// messages that arrive on the same cadence.
    func updatingAvailableResources(_ resources: AgentResources) -> Self {
        replacing(resources: AgentResources(
            totalCPU: totalCPU,
            availableCPU: resources.availableCPU,
            totalMemory: totalMemory,
            availableMemory: resources.availableMemory,
            totalDisk: totalDisk,
            availableDisk: resources.availableDisk
        ))
    }

    var resources: AgentResources {
        return AgentResources(
            totalCPU: totalCPU,
            availableCPU: availableCPU,
            totalMemory: totalMemory,
            availableMemory: availableMemory,
            totalDisk: totalDisk,
            availableDisk: availableDisk
        )
    }
}

enum AgentStatus: String, Codable, CaseIterable, Sendable {
    case online = "online"
    case offline = "offline"
    case connecting = "connecting"
    case error = "error"
}

/// Who assigned an agent's `updateDesiredVersion` (STR-145). Both sources feed
/// the same declarative field — there is only one update path since wire v28 —
/// but they differ in who may reset the assignment.
enum AgentUpdateAssignmentSource: String, Codable, Sendable {
    /// The fleet auto-update sweep, advancing enrolled agents to the
    /// deployment's target version one at a time.
    case rollout = "rollout"
    /// An operator's `POST /api/agents/:id/actions/update`. Needs no
    /// auto-update enrollment, may carry an explicit artifact, and is never
    /// reset as "stale" — the version was chosen deliberately.
    case manual = "manual"
}

extension Agent {
    /// Assigns an update, writing every field the assignment consists of at
    /// once. Both assigners go through here rather than setting the fields
    /// themselves, because `updateAssignmentSource` reads as nil without a
    /// version: written in the other order, a manual assignment would read back
    /// as `.rollout` and be swept away as stale — silently, at the next tick.
    /// Callers save.
    func assigningUpdate(
        version: String,
        source: AgentUpdateAssignmentSource,
        artifact: ResolvedAgentArtifact? = nil,
        at now: Date = Date()
    ) -> Self {
        replacing(
            updateDesiredVersion: .some(version),
            updateAssignmentSource: .some(source),
            updateArtifactOverride: .some(artifact),
            updateAttemptedAt: .some(now),
            updateBlockedReason: .some(nil),
            updateFailureReason: .some(nil))
    }

    /// Clears every update-assignment field: the version, who assigned it, any
    /// pinned artifact, the health-budget clock, and the reported
    /// blocker/failure. Used when the assignment converges, when its target
    /// goes stale, when an operator cancels it, and when an operator withdraws
    /// auto-update. Callers save.
    func clearingUpdateAssignment() -> Self {
        replacing(
            updateDesiredVersion: .some(nil),
            updateAssignmentSource: .some(nil),
            updateArtifactOverride: .some(nil),
            updateAttemptedAt: .some(nil),
            updateBlockedReason: .some(nil),
            updateFailureReason: .some(nil))
    }

    /// Records a terminal failure for the current assignment. The assignment
    /// itself stays — it is what an operator sees, and what a returning agent
    /// could still converge on if the blocker was environmental — but the
    /// pinned artifact goes, because it may carry a presigned credential and
    /// this update is not finishing on its own. Re-issuing the update supplies
    /// a fresh one. Callers save.
    func recordingUpdateFailure(_ reason: String) -> Self {
        replacing(
            updateArtifactOverride: .some(nil),
            updateBlockedReason: .some(nil),
            updateFailureReason: .some(reason))
    }
}

// MARK: - Agent Extensions for Registration

extension Agent {
    /// Create an agent from registration message
    static func from(
        registration: AgentRegisterMessage,
        name: String,
        trustDomain: String = PlatformTrustDomain.current
    ) -> Agent {
        Agent(
            name: name,
            trustDomain: trustDomain,
            hostname: registration.hostname,
            version: registration.version,
            status: .connecting,
            resources: registration.resources,
            architecture: registration.architecture,
            operatingSystem: registration.operatingSystem?.rawValue,
            hypervisors: registration.effectiveHypervisors,
            networkCapability: registration.networkCapability,
            hostInfo: registration.hostInfo,
            sandboxCapable: registration.sandboxCapable ?? false,
            sandboxNetworkingCapable: registration.sandboxNetworkingCapable ?? false,
            tpmCapable: registration.tpmCapable ?? false,
            resolverCapable: registration.resolverCapable ?? false,
            metadataServiceCapable: registration.metadataServiceCapable ?? false,
            dependencyObservations: registration.dependencyObservations,
            lastHeartbeat: Date()
        )
    }

    /// The agent's identity — the key its socket, presence and route are stored
    /// under. Never key agent state by `name` alone.
    var identity: AgentIdentity {
        AgentIdentity(trustDomain: trustDomain, name: name)
    }

    /// Check if agent is considered online based on heartbeat
    var isOnline: Bool {
        guard let lastHeartbeat = lastHeartbeat else { return false }
        return Date().timeIntervalSince(lastHeartbeat) < 60  // 60 seconds timeout
    }

    /// Host CPU architecture as a typed value; nil for agents that registered
    /// before architecture reporting (or an unrecognized raw value).
    var cpuArchitecture: CPUArchitecture? {
        architecture.flatMap(CPUArchitecture.init(rawValue:))
    }

    /// Host operating system as a typed value; nil for agents that registered
    /// before OS reporting (or an unrecognized raw value).
    var hostOperatingSystem: OperatingSystem? {
        operatingSystem.flatMap(OperatingSystem.init(rawValue:))
    }

    /// Dependency samples older than three heartbeat intervals fail closed for
    /// new work even while the WebSocket and agent row remain online.
    static let dependencyObservationStaleAfter: TimeInterval = 60

    /// Whether every fresh dependency affecting `capability` permits new work.
    func dependencyAllows(_ capability: NodeCapability, at now: Date = Date()) -> Bool {
        let relevant = dependencyObservations.filter { $0.affectedCapabilities.contains(capability) }
        guard !relevant.isEmpty, let receivedAt = dependencyObservationsReceivedAt else { return false }
        return relevant.allSatisfy {
            $0.allowsNewWork(
                receivedAt: receivedAt,
                at: now,
                staleAfter: Self.dependencyObservationStaleAfter)
        }
    }

    /// Hypervisor backends this agent can actually run. Agents probe each
    /// backend before reporting it, so an empty list means the agent cannot
    /// run VMs at all — it stays registered but is never eligible for
    /// placement. No QEMU fallback here: assuming QEMU for an empty list
    /// would defeat the agent-side probe in exactly the case it exists for.
    var supportedHypervisors: [HypervisorType] {
        hypervisors.filter { support in
            guard support.available else { return false }
            return support.type != .qemu || dependencyAllows(.qemuPlacement)
        }.map(\.type)
    }

    /// Whether this agent proved that its usable QEMU backend can attach a
    /// host-backed virtio-vsock device. Missing capability is fail-closed so
    /// registrations persisted before the probe do not attract guest-agent
    /// VMs.
    var supportsVsock: Bool {
        hypervisors.contains {
            $0.type == .qemu && $0.available && $0.supportsVsock == true
        }
    }

    /// Whether the agent explicitly advertised a node-agent guest-exec bridge
    /// for the requested VM backend. Vsock support is necessary but not
    /// sufficient: until STR-82 lands, current agents attach the device but
    /// deliberately reject `.virtualMachine` exec messages.
    func supportsGuestExec(for hypervisor: HypervisorType) -> Bool {
        hypervisors.contains {
            $0.type == hypervisor && $0.available && $0.supportsGuestExec == true
        }
    }

    /// Only OVN-backed agents can provide VM-to-VM networking; user-mode
    /// (SLIRP) agents cannot. Absence is not capability.
    var supportsInterVMNetworking: Bool {
        networkCapability.flatMap(NetworkCapability.init(rawValue:)) == .overlay
            && dependencyAllows(.overlayNetworking)
    }

    var effectiveSandboxNetworkingCapable: Bool {
        sandboxNetworkingCapable && dependencyAllows(.sandboxNetworking)
    }

    var effectiveResolverCapable: Bool {
        resolverCapable && dependencyAllows(.networkResolver)
    }

    /// Whether the structured registration report proves that this agent can
    /// capture and restore one snapshot artifact family.
    ///
    /// QEMU owns VM checkpoints and volume overlays. Sandbox checkpoints need
    /// both Firecracker snapshot support and the separately probed sandbox
    /// runtime; a Firecracker binary alone cannot load Strato's guest image.
    func supportsSnapshotArtifact(_ kind: SnapshotArtifactKind) -> Bool {
        let backend: HypervisorType
        switch kind {
        case .volumeSnapshot, .vmCheckpoint:
            backend = .qemu
        case .sandboxSnapshot:
            guard sandboxCapable else { return false }
            backend = .firecracker
        }

        return hypervisors.contains {
            $0.type == backend && $0.available && $0.capabilities.supportsSnapshots
                && (backend != .qemu || dependencyAllows(.qemuPlacement))
        }
    }

    /// The status clients should see after accounting for heartbeat age.
    ///
    /// This is deliberately non-mutating: GET endpoints use it when building
    /// response DTOs, while registration/heartbeat handling and the stale-agent
    /// monitor own durable status transitions.
    var statusBasedOnHeartbeat: AgentStatus {
        if isOnline && status == .offline {
            return .online
        } else if !isOnline && status == .online {
            return .offline
        }
        return status
    }

    /// The agent's org-or-OU owner; nil only for rows that predate mandatory
    /// scoping and were never backfilled (a fresh install has none).
    var organizationScope: OrganizationScope? {
        if let orgID = self.organizationID { return .organization(orgID) }
        if let ouID = self.organizationalUnitID { return .organizationalUnit(ouID) }
        return nil
    }

    /// The root organization the agent is dedicated to (OU scope resolves to
    /// its owning org). Placement compares this against the VM project's root.
    func rootOrganizationID(on db: PostgresStoreContext) async throws -> UUID? {
        try await organizationScope?.rootOrganizationID(on: db)
    }

    /// Whether this agent hosts a VM, sandbox, or volume whose project belongs
    /// to a different organization than the agent itself.
    ///
    /// Until the scheduler and volume placement enforce org-scoped placement
    /// (phase 2 of the hierarchy overhaul), an agent may host workloads from
    /// another tenant: cross-org placements from before scoping, or new ones
    /// the still-unscoped placement paths make. A delegated org admin must not
    /// be able to take down another tenant's workloads or strand its detached
    /// volumes, which is what the tier-1 `platform-agent-foreign-workloads`
    /// forbid keys on.
    ///
    /// Projects are resolved once each rather than once per workload: a busy
    /// agent hosts many VMs from few projects.
    func hostsForeignWorkloads(on db: PostgresStoreContext) async throws -> Bool {
        let agentOrg = try await rootOrganizationID(on: db)
        let agentIDString = try requireID().uuidString

        var projectIDs: Set<UUID> = []
        projectIDs.formUnion(
            try await LegacyVMStore.vms(hypervisorID: agentIDString, on: db).map(\.projectID))
        projectIDs.formUnion(
            try await LegacySandboxStore.sandboxes(hypervisorID: agentIDString, on: db).map(\.projectID))
        let volumeIDs = try await LegacyVolumeReplicaStore.replicas(
            agentId: agentIDString,
            states: VolumeService.authoritativeReplicaStates,
            on: db
        ).map(\.volumeID)
        if !volumeIDs.isEmpty {
            projectIDs.formUnion(
                try await LegacyVolumeStore.volumes(ids: Array(Set(volumeIDs)), on: db)
                    .map(\.projectID))
        }

        for projectID in projectIDs {
            guard let project = try await Project.find(projectID, on: db) else { continue }
            let projectOrg = try await project.getRootOrganizationId(on: db)
            if projectOrg != agentOrg { return true }
        }
        return false
    }
}

// MARK: - DTO for API responses

struct AgentResponse: Content {
    let id: UUID
    let name: String
    let hostname: String
    let version: String
    let status: AgentStatus
    let resources: AgentResources
    let architecture: CPUArchitecture?
    let operatingSystem: OperatingSystem?
    let hypervisors: [HypervisorSupport]
    let networkCapability: NetworkCapability?
    let sandboxCapable: Bool
    /// Whether a sandbox on this host can have a NIC (STR-103) — it advertised
    /// OVN, the jailer barrier, and a networking-capable guest image at its
    /// last registration. Always false when `sandboxCapable` is.
    let sandboxNetworkingCapable: Bool
    /// Whether this host can back a guest TPM 2.0 (issue #565) — it advertised
    /// a usable swtpm at its last registration.
    let tpmCapable: Bool
    /// Whether this host can run the per-network DNS resolver (STR-40).
    let resolverCapable: Bool
    /// Whether this host initialized the guest-facing instance metadata
    /// service. IMDS-backed VMs only place on nodes reporting true.
    let metadataServiceCapable: Bool
    /// Fresh dependency health used for feature-scoped placement gates.
    let dependencyObservations: [NodeDependencyObservation]
    /// Control-plane receipt time used to determine snapshot freshness.
    let dependencyObservationsReceivedAt: Date?
    /// Descriptive hardware/platform/OS details for operator display; nil for
    /// agents that registered before host-info reporting.
    let hostInfo: HostInfo?
    let siteId: UUID
    let organizationId: UUID?
    let organizationalUnitId: UUID?
    let lastHeartbeat: Date?
    let createdAt: Date?
    let isOnline: Bool
    /// The version this agent should be running (see `AgentVersionTarget`);
    /// nil when the deployment has no meaningful target (dev builds).
    let targetVersion: String?
    let updateAvailable: Bool
    /// Declarative auto-update enrollment and rollout state (issue #434).
    let autoUpdate: Bool
    /// The version this agent has been assigned, while it is converging; nil
    /// once converged (or never assigned). Present for an operator's "update
    /// now" as much as for the fleet rollout — since STR-145 both assign this
    /// same field — so it is not conditional on `autoUpdate`.
    let updateDesiredVersion: String?
    /// Who assigned it: `rollout` or `manual`. Nil exactly when there is no
    /// assignment.
    let updateAssignmentSource: String?
    let updateAttemptedAt: Date?
    /// The agent's self-reported reason for not converging yet.
    let updateBlockedReason: String?
    /// Terminal failure that halted the rollout at this agent, if any.
    let updateFailureReason: String?
    /// Why the agent last refused to converge a sync's workload teardowns
    /// (STR-98); nil in the steady state.
    let teardownRefusalReason: String?
    let teardownRefusedAt: Date?
    /// What the agent last reported about its workload manifest (STR-138); nil
    /// in the steady state. Non-nil is always operator-actionable: either the
    /// host is quarantined because it cannot read the manifest, or it is
    /// holding workloads this agent build cannot route.
    let manifestStatusReason: String?
    let manifestStatusAt: Date?
    /// False while this agent cannot enumerate its own workloads. Its capacity
    /// reads as zero and it converges nothing until the manifest is repaired.
    let manifestInventoryComplete: Bool?
    /// Workloads this agent holds that no desired-state sync accounts for and
    /// whose teardown the control plane refused to authorize, because a row
    /// still exists for them. Non-empty means the control plane is describing
    /// this host incorrectly — most often that the node re-enrolled under a
    /// new agent record and its workloads are still placed on the old one, in
    /// which case `placedOnAgentId` names it and the workloads can be adopted.
    ///
    /// Populated by the detail endpoint only; nil (not empty) in list
    /// responses, which don't pay for the query.
    let heldWorkloads: [HeldWorkloadSummary]?

    /// One workload an agent holds that the control plane will not authorize
    /// tearing down.
    struct HeldWorkloadSummary: Content, Sendable {
        let kind: String
        let id: UUID
        /// The workload's observed status on the agent.
        let status: String?
        /// `row_present_here` or `row_on_agent:<uuid>`.
        let reason: String?
        /// The agent record the workload's row is currently placed on, when
        /// that is a different record than the one holding it.
        let placedOnAgentId: String?
        let firstSeenAt: Date?

        init(from claim: HeldWorkloadClaimSnapshot) {
            self.kind = claim.resourceKind
            self.id = claim.resourceID
            self.status = claim.observedStatus
            self.reason = claim.reason
            self.placedOnAgentId = claim.placedOnAgentID
            self.firstSeenAt = claim.firstSeenAt
        }
    }

    init(
        from agent: Agent,
        targetVersion: String?,
        heldWorkloads: [HeldWorkloadSummary]? = nil
    ) throws {
        guard let id = agent.id else {
            throw Abort(.internalServerError, reason: "Agent missing ID")
        }

        self.id = id
        self.name = agent.name
        self.hostname = agent.hostname
        self.version = agent.version
        self.status = agent.statusBasedOnHeartbeat
        self.resources = agent.resources
        self.architecture = agent.architecture.flatMap(CPUArchitecture.init(rawValue:))
        self.operatingSystem = agent.hostOperatingSystem
        self.hypervisors = agent.hypervisors
        self.networkCapability = agent.networkCapability.flatMap(NetworkCapability.init(rawValue:))
        self.sandboxCapable = agent.sandboxCapable
        self.sandboxNetworkingCapable = agent.effectiveSandboxNetworkingCapable
        self.tpmCapable = agent.tpmCapable
        self.resolverCapable = agent.effectiveResolverCapable
        self.metadataServiceCapable = agent.metadataServiceCapable
        self.dependencyObservations = agent.dependencyObservations
        self.dependencyObservationsReceivedAt = agent.dependencyObservationsReceivedAt
        self.hostInfo = agent.hostInfo
        self.siteId = agent.siteID
        self.organizationId = agent.organizationID
        self.organizationalUnitId = agent.organizationalUnitID
        self.lastHeartbeat = agent.lastHeartbeat
        self.createdAt = agent.createdAt
        self.isOnline = agent.isOnline
        self.targetVersion = targetVersion
        self.updateAvailable = AgentVersionTarget.updateAvailable(
            agentVersion: agent.version,
            target: targetVersion
        )
        self.autoUpdate = agent.autoUpdate
        self.updateDesiredVersion = agent.updateDesiredVersion
        self.updateAssignmentSource = agent.updateAssignmentSource?.rawValue
        self.updateAttemptedAt = agent.updateAttemptedAt
        self.updateBlockedReason = agent.updateBlockedReason
        self.updateFailureReason = agent.updateFailureReason
        self.teardownRefusalReason = agent.teardownRefusalReason
        self.teardownRefusedAt = agent.teardownRefusedAt
        self.manifestStatusReason = agent.manifestStatusReason
        self.manifestStatusAt = agent.manifestStatusAt
        self.manifestInventoryComplete = agent.manifestInventoryComplete
        self.heldWorkloads = heldWorkloads
    }

    init(
        from agent: AgentSnapshot,
        targetVersion: String?,
        heldWorkloads: [HeldWorkloadSummary]? = nil
    ) throws {
        guard let status = AgentStatus(rawValue: agent.statusBasedOnHeartbeat) else {
            throw Abort(.internalServerError, reason: "Agent has invalid status '\(agent.status)'")
        }
        self.id = agent.id
        self.name = agent.name
        self.hostname = agent.hostname
        self.version = agent.version
        self.status = status
        self.resources = agent.resources
        self.architecture = agent.architecture.flatMap(CPUArchitecture.init(rawValue:))
        self.operatingSystem = agent.operatingSystem.flatMap(OperatingSystem.init(rawValue:))
        self.hypervisors = agent.hypervisors
        self.networkCapability = agent.networkCapability.flatMap(NetworkCapability.init(rawValue:))
        self.sandboxCapable = agent.sandboxCapable
        self.sandboxNetworkingCapable = agent.effectiveSandboxNetworkingCapable
        self.tpmCapable = agent.tpmCapable
        self.resolverCapable = agent.effectiveResolverCapable
        self.metadataServiceCapable = agent.metadataServiceCapable
        self.dependencyObservations = agent.dependencyObservations
        self.dependencyObservationsReceivedAt = agent.dependencyObservationsReceivedAt
        self.hostInfo = agent.hostInfo
        self.siteId = agent.siteID
        self.organizationId = agent.organizationID
        self.organizationalUnitId = agent.organizationalUnitID
        self.lastHeartbeat = agent.lastHeartbeat
        self.createdAt = agent.createdAt
        self.isOnline = agent.isOnline
        self.targetVersion = targetVersion
        self.updateAvailable = AgentVersionTarget.updateAvailable(
            agentVersion: agent.version,
            target: targetVersion
        )
        self.autoUpdate = agent.autoUpdate
        self.updateDesiredVersion = agent.updateDesiredVersion
        if agent.updateDesiredVersion == nil {
            self.updateAssignmentSource = nil
        } else {
            self.updateAssignmentSource = agent.updateAssignmentSource ?? "rollout"
        }
        self.updateAttemptedAt = agent.updateAttemptedAt
        self.updateBlockedReason = agent.updateBlockedReason
        self.updateFailureReason = agent.updateFailureReason
        self.teardownRefusalReason = agent.teardownRefusalReason
        self.teardownRefusedAt = agent.teardownRefusedAt
        self.manifestStatusReason = agent.manifestStatusReason
        self.manifestStatusAt = agent.manifestStatusAt
        self.manifestInventoryComplete = agent.manifestInventoryComplete
        self.heldWorkloads = heldWorkloads
    }
}
