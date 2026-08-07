import Foundation
import StratoShared
import Vapor

/// What is left of the sandbox-snapshot agent path after ADR 0001 stage 8
/// (STR-150).
///
/// Capture, delete and export are desired state now — the last of those as a
/// *placement fact* ("this snapshot should also exist in object storage")
/// rather than a verb, with the byte transfer beneath left where it belongs, in
/// the agent's `SnapshotArtifactTransfer`. None of the three goes through this
/// type any more, and neither do their sizes and compatibility constraints:
/// those ride the observed report, which is re-sent on every heartbeat instead
/// of delivered once.
///
/// What remains is `sandbox_restore`, an edge for `vm_restore`'s reason, until
/// STR-151 makes it a nonce.
enum SandboxSnapshotService {
    /// A local restore is a file copy; one that has to stage the archive from
    /// object storage first (issue #428) moves the same bytes over the network,
    /// through the control plane, one artifact at a time. Both are kept just
    /// under the matching `.restore` operation budget so the RPC verdict still
    /// decides the operation.
    static let restoreTimeout: Duration = .seconds(570)
    static let transferTimeout: Duration = .seconds(3570)

    /// Preflight an agent for `sandbox_restore`: it must be known, online, and
    /// advertise a sandbox snapshot backend. The message type postdates
    /// protocol version 8, so an older agent can't even decode the envelope —
    /// the frame is dropped before any error response can be sent and the
    /// request would burn its full timeout.
    static func requireCapableAgent(_ agentId: String, app: Application) async throws {
        guard let agentInfo = await app.agentService.getAgentInfo(agentId) else {
            throw SandboxSnapshotServiceError.agentNotFound(agentId)
        }
        guard agentInfo.status == .online else {
            throw SandboxSnapshotServiceError.agentOffline(agentId)
        }
        guard agentInfo.capabilities.contains(SnapshotArtifactKind.sandboxSnapshot.agentCapability) else {
            throw SandboxSnapshotServiceError.operationUnsupportedByAgent(agentId)
        }
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
        try await requireCapableAgent(agentId, app: app)

        let message = SandboxRestoreMessage(
            sandboxId: sandboxId.uuidString, snapshotId: snapshotId.uuidString,
            artifacts: artifacts)
        app.logger.info(
            "Sending sandbox restore message to agent",
            metadata: [
                "agentId": .string(agentId),
                "messageType": .string(message.type.rawValue),
            ])

        // A local restore is a file copy; one carrying descriptors downloads
        // the whole archive first and needs the transfer budget.
        let timeout = artifacts == nil ? Self.restoreTimeout : Self.transferTimeout
        let response = try await app.agentService.sendMessageToAgentWithResponse(
            message, agentId: agentId, timeout: timeout)

        switch response {
        case .success:
            return
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

    var errorDescription: String? {
        switch self {
        case .agentNotFound(let id):
            return "Agent '\(id)' not found"
        case .agentOffline(let id):
            return "Agent '\(id)' is offline"
        case .operationUnsupportedByAgent(let id):
            return
                "Agent '\(id)' does not support sandbox snapshots (capability '\(SnapshotArtifactKind.sandboxSnapshot.agentCapability)' not advertised). Upgrade the agent."
        case .agentOperationFailed(let error, let details):
            if let details, !details.isEmpty {
                return "\(error): \(details)"
            }
            return error
        }
    }
}
