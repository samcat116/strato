import Foundation

// MARK: - Sandbox Specification

/// Description of a sandbox workload — a microVM booted from an OCI image —
/// sent from the control plane to an agent.
///
/// Deliberately distinct from `VMSpec` so the two workload types can diverge:
/// sandboxes reference OCI images (not the `Image`/`ImageArtifact` model), boot
/// through Firecracker only (no `HypervisorType`, no firmware/boot source), have
/// no attachable volumes, and carry at most one NIC. The control plane sends
/// only what it can legitimately know; rootfs materialization, kernel choice,
/// and vsock wiring are agent-side concerns.
public struct SandboxSpec: Codable, Sendable {
    /// OCI image reference as provided by the user, e.g.
    /// `ghcr.io/acme/worker:v3`. Kept verbatim for guest identity and logging;
    /// agents converge on `imageDigest` when present.
    public let image: String
    /// Manifest digest (`sha256:...`) the reference resolved to, pinned by the
    /// control plane so convergence is immutable — a re-tagged image never
    /// changes a sandbox out from under its generation. Nil only from control
    /// planes that predate tag→digest resolution (issue #414); the agent then
    /// resolves the tag itself, accepting the mutability.
    public let imageDigest: String?
    /// Number of vCPUs.
    public let cpus: Int
    /// Guest memory size in bytes.
    public let memoryBytes: Int64
    /// Entrypoint override. Nil means use the image config's entrypoint.
    public let entrypoint: [String]?
    /// Command (arguments) override. Nil means use the image config's cmd.
    public let cmd: [String]?
    /// Environment variable overrides, merged over the image config's
    /// environment by the guest agent (override wins on key collision).
    public let env: [String: String]
    /// Working directory override. Nil means use the image config's value.
    public let workingDir: String?
    /// The sandbox's single NIC, when networked. Reuses the VM NIC spec so
    /// agents realize the attachment through the same OVN/user-mode paths.
    public let network: NetworkSpec?

    public init(
        image: String,
        imageDigest: String? = nil,
        cpus: Int,
        memoryBytes: Int64,
        entrypoint: [String]? = nil,
        cmd: [String]? = nil,
        env: [String: String] = [:],
        workingDir: String? = nil,
        network: NetworkSpec? = nil
    ) {
        self.image = image
        self.imageDigest = imageDigest
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.entrypoint = entrypoint
        self.cmd = cmd
        self.env = env
        self.workingDir = workingDir
        self.network = network
    }
}

// MARK: - Registry Credential

/// Short-lived credential material for pulling a sandbox's image from a private
/// registry. Minted fresh at every sync assembly (like signed image URLs), so a
/// long-lived desired entry never carries an expired credential. Agents use it
/// for the pull and must never persist it; durable credential storage lives
/// only on the control plane (issue #414).
public struct RegistryCredential: Codable, Sendable {
    /// Registry host the credential is scoped to, e.g. `ghcr.io`.
    public let registry: String
    public let username: String
    /// Password or short-lived bearer/identity token, per the registry's
    /// distribution auth flow.
    public let password: String
    /// When the material expires, for agent awareness (skip a doomed pull and
    /// surface a fresh-sync need instead).
    public let expiresAt: Date?
    /// When true, `password` is a distribution bearer token the control plane
    /// already minted: present it directly as `Authorization: Bearer` on
    /// registry requests. Nil/false means Basic credentials (the agent runs
    /// the registry's own challenge flow with them). Optional so payloads
    /// from control planes that predate token minting still decode.
    public let bearer: Bool?

    public init(
        registry: String, username: String, password: String, expiresAt: Date? = nil, bearer: Bool? = nil
    ) {
        self.registry = registry
        self.username = username
        self.password = password
        self.expiresAt = expiresAt
        self.bearer = bearer
    }
}

// MARK: - Sandbox Status

/// A sandbox's *observed* runtime state, as reported by an agent. Mirrors
/// `VMStatus` (including tolerant decoding), with one sandbox-specific case:
/// `.exited`, because a sandbox's workload can finish on its own — something a
/// VM never does from the control plane's point of view.
public enum SandboxStatus: String, Codable, CaseIterable, Sendable {
    /// Exists agent-side (rootfs materialized) but not running.
    case stopped = "Stopped"
    case running = "Running"
    /// The workload ran and ended on its own; `ObservedSandboxState.exitCode`
    /// carries the result. Terminal: distinct from `.stopped` (a control-plane
    /// initiated stop) so one-shot workloads are not restarted.
    case exited = "Exited"

    // Transitional states: convergence is in flight and the agent has not yet
    // reached the terminal state.
    case starting = "Starting"
    case stopping = "Stopping"

    // Diagnostic states set by reconciliation, never by normal convergence.
    case error = "Error"
    case unknown = "Unknown"

    /// True while convergence is in flight and not yet settled.
    public var isTransitional: Bool {
        switch self {
        case .starting, .stopping:
            return true
        case .stopped, .running, .exited, .error, .unknown:
            return false
        }
    }

    /// Tolerant decoding: an unrecognized status string (e.g. from an agent
    /// running a newer protocol version) decodes to `.unknown` instead of
    /// throwing, so version skew cannot crash message handling.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SandboxStatus(rawValue: raw) ?? .unknown
    }
}

// MARK: - Desired Sandbox Status

/// The state the control plane wants a sandbox to be in. Same contract as
/// `DesiredVMStatus`: a goal, never a report, so no transitional or diagnostic
/// cases — and deliberately strict decoding, because misinterpreting a desired
/// status could stop or delete a running workload. An unknown value fails the
/// whole sync and the agent keeps its current state; adding a case therefore
/// requires a `WireProtocol` version bump and a dual-mode rollout.
public enum DesiredSandboxStatus: String, Codable, CaseIterable, Sendable {
    case running = "Running"
    case stopped = "Stopped"
    /// The sandbox should not exist on the agent at all (deletion in
    /// progress). Rows are removed from the control-plane database only after
    /// an agent confirms absence, exactly like VM deletes.
    case absent = "Absent"

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
        case .absent:
            return false  // absence is confirmed by omission from the observed set, never by a status
        }
    }
}
