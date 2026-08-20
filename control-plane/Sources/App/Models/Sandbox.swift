import ControlPlanePostgres
import Fluent
import Vapor
import StratoShared

/// A sandbox: a microVM booted from an OCI image on Firecracker (issue #410).
/// Deliberately its own table and API surface — parallel to `VM`, not a VM
/// variant — so the two workload types can diverge. Mirrors the VM's
/// desired/observed state split (issue #260): `status` is purely observed,
/// `desiredStatus` is the goal written by API mutations, and the generation
/// pair tracks agent convergence.
struct Sandbox: Sendable {
    static let schema = "sandboxes"

    var id: UUID?
    var name: String
    var projectID: UUID
    var environment: String

    /// OCI image reference as provided by the user (`ghcr.io/acme/worker:v3`).
    /// Kept verbatim for identity and logging; agents converge on
    /// `imageDigest` once tag→digest resolution lands (issue #414).
    var image: String

    /// Manifest digest (`sha256:...`) the reference resolved to. Populated by
    /// tag→digest resolution (issue #414); nil until then, in which case the
    /// agent resolves the tag itself, accepting the mutability.
    var imageDigest: String?
    var cpus: Int

    /// Guest memory size in bytes.
    var memory: Int64

    /// Entrypoint/cmd/env/workdir overrides over the OCI image config, applied
    /// by the guest agent (override wins on key collision).
    var entrypoint: [String]?
    var cmd: [String]?
    var env: [String: String]
    var workingDir: String?

    /// Lifetime budget in seconds, counted from `createdAt` (see `expiresAt`).
    /// The expiry sweep deletes the sandbox once the budget runs out; nil
    /// means the sandbox lives until something else removes it.
    var ttlSeconds: Int?

    /// The agent this sandbox is placed on, written by the scheduler.
    var hypervisorId: String?

    /// Durable lineage for a fork (issue #427). Kept as an opaque id rather
    /// than a foreign key so database cascade rules can never delete a fork;
    /// the controller protects live lineage explicitly.
    var restoredFromSnapshotId: UUID?

    /// Firecracker CPU template the microVM boots with, decided at create
    /// time (issue #428) because it is baked into every checkpoint's guest
    /// state: a templated snapshot restores on any same-arch host whose
    /// Firecracker honours the template, while a nil (passthrough) snapshot
    /// only restores on identical CPU models. Immutable after create.
    var cpuTemplate: String?

    /// The sandbox's NICs explicitly loaded through
    /// `LegacySandboxNetworkInterfaceStore`. Nil means the caller did not ask
    /// for them; an empty array means this sandbox has no NIC.
    var loadedNetworkInterfaces: [SandboxNetworkInterface]?

    var networkInterfaces: [SandboxNetworkInterface] {
        loadedNetworkInterfaces ?? []
    }

    // Observed state, written only from agent reports (plus the diagnostic
    // escalations in the sweeps).
    var status: SandboxStatus

    /// When `status` last changed. Used by the reconciliation sweep to detect
    /// sandboxes stuck in a transitional state past a timeout.
    var statusChangedAt: Date?

    /// Exit code of a workload that ran to completion (`status == .exited`),
    /// as reported by the agent.
    var exitCode: Int?

    // Desired state, written by API mutations. Same contract as VM:
    // `generation` bumps on every desired change and `observedGeneration`
    // records the last generation the owning agent confirmed converging to.
    var desiredStatus: DesiredSandboxStatus
    var generation: Int64
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
    var restoreGeneration: Int64

    /// The snapshot `restoreGeneration` names. Not a foreign key, for
    /// `VM.restoreSnapshotID`'s reason.
    var restoreSnapshotID: UUID?

    // Convergence progress mirrored from the agent's observed-state report,
    // with the same contract as the VM's (STR-142): `convergencePhase` is
    // non-nil only while the agent is actively converging toward a newer
    // generation, and the error pair records the last failed attempt until a
    // successful convergence clears it. Projected as the API's `conditions`
    // block.
    var convergencePhase: String?
    var lastError: String?
    var failedGeneration: Int64?

    /// When the current error/generation pair was first observed. Stable while
    /// identical heartbeats repeat it, and cleared by successful convergence.
    var lastErrorAt: Date?

    /// Internal claim for the sustained-divergence warning. Nil starts a new
    /// episode; the sweep atomically stamps it before logging.
    var divergenceDetectedAt: Date?

    /// When the stuck-convergence sweep marks this sandbox degraded — the VM
    /// contract exactly (STR-147). Written by the mutation path as
    /// `max(existing, now + budget)`; nil means nothing is outstanding.
    var convergenceDeadline: Date?

    /// Outstanding cleanup participants blocking this sandbox's removal
    /// (ADR 0001, stage 3) — the VM contract exactly. See `ResourceFinalizer`.
    var finalizers: [String]
    var createdAt: Date?
    var updatedAt: Date?

    init(
        id: UUID? = UUID(),
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
        cpuTemplate: String? = nil,
        imageDigest: String? = nil,
        hypervisorId: String? = nil,
        loadedNetworkInterfaces: [SandboxNetworkInterface]? = nil,
        status: SandboxStatus = .stopped,
        statusChangedAt: Date? = nil,
        exitCode: Int? = nil,
        desiredStatus: DesiredSandboxStatus = .stopped,
        generation: Int64 = 0,
        observedGeneration: Int64 = 0,
        restoreGeneration: Int64 = 0,
        restoreSnapshotID: UUID? = nil,
        convergencePhase: String? = nil,
        lastError: String? = nil,
        failedGeneration: Int64? = nil,
        lastErrorAt: Date? = nil,
        divergenceDetectedAt: Date? = nil,
        convergenceDeadline: Date? = nil,
        finalizers: [String] = [],
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.projectID = projectID
        self.environment = environment
        self.image = image
        self.imageDigest = imageDigest
        self.cpus = cpus
        self.memory = memory
        self.entrypoint = entrypoint
        self.cmd = cmd
        self.env = env
        self.workingDir = workingDir
        self.ttlSeconds = ttlSeconds
        self.hypervisorId = hypervisorId
        self.restoredFromSnapshotId = restoredFromSnapshotId
        self.cpuTemplate = cpuTemplate
        self.loadedNetworkInterfaces = loadedNetworkInterfaces
        self.status = status
        self.statusChangedAt = statusChangedAt
        self.exitCode = exitCode
        self.desiredStatus = desiredStatus
        self.generation = generation
        self.observedGeneration = observedGeneration
        self.restoreGeneration = restoreGeneration
        self.restoreSnapshotID = restoreSnapshotID
        self.convergencePhase = convergencePhase
        self.lastError = lastError
        self.failedGeneration = failedGeneration
        self.lastErrorAt = lastErrorAt
        self.divergenceDetectedAt = divergenceDetectedAt
        self.convergenceDeadline = convergenceDeadline
        self.finalizers = finalizers
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func requireID() throws -> UUID {
        guard let id else { throw Abort(.internalServerError, reason: "Sandbox has no identifier") }
        return id
    }

    func persisted(on db: any Database) async throws -> Self {
        try await LegacySandboxStore.upsert(self, on: db)
    }

    func persist(on db: any Database) async throws { _ = try await persisted(on: db) }
    func save(on db: any Database) async throws { try await persist(on: db) }
    func delete(on db: any Database) async throws {
        guard let id else { return }
        _ = try await LegacySandboxStore.delete(id: id, on: db)
    }
    func remove(on db: any Database) async throws { try await delete(on: db) }

    static func find(_ id: UUID?, on db: any Database) async throws -> Self? {
        try await LegacySandboxStore.sandbox(id: id, on: db)
    }

    static func load(_ id: UUID?, on db: any Database) async throws -> Self? {
        try await find(id, on: db)
    }

    static func all(on db: any Database) async throws -> [Self] {
        try await LegacySandboxStore.sandboxes(on: db)
    }

    func loadingNetworkInterfaces(_ interfaces: [SandboxNetworkInterface]) -> Self {
        var copy = self
        copy.loadedNetworkInterfaces = interfaces
        return copy
    }
}

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
    mutating func setStatus(_ newStatus: SandboxStatus, at date: Date = Date()) {
        status = newStatus
        statusChangedAt = date
        divergenceDetectedAt = nil
    }

    /// Records a new desired state in memory. The caller advances the
    /// generation through `DesiredStateGenerationWriter` in the same
    /// transaction that persists it.
    mutating func setDesiredStatus(_ newDesired: DesiredSandboxStatus) {
        desiredStatus = newDesired
    }

    /// Asks the owning agent to load `snapshotID` back into this sandbox once
    /// (STR-151), and sets the desired status to `.running` alongside — the
    /// restored guest resumes, so desired state has to agree or the next sync
    /// would stop it right back. Does not persist.
    mutating func requestRestore(snapshotID: UUID) {
        restoreGeneration += 1
        restoreSnapshotID = snapshotID
        setDesiredStatus(.running)
    }

    /// Realigns desired state with observed reality after a failed operation.
    /// The convergence writer advances the generation when this returns true —
    /// same rationale as `VM.revertDesiredToObserved`:
    /// a failed operation's unachieved intent must not linger and replay on a
    /// later sync, except for a deletion's `.absent`, which is never abandoned
    /// (issue #734) because reverting it resurrects a sandbox the user deleted
    /// and has the reconciler recreate a blank one. Returns whether anything
    /// changed; does not persist.
    @discardableResult
    mutating func revertDesiredToObserved() -> Bool {
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
    /// reason the VM's does (STR-147). Returns whether desired state changed
    /// and needs a new generation; a status-only escalation does not. Does not
    /// persist.
    ///
    /// `telemetryReason` is accepted and ignored: there is no sandbox
    /// counterpart to `Telemetry.vmEnteredError` yet, and the parameter is here
    /// so both workload kinds present one signature to `ConvergingResource`.
    @discardableResult
    mutating func resolveForStuckOperation(
        mutation: VMOperationKind, telemetryReason: String
    ) -> Bool {
        if status.isTransitional || (mutation == .create && observedGeneration == 0) {
            setStatus(.error)
        }
        return revertDesiredToObserved()
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

    init(from nic: SandboxNetworkInterface, securityGroupIDs: [UUID]? = nil) {
        self.id = nic.id
        self.networkId = nic.logicalNetworkID
        self.network = nic.logicalNetworkName
        self.macAddress = nic.macAddress
        // ipv4-first for a stable, familiar ordering, as on the VM path.
        self.addresses = (nic.loadedAddresses ?? [])
            .sorted { ($0.family, $0.address) < ($1.family, $1.address) }
            .map(InterfaceAddressResponse.init)
        self.mtu = nic.mtu
        self.deviceName = nic.deviceName
        self.securityGroupIds = securityGroupIDs?.sorted { $0.uuidString < $1.uuidString }
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

    init(
        from sandbox: Sandbox,
        securityGroupIDsByInterfaceID: [UUID: [UUID]]? = nil,
        securityGroupsEnforced: Bool? = nil
    ) {
        self.id = sandbox.id
        self.name = sandbox.name
        self.projectId = sandbox.projectID
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
        let orderedInterfaces = (sandbox.loadedNetworkInterfaces ?? [])
            .sorted { $0.deviceName < $1.deviceName }
        self.securityGroupIds = securityGroupIDsByInterfaceID.map { memberships in
            orderedInterfaces.first?.id.flatMap { memberships[$0] } ?? []
        }
        self.networkInterfaces = orderedInterfaces.map { interface in
            SandboxNetworkInterfaceResponse(
                from: interface,
                securityGroupIDs: securityGroupIDsByInterfaceID.map { memberships in
                    interface.id.flatMap { memberships[$0] } ?? []
                })
        }
        self.securityGroupsEnforced = securityGroupsEnforced
        self.conditions = sandbox.conditions
        self.createdAt = sandbox.createdAt
        self.updatedAt = sandbox.updatedAt
    }
}
