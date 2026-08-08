import Foundation

// MARK: - WebSocket Message Types

public enum MessageType: String, Codable, Sendable {
    // Agent registration and heartbeat
    case agentRegister = "agent_register"
    case agentRegisterResponse = "agent_register_response"
    case agentHeartbeat = "agent_heartbeat"
    case agentUnregister = "agent_unregister"
    // `agent_update` (v6–v27) is gone: the agent's build is desired state, not
    // an action, and rides the sync as `DesiredStateMessage.desiredAgentUpdate`
    // (v7+). The operator's "update now" assigns that field rather than
    // dispatching a command (ADR 0001 stage 6).

    // No VM frames remain. `vm_reboot` and `vm_restore` were removed in wire
    // v34 (ADR 0001 stage 9, STR-151): both are *edges* rather than states, and
    // an edge becomes a state once "how many times it was asked" is part of the
    // state — so they ride `DesiredVMState.rebootGeneration` and
    // `DesiredVMState.restore` as monotonic nonces the agent applies once and
    // records durably. `vm_checkpoint` and `vm_snapshot_delete` went at v33: a
    // checkpoint's *result* is a durable artifact, so it rides
    // `DesiredStateMessage.snapshots` and is confirmed through
    // `ObservedStateReport.snapshots` (STR-150).

    // Network topology has no imperative messages: it is level-triggered from
    // `DesiredStateMessage.networks` alone. The removed `network_*` frames
    // named their OVN objects after user-chosen network names — which two
    // projects may now share (issue #765) — and no control plane had sent them
    // since desired-state sync landed.

    // Volume operations (QEMU only - not supported for Firecracker).
    //
    // `volume_create`, `volume_delete`, `volume_attach`, `volume_detach`,
    // `volume_resize` and `volume_clone` were removed in wire v31: volumes are
    // desired state now (ADR 0001 stage 5, STR-148), realized from
    // `DesiredStateMessage.volumes` and confirmed through
    // `ObservedStateReport.volumes`. `volume_info` followed in v32 (stage 7,
    // STR-149) — a read is not an action, and the control plane answers it
    // from the observed report it already stores. `volume_snapshot` and
    // `volume_snapshot_delete` went at v33 (stage 8, STR-150), onto
    // `DesiredStateMessage.snapshots`. Nothing volume-shaped is left here.

    // Console operations
    case consoleConnect = "console_connect"
    case consoleDisconnect = "console_disconnect"
    case consoleData = "console_data"
    case consoleConnected = "console_connected"
    case consoleDisconnected = "console_disconnected"

    // Reconciliation state sync (protocol version >= 2)
    case desiredState = "desired_state"
    case observedState = "observed_state"

    // Responses. Not correlated any more: the control plane's generic
    // pending-request apparatus went with the last imperative exchange (ADR
    // 0001 stage 11, STR-152), so nothing awaits a `requestId`. What survives
    // is control-plane → agent only, and unsolicited in both directions that
    // matter — an ACK the agent logs (register, heartbeat, unregister) and a
    // registration rejection the agent's reconnect loop reads for its
    // `ErrorMessage.code`.
    case success = "success"
    case error = "error"
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

    // No sandbox lifecycle frames remain either. `sandbox_restore` went with
    // `vm_restore` at v34 and for the same reason (STR-151), onto
    // `DesiredSandboxState.restore`; `sandbox_snapshot_create`,
    // `sandbox_snapshot_delete` and `sandbox_snapshot_export` went at v33
    // (STR-150) — the first two are the artifact's existence, the third is
    // *where* it exists, and all three are states on
    // `DesiredStateMessage.snapshots`.
    //
    // What is left in this enum, beyond registration and the two reconciliation
    // frames, is exactly the category ADR 0001 always meant to keep imperative:
    // live byte pipes with a human on the end.
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
    /// cannot realize a NIC is never handed one. Optional so registrations from
    /// older agents decode fine; absent means not capable.
    public let sandboxNetworkingCapable: Bool?
    /// Whether this host can give a guest an emulated TPM 2.0 — it has a
    /// usable `swtpm` binary (issue #565). Like `sandboxCapable`, speaking the
    /// wire version is deliberately not sufficient: the protocol carries
    /// `MachineProfile.tpm`, but only a host with swtpm installed can realize
    /// it, and a VM whose vTPM is silently dropped fails Windows setup with no
    /// explanation. Optional so registrations from older agents decode fine;
    /// absent means not capable.
    public let tpmCapable: Bool?
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
    /// Whether this agent fetches its desired state from
    /// `GET /agent/desired-state` rather than waiting for pushed
    /// `desired_state` frames (ADR 0001 stage 10). True means "stop pushing to
    /// me" — the control plane skips this agent in its periodic push pass and
    /// rings the broadcast doorbell instead of writing to its socket.
    ///
    /// Like `sandboxCapable`, speaking the wire version is deliberately not
    /// sufficient: a v29 agent understands the endpoint but may be pinned to
    /// push mode by config, and the control plane must not stop pushing to an
    /// agent that isn't actually polling. Optional so registrations from older
    /// agents decode fine; absent means push mode, which is the safe default
    /// in both directions of skew.
    public let pullsDesiredState: Bool?

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
        sandboxNetworkingCapable: Bool? = nil,
        tpmCapable: Bool? = nil,
        operatingSystem: OperatingSystem? = nil,
        hostInfo: HostInfo? = nil,
        pullsDesiredState: Bool? = nil
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
        self.sandboxNetworkingCapable = sandboxNetworkingCapable
        self.tpmCapable = tpmCapable
        self.operatingSystem = operatingSystem
        self.hostInfo = hostInfo
        self.pullsDesiredState = pullsDesiredState
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
        protocolVersion: Int? = WireProtocol.currentVersion
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
    /// Disk format raw string ("qcow2"/"raw") for `diskImage`/`rootfs`; nil for
    /// opaque blobs (`kernel`/`initramfs`). Kept as a string to avoid coupling
    /// the wire contract to the control plane's `ImageFormat` enum.
    public let format: String?
    public let filename: String
    public let checksum: String
    public let size: Int64
    public let downloadURL: String

    public init(
        kind: ArtifactKind,
        format: String? = nil,
        filename: String,
        checksum: String,
        size: Int64,
        downloadURL: String
    ) {
        self.kind = kind
        self.format = format
        self.filename = filename
        self.checksum = checksum
        self.size = size
        self.downloadURL = downloadURL
    }
}

/// Contains information for the agent to download and cache an image.
///
/// The top-level `filename`/`checksum`/`size`/`downloadURL` describe the
/// primary disk image and are retained for the QEMU disk path and for
/// backward compatibility. Multi-backend drivers read `artifacts` to fetch the
/// specific typed files they need. `architecture` and `artifacts` decode as
/// absent (nil / empty) from legacy single-file payloads. Like
/// `ArtifactInfo.downloadURL`, the download URL is a control-plane-relative
/// path fetched over SVID mTLS.
public struct ImageInfo: Codable, Sendable {
    public let imageId: UUID
    public let projectId: UUID
    public let filename: String
    public let checksum: String
    public let size: Int64
    public let downloadURL: String
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
        architecture: CPUArchitecture? = nil,
        artifacts: [ArtifactInfo] = []
    ) {
        self.imageId = imageId
        self.projectId = projectId
        self.filename = filename
        self.checksum = checksum
        self.size = size
        self.downloadURL = downloadURL
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
        architecture = try container.decodeIfPresent(CPUArchitecture.self, forKey: .architecture)
        artifacts = try container.decodeIfPresent([ArtifactInfo].self, forKey: .artifacts) ?? []
    }

    /// The artifact of a given kind, if present in the set.
    public func artifact(ofKind kind: ArtifactKind) -> ArtifactInfo? {
        artifacts.first { $0.kind == kind }
    }
}

// `VMOperationMessage` — the generic "do this verb to this VM" envelope — went
// with `vm_reboot` at wire v34 (STR-151). It outlived the imperative lifecycle
// frames of v10 by carrying exactly one verb, and that verb is a nonce now.

// MARK: - Response Messages

/// An unsolicited acknowledgement — registration, heartbeat, unregister. The
/// `data` field went with the correlation apparatus (STR-152): every typed
/// reply that used to ride it (volume info, snapshot metadata, checkpoint
/// results) is now a field on `ObservedStateReport`, so nothing has a payload
/// to return. `requestId` echoes the acknowledged frame's id for log
/// correlation only; no sender awaits it.
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
    /// Which console to attach. Nil from control planes that predate the
    /// graphics console; read it through `effectiveStream`. Optional so the
    /// synthesized encoder omits the key for a serial connect, leaving the
    /// frame a pre-#566 agent sees byte-identical to today's.
    public let stream: ConsoleStream?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String,
        stream: ConsoleStream? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.sessionId = sessionId
        self.stream = stream
    }

    /// The console to attach, defaulting to the text console — which is the
    /// only one that existed when the field was absent.
    public var effectiveStream: ConsoleStream { stream ?? .serial }
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

// The volume message section is empty by design. `volume_create`,
// `volume_delete`, `volume_attach`, `volume_detach`, `volume_resize` and
// `volume_clone` became desired state at wire v31 (STR-148); `volume_info` was
// deleted at v32 as a read that was never an action (STR-149); and
// `volume_snapshot`/`volume_snapshot_delete` became desired *artifacts* at v33
// (STR-150). What each carried now lives on `DesiredVolumeState`,
// `ObservedVolumeState`, `DesiredSnapshotState` or `ObservedSnapshotState` —
// or, for the thin-provisioning triple `volume_info` reported, nowhere, having
// had no reader.

// `VolumeStatusResponse` went with `volume_snapshot` at wire v33 (STR-150).
// It was the last imperative volume reply, and what it carried — status and
// storage path — is `ObservedVolumeState` / `ObservedSnapshotFacts` now.

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
