import Foundation
import StratoShared
import Vapor

/// Agent RPC client for sandbox snapshot operations (issue #426), mirroring
/// `VolumeService`'s imperative request/response pattern: snapshot create,
/// delete, and restore are actions — not states — so they ride correlated
/// WebSocket messages (with cross-replica forwarding handled inside
/// `AgentService.sendMessageToAgentWithResponse`) instead of the
/// level-triggered desired-state sync.
enum SandboxSnapshotService {
    /// Checkpoint/restore move the guest memory file plus (without reflink
    /// support) a full rootfs copy; just under the operation sweep budget so
    /// the RPC verdict, not the sweep, decides the operation whenever the
    /// dispatching process survives.
    static let snapshotTimeout: Duration = .seconds(570)
    static let deleteTimeout: Duration = .seconds(60)

    /// Preflight an agent for the sandbox-snapshot message set: it must be
    /// known, online, and advertise the capability. The message types
    /// postdate protocol version 8, so an older agent can't even decode the
    /// envelope — the frame is dropped before any error response can be sent
    /// and the request would burn its full timeout. Agents that understand
    /// the trio advertise `sandbox_snapshot_create` at registration; fail
    /// fast on ones that don't.
    static func requireCapableAgent(_ agentId: String, app: Application) async throws {
        guard let agentInfo = await app.agentService.getAgentInfo(agentId) else {
            throw SandboxSnapshotServiceError.agentNotFound(agentId)
        }
        guard agentInfo.status == .online else {
            throw SandboxSnapshotServiceError.agentOffline(agentId)
        }
        guard agentInfo.capabilities.contains(MessageType.sandboxSnapshotCreate.rawValue) else {
            throw SandboxSnapshotServiceError.operationUnsupportedByAgent(agentId)
        }
    }

    /// Ask the sandbox's agent to checkpoint it and await the artifact
    /// report (sizes + compatibility constraints). The report is mandatory:
    /// a success frame without a decodable payload is a protocol error, not a
    /// completed snapshot — marking the row ready without sizes would corrupt
    /// quota accounting and lose the restore-compat constraints.
    static func requestSnapshotCreate(
        sandboxId: UUID,
        snapshotId: UUID,
        mode: SandboxSnapshotMode,
        agentId: String,
        app: Application
    ) async throws -> SandboxSnapshotStatusResponse {
        let message = SandboxSnapshotCreateMessage(
            sandboxId: sandboxId.uuidString,
            snapshotId: snapshotId.uuidString,
            mode: mode)
        let response = try await send(message, toAgent: agentId, timeout: Self.snapshotTimeout, app: app)
        guard let payload = response else {
            throw SandboxSnapshotServiceError.malformedAgentResponse(
                "agent confirmed the snapshot but sent no artifact report")
        }
        do {
            return try payload.decode(as: SandboxSnapshotStatusResponse.self)
        } catch {
            throw SandboxSnapshotServiceError.malformedAgentResponse(
                "agent snapshot report failed to decode: \(error.localizedDescription)")
        }
    }

    /// Ask the agent to remove a snapshot's artifacts. Carries only IDs (the
    /// agent re-derives the path), and agent-side deletion is idempotent.
    static func requestSnapshotDelete(
        sandboxId: UUID,
        snapshotId: UUID,
        agentId: String,
        app: Application
    ) async throws {
        let message = SandboxSnapshotDeleteMessage(
            sandboxId: sandboxId.uuidString, snapshotId: snapshotId.uuidString)
        _ = try await send(message, toAgent: agentId, timeout: Self.deleteTimeout, app: app)
    }

    /// Ask the agent to restore the sandbox in place from a snapshot and
    /// await the guest's post-restore health confirmation. `artifacts`
    /// carries signed download descriptors when the agent must stage the
    /// archive from object storage first (cross-agent restore, issue #428).
    static func requestRestore(
        sandboxId: UUID,
        snapshotId: UUID,
        agentId: String,
        artifacts: [SandboxSnapshotArtifactDescriptor]? = nil,
        app: Application
    ) async throws {
        let message = SandboxRestoreMessage(
            sandboxId: sandboxId.uuidString, snapshotId: snapshotId.uuidString,
            artifacts: artifacts)
        _ = try await send(message, toAgent: agentId, timeout: Self.snapshotTimeout, app: app)
    }

    /// Ask the agent holding a snapshot's artifacts to stream them to the
    /// pre-signed object-storage upload targets (issue #428). Same timeout
    /// class as snapshot creation: the export moves the same bytes.
    static func requestSnapshotExport(
        sandboxId: UUID,
        snapshotId: UUID,
        uploads: [SandboxSnapshotArtifactUploadTarget],
        agentId: String,
        app: Application
    ) async throws {
        let message = SandboxSnapshotExportMessage(
            sandboxId: sandboxId.uuidString, snapshotId: snapshotId.uuidString, uploads: uploads)
        _ = try await send(message, toAgent: agentId, timeout: Self.snapshotTimeout, app: app)
    }

    /// Send one message and await the correlated success/error response,
    /// returning the success payload (if any) for the caller to decode.
    private static func send<T: WebSocketMessage>(
        _ message: T,
        toAgent agentId: String,
        timeout: Duration,
        app: Application
    ) async throws -> AnyCodableValue? {
        try await requireCapableAgent(agentId, app: app)

        app.logger.info(
            "Sending sandbox snapshot message to agent",
            metadata: [
                "agentId": .string(agentId),
                "messageType": .string(message.type.rawValue),
            ])

        let response = try await app.agentService.sendMessageToAgentWithResponse(
            message, agentId: agentId, timeout: timeout)

        switch response {
        case .success(let data):
            return data
        case .error(let error, let details):
            throw SandboxSnapshotServiceError.agentOperationFailed(error, details)
        }
    }
}

enum SandboxSnapshotServiceError: Error, LocalizedError {
    case agentNotFound(String)
    case agentOffline(String)
    case operationUnsupportedByAgent(String)
    case agentOperationFailed(String, String?)
    case malformedAgentResponse(String)

    var errorDescription: String? {
        switch self {
        case .agentNotFound(let id):
            return "Agent '\(id)' not found"
        case .agentOffline(let id):
            return "Agent '\(id)' is offline"
        case .operationUnsupportedByAgent(let id):
            return
                "Agent '\(id)' does not support sandbox snapshots (capability 'sandbox_snapshot_create' not advertised). Upgrade the agent."
        case .agentOperationFailed(let error, let details):
            if let details, !details.isEmpty {
                return "\(error): \(details)"
            }
            return error
        case .malformedAgentResponse(let reason):
            return reason
        }
    }
}
