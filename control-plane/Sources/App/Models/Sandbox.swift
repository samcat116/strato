import Fluent
import Vapor
import StratoShared

/// A sandbox: a microVM booted from an OCI image on Firecracker (issue #410).
/// Deliberately its own table and API surface — parallel to `VM`, not a VM
/// variant — so the two workload types can diverge. Mirrors the VM's
/// desired/observed state split (issue #260): `status` is purely observed,
/// `desiredStatus` is the goal written by API mutations, and the generation
/// pair tracks agent convergence.
final class Sandbox: Model, @unchecked Sendable {
    static let schema = "sandboxes"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Parent(key: "project_id")
    var project: Project

    @Field(key: "environment")
    var environment: String

    /// OCI image reference as provided by the user (`ghcr.io/acme/worker:v3`).
    /// Kept verbatim for identity and logging; agents converge on
    /// `imageDigest` once tag→digest resolution lands (issue #414).
    @Field(key: "image")
    var image: String

    /// Manifest digest (`sha256:...`) the reference resolved to. Populated by
    /// tag→digest resolution (issue #414); nil until then, in which case the
    /// agent resolves the tag itself, accepting the mutability.
    @OptionalField(key: "image_digest")
    var imageDigest: String?

    @Field(key: "vcpus")
    var cpus: Int

    /// Guest memory size in bytes.
    @Field(key: "memory")
    var memory: Int64

    /// Entrypoint/cmd/env/workdir overrides over the OCI image config, applied
    /// by the guest agent (override wins on key collision).
    @OptionalField(key: "entrypoint")
    var entrypoint: [String]?

    @OptionalField(key: "cmd")
    var cmd: [String]?

    @Field(key: "env")
    var env: [String: String]

    @OptionalField(key: "working_dir")
    var workingDir: String?

    /// Lifetime budget in seconds, counted from `createdAt` (see `expiresAt`).
    /// The expiry sweep deletes the sandbox once the budget runs out; nil
    /// means the sandbox lives until something else removes it.
    @OptionalField(key: "ttl_seconds")
    var ttlSeconds: Int?

    /// The agent this sandbox is placed on, written by the scheduler.
    @OptionalField(key: "hypervisor_id")
    var hypervisorId: String?

    /// Durable lineage for a fork (issue #427). Kept as an opaque id rather
    /// than a foreign key so database cascade rules can never delete a fork;
    /// the controller protects live lineage explicitly.
    @OptionalField(key: "restored_from_snapshot_id")
    var restoredFromSnapshotId: UUID?

    /// Firecracker CPU template the microVM boots with, decided at create
    /// time (issue #428) because it is baked into every checkpoint's guest
    /// state: a templated snapshot restores on any same-arch host whose
    /// Firecracker honours the template, while a nil (passthrough) snapshot
    /// only restores on identical CPU models. Immutable after create.
    @OptionalField(key: "cpu_template")
    var cpuTemplate: String?

    /// The sandbox's NICs (single-NIC in v1), allocated at create time by the
    /// same IPAM as VMs (issue #416). Requires eager loading with
    /// `.with(\.$networkInterfaces)`.
    @Children(for: \.$sandbox)
    var networkInterfaces: [SandboxNetworkInterface]

    // Observed state, written only from agent reports (plus the diagnostic
    // escalations in the sweeps).
    @Enum(key: "status")
    var status: SandboxStatus

    /// When `status` last changed. Used by the reconciliation sweep to detect
    /// sandboxes stuck in a transitional state past a timeout.
    @OptionalField(key: "status_changed_at")
    var statusChangedAt: Date?

    /// Exit code of a workload that ran to completion (`status == .exited`),
    /// as reported by the agent.
    @OptionalField(key: "exit_code")
    var exitCode: Int?

    // Desired state, written by API mutations. Same contract as VM:
    // `generation` bumps on every desired change and `observedGeneration`
    // records the last generation the owning agent confirmed converging to.
    @Enum(key: "desired_status")
    var desiredStatus: DesiredSandboxStatus

    @Field(key: "generation")
    var generation: Int64

    @Field(key: "observed_generation")
    var observedGeneration: Int64

    // Restore as an edge-nonce (ADR 0001 stage 9, STR-151). "Be at snapshot S"
    // is not something an agent can re-converge on — the guest starts writing
    // the moment it resumes — so what rides the sync is a *count* of how many
    // times a restore was asked for, applied once against the agent's durable
    // record. There is no reboot counterpart: `POST .../restart` is expressed as
    // a fresh desired-running generation rather than an edge.
    //
    // Distinct from `restoredFromSnapshotId` above, which they are easy to
    // confuse and must not be: that records the checkpoint this sandbox was
    // *forked from* at create time — a lineage fact, and the clone-safety
    // guard's whole input — while this drives a rewind of a sandbox that
    // already exists.
    @Field(key: "restore_generation")
    var restoreGeneration: Int64

    /// The snapshot `restoreGeneration` names. Not a foreign key, for
    /// `VM.restoreSnapshotID`'s reason.
    @OptionalField(key: "restore_snapshot_id")
    var restoreSnapshotID: UUID?

    // Convergence progress mirrored from the agent's observed-state report,
    // with the same contract as the VM's (STR-142): `convergencePhase` is
    // non-nil only while the agent is actively converging toward a newer
    // generation, and the error pair records the last failed attempt until a
    // successful convergence clears it. Projected as the API's `conditions`
    // block.
    @OptionalField(key: "convergence_phase")
    var convergencePhase: String?

    @OptionalField(key: "last_error")
    var lastError: String?

    @OptionalField(key: "failed_generation")
    var failedGeneration: Int64?

    /// When the current error/generation pair was first observed. Stable while
    /// identical heartbeats repeat it, and cleared by successful convergence.
    @OptionalField(key: "last_error_at")
    var lastErrorAt: Date?

    /// Internal claim for the sustained-divergence warning. Nil starts a new
    /// episode; the sweep atomically stamps it before logging.
    @OptionalField(key: "divergence_detected_at")
    var divergenceDetectedAt: Date?

    /// When the stuck-convergence sweep marks this sandbox degraded — the VM
    /// contract exactly (STR-147). Written by the mutation path as
    /// `max(existing, now + budget)`; nil means nothing is outstanding.
    @OptionalField(key: "convergence_deadline")
    var convergenceDeadline: Date?

    /// Outstanding cleanup participants blocking this sandbox's removal
    /// (ADR 0001, stage 3) — the VM contract exactly. See `ResourceFinalizer`.
    @Field(key: "finalizers")
    var finalizers: [String]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        projectID: UUID,
        environment: String,
        image: String,
        cpus: Int,
        memory: Int64,
        entrypoint: [String]? = nil,
        cmd: [String]? = nil,
        env: [String: String] = [:],
        workingDir: String? = nil,
        ttlSeconds: Int? = nil,
        restoredFromSnapshotId: UUID? = nil,
        cpuTemplate: String? = nil
    ) {
        self.id = id
        self.name = name
        self.$project.id = projectID
        self.environment = environment
        self.image = image
        self.cpus = cpus
        self.memory = memory
        self.entrypoint = entrypoint
        self.cmd = cmd
        self.env = env
        self.workingDir = workingDir
        self.ttlSeconds = ttlSeconds
        self.restoredFromSnapshotId = restoredFromSnapshotId
        self.cpuTemplate = cpuTemplate
        // A fresh sandbox exists but is not running, mirroring VM creation:
        // the create operation materializes it agent-side, and the user
        // starts it explicitly. `.stopped` here means "not yet confirmed by
        // any agent" until observedGeneration moves off 0.
        self.status = .stopped
        self.desiredStatus = .stopped
        self.generation = 0
        self.observedGeneration = 0
        self.restoreGeneration = 0
        self.finalizers = []
    }
}

extension Sandbox: Content {}

// MARK: - State helpers (mirroring VM)

extension Sandbox {
    var isRunning: Bool {
        status == .running
    }

    /// `.exited` is startable: re-running a one-shot workload is a fresh
    /// launch. `.error` is included so an operator can recover a sandbox
    /// whose state could not be confirmed.
    var canStart: Bool {
        status == .stopped || status == .exited || status == .error
    }

    /// `.error` is stoppable for the same reason it is startable, and the
    /// asymmetry was a trap: a sandbox whose state could not be confirmed is
    /// very often one whose guest is still running, and refusing the stop left
    /// deletion as the only way out of it (STR-194). Desired state is
    /// level-triggered, so a stop that reaches a guest which has in fact
    /// already gone costs nothing.
    var canStop: Bool {
        status == .running || status == .error
    }

    /// When the lifetime budget runs out, or nil for a sandbox with no TTL.
    /// Anchored at `createdAt` rather than at a start time: the budget covers
    /// the record's whole life, so a sandbox that is created and never started
    /// still expires instead of holding its quota forever.
    var expiresAt: Date? {
        guard let ttlSeconds, let createdAt else { return nil }
        return createdAt.addingTimeInterval(TimeInterval(ttlSeconds))
    }

    /// Whether the lifetime budget has run out. Always false for a sandbox
    /// with no TTL.
    func isExpired(at date: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }

    /// Updates the observed status, starts a fresh divergence episode, and
    /// stamps the change time for reconciliation sweeps. Does not persist —
    /// call `save(on:)` afterwards.
    func setStatus(_ newStatus: SandboxStatus, at date: Date = Date()) {
        status = newStatus
        statusChangedAt = date
        divergenceDetectedAt = nil
    }

    /// Records a new desired state and bumps the generation so agents treat
    /// it as newer than anything they have applied. Does not persist — call
    /// `save(on:)` afterwards.
    func setDesiredStatus(_ newDesired: DesiredSandboxStatus) {
        desiredStatus = newDesired
        generation += 1
    }

    /// Asks the owning agent to load `snapshotID` back into this sandbox once
    /// (STR-151), and sets the desired status to `.running` alongside — the
    /// restored guest resumes, so desired state has to agree or the next sync
    /// would stop it right back. Does not persist.
    func requestRestore(snapshotID: UUID) {
        restoreGeneration += 1
        restoreSnapshotID = snapshotID
        setDesiredStatus(.running)
    }

    /// Realigns desired state with observed reality after a failed operation,
    /// bumping the generation — same rationale as `VM.revertDesiredToObserved`:
    /// a failed operation's unachieved intent must not linger and replay on a
    /// later sync, except for a deletion's `.absent`, which is never abandoned
    /// (issue #734) because reverting it resurrects a sandbox the user deleted
    /// and has the reconciler recreate a blank one. Returns whether anything
    /// changed; does not persist.
    @discardableResult
    func revertDesiredToObserved() -> Bool {
        guard desiredStatus != .absent else { return false }

        // An already-satisfied desired state needs no realignment. This also
        // handles `.exited`, which satisfies both `.running` and `.stopped`,
        // without churning the desired value (and generation) either way.
        if desiredStatus.isSatisfied(by: status) {
            return false
        }
        let resting: DesiredSandboxStatus
        switch status {
        case .running, .starting:
            resting = .running
        case .stopped, .stopping, .exited, .error, .unknown:
            resting = .stopped
        }
        guard desiredStatus != resting else { return false }
        setDesiredStatus(resting)
        return true
    }

    /// Sandbox counterpart of `VM.resolveForStuckOperation`: escalates a
    /// still-transitional sandbox — or one whose `create` was never confirmed
    /// by any agent (`observedGeneration == 0`; sandboxes have no
    /// `.created`-style pre-placement status) — to `.error`, then realigns
    /// desired state with observed reality (a stuck *delete* is exempt, so it
    /// cannot resurrect the sandbox). Shared by
    /// `ResourceOperationCoordinator.recordVerdict` and the stuck-convergence
    /// sweep. Takes the mutation kind rather than an operation row, for the
    /// reason the VM's does (STR-147). Returns whether anything changed; does
    /// not persist — call `save(on:)` afterwards.
    ///
    /// `telemetryReason` is accepted and ignored: there is no sandbox
    /// counterpart to `Telemetry.vmEnteredError` yet, and the parameter is here
    /// so both workload kinds present one signature to `ConvergingResource`.
    @discardableResult
    func resolveForStuckOperation(mutation: VMOperationKind, telemetryReason: String) -> Bool {
        var changed = false
        if status.isTransitional || (mutation == .create && observedGeneration == 0) {
            setStatus(.error)
            changed = true
        }
        if revertDesiredToObserved() {
            changed = true
        }
        return changed
    }

    /// The wire spec for this sandbox, assembled fresh at every sync. `network`
    /// is the sandbox's single NIC spec (issue #416), built by the caller from
    /// the eager-loaded interface + its logical network, or nil for a sandbox
    /// with no NIC.
    func buildSpec(
        network: NetworkSpec? = nil,
        restoreFrom: SandboxSnapshotRef? = nil
    ) -> SandboxSpec {
        SandboxSpec(
            image: image,
            imageDigest: imageDigest,
            cpus: cpus,
            memoryBytes: memory,
            entrypoint: entrypoint,
            cmd: cmd,
            env: env,
            workingDir: workingDir,
            network: network,
            restoreFrom: restoreFrom,
            cpuTemplate: cpuTemplate
        )
    }
}

// MARK: - Response DTO

/// A sandbox's NIC as the API reports it (STR-102) — the sandbox analogue of
/// `NetworkInterfaceResponse`, minus the two fields sandboxes have no notion of
/// (`orderIndex`, since v1 is single-NIC, and guest-reported `observedAddresses`,
/// which need a QEMU guest agent).
struct SandboxNetworkInterfaceResponse: Content {
    let id: UUID?
    /// The network this NIC attaches to. The id is the reference; the name is a
    /// display label, present only when the caller eager-loaded the relation.
    let networkId: UUID
    let network: String?
    let macAddress: String
    let addresses: [InterfaceAddressResponse]
    let mtu: Int?
    let deviceName: String
    /// The security groups attached to this NIC, sorted to match the order
    /// agents receive in the spec. Deliberately **nil when the relation wasn't
    /// eager-loaded**, unlike the `.value ?? []` treatment of `addresses`: an
    /// empty array here reads as "this NIC is in no group", a security claim a
    /// forgotten `.with(...)` must not be able to make.
    let securityGroupIds: [UUID]?

    init(from nic: SandboxNetworkInterface) {
        self.id = nic.id
        self.networkId = nic.$logicalNetwork.id
        self.network = nic.$logicalNetwork.value?.name
        self.macAddress = nic.macAddress
        // ipv4-first for a stable, familiar ordering, as on the VM path.
        self.addresses = (nic.$addresses.value ?? [])
            .sorted { ($0.family, $0.address) < ($1.family, $1.address) }
            .map(InterfaceAddressResponse.init)
        self.mtu = nic.mtu
        self.deviceName = nic.deviceName
        self.securityGroupIds = nic.$securityGroupMemberships.value.map { memberships in
            memberships.map { $0.$securityGroup.id }.sorted { $0.uuidString < $1.uuidString }
        }
    }
}

struct SandboxDetailResponse: Content {
    let id: UUID?
    let name: String
    let projectId: UUID?
    let environment: String
    let image: String
    let imageDigest: String?
    let cpus: Int
    let memory: Int64
    let entrypoint: [String]?
    let cmd: [String]?
    let env: [String: String]
    let workingDir: String?
    let ttlSeconds: Int?
    /// Derived from `ttlSeconds` + `createdAt` so clients can show a countdown
    /// without re-deriving the anchor. Nil when the sandbox has no TTL.
    let expiresAt: Date?
    let hypervisorId: String?
    let restoredFromSnapshotId: UUID?
    let cpuTemplate: String?
    let status: SandboxStatus
    let exitCode: Int?
    /// The security groups attached to the sandbox's NIC (STR-34), flat
    /// because v1 gives a sandbox at most one interface. Nil when the NIC
    /// relation wasn't eager-loaded *or* the sandbox has no NIC at all —
    /// which are the same thing to a caller, since neither can be filtered.
    ///
    /// Kept alongside the per-NIC copy on `networkInterfaces` for clients that
    /// predate it. Whether these groups filter anything is a separate question:
    /// see `securityGroupsEnforced`.
    let securityGroupIds: [UUID]?
    /// The sandbox's NICs (STR-102) — at most one in v1, but a list for parity
    /// with the VM response and so multi-NIC sandboxes need no shape change.
    /// Empty when the relation wasn't eager-loaded, which is safe here in a way
    /// it is not for `securityGroupIds` above: an absent NIC claims nothing
    /// about filtering.
    let networkInterfaces: [SandboxNetworkInterfaceResponse]
    /// Whether the attached groups actually filter traffic. Nil means unknown —
    /// the sandbox has no NIC — and is *not* a claim that they don't; false
    /// says they demonstrably do not. False for every networked sandbox today:
    /// the NIC does not reach the wire until STR-103, so no OVN port exists to
    /// join a port group.
    ///
    /// The nil/false *meanings* match `VMDetailResponse.securityGroupsEnforced`,
    /// but the mapping does not yet: an unplaced VM reads nil (no realizer to
    /// judge), while an unplaced sandbox *with* a NIC reads false, because what
    /// makes it unenforced is the closed wire gate rather than the missing host.
    /// STR-103 removes that short-circuit and so flips unplaced-with-NIC from
    /// false to nil — a client branching on `=== false` today changes behavior
    /// then, which is the one reason to read this field as three-valued rather
    /// than as a boolean with a null.
    let securityGroupsEnforced: Bool?
    /// How far the sandbox is from the state the API was last asked to put it
    /// in (STR-142) — same contract as the VM's; see `ResourceConditions`.
    let conditions: ResourceConditions
    let createdAt: Date?
    let updatedAt: Date?

    init(from sandbox: Sandbox, securityGroupsEnforced: Bool? = nil) {
        self.id = sandbox.id
        self.name = sandbox.name
        self.projectId = sandbox.$project.id
        self.environment = sandbox.environment
        self.image = sandbox.image
        self.imageDigest = sandbox.imageDigest
        self.cpus = sandbox.cpus
        self.memory = sandbox.memory
        self.entrypoint = sandbox.entrypoint
        self.cmd = sandbox.cmd
        self.env = sandbox.env
        self.workingDir = sandbox.workingDir
        self.ttlSeconds = sandbox.ttlSeconds
        self.expiresAt = sandbox.expiresAt
        self.hypervisorId = sandbox.hypervisorId
        self.restoredFromSnapshotId = sandbox.restoredFromSnapshotId
        self.cpuTemplate = sandbox.cpuTemplate
        self.status = sandbox.status
        self.exitCode = sandbox.exitCode
        // One ordering for both fields, so "the sandbox's NIC" means the same
        // interface in each. Deriving the flat field from insertion order and
        // the list from `deviceName` agrees only while v1 is single-NIC, and
        // the flat field is the one older clients read — so the disagreement
        // would surface first for the clients least able to notice it.
        let orderedInterfaces = (sandbox.$networkInterfaces.value ?? [])
            .sorted { $0.deviceName < $1.deviceName }
        self.securityGroupIds = orderedInterfaces
            .first?
            .$securityGroupMemberships.value?
            .map { $0.$securityGroup.id }
            .sorted { $0.uuidString < $1.uuidString }
        self.networkInterfaces = orderedInterfaces.map(SandboxNetworkInterfaceResponse.init)
        self.securityGroupsEnforced = securityGroupsEnforced
        self.conditions = sandbox.conditions
        self.createdAt = sandbox.createdAt
        self.updatedAt = sandbox.updatedAt
    }
}
