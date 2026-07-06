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

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        syncId: String = UUID().uuidString,
        vms: [DesiredVMState]
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.syncId = syncId
        self.vms = vms
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
    public let resources: AgentResources

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        agentId: String,
        vms: [ObservedVMState],
        resources: AgentResources
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.agentId = agentId
        self.vms = vms
        self.resources = resources
    }
}
