import Foundation

// MARK: - WebSocket Message Types

public enum MessageType: String, Codable, Sendable {
    // Agent registration and heartbeat
    case agentRegister = "agent_register"
    case agentRegisterResponse = "agent_register_response"
    case agentHeartbeat = "agent_heartbeat"
    case agentUnregister = "agent_unregister"
    // Operator-triggered self-update of the agent binary (protocol version >= 6).
    // Like `vmReboot`, an update is an action, not a state, so it cannot ride
    // the level-triggered desired-state sync.
    case agentUpdate = "agent_update"

    // VM lifecycle operations.
    //
    // DEPRECATED (issue #261, kept one release for older control planes):
    // the control plane drives VM lifecycle exclusively through desired-state
    // sync (`desiredState`/`observedState`) and no longer sends `vmCreate`,
    // `vmBoot`, `vmShutdown`, `vmPause`, `vmResume`, `vmDelete`, `vmInfo`,
    // or `vmStatus`. Agents still handle them for compatibility with control
    // planes that predate the removal. `vmReboot` remains live: a reboot is
    // an action, not a state, so it cannot ride the level-triggered sync.
    case vmCreate = "vm_create"
    case vmBoot = "vm_boot"
    case vmShutdown = "vm_shutdown"
    case vmReboot = "vm_reboot"
    case vmPause = "vm_pause"
    case vmResume = "vm_resume"
    case vmDelete = "vm_delete"

    // VM information queries (deprecated, see above — the database's
    // observed state answers these now)
    case vmInfo = "vm_info"
    case vmStatus = "vm_status"

    // Network management operations
    case networkCreate = "network_create"
    case networkDelete = "network_delete"
    case networkList = "network_list"
    case networkInfo = "network_info"
    case networkAttach = "network_attach"
    case networkDetach = "network_detach"

    // Volume operations (QEMU only - not supported for Firecracker)
    case volumeCreate = "volume_create"
    case volumeDelete = "volume_delete"
    case volumeAttach = "volume_attach"
    case volumeDetach = "volume_detach"
    case volumeResize = "volume_resize"
    case volumeSnapshot = "volume_snapshot"
    case volumeSnapshotDelete = "volume_snapshot_delete"
    case volumeClone = "volume_clone"
    case volumeInfo = "volume_info"

    // Console operations
    case consoleConnect = "console_connect"
    case consoleDisconnect = "console_disconnect"
    case consoleData = "console_data"
    case consoleConnected = "console_connected"
    case consoleDisconnected = "console_disconnected"

    // Reconciliation state sync (protocol version >= 2)
    case desiredState = "desired_state"
    case observedState = "observed_state"

    // Responses
    case success = "success"
    case error = "error"
    case statusUpdate = "status_update"

    // VM Logs
    case vmLog = "vm_log"

    // Sandbox exec/attach and workload logs (protocol version >= 8, issue
    // #423). Exec messages are a stream, not request/response: they are
    // correlated by `sessionId`, ordered by the WebSocket, and never answered
    // with `success`/`error`.
    case sandboxExecStart = "sandbox_exec_start"
    case sandboxExecStarted = "sandbox_exec_started"
    case sandboxExecInput = "sandbox_exec_input"
    case sandboxExecOutput = "sandbox_exec_output"
    case sandboxExecResize = "sandbox_exec_resize"
    case sandboxExecExit = "sandbox_exec_exit"
    case sandboxExecClose = "sandbox_exec_close"
    case sandboxExecClosed = "sandbox_exec_closed"
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
    public let capabilities: [String]
    public let resources: AgentResources
    /// Legacy single hypervisor type. Still sent so control planes that predate
    /// `hypervisors` can register this agent; readers should prefer `hypervisors`.
    public let hypervisorType: HypervisorType
    /// Host CPU architecture. Optional so messages from agents that predate
    /// this field decode fine; absent means unknown, and the scheduler treats
    /// unknown-architecture agents as ineligible for any VM that pins an
    /// architecture.
    public let architecture: CPUArchitecture?
    /// Every hypervisor on this host with probed availability and capabilities.
    /// Optional so registrations from older agents still decode; readers fall
    /// back to deriving entries from the legacy `capabilities` strings
    /// (see `effectiveHypervisors`).
    public let hypervisors: [HypervisorSupport]?
    /// Networking capability of this host. Optional for the same reason.
    public let networkCapability: NetworkCapability?
    /// Wire/schema version the agent speaks (see `WireProtocol.currentVersion`).
    /// Optional so registrations from agents that predate protocol versioning
    /// decode fine; absent is treated as the legacy version 0. The control plane
    /// echoes its own version in `AgentRegisterResponseMessage` so each side can
    /// detect and log skew.
    public let protocolVersion: Int?
    /// Whether this agent runs sandbox workloads (OCI-image Firecracker
    /// microVMs, issue #410): it reconciles `DesiredStateMessage.sandboxes`
    /// and reports them back in `ObservedStateReport.sandboxes`. Speaking
    /// protocol v5 is deliberately NOT sufficient — a v5 build understands the
    /// fields on the wire, but the sandbox runtime lands separately (issue
    /// #421), so the scheduler keys placement on this explicit signal, not on
    /// the version. Optional so registrations from older agents decode fine;
    /// absent means not capable.
    public let sandboxCapable: Bool?
    /// Host operating system, reported so the control plane can resolve the
    /// right release artifact for an agent self-update (assets are published
    /// per OS/arch pair). Optional so registrations from agents that predate
    /// this field decode fine; absent means unknown, and the update endpoint
    /// refuses to guess.
    public let operatingSystem: OperatingSystem?
    /// Descriptive hardware/platform/OS details for operators (CPU model,
    /// kernel version, distribution, physical core count, boot time, ...).
    /// Purely informational and entirely best-effort — optional so
    /// registrations from agents that predate host-info reporting decode fine,
    /// and any individual field the agent couldn't probe is absent.
    public let hostInfo: HostInfo?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        agentId: String,
        hostname: String,
        version: String,
        capabilities: [String],
        resources: AgentResources,
        hypervisorType: HypervisorType = .qemu,
        architecture: CPUArchitecture? = nil,
        hypervisors: [HypervisorSupport]? = nil,
        networkCapability: NetworkCapability? = nil,
        protocolVersion: Int? = WireProtocol.currentVersion,
        sandboxCapable: Bool? = nil,
        operatingSystem: OperatingSystem? = nil,
        hostInfo: HostInfo? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.agentId = agentId
        self.hostname = hostname
        self.version = version
        self.capabilities = capabilities
        self.resources = resources
        self.hypervisorType = hypervisorType
        self.architecture = architecture
        self.hypervisors = hypervisors
        self.networkCapability = networkCapability
        self.protocolVersion = protocolVersion
        self.sandboxCapable = sandboxCapable
        self.operatingSystem = operatingSystem
        self.hostInfo = hostInfo
    }

    /// The hypervisor list to act on: the probed report when the agent sent
    /// one, otherwise entries derived from the hypervisor types named in the
    /// legacy `capabilities` strings. Agents have always advertised the
    /// backends they can run there (older builds hardcoded them per platform,
    /// newer ones gate each on a binary probe), so deriving from capabilities
    /// both preserves multi-hypervisor legacy agents and respects failed
    /// probes — an agent advertising no backend stays unschedulable rather
    /// than being resurrected by the configured-default `hypervisorType`
    /// scalar. Derived entries are assumed available but not accelerated,
    /// since such agents never probed KVM/HVF.
    public var effectiveHypervisors: [HypervisorSupport] {
        if let hypervisors, !hypervisors.isEmpty {
            return hypervisors
        }
        return HypervisorType.allCases
            .filter { capabilities.contains($0.rawValue) }
            .map { type in
                HypervisorSupport(
                    type: type,
                    available: true,
                    accelerated: false,
                    capabilities: .capabilities(for: type)
                )
            }
    }
}

public struct AgentHeartbeatMessage: WebSocketMessage {
    public var type: MessageType { .agentHeartbeat }
    public let requestId: String
    public let timestamp: Date
    public let agentId: String
    public let resources: AgentResources
    public let runningVMs: [String]  // VM IDs

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        agentId: String,
        resources: AgentResources,
        runningVMs: [String]
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.agentId = agentId
        self.resources = resources
        self.runningVMs = runningVMs
    }
}

public struct AgentUnregisterMessage: WebSocketMessage {
    public var type: MessageType { .agentUnregister }
    public let requestId: String
    public let timestamp: Date
    public let agentId: String
    public let reason: String?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        agentId: String,
        reason: String? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.agentId = agentId
        self.reason = reason
    }
}

/// Shape of the artifact an `AgentUpdateMessage` points at.
public enum AgentUpdateArtifactKind: String, Codable, Sendable {
    /// A gzipped tarball containing the agent binary as a member
    /// (`AgentUpdateMessage.tarballMember`) — the shape of the published
    /// release assets, which bundle control plane and agent together.
    case tarball = "tarball"
    /// A bare executable: the downloaded file *is* the new agent binary.
    case binary = "binary"
}

/// Control plane → agent command to replace the agent's own binary and restart
/// into it (issue #432). An update is an action, not a reconcilable state, so
/// it follows the `vmReboot` pattern: dispatched imperatively and answered with
/// a correlated `SuccessMessage`/`ErrorMessage`.
///
/// The agent downloads the artifact, verifies `sha256`, stages the new binary
/// next to the running one, atomically renames it over its own executable path,
/// replies, and exits for its supervisor to restart. Agents that run inside a
/// container refuse with an error (the image is the update mechanism there).
public struct AgentUpdateMessage: WebSocketMessage {
    public var type: MessageType { .agentUpdate }
    public let requestId: String
    public let timestamp: Date
    /// The version the artifact is expected to contain. Informational: the
    /// agent logs it and the control plane confirms the outcome when the
    /// restarted binary re-registers with its new reported version.
    public let targetVersion: String
    /// Where to download the artifact from. Must be an HTTPS URL the agent
    /// host can reach.
    public let artifactURL: String
    /// Hex SHA-256 digest of the artifact file (the tarball itself for
    /// `.tarball`, the executable for `.binary`). Verified before anything is
    /// swapped; a mismatch aborts with the old binary untouched.
    public let sha256: String
    public let artifactKind: AgentUpdateArtifactKind
    /// Member path of the agent binary inside a `.tarball` artifact.
    /// Ignored for `.binary`.
    public let tarballMember: String?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        targetVersion: String,
        artifactURL: String,
        sha256: String,
        artifactKind: AgentUpdateArtifactKind = .tarball,
        tarballMember: String? = "strato-agent"
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.targetVersion = targetVersion
        self.artifactURL = artifactURL
        self.sha256 = sha256
        self.artifactKind = artifactKind
        self.tarballMember = tarballMember
    }
}

extension AgentUpdateMessage {
    /// Artifact URLs may carry credentials — presigned query tokens or
    /// userinfo are often the only way to authenticate a private mirror
    /// download. Log this form, never the raw value, on both sides of the
    /// wire.
    public static func redactURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return "<unparseable-url>" }
        let hadQuery = components.query != nil
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let base = components.string else { return "<unparseable-url>" }
        return hadQuery ? base + "?[redacted]" : base
    }

    public var redactedArtifactURL: String { Self.redactURL(artifactURL) }
}

public struct AgentRegisterResponseMessage: WebSocketMessage {
    public let type: MessageType = .agentRegisterResponse
    public let requestId: String
    public let timestamp: Date
    public let agentId: String  // The database UUID assigned to this agent
    public let name: String  // The human-readable name

    /// Fresh single-use token for the agent's next (re)connection. Registration
    /// tokens are consumed on connect, so the control plane rotates them here —
    /// otherwise the agent's automatic reconnect after an unexpected drop would
    /// present an already-used token and be rejected. Nil for mTLS-authenticated
    /// connections (and from control planes that predate rotation).
    public let reconnectToken: String?

    /// Wire/schema version the control plane speaks (see
    /// `WireProtocol.currentVersion`). Optional so responses from control planes
    /// that predate protocol versioning decode fine; absent is treated as the
    /// legacy version 0. The agent compares this against its own version and
    /// logs on mismatch.
    public let protocolVersion: Int?

    public init(
        requestId: String,
        timestamp: Date = Date(),
        agentId: String,
        name: String,
        reconnectToken: String? = nil,
        protocolVersion: Int? = WireProtocol.currentVersion
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.agentId = agentId
        self.name = name
        self.reconnectToken = reconnectToken
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

// MARK: - VM Operation Messages

public struct VMCreateMessage: WebSocketMessage {
    public var type: MessageType { .vmCreate }
    public let requestId: String
    public let timestamp: Date
    public let vmData: VMData
    public let vmSpec: VMSpec
    public let imageInfo: ImageInfo?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmData: VMData,
        vmSpec: VMSpec,
        imageInfo: ImageInfo? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmData = vmData
        self.vmSpec = vmSpec
        self.imageInfo = imageInfo
    }
}

// MARK: - Image Information

/// Download information for a single typed artifact within an image's set.
///
/// The `downloadURL` is individually signed per artifact — an agent authorized
/// for the kernel is not implicitly authorized for the rootfs.
public struct ArtifactInfo: Codable, Sendable {
    public let kind: ArtifactKind
    /// Disk format raw string ("qcow2"/"raw") for `diskImage`/`rootfs`; nil for
    /// opaque blobs (`kernel`/`initramfs`). Kept as a string to avoid coupling
    /// the wire contract to the control plane's `ImageFormat` enum.
    public let format: String?
    public let filename: String
    public let checksum: String
    public let size: Int64
    public let downloadURL: String
    /// When the signed download URL expires (optional, for agent awareness).
    public let expiresAt: Date?

    public init(
        kind: ArtifactKind,
        format: String? = nil,
        filename: String,
        checksum: String,
        size: Int64,
        downloadURL: String,
        expiresAt: Date? = nil
    ) {
        self.kind = kind
        self.format = format
        self.filename = filename
        self.checksum = checksum
        self.size = size
        self.downloadURL = downloadURL
        self.expiresAt = expiresAt
    }
}

/// Contains information for the agent to download and cache an image.
///
/// The top-level `filename`/`checksum`/`size`/`downloadURL`/`expiresAt` describe
/// the primary disk image and are retained for the QEMU disk path and for
/// backward compatibility. Multi-backend drivers read `artifacts` to fetch the
/// specific typed files they need. `architecture` and `artifacts` decode as
/// absent (nil / empty) from legacy single-file payloads.
public struct ImageInfo: Codable, Sendable {
    public let imageId: UUID
    public let projectId: UUID
    public let filename: String
    public let checksum: String
    public let size: Int64
    public let downloadURL: String
    /// When the signed download URL expires (optional, for agent awareness)
    public let expiresAt: Date?
    /// Guest CPU architecture of the image; nil only for legacy payloads.
    public let architecture: CPUArchitecture?
    /// Typed artifact set. Empty for legacy single-file payloads, in which case
    /// the top-level fields describe the (disk) image.
    public let artifacts: [ArtifactInfo]

    public init(
        imageId: UUID,
        projectId: UUID,
        filename: String,
        checksum: String,
        size: Int64,
        downloadURL: String,
        expiresAt: Date? = nil,
        architecture: CPUArchitecture? = nil,
        artifacts: [ArtifactInfo] = []
    ) {
        self.imageId = imageId
        self.projectId = projectId
        self.filename = filename
        self.checksum = checksum
        self.size = size
        self.downloadURL = downloadURL
        self.expiresAt = expiresAt
        self.architecture = architecture
        self.artifacts = artifacts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        imageId = try container.decode(UUID.self, forKey: .imageId)
        projectId = try container.decode(UUID.self, forKey: .projectId)
        filename = try container.decode(String.self, forKey: .filename)
        checksum = try container.decode(String.self, forKey: .checksum)
        size = try container.decode(Int64.self, forKey: .size)
        downloadURL = try container.decode(String.self, forKey: .downloadURL)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        architecture = try container.decodeIfPresent(CPUArchitecture.self, forKey: .architecture)
        artifacts = try container.decodeIfPresent([ArtifactInfo].self, forKey: .artifacts) ?? []
    }

    /// The artifact of a given kind, if present in the set.
    public func artifact(ofKind kind: ArtifactKind) -> ArtifactInfo? {
        artifacts.first { $0.kind == kind }
    }
}

public struct VMOperationMessage: WebSocketMessage {
    public let type: MessageType
    public let requestId: String
    public let timestamp: Date
    public let vmId: String

    public init(
        type: MessageType,
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String
    ) {
        self.type = type
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
    }
}

public struct VMInfoRequestMessage: WebSocketMessage {
    public var type: MessageType { .vmInfo }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
    }
}

// MARK: - Response Messages

public struct SuccessMessage: WebSocketMessage {
    public var type: MessageType { .success }
    public let requestId: String
    public let timestamp: Date
    public let message: String?
    public let data: AnyCodableValue?

    public init(
        requestId: String,
        timestamp: Date = Date(),
        message: String? = nil,
        data: AnyCodableValue? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.message = message
        self.data = data
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
        /// The presented registration/reconnect token was rejected (invalid,
        /// expired, or already used). Retrying with the same token can never
        /// succeed.
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

public struct StatusUpdateMessage: WebSocketMessage {
    public var type: MessageType { .statusUpdate }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let status: VMStatus
    public let details: String?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        status: VMStatus,
        details: String? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.status = status
        self.details = details
    }
}

// MARK: - Any Codable Value for Dynamic Data

public struct AnyCodableValue: Codable, Sendable {
    public let value: CodableValue

    public init<T: Codable>(_ value: T) throws {
        let data = try WireProtocol.makeEncoder().encode(value)
        self.value = try WireProtocol.makeDecoder().decode(CodableValue.self, from: data)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try container.decode(CodableValue.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public func decode<T: Codable>(as type: T.Type) throws -> T {
        let data = try WireProtocol.makeEncoder().encode(value)
        return try WireProtocol.makeDecoder().decode(type, from: data)
    }
}

public enum CodableValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([CodableValue])
    case object([String: CodableValue])
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
        } else if let arrayValue = try? container.decode([CodableValue].self) {
            self = .array(arrayValue)
        } else if let objectValue = try? container.decode([String: CodableValue].self) {
            self = .object(objectValue)
        } else {
            throw DecodingError.typeMismatch(
                CodableValue.self,
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
}

// MARK: - Network Operation Messages

public struct NetworkCreateMessage: WebSocketMessage {
    public var type: MessageType { .networkCreate }
    public let requestId: String
    public let timestamp: Date
    public let networkName: String
    public let subnet: String
    public let gateway: String?
    public let vlanId: Int?
    public let dhcpEnabled: Bool
    public let dnsServers: [String]

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        networkName: String,
        subnet: String,
        gateway: String? = nil,
        vlanId: Int? = nil,
        dhcpEnabled: Bool = true,
        dnsServers: [String] = []
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.networkName = networkName
        self.subnet = subnet
        self.gateway = gateway
        self.vlanId = vlanId
        self.dhcpEnabled = dhcpEnabled
        self.dnsServers = dnsServers
    }
}

public struct NetworkDeleteMessage: WebSocketMessage {
    public var type: MessageType { .networkDelete }
    public let requestId: String
    public let timestamp: Date
    public let networkName: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        networkName: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.networkName = networkName
    }
}

public struct NetworkListMessage: WebSocketMessage {
    public var type: MessageType { .networkList }
    public let requestId: String
    public let timestamp: Date

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date()
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
    }
}

public struct NetworkInfoMessage: WebSocketMessage {
    public var type: MessageType { .networkInfo }
    public let requestId: String
    public let timestamp: Date
    public let networkName: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        networkName: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.networkName = networkName
    }
}

public struct NetworkAttachMessage: WebSocketMessage {
    public var type: MessageType { .networkAttach }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let networkName: String
    public let config: VMNetworkConfig?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        networkName: String,
        config: VMNetworkConfig? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.networkName = networkName
        self.config = config
    }
}

public struct NetworkDetachMessage: WebSocketMessage {
    public var type: MessageType { .networkDetach }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
    }
}

// MARK: - Console Operation Messages

public struct ConsoleConnectMessage: WebSocketMessage {
    public var type: MessageType { .consoleConnect }
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

// MARK: - Volume Operation Messages (QEMU only)

/// Message to create a new volume on an agent
public struct VolumeCreateMessage: WebSocketMessage {
    public var type: MessageType { .volumeCreate }
    public let requestId: String
    public let timestamp: Date
    public let volumeId: String
    public let size: Int64  // Size in bytes
    public let format: String  // "qcow2" or "raw"
    public let sourceImageInfo: ImageInfo?  // For volumes created from images
    public let sourceVolumePath: String?  // For cloning existing volumes

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        volumeId: String,
        size: Int64,
        format: String = "qcow2",
        sourceImageInfo: ImageInfo? = nil,
        sourceVolumePath: String? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.volumeId = volumeId
        self.size = size
        self.format = format
        self.sourceImageInfo = sourceImageInfo
        self.sourceVolumePath = sourceVolumePath
    }
}

/// Message to delete a volume from an agent. The agent owns volume path
/// layout and derives the volume's location from its ID; `volumePath` is a
/// legacy hint that new control planes no longer send, so deletion also
/// cleans up volumes whose create failed before a path was ever recorded.
public struct VolumeDeleteMessage: WebSocketMessage {
    public var type: MessageType { .volumeDelete }
    public let requestId: String
    public let timestamp: Date
    public let volumeId: String
    public let volumePath: String?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        volumeId: String,
        volumePath: String? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.volumeId = volumeId
        self.volumePath = volumePath
    }
}

/// Message to attach a volume to a running VM (hot-plug)
public struct VolumeAttachMessage: WebSocketMessage {
    public var type: MessageType { .volumeAttach }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let volumeId: String
    public let volumePath: String
    public let deviceName: String  // e.g., "disk1", "disk2"
    public let readonly: Bool

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        volumeId: String,
        volumePath: String,
        deviceName: String,
        readonly: Bool = false
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.volumeId = volumeId
        self.volumePath = volumePath
        self.deviceName = deviceName
        self.readonly = readonly
    }
}

/// Message to detach a volume from a running VM (hot-unplug)
public struct VolumeDetachMessage: WebSocketMessage {
    public var type: MessageType { .volumeDetach }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let volumeId: String
    public let deviceName: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        volumeId: String,
        deviceName: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.volumeId = volumeId
        self.deviceName = deviceName
    }
}

/// Message to resize a volume (must be detached)
public struct VolumeResizeMessage: WebSocketMessage {
    public var type: MessageType { .volumeResize }
    public let requestId: String
    public let timestamp: Date
    public let volumeId: String
    public let volumePath: String
    public let newSize: Int64  // New size in bytes

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        volumeId: String,
        volumePath: String,
        newSize: Int64
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.volumeId = volumeId
        self.volumePath = volumePath
        self.newSize = newSize
    }
}

/// Message to create a snapshot of a volume. The agent owns snapshot path
/// layout and reports the resulting path back in the response; `snapshotPath`
/// is a legacy hint that new control planes no longer send.
public struct VolumeSnapshotMessage: WebSocketMessage {
    public var type: MessageType { .volumeSnapshot }
    public let requestId: String
    public let timestamp: Date
    public let volumeId: String
    public let snapshotId: String
    public let volumePath: String
    public let snapshotPath: String?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        volumeId: String,
        snapshotId: String,
        volumePath: String,
        snapshotPath: String? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.volumeId = volumeId
        self.snapshotId = snapshotId
        self.volumePath = volumePath
        self.snapshotPath = snapshotPath
    }
}

/// Message to delete a snapshot of a volume from storage. Carries no file
/// path: the agent derives the snapshot's location from the IDs (the same
/// derivation it used when creating the snapshot), so deletion works even
/// when the control plane never learned the path — e.g. when the snapshot
/// was created on the agent but the success response was lost.
public struct VolumeSnapshotDeleteMessage: WebSocketMessage {
    public var type: MessageType { .volumeSnapshotDelete }
    public let requestId: String
    public let timestamp: Date
    public let volumeId: String
    public let snapshotId: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        volumeId: String,
        snapshotId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.volumeId = volumeId
        self.snapshotId = snapshotId
    }
}

/// Message to clone a volume. The agent owns volume path layout and reports
/// the clone's path back in the response; `targetVolumePath` is a legacy hint
/// that new control planes no longer send.
public struct VolumeCloneMessage: WebSocketMessage {
    public var type: MessageType { .volumeClone }
    public let requestId: String
    public let timestamp: Date
    public let sourceVolumeId: String
    public let sourceVolumePath: String
    public let targetVolumeId: String
    public let targetVolumePath: String?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sourceVolumeId: String,
        sourceVolumePath: String,
        targetVolumeId: String,
        targetVolumePath: String? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sourceVolumeId = sourceVolumeId
        self.sourceVolumePath = sourceVolumePath
        self.targetVolumeId = targetVolumeId
        self.targetVolumePath = targetVolumePath
    }
}

/// Message to get volume information
public struct VolumeInfoMessage: WebSocketMessage {
    public var type: MessageType { .volumeInfo }
    public let requestId: String
    public let timestamp: Date
    public let volumeId: String
    public let volumePath: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        volumeId: String,
        volumePath: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.volumeId = volumeId
        self.volumePath = volumePath
    }
}

/// Response with volume information from agent
public struct VolumeInfoResponse: Codable, Sendable {
    public let volumeId: String
    public let actualSize: Int64  // Actual disk usage
    public let virtualSize: Int64  // Provisioned size
    public let format: String
    public let dirty: Bool  // Has uncommitted changes
    public let encrypted: Bool

    public init(
        volumeId: String,
        actualSize: Int64,
        virtualSize: Int64,
        format: String,
        dirty: Bool = false,
        encrypted: Bool = false
    ) {
        self.volumeId = volumeId
        self.actualSize = actualSize
        self.virtualSize = virtualSize
        self.format = format
        self.dirty = dirty
        self.encrypted = encrypted
    }
}

/// Response for volume operations (create, attach, detach, etc.)
public struct VolumeStatusResponse: Codable, Sendable {
    public let volumeId: String
    public let status: String
    public let storagePath: String?

    public init(
        volumeId: String,
        status: String,
        storagePath: String?
    ) {
        self.volumeId = volumeId
        self.status = status
        self.storagePath = storagePath
    }
}

// MARK: - Message Envelope

public struct MessageEnvelope: Codable, Sendable {
    public let type: MessageType
    /// Wire/schema version of the sender (see `WireProtocol.currentVersion`).
    /// Optional so envelopes from peers that predate versioning — which omit the
    /// field entirely — still decode; a missing value is treated as the legacy
    /// version 0 via `senderVersion`.
    public let version: Int?
    public let payload: Data

    public init<T: WebSocketMessage>(message: T) throws {
        self.type = message.type
        self.version = WireProtocol.currentVersion
        self.payload = try WireProtocol.makeEncoder().encode(message)
    }

    public func decode<T: WebSocketMessage>(as messageType: T.Type) throws -> T {
        return try WireProtocol.makeDecoder().decode(messageType, from: payload)
    }

    /// The sender's wire version, mapping a pre-versioning envelope (no `version`
    /// field) to 0 so callers can compare against `WireProtocol.currentVersion`
    /// without special-casing `nil`.
    public var senderVersion: Int { version ?? 0 }
}

// MARK: - VM Log Messages

/// Log level for VM log messages
public enum VMLogLevel: String, Codable, CaseIterable, Sendable {
    case debug = "debug"
    case info = "info"
    case warning = "warning"
    case error = "error"
    /// Fallback for a level emitted by a peer on a newer protocol version.
    case unknown = "unknown"

    /// Tolerant decoding: an unrecognized level decodes to `.unknown` rather
    /// than throwing, so a purely informational field can't fail the decode of
    /// an entire log message across protocol versions.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VMLogLevel(rawValue: raw) ?? .unknown
    }
}

/// Source of the log message
public enum VMLogSource: String, Codable, CaseIterable, Sendable {
    case agent = "agent"
    case qemu = "qemu"
    case controlPlane = "control_plane"
    /// Fallback for a source emitted by a peer on a newer protocol version.
    case unknown = "unknown"

    /// Tolerant decoding: see `VMLogLevel.init(from:)`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VMLogSource(rawValue: raw) ?? .unknown
    }
}

/// Type of VM event
public enum VMEventType: String, Codable, CaseIterable, Sendable {
    case statusChange = "status_change"
    case operation = "operation"
    case qemuOutput = "qemu_output"
    case error = "error"
    case info = "info"
    /// Fallback for an event type emitted by a peer on a newer protocol version.
    case unknown = "unknown"

    /// Tolerant decoding: see `VMLogLevel.init(from:)`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VMEventType(rawValue: raw) ?? .unknown
    }
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
    public let details: String?
    public let previousStatus: VMStatus?
    public let newStatus: VMStatus?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        level: VMLogLevel,
        source: VMLogSource,
        eventType: VMEventType,
        message: String,
        operation: String? = nil,
        details: String? = nil,
        previousStatus: VMStatus? = nil,
        newStatus: VMStatus? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.level = level
        self.source = source
        self.eventType = eventType
        self.message = message
        self.operation = operation
        self.details = details
        self.previousStatus = previousStatus
        self.newStatus = newStatus
    }
}
