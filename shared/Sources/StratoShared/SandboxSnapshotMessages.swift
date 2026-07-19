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
/// resume. Same agent, same identity — the sandbox keeps its ID, NIC, and
/// addresses (v1 restores only on the agent holding the snapshot).
public struct SandboxRestoreMessage: WebSocketMessage {
    public var type: MessageType { .sandboxRestore }
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
        forkLayoutVersion: Int? = nil
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
    }
}
