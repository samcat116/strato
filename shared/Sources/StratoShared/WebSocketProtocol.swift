import Foundation
import SwiftProtobuf

// MARK: - WebSocket Message Types

public enum MessageType: String, Codable, Sendable {
    case agentRegister = "agent_register"
    case agentRegisterResponse = "agent_register_response"
    case agentHeartbeat = "agent_heartbeat"
    case agentUnregister = "agent_unregister"

    case consoleConnect = "console_connect"
    case consoleDisconnect = "console_disconnect"
    case consoleData = "console_data"
    case consoleConnected = "console_connected"
    case consoleDisconnected = "console_disconnected"

    case desiredState = "desired_state"
    case observedState = "observed_state"

    // Unsolicited acknowledgements and registration failures.
    case success = "success"
    case error = "error"
    case vmLog = "vm_log"

    // Live streams and recorded replay are keyed by sessionId.
    case guestExecStart = "guest_exec_start"
    case guestExecStarted = "guest_exec_started"
    case guestExecInput = "guest_exec_input"
    case guestExecOutput = "guest_exec_output"
    case guestExecResize = "guest_exec_resize"
    case guestExecExit = "guest_exec_exit"
    case guestExecClose = "guest_exec_close"
    case guestExecClosed = "guest_exec_closed"
    case guestExecRecordedState = "guest_exec_recorded_state"
    case guestExecRecordedAck = "guest_exec_recorded_ack"

    case sandboxLog = "sandbox_log"
}

// MARK: - Base Message Protocol

public protocol WebSocketMessage: SwiftProtobuf.Message, Codable {
    var type: MessageType { get }
    var requestId: String { get }
    var timestamp: Google_Protobuf_Timestamp { get }
}

// MARK: - Agent Messages

public typealias AgentRegisterMessage = Strato_Agent_V1_AgentRegisterMessage
extension Strato_Agent_V1_AgentRegisterMessage: WebSocketMessage {
    public var type: MessageType { .agentRegister }
    /// Host CPU architecture.
    /// Every hypervisor on this host with probed availability and capabilities.
    /// Networking capability of this host. Nil means networking is disabled or
    /// its host probe could not establish a usable mode.
    /// Registration offers the stable protocol major and supported capabilities.
    /// Peers agree on required features before accepting workload messages.
    /// Whether this agent runs sandbox workloads (OCI-image Firecracker
    /// microVMs, issue #410): it reconciles `DesiredStateMessage.sandboxes`
    /// and reports them back in `ObservedStateReport.sandboxes`. The scheduler
    /// keys placement on this explicit signal because the
    /// separately installed runtime, not the wire version, determines support.
    /// Whether this agent can realize a **sandbox NIC** (STR-103), as opposed
    /// to merely running sandboxes.
    ///
    /// A second signal on top of `sandboxCapable`, and for a sharper version of
    /// the same reason: the pieces a sandbox NIC needs are installed
    /// independently of the agent binary, so no version and no other capability
    /// implies them. It takes OVN/OVS networking (the veth + in-namespace TAP
    /// recipe has no user-mode equivalent), the jailer barrier (the NIC lives in
    /// the jail's network namespace, and an unjailed sandbox has none), and a
    /// **guest image** whose init understands the config drive's `network`
    /// block — and the guest image is a separately distributed artifact at
    /// `sandbox_guest_image_path`, so an up-to-date agent can be paired with a
    /// guest that would refuse the document.
    ///
    /// The control plane uses it twice: the scheduler refuses to place a
    /// sandbox that has a NIC on a host without it, and desired-state assembly
    /// withholds `SandboxSpec.network` from such a host — so an agent that
    /// cannot realize a NIC is never handed one.
    /// Whether this host can give a guest an emulated TPM 2.0 — it has a
    /// usable `swtpm` binary (issue #565). Like `sandboxCapable`, speaking the
    /// wire version is deliberately not sufficient: the protocol carries
    /// `MachineProfile.tpm`, but only a host with swtpm installed can realize
    /// it, and a VM whose vTPM is silently dropped fails Windows setup with no
    /// explanation.
    /// Host operating system, reported so the control plane can resolve the
    /// right release artifact for an agent self-update (assets are published
    /// per OS/arch pair).
    /// Descriptive hardware/platform/OS details for operators (CPU model,
    /// kernel version, distribution, physical core count, boot time, ...).
    /// Purely informational and entirely best-effort; any individual field the
    /// agent could not probe is absent.
    /// Whether this host can actually run the per-network DNS resolver
    /// (STR-40): it is in OVN network mode and has a usable CoreDNS binary.
    ///
    /// Like `sandboxCapable` and `tpmCapable`, speaking the wire version is
    /// deliberately not sufficient — a v37 build understands `resolverEnabled`,
    /// but only a host with CoreDNS installed can answer on the resolver
    /// address, and a guest pointed at an address nothing listens on loses
    /// external name resolution entirely.
    ///
    /// The control plane combines this **across the whole site** before
    /// enabling a network's resolver, because the DHCP option is authored once
    /// per network by the topology authority while the listener is per
    /// chassis: one incapable host would otherwise give a network DNS that
    /// works until a VM lands somewhere else.
    /// Whether this host initialized the guest-facing instance metadata
    /// service. This is independent of overlay networking: an OVN host may
    /// disable the service in its agent configuration or lack a host tool the
    /// listener supervisor needs.
    /// Periodic, feature-scoped software dependency health. This is also sent
    /// at registration so a newly connected agent is not placement-eligible in
    /// the window before its first heartbeat.
    /// Nil/empty advertises no burstable support. STR272 must supply verified backend evidence.

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        agentId: String,
        hostname: String,
        version: String,
        resources: AgentResources,
        architecture: CPUArchitecture = .x86_64,
        hypervisors: [HypervisorSupport] = [],
        networkCapability: NetworkCapability? = nil,
        protocolOffer: Strato_Agent_V1_ProtocolOffer = AgentProtocolCompatibility.localOffer,
        sandboxCapable: Bool = false,
        sandboxNetworkingCapable: Bool = false,
        tpmCapable: Bool = false,
        operatingSystem: OperatingSystem = .current,
        hostInfo: HostInfo? = nil,
        resolverCapable: Bool = false,
        metadataServiceCapable: Bool = false,
        resourceClassEnforcement: [WorkloadResourceClassEnforcement]? = nil,
        dependencyObservations: [NodeDependencyObservation] = []
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonAgentId = agentId
        self._jsonHostname = hostname
        self._jsonVersion = version
        self._jsonResources = resources
        self._jsonArchitecture = architecture
        self._jsonHypervisors = hypervisors
        self._jsonNetworkCapability = networkCapability
        self._jsonProtocolOffer = protocolOffer
        self._jsonSandboxCapable = sandboxCapable
        self._jsonSandboxNetworkingCapable = sandboxNetworkingCapable
        self._jsonTpmCapable = tpmCapable
        self._jsonOperatingSystem = operatingSystem
        self._jsonHostInfo = hostInfo
        self._jsonResolverCapable = resolverCapable
        self._jsonMetadataServiceCapable = metadataServiceCapable
        self._jsonResourceClassEnforcement = resourceClassEnforcement
        self._jsonDependencyObservations = dependencyObservations
    }

    private enum CodingKeys: String, CodingKey {
        case requestId; case timestamp; case agentId; case hostname; case version; case resources; case architecture;
        case hypervisors; case networkCapability; case protocolOffer; case sandboxCapable;
        case sandboxNetworkingCapable; case tpmCapable; case operatingSystem; case hostInfo; case resolverCapable;
        case metadataServiceCapable; case resourceClassEnforcement; case dependencyObservations
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonAgentId = try container.decode(String.self, forKey: .agentId)
        self._jsonHostname = try container.decode(String.self, forKey: .hostname)
        self._jsonVersion = try container.decode(String.self, forKey: .version)
        self._jsonResources = try container.decode(AgentResources.self, forKey: .resources)
        self._jsonArchitecture = try container.decode(CPUArchitecture.self, forKey: .architecture)
        self._jsonHypervisors = try container.decode([HypervisorSupport].self, forKey: .hypervisors)
        self._jsonNetworkCapability = try container.decodeIfPresent(NetworkCapability.self, forKey: .networkCapability)
        self._jsonProtocolOffer = try container.decode(Strato_Agent_V1_ProtocolOffer.self, forKey: .protocolOffer)
        self._jsonSandboxCapable = try container.decode(Bool.self, forKey: .sandboxCapable)
        self._jsonSandboxNetworkingCapable = try container.decode(Bool.self, forKey: .sandboxNetworkingCapable)
        self._jsonTpmCapable = try container.decode(Bool.self, forKey: .tpmCapable)
        self._jsonOperatingSystem = try container.decode(OperatingSystem.self, forKey: .operatingSystem)
        self._jsonHostInfo = try container.decodeIfPresent(HostInfo.self, forKey: .hostInfo)
        self._jsonResolverCapable = try container.decode(Bool.self, forKey: .resolverCapable)
        self._jsonMetadataServiceCapable = try container.decode(Bool.self, forKey: .metadataServiceCapable)
        self._jsonResourceClassEnforcement = try container.decodeIfPresent(
            [WorkloadResourceClassEnforcement].self, forKey: .resourceClassEnforcement)
        self._jsonDependencyObservations = try container.decode(
            [NodeDependencyObservation].self, forKey: .dependencyObservations)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonAgentId, forKey: .agentId)
        try container.encode(_jsonHostname, forKey: .hostname)
        try container.encode(_jsonVersion, forKey: .version)
        try container.encode(_jsonResources, forKey: .resources)
        try container.encode(_jsonArchitecture, forKey: .architecture)
        try container.encode(_jsonHypervisors, forKey: .hypervisors)
        try container.encodeIfPresent(_jsonNetworkCapability, forKey: .networkCapability)
        try container.encode(_jsonProtocolOffer, forKey: .protocolOffer)
        try container.encode(_jsonSandboxCapable, forKey: .sandboxCapable)
        try container.encode(_jsonSandboxNetworkingCapable, forKey: .sandboxNetworkingCapable)
        try container.encode(_jsonTpmCapable, forKey: .tpmCapable)
        try container.encode(_jsonOperatingSystem, forKey: .operatingSystem)
        try container.encodeIfPresent(_jsonHostInfo, forKey: .hostInfo)
        try container.encode(_jsonResolverCapable, forKey: .resolverCapable)
        try container.encode(_jsonMetadataServiceCapable, forKey: .metadataServiceCapable)
        try container.encodeIfPresent(_jsonResourceClassEnforcement, forKey: .resourceClassEnforcement)
        try container.encode(_jsonDependencyObservations, forKey: .dependencyObservations)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonAgentId: String {
        get { agentID }
        set { let value = newValue; agentID = value }
    }
    var _jsonHostname: String {
        get { hostname }
        set { let value = newValue; hostname = value }
    }
    var _jsonVersion: String {
        get { version }
        set { let value = newValue; version = value }
    }
    var _jsonResources: AgentResources {
        get { resources }
        set { let value = newValue; resources = value }
    }
    var _jsonArchitecture: CPUArchitecture {
        get { architecture }
        set { let value = newValue; architecture = value }
    }
    var _jsonHypervisors: [HypervisorSupport] {
        get { hypervisors.values }
        set {
            let value = newValue;
            hypervisors = Strato_Agent_V1_AgentRegisterMessageHypervisorsSection.with { $0.values = value }
        }
    }
    var _jsonNetworkCapability: NetworkCapability? {
        get { hasNetworkCapability ? (networkCapability) : nil }
        set { if let value = newValue { networkCapability = value } else { clearNetworkCapability() } }
    }
    var _jsonProtocolOffer: Strato_Agent_V1_ProtocolOffer {
        get { protocolOffer }
        set { let value = newValue; protocolOffer = value }
    }
    var _jsonSandboxCapable: Bool {
        get { sandboxCapable }
        set { let value = newValue; sandboxCapable = value }
    }
    var _jsonSandboxNetworkingCapable: Bool {
        get { sandboxNetworkingCapable }
        set { let value = newValue; sandboxNetworkingCapable = value }
    }
    var _jsonTpmCapable: Bool {
        get { tpmCapable }
        set { let value = newValue; tpmCapable = value }
    }
    var _jsonOperatingSystem: OperatingSystem {
        get { operatingSystem }
        set { let value = newValue; operatingSystem = value }
    }
    var _jsonHostInfo: HostInfo? {
        get { hasHostInfo ? (hostInfo) : nil }
        set { if let value = newValue { hostInfo = value } else { clearHostInfo() } }
    }
    var _jsonResolverCapable: Bool {
        get { resolverCapable }
        set { let value = newValue; resolverCapable = value }
    }
    var _jsonMetadataServiceCapable: Bool {
        get { metadataServiceCapable }
        set { let value = newValue; metadataServiceCapable = value }
    }
    var _jsonResourceClassEnforcement: [WorkloadResourceClassEnforcement]? {
        get { hasResourceClassEnforcement ? (resourceClassEnforcement.values) : nil }
        set {
            if let value = newValue {
                resourceClassEnforcement = Strato_Agent_V1_AgentRegisterMessageResourceClassEnforcementSection.with {
                    $0.values = value
                }
            } else {
                clearResourceClassEnforcement()
            }
        }
    }
    var _jsonDependencyObservations: [NodeDependencyObservation] {
        get { dependencyObservations.values }
        set {
            let value = newValue;
            dependencyObservations = Strato_Agent_V1_AgentRegisterMessageDependencyObservationsSection.with {
                $0.values = value
            }
        }
    }
}

public typealias AgentHeartbeatMessage = Strato_Agent_V1_AgentHeartbeatMessage
extension Strato_Agent_V1_AgentHeartbeatMessage: WebSocketMessage {
    public var type: MessageType { .agentHeartbeat }
    /// Last host-resource sample gathered independently of this heartbeat.
    /// Nil only before the first sampling pass or from a pre-v59 sender.

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        agentId: String,
        resources: AgentResources,
        dependencyObservations: [NodeDependencyObservation] = [],
        hostResourceTelemetry: HostResourceTelemetry? = nil
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonAgentId = agentId
        self._jsonResources = resources
        self._jsonDependencyObservations = dependencyObservations
        self._jsonHostResourceTelemetry = hostResourceTelemetry
    }

    private enum CodingKeys: String, CodingKey {
        case requestId; case timestamp; case agentId; case resources; case dependencyObservations;
        case hostResourceTelemetry
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonAgentId = try container.decode(String.self, forKey: .agentId)
        self._jsonResources = try container.decode(AgentResources.self, forKey: .resources)
        self._jsonDependencyObservations = try container.decode(
            [NodeDependencyObservation].self, forKey: .dependencyObservations)
        self._jsonHostResourceTelemetry = try container.decodeIfPresent(
            HostResourceTelemetry.self, forKey: .hostResourceTelemetry)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonAgentId, forKey: .agentId)
        try container.encode(_jsonResources, forKey: .resources)
        try container.encode(_jsonDependencyObservations, forKey: .dependencyObservations)
        try container.encodeIfPresent(_jsonHostResourceTelemetry, forKey: .hostResourceTelemetry)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonAgentId: String {
        get { agentID }
        set { let value = newValue; agentID = value }
    }
    var _jsonResources: AgentResources {
        get { resources }
        set { let value = newValue; resources = value }
    }
    var _jsonDependencyObservations: [NodeDependencyObservation] {
        get { dependencyObservations.values }
        set {
            let value = newValue;
            dependencyObservations = Strato_Agent_V1_AgentHeartbeatMessageDependencyObservationsSection.with {
                $0.values = value
            }
        }
    }
    var _jsonHostResourceTelemetry: HostResourceTelemetry? {
        get { hasHostResourceTelemetry ? (hostResourceTelemetry) : nil }
        set { if let value = newValue { hostResourceTelemetry = value } else { clearHostResourceTelemetry() } }
    }
}

public typealias AgentUnregisterMessage = Strato_Agent_V1_AgentUnregisterMessage
extension Strato_Agent_V1_AgentUnregisterMessage: WebSocketMessage {
    public var type: MessageType { .agentUnregister }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        agentId: String
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonAgentId = agentId
    }

    private enum CodingKeys: String, CodingKey { case requestId; case timestamp; case agentId }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonAgentId = try container.decode(String.self, forKey: .agentId)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonAgentId, forKey: .agentId)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonAgentId: String {
        get { agentID }
        set { let value = newValue; agentID = value }
    }
}

/// Shape of the artifact a `DesiredAgentUpdate` points at.
public typealias AgentUpdateArtifactKind = Strato_Agent_V1_AgentUpdateArtifactKind
extension Strato_Agent_V1_AgentUpdateArtifactKind: Codable {
    /// A gzipped tarball containing the agent binary as a member
    /// (`DesiredAgentUpdate.tarballMember`) — the shape of the published
    /// release assets, which bundle control plane and agent together.

    /// A bare executable: the downloaded file *is* the new agent binary.

    public var protocolValue: String {
        switch self {
        case .tarball: return "tarball"
        case .binary: return "binary"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "tarball": self = .tarball
        case "binary": self = .binary
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

public typealias AgentRegisterResponseMessage = Strato_Agent_V1_AgentRegisterResponseMessage
extension Strato_Agent_V1_AgentRegisterResponseMessage: WebSocketMessage {
    public var type: MessageType { .agentRegisterResponse }

    /// The negotiated stable major and capabilities for this connection.
    /// The agent validates the agreement against its registration offer.

    public init(
        requestId: String,
        timestamp: Date = Date(),
        agentId: String,
        name: String,
        agreement: Strato_Agent_V1_ProtocolAgreement
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonAgentId = agentId
        self._jsonName = name
        self._jsonAgreement = agreement
    }

    private enum CodingKeys: String, CodingKey {
        case requestId; case timestamp; case agentId; case name; case agreement
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonAgentId = try container.decode(String.self, forKey: .agentId)
        self._jsonName = try container.decode(String.self, forKey: .name)
        self._jsonAgreement = try container.decode(Strato_Agent_V1_ProtocolAgreement.self, forKey: .agreement)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonAgentId, forKey: .agentId)
        try container.encode(_jsonName, forKey: .name)
        try container.encode(_jsonAgreement, forKey: .agreement)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonAgentId: String {
        get { agentID }
        set { let value = newValue; agentID = value }
    }
    var _jsonName: String {
        get { name }
        set { let value = newValue; name = value }
    }
    var _jsonAgreement: Strato_Agent_V1_ProtocolAgreement {
        get { agreement }
        set { let value = newValue; agreement = value }
    }
}

public typealias AgentResources = Strato_Agent_V1_AgentResources
extension Strato_Agent_V1_AgentResources: Codable {
    private enum CodingKeys: String, CodingKey {
        case totalCPU
        case availableCPU
        case totalMemory
        case availableMemory
        case totalDisk
        case availableDisk
        case physicalFreeDisk
        case memoryAccounting, availableCPUMicroUnits
    }

    /// Provisioned local-disk bytes still available for new commitments.
    /// Bytes physically free on the filesystem backing local volumes.

    public init(
        totalCPU: Int,
        availableCPU: Int,
        totalMemory: Int64,
        availableMemory: Int64,
        totalDisk: Int64,
        availableDisk: Int64,
        physicalFreeDisk: Int64? = nil,
        memoryAccounting: HostMemoryAccounting? = nil,
        availableCPUMicroUnits: Int64? = nil
    ) {
        self.init()
        self._jsonAvailableCPUMicroUnits = availableCPUMicroUnits
        self._jsonMemoryAccounting = memoryAccounting
        self._jsonTotalCPU = totalCPU
        self._jsonAvailableCPU = availableCPU
        self._jsonTotalMemory = totalMemory
        self._jsonAvailableMemory = availableMemory
        self._jsonTotalDisk = totalDisk
        self._jsonAvailableDisk = availableDisk
        self._jsonPhysicalFreeDisk = physicalFreeDisk ?? availableDisk
    }

    public init(from decoder: Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonAvailableCPUMicroUnits = try container.decodeIfPresent(Int64.self, forKey: .availableCPUMicroUnits)
        self._jsonMemoryAccounting = try container.decodeIfPresent(HostMemoryAccounting.self, forKey: .memoryAccounting)
        self._jsonTotalCPU = try container.decode(Int.self, forKey: .totalCPU)
        self._jsonAvailableCPU = try container.decode(Int.self, forKey: .availableCPU)
        self._jsonTotalMemory = try container.decode(Int64.self, forKey: .totalMemory)
        self._jsonAvailableMemory = try container.decode(Int64.self, forKey: .availableMemory)
        self._jsonTotalDisk = try container.decode(Int64.self, forKey: .totalDisk)
        self._jsonAvailableDisk = try container.decode(Int64.self, forKey: .availableDisk)
        self._jsonPhysicalFreeDisk =
            try container.decodeIfPresent(Int64.self, forKey: .physicalFreeDisk)
            ?? self._jsonAvailableDisk
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(_jsonAvailableCPUMicroUnits, forKey: .availableCPUMicroUnits)
        try container.encodeIfPresent(_jsonMemoryAccounting, forKey: .memoryAccounting)
        try container.encode(_jsonTotalCPU, forKey: .totalCPU)
        try container.encode(_jsonAvailableCPU, forKey: .availableCPU)
        try container.encode(_jsonTotalMemory, forKey: .totalMemory)
        try container.encode(_jsonAvailableMemory, forKey: .availableMemory)
        try container.encode(_jsonTotalDisk, forKey: .totalDisk)
        try container.encode(_jsonAvailableDisk, forKey: .availableDisk)
        try container.encode(_jsonPhysicalFreeDisk, forKey: .physicalFreeDisk)
    }

    var _jsonAvailableCPUMicroUnits: Int64? {
        get { hasAvailableCpuMicroUnits ? (availableCpuMicroUnits) : nil }
        set { if let value = newValue { availableCpuMicroUnits = value } else { clearAvailableCpuMicroUnits() } }
    }
    var _jsonMemoryAccounting: HostMemoryAccounting? {
        get { hasMemoryAccounting ? (memoryAccounting) : nil }
        set { if let value = newValue { memoryAccounting = value } else { clearMemoryAccounting() } }
    }
    var _jsonTotalCPU: Int {
        get { Int(totalCpu) }
        set { let value = newValue; totalCpu = Int64(value) }
    }
    var _jsonAvailableCPU: Int {
        get { Int(availableCpu) }
        set { let value = newValue; availableCpu = Int64(value) }
    }
    var _jsonTotalMemory: Int64 {
        get { totalMemory }
        set { let value = newValue; totalMemory = value }
    }
    var _jsonAvailableMemory: Int64 {
        get { availableMemory }
        set { let value = newValue; availableMemory = value }
    }
    var _jsonTotalDisk: Int64 {
        get { totalDisk }
        set { let value = newValue; totalDisk = value }
    }
    var _jsonAvailableDisk: Int64 {
        get { availableDisk }
        set { let value = newValue; availableDisk = value }
    }
    var _jsonPhysicalFreeDisk: Int64 {
        get { physicalFreeDisk }
        set { let value = newValue; physicalFreeDisk = value }
    }
}

// MARK: - Image Information

/// Download information for a single typed artifact within an image's set.
///
/// The `downloadURL` is a control-plane-relative path
/// (`/api/projects/{p}/images/{i}/download?artifact={kind}`). The agent
/// resolves it against the control-plane base URL it already dials and
/// authenticates the fetch with its SPIFFE SVID over mTLS — there is no
/// credential in the URL itself (issue #493).
public typealias ArtifactInfo = Strato_Agent_V1_ArtifactInfo
extension Strato_Agent_V1_ArtifactInfo: Codable {

    public init(
        kind: ArtifactKind,
        filename: String,
        checksum: String,
        size: Int64,
        downloadURL: String
    ) {
        self.init()
        self._jsonKind = kind
        self._jsonFilename = filename
        self._jsonChecksum = checksum
        self._jsonSize = size
        self._jsonDownloadURL = downloadURL
    }

    private enum CodingKeys: String, CodingKey { case kind; case filename; case checksum; case size; case downloadURL }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonKind = try container.decode(ArtifactKind.self, forKey: .kind)
        self._jsonFilename = try container.decode(String.self, forKey: .filename)
        self._jsonChecksum = try container.decode(String.self, forKey: .checksum)
        self._jsonSize = try container.decode(Int64.self, forKey: .size)
        self._jsonDownloadURL = try container.decode(String.self, forKey: .downloadURL)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonKind, forKey: .kind)
        try container.encode(_jsonFilename, forKey: .filename)
        try container.encode(_jsonChecksum, forKey: .checksum)
        try container.encode(_jsonSize, forKey: .size)
        try container.encode(_jsonDownloadURL, forKey: .downloadURL)
    }

    var _jsonKind: ArtifactKind {
        get { kind }
        set { let value = newValue; kind = value }
    }
    var _jsonFilename: String {
        get { filename }
        set { let value = newValue; filename = value }
    }
    var _jsonChecksum: String {
        get { checksum }
        set { let value = newValue; checksum = value }
    }
    var _jsonSize: Int64 {
        get { size }
        set { let value = newValue; size = value }
    }
    var _jsonDownloadURL: String {
        get { downloadURL }
        set { let value = newValue; downloadURL = value }
    }
}

/// Contains information for the agent to download and cache an image.
///
/// Every stored file is represented exactly once in `artifacts`. Hypervisor
/// drivers select the kind they require and fail explicitly when it is absent.
public typealias ImageInfo = Strato_Agent_V1_ImageInfo
extension Strato_Agent_V1_ImageInfo: Codable {

    public init(
        imageId: UUID,
        projectId: UUID,
        architecture: CPUArchitecture,
        artifacts: [ArtifactInfo]
    ) {
        self.init()
        self._jsonImageId = imageId
        self._jsonProjectId = projectId
        self._jsonArchitecture = architecture
        self._jsonArtifacts = artifacts
    }

    /// The artifact of a given kind, if present in the set.
    public func artifact(ofKind kind: ArtifactKind) -> ArtifactInfo? {
        _jsonArtifacts.first { $0._jsonKind == kind }
    }

    private enum CodingKeys: String, CodingKey { case imageId; case projectId; case architecture; case artifacts }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonImageId = try container.decode(UUID.self, forKey: .imageId)
        self._jsonProjectId = try container.decode(UUID.self, forKey: .projectId)
        self._jsonArchitecture = try container.decode(CPUArchitecture.self, forKey: .architecture)
        self._jsonArtifacts = try container.decode([ArtifactInfo].self, forKey: .artifacts)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonImageId, forKey: .imageId)
        try container.encode(_jsonProjectId, forKey: .projectId)
        try container.encode(_jsonArchitecture, forKey: .architecture)
        try container.encode(_jsonArtifacts, forKey: .artifacts)
    }

    var _jsonImageId: UUID {
        get { UUID(uuidString: imageID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
        set { let value = newValue; imageID = value.uuidString }
    }
    var _jsonProjectId: UUID {
        get { UUID(uuidString: projectID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
        set { let value = newValue; projectID = value.uuidString }
    }
    var _jsonArchitecture: CPUArchitecture {
        get { architecture }
        set { let value = newValue; architecture = value }
    }
    var _jsonArtifacts: [ArtifactInfo] {
        get { artifacts.values }
        set { let value = newValue; artifacts = Strato_Agent_V1_ImageInfoArtifactsSection.with { $0.values = value } }
    }
}

// MARK: - Response Messages

/// An unsolicited registration, heartbeat, or unregister acknowledgement.
/// `requestId` is retained for log correlation; no sender awaits it.
public typealias SuccessMessage = Strato_Agent_V1_SuccessMessage
extension Strato_Agent_V1_SuccessMessage: WebSocketMessage {
    public var type: MessageType { .success }

    public init(
        requestId: String,
        timestamp: Date = Date(),
        message: String? = nil
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonMessage = message
    }

    private enum CodingKeys: String, CodingKey { case requestId; case timestamp; case message }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonMessage = try container.decodeIfPresent(String.self, forKey: .message)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encodeIfPresent(_jsonMessage, forKey: .message)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonMessage: String? {
        get { hasMessage ? (message) : nil }
        set { if let value = newValue { message = value } else { clearMessage() } }
    }
}

public typealias ErrorMessage = Strato_Agent_V1_ErrorMessage
extension Strato_Agent_V1_ErrorMessage: WebSocketMessage {
    public var type: MessageType { .error }
    /// Machine-readable error classification (see `ErrorCode`). Optional so
    /// peers that predate it decode fine; absent means unclassified, which
    /// receivers must treat as potentially transient (safe to retry).

    /// Well-known values for `code`.
    public enum ErrorCode {
        /// The agent's credential/enrollment was rejected permanently (today:
        /// an enrollment with no organization scope). Named for the bearer
        /// tokens that predated SVID-only auth (wire v11) — the string
        /// survives because deployed agents key their "stop reconnecting and
        /// exit" behavior on it. Retrying can never succeed without operator
        /// action.
        public static let invalidToken = "invalid_token"

        /// The agent's wire protocol version predates desired-state sync,
        /// which the control plane requires (issue #261). Retrying without
        /// upgrading the agent can never succeed.
        public static let unsupportedProtocolVersion = "unsupported_protocol_version"
    }

    public init(
        requestId: String,
        timestamp: Date = Date(),
        error: String,
        details: String? = nil,
        code: String? = nil
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonError = error
        self._jsonDetails = details
        self._jsonCode = code
    }

    private enum CodingKeys: String, CodingKey { case requestId; case timestamp; case error; case details; case code }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonError = try container.decode(String.self, forKey: .error)
        self._jsonDetails = try container.decodeIfPresent(String.self, forKey: .details)
        self._jsonCode = try container.decodeIfPresent(String.self, forKey: .code)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonError, forKey: .error)
        try container.encodeIfPresent(_jsonDetails, forKey: .details)
        try container.encodeIfPresent(_jsonCode, forKey: .code)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonError: String {
        get { error }
        set { let value = newValue; error = value }
    }
    var _jsonDetails: String? {
        get { hasDetails ? (details) : nil }
        set { if let value = newValue { details = value } else { clearDetails() } }
    }
    var _jsonCode: String? {
        get { hasCode ? (code) : nil }
        set { if let value = newValue { code = value } else { clearCode() } }
    }
}

/// A version-tolerant JSON tree for data whose complete schema is not owned by
/// Strato. Unknown object fields and array elements remain available without
/// falling back to unchecked `Any` values.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
        } else if let objectValue = try? container.decode([String: JSONValue].self) {
            self = .object(objectValue)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported type"))
        }
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        let data = try WireProtocol.makeEncoder().encode(self)
        return try WireProtocol.makeDecoder().decode(type, from: data)
    }
}

// MARK: - Console Operation Messages

/// Which of a VM's consoles a session attaches to (issue #566).
///
/// Only `console_connect` carries this — once a session exists both sides key
/// it by `sessionId`, and the bytes in either direction are opaque, so
/// `console_data` and `console_disconnect` stay stream-agnostic.
public typealias ConsoleStream = Strato_Agent_V1_ConsoleStream
extension Strato_Agent_V1_ConsoleStream: Codable {
    /// The text console: the serial socket, falling back to virtio-console.

    /// The framebuffer: the VM's VNC socket, relayed as opaque RFB bytes.

    public var protocolValue: String {
        switch self {
        case .serial: return "Serial"
        case .vnc: return "Vnc"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "Serial": self = .serial
        case "Vnc": self = .vnc
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

public typealias ConsoleConnectMessage = Strato_Agent_V1_ConsoleConnectMessage
extension Strato_Agent_V1_ConsoleConnectMessage: WebSocketMessage {
    public var type: MessageType { .consoleConnect }
    /// Which console to attach.

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String,
        stream: ConsoleStream = .serial
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonVmId = vmId
        self._jsonSessionId = sessionId
        self._jsonStream = stream
    }

    private enum CodingKeys: String, CodingKey {
        case requestId; case timestamp; case vmId; case sessionId; case stream
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonVmId = try container.decode(String.self, forKey: .vmId)
        self._jsonSessionId = try container.decode(String.self, forKey: .sessionId)
        self._jsonStream = try container.decode(ConsoleStream.self, forKey: .stream)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonVmId, forKey: .vmId)
        try container.encode(_jsonSessionId, forKey: .sessionId)
        try container.encode(_jsonStream, forKey: .stream)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonVmId: String {
        get { vmID }
        set { let value = newValue; vmID = value }
    }
    var _jsonSessionId: String {
        get { sessionID }
        set { let value = newValue; sessionID = value }
    }
    var _jsonStream: ConsoleStream {
        get { stream }
        set { let value = newValue; stream = value }
    }
}

public typealias ConsoleDisconnectMessage = Strato_Agent_V1_ConsoleDisconnectMessage
extension Strato_Agent_V1_ConsoleDisconnectMessage: WebSocketMessage {
    public var type: MessageType { .consoleDisconnect }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonVmId = vmId
        self._jsonSessionId = sessionId
    }

    private enum CodingKeys: String, CodingKey { case requestId; case timestamp; case vmId; case sessionId }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonVmId = try container.decode(String.self, forKey: .vmId)
        self._jsonSessionId = try container.decode(String.self, forKey: .sessionId)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonVmId, forKey: .vmId)
        try container.encode(_jsonSessionId, forKey: .sessionId)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonVmId: String {
        get { vmID }
        set { let value = newValue; vmID = value }
    }
    var _jsonSessionId: String {
        get { sessionID }
        set { let value = newValue; sessionID = value }
    }
}

public typealias ConsoleDataMessage = Strato_Agent_V1_ConsoleDataMessage
extension Strato_Agent_V1_ConsoleDataMessage: WebSocketMessage {
    public var type: MessageType { .consoleData }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String,
        data: String
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonVmId = vmId
        self._jsonSessionId = sessionId
        self._jsonData = data
    }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String,
        rawData: Data
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonVmId = vmId
        self._jsonSessionId = sessionId
        self.data = rawData
    }

    public var rawData: Data? {
        hasData ? data : nil
    }

    private enum CodingKeys: String, CodingKey { case requestId; case timestamp; case vmId; case sessionId; case data }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonVmId = try container.decode(String.self, forKey: .vmId)
        self._jsonSessionId = try container.decode(String.self, forKey: .sessionId)
        self._jsonData = try container.decode(String.self, forKey: .data)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonVmId, forKey: .vmId)
        try container.encode(_jsonSessionId, forKey: .sessionId)
        try container.encode(_jsonData, forKey: .data)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonVmId: String {
        get { vmID }
        set { let value = newValue; vmID = value }
    }
    var _jsonSessionId: String {
        get { sessionID }
        set { let value = newValue; sessionID = value }
    }
    var _jsonData: String {
        get { data.base64EncodedString() }
        set { let value = newValue; if let bytes = Data(base64Encoded: value) { data = bytes } else { clearData() } }
    }
}

public typealias ConsoleConnectedMessage = Strato_Agent_V1_ConsoleConnectedMessage
extension Strato_Agent_V1_ConsoleConnectedMessage: WebSocketMessage {
    public var type: MessageType { .consoleConnected }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonVmId = vmId
        self._jsonSessionId = sessionId
    }

    private enum CodingKeys: String, CodingKey { case requestId; case timestamp; case vmId; case sessionId }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonVmId = try container.decode(String.self, forKey: .vmId)
        self._jsonSessionId = try container.decode(String.self, forKey: .sessionId)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonVmId, forKey: .vmId)
        try container.encode(_jsonSessionId, forKey: .sessionId)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonVmId: String {
        get { vmID }
        set { let value = newValue; vmID = value }
    }
    var _jsonSessionId: String {
        get { sessionID }
        set { let value = newValue; sessionID = value }
    }
}

public typealias ConsoleDisconnectedMessage = Strato_Agent_V1_ConsoleDisconnectedMessage
extension Strato_Agent_V1_ConsoleDisconnectedMessage: WebSocketMessage {
    public var type: MessageType { .consoleDisconnected }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String,
        reason: String? = nil
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonVmId = vmId
        self._jsonSessionId = sessionId
        self._jsonReason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case requestId; case timestamp; case vmId; case sessionId; case reason
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonVmId = try container.decode(String.self, forKey: .vmId)
        self._jsonSessionId = try container.decode(String.self, forKey: .sessionId)
        self._jsonReason = try container.decodeIfPresent(String.self, forKey: .reason)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonVmId, forKey: .vmId)
        try container.encode(_jsonSessionId, forKey: .sessionId)
        try container.encodeIfPresent(_jsonReason, forKey: .reason)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonVmId: String {
        get { vmID }
        set { let value = newValue; vmID = value }
    }
    var _jsonSessionId: String {
        get { sessionID }
        set { let value = newValue; sessionID = value }
    }
    var _jsonReason: String? {
        get { hasReason ? (reason) : nil }
        set { if let value = newValue { reason = value } else { clearReason() } }
    }
}

// MARK: - Message Envelope

// MARK: - VM Log Messages

/// Log level for VM log messages
public typealias VMLogLevel = Strato_Agent_V1_VMLogLevel
extension Strato_Agent_V1_VMLogLevel: Codable {

    public var protocolValue: String {
        switch self {
        case .debug: return "debug"
        case .info: return "info"
        case .warning: return "warning"
        case .error: return "error"
        case .unknown: return "unknown"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "debug": self = .debug
        case "info": self = .info
        case "warning": self = .warning
        case "error": self = .error
        case "unknown": self = .unknown
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.debug, .info, .warning, .error, .unknown] }

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

/// Source of the log message
public typealias VMLogSource = Strato_Agent_V1_VMLogSource
extension Strato_Agent_V1_VMLogSource: Codable {

    public var protocolValue: String {
        switch self {
        case .agent: return "agent"
        case .unknown: return "unknown"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "agent": self = .agent
        case "unknown": self = .unknown
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.agent, .unknown] }

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

/// Type of VM event
public typealias VMEventType = Strato_Agent_V1_VMEventType
extension Strato_Agent_V1_VMEventType: Codable {

    public var protocolValue: String {
        switch self {
        case .statusChange: return "status_change"
        case .operation: return "operation"
        case .error: return "error"
        case .info: return "info"
        case .unknown: return "unknown"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "status_change": self = .statusChange
        case "operation": self = .operation
        case "error": self = .error
        case "info": self = .info
        case "unknown": self = .unknown
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.statusChange, .operation, .error, .info, .unknown] }

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

/// VM log message sent from agent to control plane
public typealias VMLogMessage = Strato_Agent_V1_VMLogMessage
extension Strato_Agent_V1_VMLogMessage: WebSocketMessage {
    public var type: MessageType { .vmLog }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        level: VMLogLevel,
        source: VMLogSource,
        eventType: VMEventType,
        message: String,
        operation: String? = nil
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonVmId = vmId
        self._jsonLevel = level
        self._jsonSource = source
        self._jsonEventType = eventType
        self._jsonMessage = message
        self._jsonOperation = operation
    }

    private enum CodingKeys: String, CodingKey {
        case requestId; case timestamp; case vmId; case level; case source; case eventType; case message; case operation
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonVmId = try container.decode(String.self, forKey: .vmId)
        self._jsonLevel = try container.decode(VMLogLevel.self, forKey: .level)
        self._jsonSource = try container.decode(VMLogSource.self, forKey: .source)
        self._jsonEventType = try container.decode(VMEventType.self, forKey: .eventType)
        self._jsonMessage = try container.decode(String.self, forKey: .message)
        self._jsonOperation = try container.decodeIfPresent(String.self, forKey: .operation)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonVmId, forKey: .vmId)
        try container.encode(_jsonLevel, forKey: .level)
        try container.encode(_jsonSource, forKey: .source)
        try container.encode(_jsonEventType, forKey: .eventType)
        try container.encode(_jsonMessage, forKey: .message)
        try container.encodeIfPresent(_jsonOperation, forKey: .operation)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonVmId: String {
        get { vmID }
        set { let value = newValue; vmID = value }
    }
    var _jsonLevel: VMLogLevel {
        get { level }
        set { let value = newValue; level = value }
    }
    var _jsonSource: VMLogSource {
        get { source }
        set { let value = newValue; source = value }
    }
    var _jsonEventType: VMEventType {
        get { eventType }
        set { let value = newValue; eventType = value }
    }
    var _jsonMessage: String {
        get { message }
        set { let value = newValue; message = value }
    }
    var _jsonOperation: String? {
        get { hasOperation ? (operation) : nil }
        set { if let value = newValue { operation = value } else { clearOperation() } }
    }
}
