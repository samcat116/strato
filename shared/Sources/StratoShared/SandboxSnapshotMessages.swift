import Foundation
import SwiftProtobuf

// MARK: - Sandbox snapshot vocabulary

/// How the sandbox proceeds once its checkpoint is captured.
public typealias SandboxSnapshotMode = Strato_Agent_V1_SandboxSnapshotMode
extension Strato_Agent_V1_SandboxSnapshotMode: Codable {
    /// Resume the guest after the snapshot: the sandbox keeps running and
    /// the snapshot is a point-in-time checkpoint it can later be restored to.

    /// Leave the guest stopped after the snapshot (checkpoint-and-stop): the
    /// sandbox converges to `stopped` and can later resume from the
    /// checkpoint via restore.

    public var protocolValue: String {
        switch self {
        case .resume: return "resume"
        case .stop: return "stop"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "resume": self = .resume
        case "stop": self = .stop
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.resume, .stop] }

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

/// Artifact-layout capability recorded with a checkpoint. Fork restore
/// reuses Firecracker's chroot-relative device paths under a new jail root,
/// so snapshots captured from an unjailed microVM are intentionally
/// ineligible even when the agent and checkpointed guest are otherwise new.
public enum SandboxSnapshotForkLayout {
    public static let jailedV1 = 1
    public static let currentVersion = jailedV1

    public static func supportsFork(_ version: Int?) -> Bool {
        version == currentVersion
    }
}

// MARK: - Snapshot artifact transfer

/// The artifacts that make up one checkpoint archive. Raw values are stable
/// wire/object-key identifiers; `filename` is the canonical name inside a
/// snapshot directory and under an exported object prefix.
public typealias SandboxSnapshotArtifactKind = Strato_Agent_V1_SandboxSnapshotArtifactKind
extension Strato_Agent_V1_SandboxSnapshotArtifactKind: Codable {

    public var filename: String {
        switch self {
        case .memory: return "memory.snap"
        case .vmstate: return "vmstate.snap"
        case .rootfs: return "rootfs.ext4"
        case .config: return "config.img"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public var protocolValue: String {
        switch self {
        case .memory: return "memory"
        case .vmstate: return "vmstate"
        case .rootfs: return "rootfs"
        case .config: return "config"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "memory": self = .memory
        case "vmstate": self = .vmstate
        case "rootfs": self = .rootfs
        case "config": self = .config
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.memory, .vmstate, .rootfs, .config] }

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

/// Where an agent fetches an exported artifact and how it verifies the bytes.
/// The control plane records size and SHA-256 while streaming the export, so
/// integrity metadata is not agent-supplied.
public typealias SandboxSnapshotArtifactDescriptor = Strato_Agent_V1_SandboxSnapshotArtifactDescriptor
extension Strato_Agent_V1_SandboxSnapshotArtifactDescriptor: Codable {
    /// Control-plane-relative download path
    /// (`/api/sandboxes/.../snapshots/.../artifacts/<kind>`).
    /// Lowercase hex SHA-256 of the artifact bytes.

    public init(
        kind: SandboxSnapshotArtifactKind,
        downloadURL: String,
        sizeBytes: Int64,
        sha256: String
    ) {
        self.init()
        self._jsonKind = kind
        self._jsonDownloadURL = downloadURL
        self._jsonSizeBytes = sizeBytes
        self._jsonSha256 = sha256
    }

    private enum CodingKeys: String, CodingKey { case kind; case downloadURL; case sizeBytes; case sha256 }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonKind = try container.decode(SandboxSnapshotArtifactKind.self, forKey: .kind)
        self._jsonDownloadURL = try container.decode(String.self, forKey: .downloadURL)
        self._jsonSizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        self._jsonSha256 = try container.decode(String.self, forKey: .sha256)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonKind, forKey: .kind)
        try container.encode(_jsonDownloadURL, forKey: .downloadURL)
        try container.encode(_jsonSizeBytes, forKey: .sizeBytes)
        try container.encode(_jsonSha256, forKey: .sha256)
    }

    var _jsonKind: SandboxSnapshotArtifactKind {
        get { kind }
        set { let value = newValue; kind = value }
    }
    var _jsonDownloadURL: String {
        get { downloadURL }
        set { let value = newValue; downloadURL = value }
    }
    var _jsonSizeBytes: Int64 {
        get { sizeBytes }
        set { let value = newValue; sizeBytes = value }
    }
    var _jsonSha256: String {
        get { sha256 }
        set { let value = newValue; sha256 = value }
    }
}

/// An mTLS upload slot for one snapshot artifact. The control plane hashes and
/// sizes the stream as it lands in object storage.
public typealias SandboxSnapshotArtifactUploadTarget = Strato_Agent_V1_SandboxSnapshotArtifactUploadTarget
extension Strato_Agent_V1_SandboxSnapshotArtifactUploadTarget: Codable {
    /// Control-plane-relative upload path (same route as the download,
    /// method PUT).

    public init(kind: SandboxSnapshotArtifactKind, uploadURL: String) {
        self.init()
        self._jsonKind = kind
        self._jsonUploadURL = uploadURL
    }

    private enum CodingKeys: String, CodingKey { case kind; case uploadURL }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonKind = try container.decode(SandboxSnapshotArtifactKind.self, forKey: .kind)
        self._jsonUploadURL = try container.decode(String.self, forKey: .uploadURL)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonKind, forKey: .kind)
        try container.encode(_jsonUploadURL, forKey: .uploadURL)
    }

    var _jsonKind: SandboxSnapshotArtifactKind {
        get { kind }
        set { let value = newValue; kind = value }
    }
    var _jsonUploadURL: String {
        get { uploadURL }
        set { let value = newValue; uploadURL = value }
    }
}
