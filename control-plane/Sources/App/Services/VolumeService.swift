import Foundation
import Vapor
import Fluent
import StratoShared

/// Service for managing volume operations across agents
/// Coordinates between the database and AgentService
actor VolumeService {
    private let app: Application
    private let logger: Logger

    /// Fast, metadata-level operations (delete, resize, attach, detach).
    private static let defaultTimeout: Duration = .seconds(30)
    /// Operations that copy volume data (snapshot of a large volume).
    private static let snapshotTimeout: Duration = .seconds(120)
    /// Operations that copy or download gigabytes (blank create, clone,
    /// image-backed create).
    private static let createTimeout: Duration = .seconds(60)
    private static let transferTimeout: Duration = .seconds(600)

    init(app: Application) {
        self.app = app
        self.logger = app.logger
    }

    // MARK: - Volume Provisioning

    /// Provision a volume on an agent and reconcile database state from the
    /// agent's response. Intended to run detached from the create request:
    /// the client sees the volume in `.creating` until the agent confirms,
    /// after which the volume becomes `.available` (with its real storage
    /// path and hypervisor) or `.error`.
    func provisionVolume(volumeId: UUID, sourceImage: Image?) async {
        // Registered with the drain registry: shutdown cancels this before
        // Fluent tears down. Capture the database up front and bail if we were
        // already cancelled (see `Application.liveDB`); a cancellation
        // mid-flight then surfaces as a thrown error on the captured handle
        // rather than a fatal `app.db` unwrap.
        guard let db = app.liveDB else { return }
        do {
            guard let volume = try await Volume.find(volumeId, on: db) else {
                logger.warning(
                    "Volume deleted before provisioning started",
                    metadata: [
                        "volumeId": .string(volumeId.uuidString)
                    ])
                return
            }

            let pool = try await volume.$pool.get(on: db)
            let result = try await requestVolumeCreation(
                volume: volume,
                sourceImage: sourceImage,
                memberAgentIds: pool?.memberAgentIds ?? []
            )

            // The agent RPC above can span the drain; bail cleanly before the
            // write-back rather than issue doomed queries during shutdown.
            guard !Task.isCancelled else { return }
            try await recordReplica(volumeId: volumeId, agentId: result.agentId, datasetPath: result.storagePath)

            volume.hypervisorId = result.agentId
            volume.storagePath = result.storagePath
            volume.status = .available
            volume.errorMessage = nil
            try await volume.save(on: db)

            logger.info(
                "Volume provisioned on agent",
                metadata: [
                    "volumeId": .string(volumeId.uuidString),
                    "agentId": .string(result.agentId),
                    "storagePath": .string(result.storagePath ?? ""),
                ])
        } catch {
            await markVolumeFailed(volumeId: volumeId, error: error)
        }
    }

    /// Clone a volume on its agent and reconcile both records from the
    /// agent's response. The source volume returns to `restoreSourceStatusTo`
    /// whether the clone succeeds or fails; the target becomes `.available`
    /// or `.error`.
    func performClone(sourceVolumeId: UUID, targetVolumeId: UUID, restoreSourceStatusTo: VolumeStatus) async {
        // Registered with the drain registry: bail if shutdown already
        // cancelled us, and reuse the captured handle (see `Application.liveDB`).
        guard let db = app.liveDB else { return }
        guard let source = try? await Volume.find(sourceVolumeId, on: db),
            let target = try? await Volume.find(targetVolumeId, on: db)
        else {
            logger.warning(
                "Volume disappeared before clone started",
                metadata: [
                    "sourceVolumeId": .string(sourceVolumeId.uuidString),
                    "targetVolumeId": .string(targetVolumeId.uuidString),
                ])
            return
        }

        do {
            let storagePath = try await requestVolumeClone(sourceVolume: source, targetVolume: target)
            // The agent RPC above can span the drain; bail cleanly before the
            // write-back rather than issue doomed queries during shutdown.
            guard !Task.isCancelled else { return }
            let sourcePlacement = try await placement(of: source)
            if let agentId = sourcePlacement?.agentId {
                try await recordReplica(volumeId: targetVolumeId, agentId: agentId, datasetPath: storagePath)
            }
            target.hypervisorId = sourcePlacement?.agentId ?? source.hypervisorId
            target.storagePath = storagePath
            target.status = .available
            target.errorMessage = nil
            try await target.save(on: db)

            logger.info(
                "Volume cloned on agent",
                metadata: [
                    "sourceVolumeId": .string(sourceVolumeId.uuidString),
                    "targetVolumeId": .string(targetVolumeId.uuidString),
                ])
        } catch {
            await markVolumeFailed(volumeId: targetVolumeId, error: error)
        }

        // Whether the clone succeeded or failed, the source is no longer busy.
        guard !Task.isCancelled else { return }
        source.status = restoreSourceStatusTo
        do {
            try await source.save(on: db)
        } catch {
            logger.error(
                "Failed to restore source volume status after clone",
                metadata: [
                    "sourceVolumeId": .string(sourceVolumeId.uuidString),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    private func markVolumeFailed(volumeId: UUID, error: Error) async {
        logger.error(
            "Volume operation failed",
            metadata: [
                "volumeId": .string(volumeId.uuidString),
                "error": .string(error.localizedDescription),
            ])
        // Skip the status write-back if shutdown cancelled us; the database may
        // already be torn down (see `Application.liveDB`).
        guard let db = app.liveDB else { return }
        do {
            guard let volume = try await Volume.find(volumeId, on: db) else { return }
            volume.status = .error
            volume.errorMessage = error.localizedDescription
            try await volume.save(on: db)
        } catch {
            logger.error(
                "Failed to record volume error state",
                metadata: [
                    "volumeId": .string(volumeId.uuidString),
                    "error": .string(error.localizedDescription),
                ])
        }
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

    /// Record the physical copy an agent just confirmed it holds. Idempotent:
    /// a replica already recorded for that agent is updated in place.
    private func recordReplica(volumeId: UUID, agentId: String, datasetPath: String?) async throws {
        guard let db = app.liveDB else { return }
        if let existing = try await VolumeReplica.query(on: db)
            .filter(\.$volume.$id == volumeId)
            .filter(\.$agentId == agentId)
            .first()
        {
            existing.datasetPath = datasetPath
            existing.state = .healthy
            try await existing.save(on: db)
            return
        }
        try await VolumeReplica(
            volumeID: volumeId,
            agentId: agentId,
            datasetPath: datasetPath,
            state: .healthy
        ).create(on: db)
    }

    // MARK: - Volume Creation

    /// Request an agent to create a volume and await its confirmation.
    /// Returns the agent that holds the volume and the storage path it reported.
    func requestVolumeCreation(
        volume: Volume,
        sourceImage: Image? = nil,
        memberAgentIds: [String] = []
    ) async throws -> (agentId: String, storagePath: String?) {
        // In the future, we might want to consider storage locality
        let agentService = app.agentService

        let agents = await agentService.getAgentList()

        guard let selectedAgent = Self.selectVolumeAgent(from: agents, memberAgentIds: memberAgentIds),
            let selectedAgentId = selectedAgent.id?.uuidString
        else {
            throw VolumeServiceError.noAgentsAvailable
        }

        var sourceImageInfo: ImageInfo?
        if let image = sourceImage {
            // The artifact set drives which download URLs are emitted; load it
            // (no-op if already eager-loaded) so buildImageInfo doesn't fall back
            // to the legacy single-file branch and drop the typed artifacts.
            // Bail if shutdown's drain cancelled us first (see `Application.liveDB`).
            guard let db = app.liveDB else { throw CancellationError() }
            try await image.$artifacts.load(on: db)
            sourceImageInfo = try VMSpecBuilder.buildImageInfo(from: image)
        }

        let message = VolumeCreateMessage(
            volumeId: volume.id!.uuidString,
            size: volume.size,
            format: volume.format.rawValue,
            sourceImageInfo: sourceImageInfo
        )

        let timeout = sourceImageInfo != nil ? Self.transferTimeout : Self.createTimeout
        let status = try await sendVolumeRequest(message, toAgent: selectedAgentId, timeout: timeout)

        logger.info(
            "Agent confirmed volume creation",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "agentId": .string(selectedAgentId),
                "hasSourceImage": .stringConvertible(sourceImageInfo != nil),
            ])

        return (selectedAgentId, status?.storagePath)
    }

    /// Pick the agent that should host a new volume's replica. Volume
    /// attachment goes through QEMU's block layer and requires the volume to
    /// live on an agent the VM can run on, so only online agents that can run
    /// QEMU are eligible — a volume placed on a Firecracker-only agent could
    /// never be attached. A pool with an explicit member list further
    /// restricts candidates to those members; an empty list (the default
    /// local pool) leaves all agents eligible.
    static func selectVolumeAgent(from agents: [Agent], memberAgentIds: [String] = []) -> Agent? {
        agents.first {
            $0.status == .online && $0.supportedHypervisors.contains(.qemu)
                && (memberAgentIds.isEmpty || memberAgentIds.contains($0.id?.uuidString ?? ""))
        }
    }

    /// Request an agent to delete a volume and await its confirmation.
    /// The message carries only the volume ID — the agent owns path layout
    /// and derives the volume's location itself — so this also cleans up
    /// volumes whose create succeeded on the agent but whose response was
    /// lost (no recorded storage path). Agent-side deletion is idempotent.
    func requestVolumeDeletion(volume: Volume) async throws {
        guard let hypervisorId = try await placement(of: volume)?.agentId else {
            // Volume was never created on an agent, just delete from DB
            logger.info(
                "Volume has no replica on any agent, skipping agent deletion",
                metadata: [
                    "volumeId": .string(volume.id!.uuidString)
                ])
            return
        }

        let message = VolumeDeleteMessage(
            volumeId: volume.id!.uuidString
        )

        _ = try await sendVolumeRequest(message, toAgent: hypervisorId)

        logger.info(
            "Agent confirmed volume deletion",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "agentId": .string(hypervisorId),
            ])
    }

    // MARK: - Volume Attachment

    /// Request an agent to attach a volume to a VM and await its confirmation.
    func requestVolumeAttachment(
        volume: Volume,
        vm: VM,
        deviceName: String,
        readonly: Bool = false
    ) async throws {
        guard let hypervisorId = vm.hypervisorId else {
            throw VolumeServiceError.vmNotScheduled
        }

        // Verify VM is QEMU (not Firecracker)
        guard vm.hypervisorType == .qemu else {
            throw VolumeServiceError.firecrackerNotSupported
        }

        guard let volumePath = try await placement(of: volume)?.path else {
            throw VolumeServiceError.volumeNotOnAgent
        }

        let message = VolumeAttachMessage(
            vmId: vm.id!.uuidString,
            volumeId: volume.id!.uuidString,
            volumePath: volumePath,
            deviceName: deviceName,
            readonly: readonly
        )

        _ = try await sendVolumeRequest(message, toAgent: hypervisorId)

        logger.info(
            "Agent confirmed volume attachment",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "vmId": .string(vm.id!.uuidString),
                "deviceName": .string(deviceName),
                "agentId": .string(hypervisorId),
            ])
    }

    /// Request an agent to detach a volume from a VM and await its confirmation.
    func requestVolumeDetachment(volume: Volume, vm: VM) async throws {
        guard let hypervisorId = vm.hypervisorId else {
            throw VolumeServiceError.vmNotScheduled
        }

        guard let deviceName = volume.deviceName else {
            throw VolumeServiceError.volumeNotAttached
        }

        let message = VolumeDetachMessage(
            vmId: vm.id!.uuidString,
            volumeId: volume.id!.uuidString,
            deviceName: deviceName
        )

        _ = try await sendVolumeRequest(message, toAgent: hypervisorId)

        logger.info(
            "Agent confirmed volume detachment",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "vmId": .string(vm.id!.uuidString),
                "deviceName": .string(deviceName),
                "agentId": .string(hypervisorId),
            ])
    }

    // MARK: - Volume Operations

    /// Request an agent to resize a volume and await its confirmation.
    func requestVolumeResize(volume: Volume, newSizeBytes: Int64) async throws {
        guard let (hypervisorId, path) = try await placement(of: volume), let volumePath = path else {
            throw VolumeServiceError.volumeNotOnAgent
        }

        let message = VolumeResizeMessage(
            volumeId: volume.id!.uuidString,
            volumePath: volumePath,
            newSize: newSizeBytes
        )

        _ = try await sendVolumeRequest(message, toAgent: hypervisorId)

        logger.info(
            "Agent confirmed volume resize",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "newSizeBytes": .stringConvertible(newSizeBytes),
                "agentId": .string(hypervisorId),
            ])
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

        // Name the attached VM so the agent can fs-freeze that guest around the
        // overlay for an application-consistent snapshot (issue #563). Nil when
        // the volume is detached — the agent then takes a crash-consistent one.
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

    /// Request an agent to clone a volume and await its confirmation.
    /// Returns the target volume's storage path as reported by the agent.
    func requestVolumeClone(
        sourceVolume: Volume,
        targetVolume: Volume
    ) async throws -> String? {
        guard let (hypervisorId, path) = try await placement(of: sourceVolume), let sourceVolumePath = path
        else {
            throw VolumeServiceError.volumeNotOnAgent
        }

        // The agent owns volume placement and reports the clone's path back.
        let message = VolumeCloneMessage(
            sourceVolumeId: sourceVolume.id!.uuidString,
            sourceVolumePath: sourceVolumePath,
            targetVolumeId: targetVolume.id!.uuidString
        )

        let status = try await sendVolumeRequest(message, toAgent: hypervisorId, timeout: Self.transferTimeout)

        logger.info(
            "Agent confirmed volume clone",
            metadata: [
                "sourceVolumeId": .string(sourceVolume.id!.uuidString),
                "targetVolumeId": .string(targetVolume.id!.uuidString),
                "agentId": .string(hypervisorId),
            ])

        return status?.storagePath
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
            storage[VolumeServiceKey.self] = newValue
        }
    }
}
