import Foundation
import StratoShared
import Vapor

/// Agent RPC client for full-VM checkpoint operations (issue #564), mirroring
/// `SandboxSnapshotService`: checkpoint, restore, and delete are actions — not
/// states — so they ride correlated WebSocket messages (with cross-replica
/// forwarding handled inside `AgentService.sendMessageToAgentWithResponse`)
/// instead of the level-triggered desired-state sync.
enum VMSnapshotService {
    /// A checkpoint or restore moves the guest's whole RAM through a QEMU
    /// background job. Just under the matching operation budget so the RPC
    /// verdict, not the sweep, decides the operation whenever the dispatching
    /// process survives.
    static let checkpointTimeout: Duration = .seconds(1770)
    static let deleteTimeout: Duration = .seconds(90)

    /// Preflight an agent for the checkpoint message set: it must be known,
    /// online, speak wire protocol v22, and advertise the capability. The
    /// message types postdate protocol version 21, so an older agent cannot
    /// decode the envelope — the frame is dropped before any error response
    /// can be sent and the request would burn its full timeout against
    /// silence. The capability adds what the version cannot say: a v22 agent
    /// on a host with no usable QEMU understands the frames but can only ever
    /// answer `notSupported`.
    static func requireCapableAgent(_ agentId: String, app: Application) async throws {
        guard let agentInfo = await app.agentService.getAgentInfo(agentId) else {
            throw VMSnapshotServiceError.agentNotFound(agentId)
        }
        guard agentInfo.status == .online else {
            throw VMSnapshotServiceError.agentOffline(agentId)
        }
        // Two signals, the `sandboxCapable` rule from issue #415: the wire
        // version proves the frames decode at all, the capability proves a
        // backend that can realize them is usable on that host. Either alone
        // admits a request that can only fail — a pre-v22 agent silently, by
        // dropping the frame.
        guard WireProtocol.supportsVMCheckpoint(agentInfo.wireProtocolVersion ?? 0),
            agentInfo.capabilities.contains(MessageType.vmCheckpoint.rawValue)
        else {
            throw VMSnapshotServiceError.operationUnsupportedByAgent(agentId)
        }
    }

    /// Ask the VM's agent to checkpoint it and await the report. The report is
    /// mandatory: a success frame without a decodable payload is a protocol
    /// error, not a completed checkpoint — marking the row ready without it
    /// would lose both the quota figure and the restore-compat constraints.
    static func requestCheckpoint(
        vmId: UUID,
        snapshotId: UUID,
        agentId: String,
        app: Application
    ) async throws -> VMCheckpointStatusResponse {
        let message = VMCheckpointMessage(
            vmId: vmId.uuidString, snapshotId: snapshotId.uuidString)
        let response = try await send(message, toAgent: agentId, timeout: Self.checkpointTimeout, app: app)
        guard let payload = response else {
            throw VMSnapshotServiceError.malformedAgentResponse(
                "agent confirmed the checkpoint but sent no report")
        }
        do {
            return try payload.decode(as: VMCheckpointStatusResponse.self)
        } catch {
            throw VMSnapshotServiceError.malformedAgentResponse(
                "agent checkpoint report failed to decode: \(error.localizedDescription)")
        }
    }

    /// Ask the agent to restore the VM in place from a checkpoint. The agent
    /// resumes the guest itself, so a success here means the machine is
    /// running again from the captured state.
    static func requestRestore(
        vmId: UUID,
        snapshotId: UUID,
        agentId: String,
        app: Application
    ) async throws {
        let message = VMRestoreMessage(vmId: vmId.uuidString, snapshotId: snapshotId.uuidString)
        _ = try await send(message, toAgent: agentId, timeout: Self.checkpointTimeout, app: app)
    }

    /// Ask the agent to drop a checkpoint from the VM's disks. Carries only
    /// IDs (the agent re-derives the tag), and agent-side deletion is
    /// idempotent.
    static func requestDelete(
        vmId: UUID,
        snapshotId: UUID,
        agentId: String,
        app: Application
    ) async throws {
        let message = VMSnapshotDeleteMessage(vmId: vmId.uuidString, snapshotId: snapshotId.uuidString)
        _ = try await send(message, toAgent: agentId, timeout: Self.deleteTimeout, app: app)
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
            "Sending VM checkpoint message to agent",
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
            throw VMSnapshotServiceError.agentOperationFailed(error, details)
        }
    }
}

enum VMSnapshotServiceError: Error, LocalizedError {
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
                "Agent '\(id)' does not support full-VM checkpoints (capability '\(MessageType.vmCheckpoint.rawValue)' not advertised). Upgrade the agent, or place the VM on a QEMU-capable host."
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
