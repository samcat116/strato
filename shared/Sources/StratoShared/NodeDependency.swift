import Foundation

/// Stable identities for software the agent depends on to serve a feature.
///
/// The registry is compiled with the agent. Configuration can select a desired
/// state for one of these modules, but cannot name an executable or load code.
public enum NodeDependencyID: String, Codable, CaseIterable, Sendable {
    case spire
    case libvirt
    case ovnOvs = "ovn_ovs"
    case frr
    case cephClient = "ceph_client"
    case cephCluster = "ceph_cluster"
}

public enum NodeDependencyRole: String, Codable, Sendable {
    case identity
    case compute
    case networking
    case routing
    case storage
}

/// Who may change a dependency's host state.
public enum NodeDependencyOwnership: String, Codable, Sendable {
    /// An operator or external orchestrator owns it. Strato only observes.
    case observeOnly = "observe_only"
    /// Strato may enable/start/restart the low-level supervisor, within policy.
    case ensureRunning = "ensure_running"
    /// Strato owns both desired configuration and lifecycle.
    case reconcile
}

public enum NodeDependencyDesiredState: String, Codable, Sendable {
    case disabled
    case required
}

public enum NodeDependencySupervisorState: String, Codable, Sendable {
    case notApplicable = "not_applicable"
    case missing
    case inactive
    case activating
    case active
    case failed
    case unknown
}

public enum NodeDependencyCompatibility: String, Codable, Sendable {
    case unknown
    case compatible
    case incompatible
}

public enum NodeDependencyFunctionalState: String, Codable, Sendable {
    case unknown
    case starting
    case healthy
    case degraded
    case unhealthy
}

/// Feature-scoped placement and serving promises a dependency can withdraw.
public enum NodeCapability: String, Codable, CaseIterable, Sendable {
    case workloadIdentity = "workload_identity"
    case qemuPlacement = "qemu_placement"
    case overlayNetworking = "overlay_networking"
    case sandboxNetworking = "sandbox_networking"
    case networkResolver = "network_resolver"
    case dynamicRouting = "dynamic_routing"
    case cephVolumes = "ceph_volumes"
}

public enum NodeDependencyFailureCode: String, Codable, Sendable {
    case dependencyFailed = "dependency_failed"
    case missingBinary = "missing_binary"
    case missingUnit = "missing_unit"
    case incompatibleVersion = "incompatible_version"
    case inactiveUnit = "inactive_unit"
    case failedUnit = "failed_unit"
    case commandTimedOut = "command_timed_out"
    case malformedOutput = "malformed_output"
    case functionalProbeFailed = "functional_probe_failed"
    case staleObservation = "stale_observation"
    case remediationUnauthorized = "remediation_unauthorized"
    case remediationBudgetExhausted = "remediation_budget_exhausted"
    case remediationFailed = "remediation_failed"
}

public struct NodeDependencyFailureReason: Codable, Equatable, Sendable {
    public let code: NodeDependencyFailureCode
    public let message: String

    public init(code: NodeDependencyFailureCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// The latest level-triggered observation of one node dependency.
public struct NodeDependencyObservation: Codable, Equatable, Sendable {
    public let id: NodeDependencyID
    public let role: NodeDependencyRole
    public let desiredState: NodeDependencyDesiredState
    public let ownership: NodeDependencyOwnership
    public let supervisorState: NodeDependencySupervisorState
    public let installedVersion: String?
    public let daemonVersion: String?
    public let compatibility: NodeDependencyCompatibility
    public let functionalState: NodeDependencyFunctionalState
    public let checkedAt: Date
    public let lastHealthyAt: Date?
    public let reason: NodeDependencyFailureReason?
    public let consecutiveFailures: Int
    public let remediationCount: Int
    public let restartCount: Int
    public let affectedCapabilities: [NodeCapability]

    public init(
        id: NodeDependencyID,
        role: NodeDependencyRole,
        desiredState: NodeDependencyDesiredState,
        ownership: NodeDependencyOwnership,
        supervisorState: NodeDependencySupervisorState,
        installedVersion: String? = nil,
        daemonVersion: String? = nil,
        compatibility: NodeDependencyCompatibility,
        functionalState: NodeDependencyFunctionalState,
        checkedAt: Date,
        lastHealthyAt: Date? = nil,
        reason: NodeDependencyFailureReason? = nil,
        consecutiveFailures: Int = 0,
        remediationCount: Int = 0,
        restartCount: Int = 0,
        affectedCapabilities: [NodeCapability]
    ) {
        self.id = id
        self.role = role
        self.desiredState = desiredState
        self.ownership = ownership
        self.supervisorState = supervisorState
        self.installedVersion = installedVersion
        self.daemonVersion = daemonVersion
        self.compatibility = compatibility
        self.functionalState = functionalState
        self.checkedAt = checkedAt
        self.lastHealthyAt = lastHealthyAt
        self.reason = reason
        self.consecutiveFailures = consecutiveFailures
        self.remediationCount = remediationCount
        self.restartCount = restartCount
        self.affectedCapabilities = affectedCapabilities
    }

    /// Whether this observation is fresh and authoritative for new work.
    /// Running workloads are deliberately not coupled to this answer.
    public func allowsNewWork(at now: Date, staleAfter: TimeInterval) -> Bool {
        guard desiredState == .required,
            now.timeIntervalSince(checkedAt) <= staleAfter,
            compatibility == .compatible,
            supervisorState == .active || supervisorState == .notApplicable
        else { return false }

        // A single failed sample is reported as degraded but remains eligible;
        // the manager promotes it to unhealthy only after its failure threshold.
        return functionalState == .healthy || functionalState == .degraded
    }
}
