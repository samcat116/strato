import Foundation

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

public protocol WebSocketMessage: Codable, Sendable {
    var type: MessageType { get }
    var requestId: String { get }
    var timestamp: Date { get }
}

// MARK: - Agent Messages

public struct AgentRegisterMessage: WebSocketMessage {
    public var type: MessageType { .agentRegister }
    public let requestId: String
    public let timestamp: Date
    public let agentId: String
    public let hostname: String
    public let version: String
    public let resources: AgentResources
    /// Host CPU architecture.
    public let architecture: CPUArchitecture
    /// Every hypervisor on this host with probed availability and capabilities.
    public let hypervisors: [HypervisorSupport]
    /// Networking capability of this host. Nil means networking is disabled or
    /// its host probe could not establish a usable mode.
    public let networkCapability: NetworkCapability?
    /// Exact wire/schema version the agent speaks. Registration is the sole
    /// protocol-version handshake; peers must equal `WireProtocol.currentVersion`.
    public let protocolVersion: Int
    /// Whether this agent runs sandbox workloads (OCI-image Firecracker
    /// microVMs, issue #410): it reconciles `DesiredStateMessage.sandboxes`
    /// and reports them back in `ObservedStateReport.sandboxes`. The scheduler
    /// keys placement on this explicit signal because the
    /// separately installed runtime, not the wire version, determines support.
    public let sandboxCapable: Bool
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
    public let sandboxNetworkingCapable: Bool
    /// Whether this host can give a guest an emulated TPM 2.0 — it has a
    /// usable `swtpm` binary (issue #565). Like `sandboxCapable`, speaking the
    /// wire version is deliberately not sufficient: the protocol carries
    /// `MachineProfile.tpm`, but only a host with swtpm installed can realize
    /// it, and a VM whose vTPM is silently dropped fails Windows setup with no
    /// explanation.
    public let tpmCapable: Bool
    /// Host operating system, reported so the control plane can resolve the
    /// right release artifact for an agent self-update (assets are published
    /// per OS/arch pair).
    public let operatingSystem: OperatingSystem
    /// Descriptive hardware/platform/OS details for operators (CPU model,
    /// kernel version, distribution, physical core count, boot time, ...).
    /// Purely informational and entirely best-effort; any individual field the
    /// agent could not probe is absent.
    public let hostInfo: HostInfo?
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
    public let resolverCapable: Bool
    /// Whether this host initialized the guest-facing instance metadata
    /// service. This is independent of overlay networking: an OVN host may
    /// disable the service in its agent configuration or lack a host tool the
    /// listener supervisor needs.
    public let metadataServiceCapable: Bool
    /// Periodic, feature-scoped software dependency health. This is also sent
    /// at registration so a newly connected agent is not placement-eligible in
    /// the window before its first heartbeat.
    public let dependencyObservations: [NodeDependencyObservation]

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
        protocolVersion: Int = WireProtocol.currentVersion,
        sandboxCapable: Bool = false,
        sandboxNetworkingCapable: Bool = false,
        tpmCapable: Bool = false,
        operatingSystem: OperatingSystem = .current,
        hostInfo: HostInfo? = nil,
        resolverCapable: Bool = false,
        metadataServiceCapable: Bool = false,
        dependencyObservations: [NodeDependencyObservation] = []
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.agentId = agentId
        self.hostname = hostname
        self.version = version
        self.resources = resources
        self.architecture = architecture
        self.hypervisors = hypervisors
        self.networkCapability = networkCapability
        self.protocolVersion = protocolVersion
        self.sandboxCapable = sandboxCapable
        self.sandboxNetworkingCapable = sandboxNetworkingCapable
        self.tpmCapable = tpmCapable
        self.operatingSystem = operatingSystem
        self.hostInfo = hostInfo
        self.resolverCapable = resolverCapable
        self.metadataServiceCapable = metadataServiceCapable
        self.dependencyObservations = dependencyObservations
    }

}

public struct AgentHeartbeatMessage: WebSocketMessage {
    public var type: MessageType { .agentHeartbeat }
    public let requestId: String
    public let timestamp: Date
    public let agentId: String
    public let resources: AgentResources
    public let dependencyObservations: [NodeDependencyObservation]
    /// Last host-resource sample gathered independently of this heartbeat.
    /// Nil only before the first sampling pass or from a pre-v59 sender.
    public let hostResourceTelemetry: HostResourceTelemetry?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        agentId: String,
        resources: AgentResources,
        dependencyObservations: [NodeDependencyObservation] = [],
        hostResourceTelemetry: HostResourceTelemetry? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.agentId = agentId
        self.resources = resources
        self.dependencyObservations = dependencyObservations
        self.hostResourceTelemetry = hostResourceTelemetry
    }
}

public struct AgentUnregisterMessage: WebSocketMessage {
    public var type: MessageType { .agentUnregister }
    public let requestId: String
    public let timestamp: Date
    public let agentId: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        agentId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.agentId = agentId
    }
}

/// Shape of the artifact a `DesiredAgentUpdate` points at.
public enum AgentUpdateArtifactKind: String, Codable, Sendable {
    /// A gzipped tarball containing the agent binary as a member
    /// (`DesiredAgentUpdate.tarballMember`) — the shape of the published
    /// release assets, which bundle control plane and agent together.
    case tarball = "tarball"
    /// A bare executable: the downloaded file *is* the new agent binary.
    case binary = "binary"
}

public struct AgentRegisterResponseMessage: WebSocketMessage {
    public var type: MessageType { .agentRegisterResponse }
    public let requestId: String
    public let timestamp: Date
    public let agentId: String  // The database UUID assigned to this agent
    public let name: String  // The human-readable name

    /// Exact wire/schema version the control plane speaks. The agent refuses a
    /// response that does not equal `WireProtocol.currentVersion`.
    public let protocolVersion: Int

    public init(
        requestId: String,
        timestamp: Date = Date(),
        agentId: String,
        name: String,
        protocolVersion: Int = WireProtocol.currentVersion
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.agentId = agentId
        self.name = name
        self.protocolVersion = protocolVersion
    }
}

public struct AgentResources: Codable, Sendable {
    public let totalCPU: Int
    public let availableCPU: Int
    public let totalMemory: Int64
    public let availableMemory: Int64
    public let totalDisk: Int64
    public let availableDisk: Int64

    public init(
        totalCPU: Int,
        availableCPU: Int,
        totalMemory: Int64,
        availableMemory: Int64,
        totalDisk: Int64,
        availableDisk: Int64
    ) {
        self.totalCPU = totalCPU
        self.availableCPU = availableCPU
        self.totalMemory = totalMemory
        self.availableMemory = availableMemory
        self.totalDisk = totalDisk
        self.availableDisk = availableDisk
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
public struct ArtifactInfo: Codable, Sendable {
    public let kind: ArtifactKind
    public let filename: String
    public let checksum: String
    public let size: Int64
    public let downloadURL: String

    public init(
        kind: ArtifactKind,
        filename: String,
        checksum: String,
        size: Int64,
        downloadURL: String
    ) {
        self.kind = kind
        self.filename = filename
        self.checksum = checksum
        self.size = size
        self.downloadURL = downloadURL
    }
}

/// Contains information for the agent to download and cache an image.
///
/// Every stored file is represented exactly once in `artifacts`. Hypervisor
/// drivers select the kind they require and fail explicitly when it is absent.
public struct ImageInfo: Codable, Sendable {
    public let imageId: UUID
    public let projectId: UUID
    public let architecture: CPUArchitecture
    public let artifacts: [ArtifactInfo]

    public init(
        imageId: UUID,
        projectId: UUID,
        architecture: CPUArchitecture,
        artifacts: [ArtifactInfo]
    ) {
        self.imageId = imageId
        self.projectId = projectId
        self.architecture = architecture
        self.artifacts = artifacts
    }

    /// The artifact of a given kind, if present in the set.
    public func artifact(ofKind kind: ArtifactKind) -> ArtifactInfo? {
        artifacts.first { $0.kind == kind }
    }
}

// MARK: - Response Messages

/// An unsolicited registration, heartbeat, or unregister acknowledgement.
/// `requestId` is retained for log correlation; no sender awaits it.
public struct SuccessMessage: WebSocketMessage {
    public var type: MessageType { .success }
    public let requestId: String
    public let timestamp: Date
    public let message: String?

    public init(
        requestId: String,
        timestamp: Date = Date(),
        message: String? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.message = message
    }
}

public struct ErrorMessage: WebSocketMessage {
    public var type: MessageType { .error }
    public let requestId: String
    public let timestamp: Date
    public let error: String
    public let details: String?
    /// Machine-readable error classification (see `ErrorCode`). Optional so
    /// peers that predate it decode fine; absent means unclassified, which
    /// receivers must treat as potentially transient (safe to retry).
    public let code: String?

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
        self.requestId = requestId
        self.timestamp = timestamp
        self.error = error
        self.details = details
        self.code = code
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

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
public enum ConsoleStream: String, Codable, Sendable {
    /// The text console: the serial socket, falling back to virtio-console.
    case serial = "Serial"
    /// The framebuffer: the VM's VNC socket, relayed as opaque RFB bytes.
    case vnc = "Vnc"
}

public struct ConsoleConnectMessage: WebSocketMessage {
    public var type: MessageType { .consoleConnect }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let sessionId: String
    /// Which console to attach.
    public let stream: ConsoleStream

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String,
        stream: ConsoleStream = .serial
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.sessionId = sessionId
        self.stream = stream
    }
}

public struct ConsoleDisconnectMessage: WebSocketMessage {
    public var type: MessageType { .consoleDisconnect }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let sessionId: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.sessionId = sessionId
    }
}

public struct ConsoleDataMessage: WebSocketMessage {
    public var type: MessageType { .consoleData }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let sessionId: String
    public let data: String  // Base64 encoded bytes

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String,
        data: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.sessionId = sessionId
        self.data = data
    }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String,
        rawData: Data
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.sessionId = sessionId
        self.data = rawData.base64EncodedString()
    }

    public var rawData: Data? {
        Data(base64Encoded: data)
    }
}

public struct ConsoleConnectedMessage: WebSocketMessage {
    public var type: MessageType { .consoleConnected }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let sessionId: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.sessionId = sessionId
    }
}

public struct ConsoleDisconnectedMessage: WebSocketMessage {
    public var type: MessageType { .consoleDisconnected }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let sessionId: String
    public let reason: String?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String,
        reason: String? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.sessionId = sessionId
        self.reason = reason
    }
}

// MARK: - Message Envelope

public struct MessageEnvelope: Codable, Sendable {
    public let type: MessageType
    public let payload: Data

    public init<T: WebSocketMessage>(message: T) throws {
        self.type = message.type
        self.payload = try WireProtocol.makeEncoder().encode(message)
    }

    public func decode<T: WebSocketMessage>(as messageType: T.Type) throws -> T {
        return try WireProtocol.makeDecoder().decode(messageType, from: payload)
    }
}

extension WireProtocol {
    /// Encodes a wire message as an envelope-wrapped JSON payload.
    public static func encodeEnvelope<T: WebSocketMessage>(_ message: T) throws -> Data {
        try makeEncoder().encode(MessageEnvelope(message: message))
    }
}

// MARK: - VM Log Messages

/// Log level for VM log messages
public enum VMLogLevel: String, Codable, CaseIterable, Sendable {
    case debug = "debug"
    case info = "info"
    case warning = "warning"
    case error = "error"
    case unknown = "unknown"
}

/// Source of the log message
public enum VMLogSource: String, Codable, CaseIterable, Sendable {
    case agent = "agent"
    case unknown = "unknown"
}

/// Type of VM event
public enum VMEventType: String, Codable, CaseIterable, Sendable {
    case statusChange = "status_change"
    case operation = "operation"
    case error = "error"
    case info = "info"
    case unknown = "unknown"
}

/// VM log message sent from agent to control plane
public struct VMLogMessage: WebSocketMessage {
    public var type: MessageType { .vmLog }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let level: VMLogLevel
    public let source: VMLogSource
    public let eventType: VMEventType
    public let message: String
    public let operation: String?

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
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.level = level
        self.source = source
        self.eventType = eventType
        self.message = message
        self.operation = operation
    }
}
