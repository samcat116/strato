import Foundation
import StratoShared
import Vapor

/// What is left of the full-VM checkpoint agent path after ADR 0001 stage 8
/// (STR-150).
///
/// Capturing a checkpoint and deleting one are desired state now: the control
/// plane writes the intent onto the artifact's row, the assembler puts it on the
/// agent's sync, and the agent's observed report closes the loop — carrying the
/// footprint, QEMU version and architecture that used to ride a one-shot RPC
/// reply. Neither goes through this type, and the pending-request apparatus
/// behind them is one caller closer to deletion.
///
/// What remains is `vm_restore`. Loading a captured RAM image back into a live
/// QEMU process is genuinely an edge rather than a state — "the VM should be at
/// checkpoint C" is not something an agent can re-converge on, because the guest
/// starts writing the moment it resumes — so it stays a correlated
/// request/response until STR-151 turns it into a monotonic nonce on the
/// desired entry.
enum VMSnapshotService {
    /// A restore moves the guest's whole RAM through a QEMU background job.
    /// Just under the matching operation budget so the RPC verdict, not the
    /// sweep, decides the operation whenever the dispatching process survives.
    static let restoreTimeout: Duration = .seconds(1770)

    /// Preflight an agent for `vm_restore`: it must be known, online, speak
    /// wire protocol v22, and advertise a QEMU backend. The message type
    /// postdates protocol version 21, so an older agent cannot decode the
    /// envelope — the frame is dropped before any error response can be sent
    /// and the request would burn its full timeout against silence. The
    /// capability adds what the version cannot say: a v22 agent on a host with
    /// no usable QEMU understands the frame but can only ever answer
    /// `notSupported`.
    static func requireCapableAgent(_ agentId: String, app: Application) async throws {
        guard let agentInfo = await app.agentService.getAgentInfo(agentId) else {
            throw VMSnapshotServiceError.agentNotFound(agentId)
        }
        guard agentInfo.status == .online else {
            throw VMSnapshotServiceError.agentOffline(agentId)
        }
        // Two signals, the `sandboxCapable` rule from issue #415: the wire
        // version proves the frame decodes at all, the capability proves a
        // backend that can realize it is usable on that host. Either alone
        // admits a request that can only fail — a pre-v22 agent silently, by
        // dropping the frame.
        guard WireProtocol.supportsVMCheckpoint(agentInfo.wireProtocolVersion ?? 0),
            agentInfo.capabilities.contains(SnapshotArtifactKind.vmCheckpoint.agentCapability)
        else {
            throw VMSnapshotServiceError.operationUnsupportedByAgent(agentId)
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
        try await requireCapableAgent(agentId, app: app)

        let message = VMRestoreMessage(vmId: vmId.uuidString, snapshotId: snapshotId.uuidString)
        app.logger.info(
            "Sending VM restore message to agent",
            metadata: [
                "agentId": .string(agentId),
                "messageType": .string(message.type.rawValue),
            ])

        let response = try await app.agentService.sendMessageToAgentWithResponse(
            message, agentId: agentId, timeout: Self.restoreTimeout)

        switch response {
        case .success:
            return
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

    var errorDescription: String? {
        switch self {
        case .agentNotFound(let id):
            return "Agent '\(id)' not found"
        case .agentOffline(let id):
            return "Agent '\(id)' is offline"
        case .operationUnsupportedByAgent(let id):
            return
                "Agent '\(id)' does not support full-VM checkpoints (capability '\(SnapshotArtifactKind.vmCheckpoint.agentCapability)' not advertised). Upgrade the agent, or place the VM on a QEMU-capable host."
        case .agentOperationFailed(let error, let details):
            if let details, !details.isEmpty {
                return "\(error): \(details)"
            }
            return error
        }
    }
}
