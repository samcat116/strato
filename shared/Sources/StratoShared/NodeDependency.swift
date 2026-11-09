import Foundation
import SwiftProtobuf

/// Stable identities for software the agent depends on to serve a feature.
///
/// The registry is compiled with the agent. Configuration can select a desired
/// state for one of these modules, but cannot name an executable or load code.
public typealias NodeDependencyID = Strato_Agent_V1_NodeDependencyID
extension Strato_Agent_V1_NodeDependencyID: Codable {

    public var protocolValue: String {
        switch self {
        case .spire: return "spire"
        case .libvirt: return "libvirt"
        case .ovnOvs: return "ovn_ovs"
        case .frr: return "frr"
        case .cephClient: return "ceph_client"
        case .cephCluster: return "ceph_cluster"
        case .hostMemoryProfile: return "host_memory_profile"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "spire": self = .spire
        case "libvirt": self = .libvirt
        case "ovn_ovs": self = .ovnOvs
        case "frr": self = .frr
        case "ceph_client": self = .cephClient
        case "ceph_cluster": self = .cephCluster
        case "host_memory_profile": self = .hostMemoryProfile
        default: return nil
        }
    }

    public static var knownCases: [Self] {
        [.spire, .libvirt, .ovnOvs, .frr, .cephClient, .cephCluster, .hostMemoryProfile]
    }

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

public typealias NodeDependencyRole = Strato_Agent_V1_NodeDependencyRole
extension Strato_Agent_V1_NodeDependencyRole: Codable {

    public var protocolValue: String {
        switch self {
        case .identity: return "identity"
        case .compute: return "compute"
        case .networking: return "networking"
        case .routing: return "routing"
        case .storage: return "storage"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "identity": self = .identity
        case "compute": self = .compute
        case "networking": self = .networking
        case "routing": self = .routing
        case "storage": self = .storage
        default: return nil
        }
    }

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

/// Who may change a dependency's host state.
public typealias NodeDependencyOwnership = Strato_Agent_V1_NodeDependencyOwnership
extension Strato_Agent_V1_NodeDependencyOwnership: Codable {
    /// An operator or external orchestrator owns it. Strato only observes.

    /// Strato may enable/start/restart the low-level supervisor, within policy.

    /// Strato owns both desired configuration and lifecycle.

    public var protocolValue: String {
        switch self {
        case .observeOnly: return "observe_only"
        case .ensureRunning: return "ensure_running"
        case .reconcile: return "reconcile"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "observe_only": self = .observeOnly
        case "ensure_running": self = .ensureRunning
        case "reconcile": self = .reconcile
        default: return nil
        }
    }

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

public typealias NodeDependencyDesiredState = Strato_Agent_V1_NodeDependencyDesiredState
extension Strato_Agent_V1_NodeDependencyDesiredState: Codable {

    public var protocolValue: String {
        switch self {
        case .disabled: return "disabled"
        case .`required`: return "required"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "disabled": self = .disabled
        case "required": self = .`required`
        default: return nil
        }
    }

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

public typealias NodeDependencySupervisorState = Strato_Agent_V1_NodeDependencySupervisorState
extension Strato_Agent_V1_NodeDependencySupervisorState: Codable {

    public var protocolValue: String {
        switch self {
        case .notApplicable: return "not_applicable"
        case .missing: return "missing"
        case .inactive: return "inactive"
        case .activating: return "activating"
        case .active: return "active"
        case .failed: return "failed"
        case .unknown: return "unknown"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "not_applicable": self = .notApplicable
        case "missing": self = .missing
        case "inactive": self = .inactive
        case "activating": self = .activating
        case "active": self = .active
        case "failed": self = .failed
        case "unknown": self = .unknown
        default: return nil
        }
    }

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

public typealias NodeDependencyCompatibility = Strato_Agent_V1_NodeDependencyCompatibility
extension Strato_Agent_V1_NodeDependencyCompatibility: Codable {

    public var protocolValue: String {
        switch self {
        case .unknown: return "unknown"
        case .compatible: return "compatible"
        case .incompatible: return "incompatible"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "unknown": self = .unknown
        case "compatible": self = .compatible
        case "incompatible": self = .incompatible
        default: return nil
        }
    }

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

public typealias NodeDependencyFunctionalState = Strato_Agent_V1_NodeDependencyFunctionalState
extension Strato_Agent_V1_NodeDependencyFunctionalState: Codable {

    public var protocolValue: String {
        switch self {
        case .unknown: return "unknown"
        case .starting: return "starting"
        case .healthy: return "healthy"
        case .degraded: return "degraded"
        case .unhealthy: return "unhealthy"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "unknown": self = .unknown
        case "starting": self = .starting
        case "healthy": self = .healthy
        case "degraded": self = .degraded
        case "unhealthy": self = .unhealthy
        default: return nil
        }
    }

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

/// Feature-scoped placement and serving promises a dependency can withdraw.
public typealias NodeCapability = Strato_Agent_V1_NodeCapability
extension Strato_Agent_V1_NodeCapability: Codable {

    public var protocolValue: String {
        switch self {
        case .workloadIdentity: return "workload_identity"
        case .qemuPlacement: return "qemu_placement"
        case .overlayNetworking: return "overlay_networking"
        case .sandboxNetworking: return "sandbox_networking"
        case .networkResolver: return "network_resolver"
        case .dynamicRouting: return "dynamic_routing"
        case .cephVolumes: return "ceph_volumes"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "workload_identity": self = .workloadIdentity
        case "qemu_placement": self = .qemuPlacement
        case "overlay_networking": self = .overlayNetworking
        case "sandbox_networking": self = .sandboxNetworking
        case "network_resolver": self = .networkResolver
        case "dynamic_routing": self = .dynamicRouting
        case "ceph_volumes": self = .cephVolumes
        default: return nil
        }
    }

    public static var knownCases: [Self] {
        [
            .workloadIdentity, .qemuPlacement, .overlayNetworking, .sandboxNetworking, .networkResolver,
            .dynamicRouting, .cephVolumes,
        ]
    }

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

public typealias NodeDependencyFailureCode = Strato_Agent_V1_NodeDependencyFailureCode
extension Strato_Agent_V1_NodeDependencyFailureCode: Codable {

    public var protocolValue: String {
        switch self {
        case .dependencyFailed: return "dependency_failed"
        case .missingBinary: return "missing_binary"
        case .missingUnit: return "missing_unit"
        case .incompatibleVersion: return "incompatible_version"
        case .inactiveUnit: return "inactive_unit"
        case .failedUnit: return "failed_unit"
        case .commandTimedOut: return "command_timed_out"
        case .malformedOutput: return "malformed_output"
        case .functionalProbeFailed: return "functional_probe_failed"
        case .staleObservation: return "stale_observation"
        case .remediationUnauthorized: return "remediation_unauthorized"
        case .remediationBudgetExhausted: return "remediation_budget_exhausted"
        case .remediationFailed: return "remediation_failed"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "dependency_failed": self = .dependencyFailed
        case "missing_binary": self = .missingBinary
        case "missing_unit": self = .missingUnit
        case "incompatible_version": self = .incompatibleVersion
        case "inactive_unit": self = .inactiveUnit
        case "failed_unit": self = .failedUnit
        case "command_timed_out": self = .commandTimedOut
        case "malformed_output": self = .malformedOutput
        case "functional_probe_failed": self = .functionalProbeFailed
        case "stale_observation": self = .staleObservation
        case "remediation_unauthorized": self = .remediationUnauthorized
        case "remediation_budget_exhausted": self = .remediationBudgetExhausted
        case "remediation_failed": self = .remediationFailed
        default: return nil
        }
    }

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

public typealias NodeDependencyFailureReason = Strato_Agent_V1_NodeDependencyFailureReason
extension Strato_Agent_V1_NodeDependencyFailureReason: Codable {

    public init(code: NodeDependencyFailureCode, message: String) {
        self.init()
        self._jsonCode = code
        self._jsonMessage = message
    }

    private enum CodingKeys: String, CodingKey { case code; case message }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonCode = try container.decode(NodeDependencyFailureCode.self, forKey: .code)
        self._jsonMessage = try container.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonCode, forKey: .code)
        try container.encode(_jsonMessage, forKey: .message)
    }

    var _jsonCode: NodeDependencyFailureCode {
        get { code }
        set { let value = newValue; code = value }
    }
    var _jsonMessage: String {
        get { message }
        set { let value = newValue; message = value }
    }
}

/// The latest level-triggered observation of one node dependency.
public typealias NodeDependencyObservation = Strato_Agent_V1_NodeDependencyObservation
extension Strato_Agent_V1_NodeDependencyObservation: Codable {

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
        self.init()
        self._jsonId = id
        self._jsonRole = role
        self._jsonDesiredState = desiredState
        self._jsonOwnership = ownership
        self._jsonSupervisorState = supervisorState
        self._jsonInstalledVersion = installedVersion
        self._jsonDaemonVersion = daemonVersion
        self._jsonCompatibility = compatibility
        self._jsonFunctionalState = functionalState
        self._jsonCheckedAt = checkedAt
        self._jsonLastHealthyAt = lastHealthyAt
        self._jsonReason = reason
        self._jsonConsecutiveFailures = consecutiveFailures
        self._jsonRemediationCount = remediationCount
        self._jsonRestartCount = restartCount
        self._jsonAffectedCapabilities = affectedCapabilities
    }

    /// Whether the observed state permits dependent work. Freshness is a
    /// receiver concern because `checkedAt` comes from the agent's clock.
    public var permitsDependentWork: Bool {
        guard _jsonDesiredState == .required,
            _jsonCompatibility == .compatible
        else { return false }

        // Supervisor state is diagnostic metadata. The dependency module has
        // already incorporated it when the configured supervisor owns the
        // process; externally supervised dependencies remain usable when their
        // functional probe succeeds.
        // A single failed sample is reported as degraded but remains eligible;
        // the manager promotes it to unhealthy only after its failure threshold.
        return _jsonFunctionalState == .healthy || _jsonFunctionalState == .degraded
    }

    /// Whether this observation is fresh and authoritative for new work.
    /// `receivedAt` must be assigned by the control plane when it ingests the
    /// snapshot; agent-supplied timestamps remain diagnostic only.
    public func allowsNewWork(
        receivedAt: Date,
        at now: Date,
        staleAfter: TimeInterval
    ) -> Bool {
        let age = now.timeIntervalSince(receivedAt)
        return age >= 0 && age <= staleAfter && permitsDependentWork
    }

    private enum CodingKeys: String, CodingKey {
        case id; case role; case desiredState; case ownership; case supervisorState; case installedVersion;
        case daemonVersion; case compatibility; case functionalState; case checkedAt; case lastHealthyAt; case reason;
        case consecutiveFailures; case remediationCount; case restartCount; case affectedCapabilities
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonId = try container.decode(NodeDependencyID.self, forKey: .id)
        self._jsonRole = try container.decode(NodeDependencyRole.self, forKey: .role)
        self._jsonDesiredState = try container.decode(NodeDependencyDesiredState.self, forKey: .desiredState)
        self._jsonOwnership = try container.decode(NodeDependencyOwnership.self, forKey: .ownership)
        self._jsonSupervisorState = try container.decode(NodeDependencySupervisorState.self, forKey: .supervisorState)
        self._jsonInstalledVersion = try container.decodeIfPresent(String.self, forKey: .installedVersion)
        self._jsonDaemonVersion = try container.decodeIfPresent(String.self, forKey: .daemonVersion)
        self._jsonCompatibility = try container.decode(NodeDependencyCompatibility.self, forKey: .compatibility)
        self._jsonFunctionalState = try container.decode(NodeDependencyFunctionalState.self, forKey: .functionalState)
        self._jsonCheckedAt = try container.decode(Date.self, forKey: .checkedAt)
        self._jsonLastHealthyAt = try container.decodeIfPresent(Date.self, forKey: .lastHealthyAt)
        self._jsonReason = try container.decodeIfPresent(NodeDependencyFailureReason.self, forKey: .reason)
        self._jsonConsecutiveFailures = try container.decode(Int.self, forKey: .consecutiveFailures)
        self._jsonRemediationCount = try container.decode(Int.self, forKey: .remediationCount)
        self._jsonRestartCount = try container.decode(Int.self, forKey: .restartCount)
        self._jsonAffectedCapabilities = try container.decode([NodeCapability].self, forKey: .affectedCapabilities)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonId, forKey: .id)
        try container.encode(_jsonRole, forKey: .role)
        try container.encode(_jsonDesiredState, forKey: .desiredState)
        try container.encode(_jsonOwnership, forKey: .ownership)
        try container.encode(_jsonSupervisorState, forKey: .supervisorState)
        try container.encodeIfPresent(_jsonInstalledVersion, forKey: .installedVersion)
        try container.encodeIfPresent(_jsonDaemonVersion, forKey: .daemonVersion)
        try container.encode(_jsonCompatibility, forKey: .compatibility)
        try container.encode(_jsonFunctionalState, forKey: .functionalState)
        try container.encode(_jsonCheckedAt, forKey: .checkedAt)
        try container.encodeIfPresent(_jsonLastHealthyAt, forKey: .lastHealthyAt)
        try container.encodeIfPresent(_jsonReason, forKey: .reason)
        try container.encode(_jsonConsecutiveFailures, forKey: .consecutiveFailures)
        try container.encode(_jsonRemediationCount, forKey: .remediationCount)
        try container.encode(_jsonRestartCount, forKey: .restartCount)
        try container.encode(_jsonAffectedCapabilities, forKey: .affectedCapabilities)
    }

    var _jsonId: NodeDependencyID {
        get { id }
        set { let value = newValue; id = value }
    }
    var _jsonRole: NodeDependencyRole {
        get { role }
        set { let value = newValue; role = value }
    }
    var _jsonDesiredState: NodeDependencyDesiredState {
        get { desiredState }
        set { let value = newValue; desiredState = value }
    }
    var _jsonOwnership: NodeDependencyOwnership {
        get { ownership }
        set { let value = newValue; ownership = value }
    }
    var _jsonSupervisorState: NodeDependencySupervisorState {
        get { supervisorState }
        set { let value = newValue; supervisorState = value }
    }
    var _jsonInstalledVersion: String? {
        get { hasInstalledVersion ? (installedVersion) : nil }
        set { if let value = newValue { installedVersion = value } else { clearInstalledVersion() } }
    }
    var _jsonDaemonVersion: String? {
        get { hasDaemonVersion ? (daemonVersion) : nil }
        set { if let value = newValue { daemonVersion = value } else { clearDaemonVersion() } }
    }
    var _jsonCompatibility: NodeDependencyCompatibility {
        get { compatibility }
        set { let value = newValue; compatibility = value }
    }
    var _jsonFunctionalState: NodeDependencyFunctionalState {
        get { functionalState }
        set { let value = newValue; functionalState = value }
    }
    var _jsonCheckedAt: Date {
        get { checkedAt.date }
        set { let value = newValue; checkedAt = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonLastHealthyAt: Date? {
        get { hasLastHealthyAt ? (lastHealthyAt.date) : nil }
        set {
            if let value = newValue {
                lastHealthyAt = Google_Protobuf_Timestamp(date: value)
            } else {
                clearLastHealthyAt()
            }
        }
    }
    var _jsonReason: NodeDependencyFailureReason? {
        get { hasReason ? (reason) : nil }
        set { if let value = newValue { reason = value } else { clearReason() } }
    }
    var _jsonConsecutiveFailures: Int {
        get { Int(consecutiveFailures) }
        set { let value = newValue; consecutiveFailures = Int64(value) }
    }
    var _jsonRemediationCount: Int {
        get { Int(remediationCount) }
        set { let value = newValue; remediationCount = Int64(value) }
    }
    var _jsonRestartCount: Int {
        get { Int(restartCount) }
        set { let value = newValue; restartCount = Int64(value) }
    }
    var _jsonAffectedCapabilities: [NodeCapability] {
        get { affectedCapabilities.values }
        set {
            let value = newValue;
            affectedCapabilities = Strato_Agent_V1_NodeDependencyObservationAffectedCapabilitiesSection.with {
                $0.values = value
            }
        }
    }
}
