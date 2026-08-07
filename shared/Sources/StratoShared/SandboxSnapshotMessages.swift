import Foundation

// MARK: - Sandbox snapshot / checkpoint messages (protocol version >= 9, issue #426)
//
// Creating, deleting and exporting a checkpoint were imperative RPCs until wire
// v33 (ADR 0001 stage 8, STR-150). They are desired state now: a checkpoint's
// *existence* rides `DesiredStateMessage.snapshots`, and so does *where* it
// exists — an export is the placement fact "this snapshot also lives in the
// control plane's object store", with the byte transfer beneath left as a
// transport concern (`SnapshotArtifactTransfer`), exactly like a console pipe.
//
// `sandbox_restore` went at wire v34 (stage 9, STR-151), for `vm_restore`'s
// reason and by its route: an edge becomes a state once it is counted, so it
// rides `DesiredSandboxState.restore` as a monotonic nonce naming the snapshot
// to load — with the exported artifacts' transfer descriptors alongside it when
// the sandbox has moved off the host that captured it.
//
// What is left here is the vocabulary those desired entries are written in:
// capture mode, fork-layout versioning, artifact kinds and their transfer
// descriptors.

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

// MARK: - Snapshot artifact transfer (protocol version >= 14, issue #428)

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

/// Where an agent fetches one exported snapshot artifact and what the bytes
/// must verify to. `downloadURL` is a control-plane-relative path the agent
/// resolves against the base URL it already dials — the Envoy mTLS listener —
/// and fetches with its SVID-backed TLS client (the v13 image-download
/// model; issue #493). The size and SHA-256 were recorded by the control
/// plane while the export streamed through it, so a corrupt or truncated
/// download can never be restored.
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

/// One upload slot for a snapshot export: the agent streams the named
/// artifact's bytes to the control-plane-relative `uploadURL` with an mTLS
/// HTTP PUT, presenting its SVID. The control plane hashes and sizes the
/// stream itself as it lands in object storage — the recorded integrity
/// material is never agent-supplied.
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

// `SandboxSnapshotStatusResponse` went with `sandbox_snapshot_create` at wire
// v33. Everything it carried now travels on `ObservedSnapshotFacts`, which is
// re-sent on every heartbeat rather than delivered once: the old shape forced
// the control plane to treat a lost reply as a protocol error and mark a
// checkpoint that in fact existed `.error`.
