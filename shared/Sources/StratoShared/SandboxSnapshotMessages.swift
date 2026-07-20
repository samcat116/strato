import Foundation

// MARK: - Sandbox snapshot / checkpoint messages (protocol version >= 9, issue #426)
//
// Snapshot creation, deletion, and restore are imperative actions — not
// states — so, like volume operations and `vmReboot`, they cannot ride the
// level-triggered desired-state sync. Each is a request/response pair over
// the agent WebSocket, correlated by `requestId` and answered with
// `success`/`error`; cross-replica requests forward over the replica RPC
// channel exactly like volume operations.

/// How the sandbox proceeds once its checkpoint is captured.
public enum SandboxSnapshotMode: String, Codable, Sendable {
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

/// Ask the agent holding a snapshot's artifacts to export them to the control
/// plane's object storage (issue #428): one sequential streaming PUT per
/// artifact to the pre-signed upload targets. Uploads are idempotent — each
/// PUT replaces the object at its deterministic key — so a retried export
/// after a lost response converges on the same bytes.
public struct SandboxSnapshotExportMessage: WebSocketMessage {
    public var type: MessageType { .sandboxSnapshotExport }
    public let requestId: String
    public let timestamp: Date
    public let sandboxId: String
    public let snapshotId: String
    public let uploads: [SandboxSnapshotArtifactUploadTarget]

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sandboxId: String,
        snapshotId: String,
        uploads: [SandboxSnapshotArtifactUploadTarget]
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sandboxId = sandboxId
        self.snapshotId = snapshotId
        self.uploads = uploads
    }
}

/// Ask an agent to checkpoint a sandbox: drain host↔guest connections, pause
/// the microVM, capture guest memory + vmstate, copy the rootfs, then resume
/// or stay stopped per `mode`. The agent owns snapshot artifact layout and
/// reports sizes + compatibility constraints back in
/// `SandboxSnapshotStatusResponse`.
public struct SandboxSnapshotCreateMessage: WebSocketMessage {
    public var type: MessageType { .sandboxSnapshotCreate }
    public let requestId: String
    public let timestamp: Date
    public let sandboxId: String
    public let snapshotId: String
    public let mode: SandboxSnapshotMode

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sandboxId: String,
        snapshotId: String,
        mode: SandboxSnapshotMode
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sandboxId = sandboxId
        self.snapshotId = snapshotId
        self.mode = mode
    }
}

/// Ask an agent to delete a sandbox snapshot's artifacts. Carries only IDs:
/// the agent derives the snapshot's location the same way it did at creation,
/// so deletion also cleans up snapshots whose create succeeded agent-side but
/// whose response was lost. Agent-side deletion is idempotent.
public struct SandboxSnapshotDeleteMessage: WebSocketMessage {
    public var type: MessageType { .sandboxSnapshotDelete }
    public let requestId: String
    public let timestamp: Date
    public let sandboxId: String
    public let snapshotId: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sandboxId: String,
        snapshotId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sandboxId = sandboxId
        self.snapshotId = snapshotId
    }
}

/// Ask an agent to restore a sandbox in place from one of its snapshots:
/// tear down the current microVM, load the checkpointed memory + rootfs, and
/// resume. Same sandbox, same identity — it keeps its ID, NIC, and addresses.
/// When the sandbox no longer lives on the agent that took the snapshot,
/// `artifacts` carries signed download descriptors for the exported copy and
/// the agent stages the archive from object storage first (issue #428).
public struct SandboxRestoreMessage: WebSocketMessage {
    public var type: MessageType { .sandboxRestore }
    public let requestId: String
    public let timestamp: Date
    public let sandboxId: String
    public let snapshotId: String
    /// Download descriptors for an exported snapshot, present only when this
    /// agent does not hold the local artifacts. Additive: absent decodes to
    /// nil, preserving the v9 local-restore contract.
    public let artifacts: [SandboxSnapshotArtifactDescriptor]?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sandboxId: String,
        snapshotId: String,
        artifacts: [SandboxSnapshotArtifactDescriptor]? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sandboxId = sandboxId
        self.snapshotId = snapshotId
        self.artifacts = artifacts
    }
}

/// The agent's report on a completed sandbox snapshot, carried in the
/// `success` response payload. Sizes let the control plane charge storage
/// quota; the compatibility fields record what a future restore must match —
/// Firecracker snapshots are tied to the Firecracker version, CPU, and device
/// topology they were taken with.
public struct SandboxSnapshotStatusResponse: Codable, Sendable {
    public let snapshotId: String
    /// Total on-disk footprint (memory + vmstate + rootfs copy) in bytes.
    public let sizeBytes: Int64
    public let memorySizeBytes: Int64
    public let vmstateSizeBytes: Int64
    public let rootfsSizeBytes: Int64
    /// The agent-owned directory holding the snapshot artifacts.
    public let storagePath: String
    /// `vmm_version` of the Firecracker that took the snapshot; a restore
    /// needs a compatible (in practice: identical) Firecracker version.
    public let firecrackerVersion: String
    /// Host CPU architecture the snapshot was taken on.
    public let architecture: CPUArchitecture?
    /// Version advertised by the guest frozen into this checkpoint. Nil is a
    /// legacy/unknown guest and must not be assumed to support fork identity
    /// rotation merely because its owning agent is current.
    public let guestControlProtocolVersion: Int?
    /// Version of the fork-safe artifact layout, or nil for legacy/unjailed
    /// checkpoints that remain eligible for in-place restore only.
    public let forkLayoutVersion: Int?
    /// Firecracker CPU template the checkpointed guest booted with (issue
    /// #428) — the agent-authoritative record of what the guest state was
    /// actually captured under. Nil means no template: the snapshot only
    /// restores on hosts with an identical CPU model.
    public let cpuTemplate: String?

    public init(
        snapshotId: String,
        sizeBytes: Int64,
        memorySizeBytes: Int64,
        vmstateSizeBytes: Int64,
        rootfsSizeBytes: Int64,
        storagePath: String,
        firecrackerVersion: String,
        architecture: CPUArchitecture?,
        guestControlProtocolVersion: Int? = nil,
        forkLayoutVersion: Int? = nil,
        cpuTemplate: String? = nil
    ) {
        self.snapshotId = snapshotId
        self.sizeBytes = sizeBytes
        self.memorySizeBytes = memorySizeBytes
        self.vmstateSizeBytes = vmstateSizeBytes
        self.rootfsSizeBytes = rootfsSizeBytes
        self.storagePath = storagePath
        self.firecrackerVersion = firecrackerVersion
        self.architecture = architecture
        self.guestControlProtocolVersion = guestControlProtocolVersion
        self.forkLayoutVersion = forkLayoutVersion
        self.cpuTemplate = cpuTemplate
    }
}
