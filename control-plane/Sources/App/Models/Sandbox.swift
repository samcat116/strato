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
        ttlSeconds: Int? = nil
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
        // A fresh sandbox exists but is not running, mirroring VM creation:
        // the create operation materializes it agent-side, and the user
        // starts it explicitly. `.stopped` here means "not yet confirmed by
        // any agent" until observedGeneration moves off 0.
        self.status = .stopped
        self.desiredStatus = .stopped
        self.generation = 0
        self.observedGeneration = 0
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

    var canStop: Bool {
        status == .running
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

    /// Updates the observed status and stamps the change time for the
    /// reconciliation sweep. Does not persist — call `save(on:)` afterwards.
    func setStatus(_ newStatus: SandboxStatus, at date: Date = Date()) {
        status = newStatus
        statusChangedAt = date
    }

    /// Records a new desired state and bumps the generation so agents treat
    /// it as newer than anything they have applied. Does not persist — call
    /// `save(on:)` afterwards.
    func setDesiredStatus(_ newDesired: DesiredSandboxStatus) {
        desiredStatus = newDesired
        generation += 1
    }

    /// True once the owning agent has confirmed converging to the current
    /// generation and the observed status satisfies the desired one.
    var isConverged: Bool {
        observedGeneration >= generation && desiredStatus.isSatisfied(by: status)
    }

    /// Realigns desired state with observed reality after a failed operation,
    /// bumping the generation — same rationale as `VM.revertDesiredToObserved`:
    /// a failed operation's unachieved intent (e.g. a delete's `.absent`) must
    /// not linger and replay destructively on a later sync. Returns whether
    /// anything changed; does not persist.
    @discardableResult
    func revertDesiredToObserved() -> Bool {
        // An already-satisfied desired state needs no realignment. This also
        // handles `.exited`, which satisfies both `.running` and `.stopped`,
        // without churning the desired value (and generation) either way.
        if desiredStatus != .absent, desiredStatus.isSatisfied(by: status) {
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

    /// The wire spec for this sandbox, assembled fresh at every sync. `network`
    /// is the sandbox's single NIC spec (issue #416), built by the caller from
    /// the eager-loaded interface + its logical network, or nil for a sandbox
    /// with no NIC.
    func buildSpec(network: NetworkSpec? = nil) -> SandboxSpec {
        SandboxSpec(
            image: image,
            imageDigest: imageDigest,
            cpus: cpus,
            memoryBytes: memory,
            entrypoint: entrypoint,
            cmd: cmd,
            env: env,
            workingDir: workingDir,
            network: network
        )
    }
}

// MARK: - Response DTO

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
    let status: SandboxStatus
    let exitCode: Int?
    let createdAt: Date?
    let updatedAt: Date?

    init(from sandbox: Sandbox) {
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
        self.status = sandbox.status
        self.exitCode = sandbox.exitCode
        self.createdAt = sandbox.createdAt
        self.updatedAt = sandbox.updatedAt
    }
}
