import Foundation

// MARK: - Sandbox snapshot vocabulary

/// How the sandbox proceeds once its checkpoint is captured.
public enum SandboxSnapshotMode: String, Codable, CaseIterable, Sendable {
    /// Resume the guest after the snapshot: the sandbox keeps running and
    /// the snapshot is a point-in-time checkpoint it can later be restored to.
    case resume
    /// Leave the guest stopped after the snapshot (checkpoint-and-stop): the
    /// sandbox converges to `stopped` and can later resume from the
    /// checkpoint via restore.
    case stop
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
public enum SandboxSnapshotArtifactKind: String, Codable, CaseIterable, Sendable {
    case memory
    case vmstate
    case rootfs
    case config

    public var filename: String {
        switch self {
        case .memory: return "memory.snap"
        case .vmstate: return "vmstate.snap"
        case .rootfs: return "rootfs.ext4"
        case .config: return "config.img"
        }
    }
}

/// Where an agent fetches an exported artifact and how it verifies the bytes.
/// The control plane records size and SHA-256 while streaming the export, so
/// integrity metadata is not agent-supplied.
public struct SandboxSnapshotArtifactDescriptor: Codable, Equatable, Sendable {
    public let kind: SandboxSnapshotArtifactKind
    /// Control-plane-relative download path
    /// (`/api/sandboxes/.../snapshots/.../artifacts/<kind>`).
    public let downloadURL: String
    public let sizeBytes: Int64
    /// Lowercase hex SHA-256 of the artifact bytes.
    public let sha256: String

    public init(
        kind: SandboxSnapshotArtifactKind,
        downloadURL: String,
        sizeBytes: Int64,
        sha256: String
    ) {
        self.kind = kind
        self.downloadURL = downloadURL
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

/// An mTLS upload slot for one snapshot artifact. The control plane hashes and
/// sizes the stream as it lands in object storage.
public struct SandboxSnapshotArtifactUploadTarget: Codable, Equatable, Sendable {
    public let kind: SandboxSnapshotArtifactKind
    /// Control-plane-relative upload path (same route as the download,
    /// method PUT).
    public let uploadURL: String

    public init(kind: SandboxSnapshotArtifactKind, uploadURL: String) {
        self.kind = kind
        self.uploadURL = uploadURL
    }
}
