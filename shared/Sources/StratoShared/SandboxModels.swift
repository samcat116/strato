import Foundation
import SwiftProtobuf

// MARK: - Sandbox Specification

/// Reference to the checkpoint artifacts used to create a sandbox fork
/// (issue #427). The source sandbox id lets an agent holding the artifacts
/// resolve its host-owned archive directory; when the fork lands on a
/// *different* agent (issue #428), `artifacts` carries signed download
/// descriptors for the exported copy — refreshed at sync assembly like image
/// URLs — and the target agent stages the archive from object storage instead.
public typealias SandboxSnapshotRef = Strato_Agent_V1_SandboxSnapshotRef
extension Strato_Agent_V1_SandboxSnapshotRef: Codable {
    /// Download descriptors for an exported snapshot, present only when the
    /// receiving agent is not the one holding the local artifacts. Additive:
    /// pre-v13 control planes never send it, and pre-v13 agents never receive
    /// it (cross-agent placement is gated on the wire version).

    public init(
        snapshotId: UUID,
        sourceSandboxId: UUID,
        artifacts: [SandboxSnapshotArtifactDescriptor]? = nil
    ) {
        self.init()
        self._jsonSnapshotId = snapshotId
        self._jsonSourceSandboxId = sourceSandboxId
        self._jsonArtifacts = artifacts
    }

    private enum CodingKeys: String, CodingKey { case snapshotId; case sourceSandboxId; case artifacts }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonSnapshotId = try container.decode(UUID.self, forKey: .snapshotId)
        self._jsonSourceSandboxId = try container.decode(UUID.self, forKey: .sourceSandboxId)
        self._jsonArtifacts = try container.decodeIfPresent(
            [SandboxSnapshotArtifactDescriptor].self, forKey: .artifacts)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonSnapshotId, forKey: .snapshotId)
        try container.encode(_jsonSourceSandboxId, forKey: .sourceSandboxId)
        try container.encodeIfPresent(_jsonArtifacts, forKey: .artifacts)
    }

    var _jsonSnapshotId: UUID {
        get { UUID(uuidString: snapshotID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
        set { let value = newValue; snapshotID = value.uuidString }
    }
    var _jsonSourceSandboxId: UUID {
        get { UUID(uuidString: sourceSandboxID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
        set { let value = newValue; sourceSandboxID = value.uuidString }
    }
    var _jsonArtifacts: [SandboxSnapshotArtifactDescriptor]? {
        get { hasArtifacts ? (artifacts.values) : nil }
        set {
            if let value = newValue {
                artifacts = Strato_Agent_V1_SandboxSnapshotRefArtifactsSection.with { $0.values = value }
            } else {
                clearArtifacts()
            }
        }
    }
}

/// Firecracker CPU templates a sandbox may be created with (issue #428).
/// A template normalizes guest-visible CPU features to a fixed baseline, which
/// is what makes a snapshot restorable on a host with a different (same-arch)
/// CPU — an un-templated snapshot only restores on identical CPU models. Kept
/// as a raw string on the wire; this set is the control plane's admission
/// validation, while the agent's Firecracker rejects templates its host
/// cannot honour.
public enum SandboxCPUTemplate {
    /// Static templates understood by current Firecracker builds:
    /// C3/T2/T2S/T2CL (Intel) and T2A (AMD) on x86_64, V1N1 on aarch64.
    public static let known: Set<String> = ["C3", "T2", "T2S", "T2CL", "T2A", "V1N1"]
}

/// Description of a sandbox workload — a microVM booted from an OCI image —
/// sent from the control plane to an agent.
///
/// Deliberately distinct from `VMSpec` so the two workload types can diverge:
/// sandboxes reference OCI images (not the `Image`/`ImageArtifact` model), boot
/// through Firecracker only (no `HypervisorType`, no firmware/boot source), have
/// no attachable volumes, and carry at most one NIC. The control plane sends
/// only what it can legitimately know; rootfs materialization, kernel choice,
/// and vsock wiring are agent-side concerns.
public typealias SandboxSpec = Strato_Agent_V1_SandboxSpec
extension Strato_Agent_V1_SandboxSpec: Codable {
    /// OCI image reference as provided by the user, e.g.
    /// `ghcr.io/acme/worker:v3`. Kept verbatim for guest identity and logging;
    /// agents converge on `imageDigest` when present.
    /// Manifest digest (`sha256:...`) the reference resolved to, pinned by the
    /// control plane so convergence is immutable — a re-tagged image never
    /// changes a sandbox out from under its generation. Nil only from control
    /// planes that predate tag→digest resolution (issue #414); the agent then
    /// resolves the tag itself, accepting the mutability.
    /// Number of vCPUs.
    /// Guest memory size in bytes.
    /// Entrypoint override. Nil means use the image config's entrypoint.
    /// Command (arguments) override. Nil means use the image config's cmd.
    /// Environment variable overrides, merged over the image config's
    /// environment by the guest agent (override wins on key collision).
    /// Working directory override. Nil means use the image config's value.
    /// The sandbox's single NIC, when networked. Reuses the VM NIC spec so
    /// agents realize the attachment through the same OVN/user-mode paths.
    /// A ready checkpoint to restore into this new sandbox instead of booting
    /// its image. Additive/optional for compatibility with pre-fork peers.
    /// Firecracker CPU template the microVM boots with (issue #428), chosen at
    /// sandbox create time — never at restore time, because the template is
    /// baked into every checkpoint's guest state and decides where those
    /// checkpoints can later restore. Nil boots without a template (host CPU
    /// passthrough); snapshots of such a sandbox only restore on identical
    /// CPU models. Additive/optional: pre-v13 agents ignore it, so templated
    /// sandbox placement is gated on the wire version.

    public init(
        image: String,
        imageDigest: String? = nil,
        cpus: Int,
        memoryBytes: Int64,
        entrypoint: [String]? = nil,
        cmd: [String]? = nil,
        env: [String: String] = [:],
        workingDir: String? = nil,
        network: NetworkSpec? = nil,
        restoreFrom: SandboxSnapshotRef? = nil,
        cpuTemplate: String? = nil,
        resourceClass: WorkloadResourceClassSnapshot? = nil,
        admittedReservation: WorkloadAdmittedReservation? = nil
    ) {
        self.init()
        self._jsonAdmittedReservation = admittedReservation
        self._jsonResourceClass = resourceClass
        self._jsonImage = image
        self._jsonImageDigest = imageDigest
        self._jsonCpus = cpus
        self._jsonMemoryBytes = memoryBytes
        self._jsonEntrypoint = entrypoint
        self._jsonCmd = cmd
        self._jsonEnv = env
        self._jsonWorkingDir = workingDir
        self._jsonNetwork = network
        self._jsonRestoreFrom = restoreFrom
        self._jsonCpuTemplate = cpuTemplate
    }

    private enum CodingKeys: String, CodingKey {
        case admittedReservation; case resourceClass; case image; case imageDigest; case cpus; case memoryBytes;
        case entrypoint; case cmd; case env; case workingDir; case network; case restoreFrom; case cpuTemplate
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonAdmittedReservation = try container.decodeIfPresent(
            WorkloadAdmittedReservation.self, forKey: .admittedReservation)
        self._jsonResourceClass = try container.decodeIfPresent(
            WorkloadResourceClassSnapshot.self, forKey: .resourceClass)
        self._jsonImage = try container.decode(String.self, forKey: .image)
        self._jsonImageDigest = try container.decodeIfPresent(String.self, forKey: .imageDigest)
        self._jsonCpus = try container.decode(Int.self, forKey: .cpus)
        self._jsonMemoryBytes = try container.decode(Int64.self, forKey: .memoryBytes)
        self._jsonEntrypoint = try container.decodeIfPresent([String].self, forKey: .entrypoint)
        self._jsonCmd = try container.decodeIfPresent([String].self, forKey: .cmd)
        self._jsonEnv = try container.decode([String: String].self, forKey: .env)
        self._jsonWorkingDir = try container.decodeIfPresent(String.self, forKey: .workingDir)
        self._jsonNetwork = try container.decodeIfPresent(NetworkSpec.self, forKey: .network)
        self._jsonRestoreFrom = try container.decodeIfPresent(SandboxSnapshotRef.self, forKey: .restoreFrom)
        self._jsonCpuTemplate = try container.decodeIfPresent(String.self, forKey: .cpuTemplate)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(_jsonAdmittedReservation, forKey: .admittedReservation)
        try container.encodeIfPresent(_jsonResourceClass, forKey: .resourceClass)
        try container.encode(_jsonImage, forKey: .image)
        try container.encodeIfPresent(_jsonImageDigest, forKey: .imageDigest)
        try container.encode(_jsonCpus, forKey: .cpus)
        try container.encode(_jsonMemoryBytes, forKey: .memoryBytes)
        try container.encodeIfPresent(_jsonEntrypoint, forKey: .entrypoint)
        try container.encodeIfPresent(_jsonCmd, forKey: .cmd)
        try container.encode(_jsonEnv, forKey: .env)
        try container.encodeIfPresent(_jsonWorkingDir, forKey: .workingDir)
        try container.encodeIfPresent(_jsonNetwork, forKey: .network)
        try container.encodeIfPresent(_jsonRestoreFrom, forKey: .restoreFrom)
        try container.encodeIfPresent(_jsonCpuTemplate, forKey: .cpuTemplate)
    }

    var _jsonAdmittedReservation: WorkloadAdmittedReservation? {
        get { hasAdmittedReservation ? (admittedReservation) : nil }
        set { if let value = newValue { admittedReservation = value } else { clearAdmittedReservation() } }
    }
    var _jsonResourceClass: WorkloadResourceClassSnapshot? {
        get { hasResourceClass ? (resourceClass) : nil }
        set { if let value = newValue { resourceClass = value } else { clearResourceClass() } }
    }
    var _jsonImage: String {
        get { image }
        set { let value = newValue; image = value }
    }
    var _jsonImageDigest: String? {
        get { hasImageDigest ? (imageDigest) : nil }
        set { if let value = newValue { imageDigest = value } else { clearImageDigest() } }
    }
    var _jsonCpus: Int {
        get { Int(cpus) }
        set { let value = newValue; cpus = Int64(value) }
    }
    var _jsonMemoryBytes: Int64 {
        get { memoryBytes }
        set { let value = newValue; memoryBytes = value }
    }
    var _jsonEntrypoint: [String]? {
        get { hasEntrypoint ? (entrypoint.values) : nil }
        set {
            if let value = newValue {
                entrypoint = Strato_Agent_V1_SandboxSpecEntrypointSection.with { $0.values = value }
            } else {
                clearEntrypoint()
            }
        }
    }
    var _jsonCmd: [String]? {
        get { hasCmd ? (cmd.values) : nil }
        set {
            if let value = newValue {
                cmd = Strato_Agent_V1_SandboxSpecCmdSection.with { $0.values = value }
            } else {
                clearCmd()
            }
        }
    }
    var _jsonEnv: [String: String] {
        get { env.values }
        set { let value = newValue; env = Strato_Agent_V1_SandboxSpecEnvSection.with { $0.values = value } }
    }
    var _jsonWorkingDir: String? {
        get { hasWorkingDir ? (workingDir) : nil }
        set { if let value = newValue { workingDir = value } else { clearWorkingDir() } }
    }
    var _jsonNetwork: NetworkSpec? {
        get { hasNetwork ? (network) : nil }
        set { if let value = newValue { network = value } else { clearNetwork() } }
    }
    var _jsonRestoreFrom: SandboxSnapshotRef? {
        get { hasRestoreFrom ? (restoreFrom) : nil }
        set { if let value = newValue { restoreFrom = value } else { clearRestoreFrom() } }
    }
    var _jsonCpuTemplate: String? {
        get { hasCpuTemplate ? (cpuTemplate) : nil }
        set { if let value = newValue { cpuTemplate = value } else { clearCpuTemplate() } }
    }
}

// MARK: - Registry Credential

/// Short-lived credential material for pulling a sandbox's image from a private
/// registry. Reused across syncs only while safely inside its own expiry, so a
/// long-lived desired entry never carries an expired credential. Agents use it
/// for the pull and must never persist it; durable credential storage lives
/// only on the control plane (issue #414).
public typealias RegistryCredential = Strato_Agent_V1_RegistryCredential
extension Strato_Agent_V1_RegistryCredential: Codable {
    /// Registry host the credential is scoped to, e.g. `ghcr.io`.
    /// Password or short-lived bearer/identity token, per the registry's
    /// distribution auth flow.
    /// When the material expires, for agent awareness (skip a doomed pull and
    /// surface a fresh-sync need instead).
    /// When true, `password` is a distribution bearer token the control plane
    /// already minted: present it directly as `Authorization: Bearer` on
    /// registry requests. Nil/false means Basic credentials (the agent runs
    /// the registry's own challenge flow with them). Optional so payloads
    /// from control planes that predate token minting still decode.

    public init(
        registry: String, username: String, password: String, expiresAt: Date? = nil, bearer: Bool = false
    ) {
        self.init()
        self._jsonRegistry = registry
        self._jsonUsername = username
        self._jsonPassword = password
        self._jsonExpiresAt = expiresAt
        self._jsonBearer = bearer
    }

    private enum CodingKeys: String, CodingKey {
        case registry; case username; case password; case expiresAt; case bearer
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRegistry = try container.decode(String.self, forKey: .registry)
        self._jsonUsername = try container.decode(String.self, forKey: .username)
        self._jsonPassword = try container.decode(String.self, forKey: .password)
        self._jsonExpiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        self._jsonBearer = try container.decode(Bool.self, forKey: .bearer)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRegistry, forKey: .registry)
        try container.encode(_jsonUsername, forKey: .username)
        try container.encode(_jsonPassword, forKey: .password)
        try container.encodeIfPresent(_jsonExpiresAt, forKey: .expiresAt)
        try container.encode(_jsonBearer, forKey: .bearer)
    }

    var _jsonRegistry: String {
        get { registry }
        set { let value = newValue; registry = value }
    }
    var _jsonUsername: String {
        get { username }
        set { let value = newValue; username = value }
    }
    var _jsonPassword: String {
        get { password }
        set { let value = newValue; password = value }
    }
    var _jsonExpiresAt: Date? {
        get { hasExpiresAt ? (expiresAt.date) : nil }
        set { if let value = newValue { expiresAt = Google_Protobuf_Timestamp(date: value) } else { clearExpiresAt() } }
    }
    var _jsonBearer: Bool {
        get { bearer }
        set { let value = newValue; bearer = value }
    }
}

// MARK: - Sandbox Status

/// A sandbox's *observed* runtime state, as reported by an agent. Mirrors
/// `VMStatus` (including tolerant decoding), with one sandbox-specific case:
/// `.exited`, because a sandbox's workload can finish on its own — something a
/// VM never does from the control plane's point of view.
public typealias SandboxStatus = Strato_Agent_V1_SandboxStatus
extension Strato_Agent_V1_SandboxStatus: Codable {
    /// Exists agent-side (rootfs materialized) but not running.

    /// Durable, verified checkpoint exists and the original VMM is gone.

    /// The workload ran and ended on its own; `ObservedSandboxState.exitCode`
    /// carries the result. Terminal: distinct from `.stopped` (a control-plane
    /// initiated stop) so one-shot workloads are not restarted.

    // Transitional states: convergence is in flight and the agent has not yet
    // reached the terminal state.

    // Diagnostic states set by reconciliation, never by normal convergence.

    /// True while convergence is in flight and not yet settled.
    public var isTransitional: Bool {
        switch self {
        case .starting, .stopping:
            return true
        case .stopped, .suspended, .running, .exited, .error, .unknown, .unspecified, .UNRECOGNIZED:
            return false
        }
    }

    /// Tolerant decoding: an unrecognized status string (e.g. from an agent
    /// running a newer protocol version) decodes to `.unknown` instead of
    /// throwing, so version skew cannot crash message handling.
    public init(from decoder: Swift.Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SandboxStatus(rawValue: raw) ?? .unknown
    }

    public var protocolValue: String {
        switch self {
        case .stopped: return "Stopped"
        case .suspended: return "Suspended"
        case .running: return "Running"
        case .exited: return "Exited"
        case .starting: return "Starting"
        case .stopping: return "Stopping"
        case .error: return "Error"
        case .unknown: return "Unknown"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "Stopped": self = .stopped
        case "Suspended": self = .suspended
        case "Running": self = .running
        case "Exited": self = .exited
        case "Starting": self = .starting
        case "Stopping": self = .stopping
        case "Error": self = .error
        case "Unknown": self = .unknown
        default: return nil
        }
    }

    public static var knownCases: [Self] {
        [.stopped, .suspended, .running, .exited, .starting, .stopping, .error, .unknown]
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

// MARK: - Desired Sandbox Status

/// The state the control plane wants a sandbox to be in. Same contract as
/// `DesiredVMStatus`: a goal, never a report, so no transitional or diagnostic
/// cases — and deliberately strict decoding, because misinterpreting a desired
/// status could stop or delete a running workload. An unknown value fails the
/// whole sync and the agent keeps its current state; adding a case therefore
/// requires a `WireProtocol` version bump and a dual-mode rollout.
public typealias DesiredSandboxStatus = Strato_Agent_V1_DesiredSandboxStatus
extension Strato_Agent_V1_DesiredSandboxStatus: Codable {

    /// Durable, verified checkpoint exists and the original VMM is gone.

    /// The sandbox should not exist on the agent at all (deletion in
    /// progress). Rows are removed from the control-plane database only after
    /// an agent confirms absence, exactly like VM deletes.

    /// Whether an observed status already satisfies this goal. `.exited`
    /// satisfies `.running`: desired-running means "the workload should have
    /// been started", and a workload that ran to completion fulfilled that —
    /// phase 1 has no restart policy, so the reconciler must not relaunch
    /// one-shot workloads forever. `.exited` also satisfies `.stopped` (it is
    /// equally not-running; the two differ only in how the run ended).
    public func isSatisfied(by observed: SandboxStatus) -> Bool {
        switch self {
        case .running:
            return observed == .running || observed == .exited
        case .stopped:
            return observed == .stopped || observed == .exited
        case .suspended:
            return observed == .suspended
        case .absent:
            return false  // absence is confirmed by omission from the observed set, never by a status
        case .unspecified, .UNRECOGNIZED:
            return false
        }
    }

    public var protocolValue: String {
        switch self {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .suspended: return "Suspended"
        case .absent: return "Absent"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "Running": self = .running
        case "Stopped": self = .stopped
        case "Suspended": self = .suspended
        case "Absent": self = .absent
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.running, .stopped, .suspended, .absent] }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}
