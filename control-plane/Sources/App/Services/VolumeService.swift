import Foundation
import Vapor
import Fluent
import StratoShared

/// What is left of the volume agent path after ADR 0001 stage 5 (STR-148).
///
/// Volume creation, deletion, attachment, detachment, resize and cloning are
/// desired state now: the control plane writes the intent, the assembler puts
/// it on the agent's sync, and the agent's observed report closes the loop.
/// None of that goes through this type.
///
/// What remains is placement — choosing which agent hosts a new volume, a
/// decision that must be a committed fact before any sync can carry the volume
/// — and the await-response dispatch for the two verbs that have not converted
/// yet: `volume_snapshot` and `volume_snapshot_delete` (ADR stage 8), plus the
/// `volume_info` read (stage 7).
actor VolumeService {
    private let app: Application
    private let logger: Logger

    /// Fast, metadata-level operations (snapshot deletion).
    private static let defaultTimeout: Duration = .seconds(30)
    /// Operations that copy volume data (snapshot of a large volume).
    private static let snapshotTimeout: Duration = .seconds(120)

    init(app: Application) {
        self.app = app
        self.logger = app.logger
    }

    // MARK: - Placement

    /// The agent and path holding a volume's data. Local pools have a single
    /// replica, so "the volume's placement" is well-defined; rows without a
    /// replica (mid-provisioning races, pre-backfill data) fall back to the
    /// legacy hypervisor_id/storage_path columns, which are dual-written.
    private func placement(of volume: Volume) async throws -> (agentId: String, path: String?)? {
        guard let db = app.liveDB else { return nil }
        if let replica = try await VolumeReplica.query(on: db)
            .filter(\.$volume.$id == volume.id!)
            .sort(\.$createdAt)
            .first()
        {
            return (replica.agentId, replica.datasetPath ?? volume.storagePath)
        }
        guard let agentId = volume.hypervisorId else { return nil }
        return (agentId, volume.storagePath)
    }

    /// Pick the agent that should host a new volume's replica. Volume
    /// attachment goes through QEMU's block layer and requires the volume to
    /// live on an agent the VM can run on, so only online agents that can run
    /// QEMU are eligible — a volume placed on a Firecracker-only agent could
    /// never be attached. A pool with an explicit member list further
    /// restricts candidates to those members; an empty list (the default
    /// local pool) leaves all agents eligible.
    ///
    /// The wire-version filter is new with STR-148 and is the one placement
    /// gate in this file that refuses rather than degrades: with the imperative
    /// volume frames gone, an agent below v31 has no way to hear about a volume
    /// at all, so placing one there would produce a resource that could never
    /// converge and could only be deleted by force-clearing its finalizer.
    static func selectVolumeAgent(from agents: [Agent], memberAgentIds: [String] = []) -> Agent? {
        agents.first {
            $0.status == .online && $0.supportedHypervisors.contains(.qemu)
                && WireProtocol.supportsVolumeSync($0.wireProtocolVersion ?? 0)
                && (memberAgentIds.isEmpty || memberAgentIds.contains($0.id?.uuidString ?? ""))
        }
    }

    /// Request an agent to create a snapshot of a volume and await its
    /// confirmation. Returns the snapshot's storage path as reported by the
    /// agent (the agent decides the actual on-disk location).
    func requestVolumeSnapshot(
        volume: Volume,
        snapshot: VolumeSnapshot
    ) async throws -> String? {
        guard let (hypervisorId, path) = try await placement(of: volume), let volumePath = path else {
            throw VolumeServiceError.volumeNotOnAgent
        }

        // Still name the attached VM, even though `canSnapshot` now admits
        // only detached volumes (issue #747): if the control plane's own
        // bookkeeping ever drifts — status `.available` with `$vm` still set —
        // the agent uses this to refuse rather than write a snapshot that
        // isn't point-in-time.
        let message = VolumeSnapshotMessage(
            volumeId: volume.id!.uuidString,
            snapshotId: snapshot.id!.uuidString,
            volumePath: volumePath,
            attachedVMId: volume.$vm.id?.uuidString
        )

        let status = try await sendVolumeRequest(message, toAgent: hypervisorId, timeout: Self.snapshotTimeout)

        logger.info(
            "Agent confirmed volume snapshot",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "snapshotId": .string(snapshot.id!.uuidString),
                "agentId": .string(hypervisorId),
            ])

        return status?.storagePath
    }

    /// Request an agent to delete a volume snapshot from storage and await
    /// its confirmation. The message carries only IDs — the agent derives the
    /// file's location the same way it did at creation — so this also cleans
    /// up snapshots whose create succeeded on the agent but whose response
    /// was lost (status `.error`, no recorded storage path). Only volumes
    /// that were never provisioned on any hypervisor skip the agent
    /// round-trip; agent-side deletion is idempotent, so a snapshot with no
    /// backing file confirms cleanly.
    func requestVolumeSnapshotDeletion(
        volume: Volume,
        snapshot: VolumeSnapshot
    ) async throws {
        guard let hypervisorId = try await placement(of: volume)?.agentId else {
            logger.info(
                "Volume has no replica on any agent, skipping agent snapshot deletion",
                metadata: [
                    "volumeId": .string(volume.id!.uuidString),
                    "snapshotId": .string(snapshot.id!.uuidString),
                ])
            return
        }

        // `volume_snapshot_delete` postdates protocol version 1, so an older
        // agent can't decode it — the frame is dropped before the agent can
        // even reply with an error, and the request would burn its full
        // timeout. Agents that understand the message advertise it as a
        // capability at registration; fail fast on ones that don't.
        if let agentInfo = await app.agentService.getAgentInfo(hypervisorId),
            !agentInfo.capabilities.contains(MessageType.volumeSnapshotDelete.rawValue)
        {
            throw VolumeServiceError.operationUnsupportedByAgent(
                MessageType.volumeSnapshotDelete.rawValue, hypervisorId
            )
        }

        let message = VolumeSnapshotDeleteMessage(
            volumeId: volume.id!.uuidString,
            snapshotId: snapshot.id!.uuidString
        )

        _ = try await sendVolumeRequest(message, toAgent: hypervisorId)

        logger.info(
            "Agent confirmed snapshot deletion",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "snapshotId": .string(snapshot.id!.uuidString),
                "agentId": .string(hypervisorId),
            ])
    }

    // MARK: - Private Helpers

    /// Send a volume message to an agent and await the correlated
    /// success/error response. Returns the agent's `VolumeStatusResponse`
    /// when the success payload carries one.
    private func sendVolumeRequest<T: WebSocketMessage>(
        _ message: T,
        toAgent agentId: String,
        timeout: Duration = VolumeService.defaultTimeout
    ) async throws -> VolumeStatusResponse? {
        let agentService = app.agentService

        guard let agentInfo = await agentService.getAgentInfo(agentId) else {
            logger.error("Agent not found for volume message", metadata: ["agentId": .string(agentId)])
            throw VolumeServiceError.agentNotFound(agentId)
        }

        guard agentInfo.status == .online else {
            logger.error("Agent is offline", metadata: ["agentId": .string(agentId)])
            throw VolumeServiceError.agentOffline(agentId)
        }

        logger.info(
            "Sending volume message to agent",
            metadata: [
                "agentId": .string(agentId),
                "agentName": .string(agentInfo.name),
                "messageType": .string(message.type.rawValue),
            ])

        let response = try await agentService.sendMessageToAgentWithResponse(
            message, agentId: agentId, timeout: timeout)

        switch response {
        case .success(let data):
            return try? data?.decode(as: VolumeStatusResponse.self)
        case .error(let error, let details):
            throw VolumeServiceError.agentOperationFailed(error, details)
        }
    }
}

// MARK: - Errors

enum VolumeServiceError: Error, LocalizedError {
    case noAgentsAvailable
    case agentNotFound(String)
    case agentOffline(String)
    case vmNotScheduled
    case volumeNotOnAgent
    case volumeNotAttached
    case firecrackerNotSupported
    case agentOperationFailed(String, String?)
    case operationUnsupportedByAgent(String, String)

    var errorDescription: String? {
        switch self {
        case .noAgentsAvailable:
            return "No agents available to handle volume operation"
        case .agentNotFound(let id):
            return "Agent '\(id)' not found"
        case .agentOffline(let id):
            return "Agent '\(id)' is offline"
        case .vmNotScheduled:
            return "VM is not scheduled on any hypervisor"
        case .volumeNotOnAgent:
            return "Volume is not stored on any agent"
        case .volumeNotAttached:
            return "Volume is not attached to any VM"
        case .firecrackerNotSupported:
            return "Volume operations are not supported for Firecracker VMs"
        case .agentOperationFailed(let error, let details):
            if let details {
                return "\(error) (\(details))"
            }
            return error
        case .operationUnsupportedByAgent(let operation, let agentId):
            return "Agent '\(agentId)' does not support '\(operation)'; upgrade the agent and retry"
        }
    }
}

// MARK: - Application Extension

extension Application {
    private struct VolumeServiceKey: StorageKey, LockKey {
        typealias Value = VolumeService
    }

    var volumeService: VolumeService {
        get {
            lazyService(VolumeServiceKey.self) { VolumeService(app: self) }
        }
        set {
            setStorageValue(VolumeServiceKey.self, to: newValue)
        }
    }
}
