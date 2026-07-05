import Foundation
import Vapor
import Fluent
import StratoShared

/// Service for managing volume operations across agents
/// Coordinates between the database, SpiceDB, and AgentService
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
        do {
            guard let volume = try await Volume.find(volumeId, on: app.db) else {
                logger.warning(
                    "Volume deleted before provisioning started",
                    metadata: [
                        "volumeId": .string(volumeId.uuidString)
                    ])
                return
            }

            let result = try await requestVolumeCreation(volume: volume, sourceImage: sourceImage)

            volume.hypervisorId = result.agentId
            volume.storagePath = result.storagePath
            volume.status = .available
            volume.errorMessage = nil
            try await volume.save(on: app.db)

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
        guard let source = try? await Volume.find(sourceVolumeId, on: app.db),
            let target = try? await Volume.find(targetVolumeId, on: app.db)
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
            target.hypervisorId = source.hypervisorId
            target.storagePath = storagePath
            target.status = .available
            target.errorMessage = nil
            try await target.save(on: app.db)

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
        source.status = restoreSourceStatusTo
        do {
            try await source.save(on: app.db)
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
        do {
            guard let volume = try await Volume.find(volumeId, on: app.db) else { return }
            volume.status = .error
            volume.errorMessage = error.localizedDescription
            try await volume.save(on: app.db)
        } catch {
            logger.error(
                "Failed to record volume error state",
                metadata: [
                    "volumeId": .string(volumeId.uuidString),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    // MARK: - Volume Creation

    /// Request an agent to create a volume and await its confirmation.
    /// Returns the agent that holds the volume and the storage path it reported.
    func requestVolumeCreation(
        volume: Volume,
        sourceImage: Image? = nil
    ) async throws -> (agentId: String, storagePath: String?) {
        // For now, select an agent using the scheduler
        // In the future, we might want to consider storage locality
        let agentService = app.agentService

        // Get list of online agents
        let agents = await agentService.getAgentList()

        guard let selectedAgent = agents.first(where: { $0.status == .online }) else {
            throw VolumeServiceError.noAgentsAvailable
        }

        // The download URL must be signed for the selected agent, so the
        // ImageInfo can only be built after agent selection.
        var sourceImageInfo: ImageInfo?
        if let image = sourceImage {
            let controlPlaneURL = Environment.get("CONTROL_PLANE_URL") ?? "http://localhost:8080"
            let signingKey = try URLSigningService.getSigningKey(from: app)
            sourceImageInfo = try VMSpecBuilder.buildImageInfo(
                from: image,
                controlPlaneURL: controlPlaneURL,
                agentName: selectedAgent.id,
                signingKey: signingKey
            )
        }

        let message = VolumeCreateMessage(
            volumeId: volume.id!.uuidString,
            size: volume.size,
            format: volume.format.rawValue,
            sourceImageInfo: sourceImageInfo
        )

        let timeout = sourceImageInfo != nil ? Self.transferTimeout : Self.createTimeout
        let status = try await sendVolumeRequest(message, toAgent: selectedAgent.id, timeout: timeout)

        logger.info(
            "Agent confirmed volume creation",
            metadata: [
                "volumeId": .string(volume.id!.uuidString),
                "agentId": .string(selectedAgent.id),
                "hasSourceImage": .stringConvertible(sourceImageInfo != nil),
            ])

        return (selectedAgent.id, status?.storagePath)
    }

    /// Request an agent to delete a volume and await its confirmation.
    func requestVolumeDeletion(volume: Volume) async throws {
        guard let hypervisorId = volume.hypervisorId else {
            // Volume was never created on an agent, just delete from DB
            logger.info(
                "Volume has no hypervisor, skipping agent deletion",
                metadata: [
                    "volumeId": .string(volume.id!.uuidString)
                ])
            return
        }

        guard let volumePath = volume.storagePath else {
            logger.info(
                "Volume has no storage path, skipping agent deletion",
                metadata: [
                    "volumeId": .string(volume.id!.uuidString)
                ])
            return
        }

        let message = VolumeDeleteMessage(
            volumeId: volume.id!.uuidString,
            volumePath: volumePath
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

        guard let volumePath = volume.storagePath else {
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
        guard let hypervisorId = volume.hypervisorId else {
            throw VolumeServiceError.volumeNotOnAgent
        }

        guard let volumePath = volume.storagePath else {
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
        guard let hypervisorId = volume.hypervisorId else {
            throw VolumeServiceError.volumeNotOnAgent
        }

        guard let volumePath = volume.storagePath else {
            throw VolumeServiceError.volumeNotOnAgent
        }

        // Build snapshot path based on volume path
        let snapshotPath =
            snapshot.buildStoragePath(
                basePath: volumePath.components(separatedBy: "/").dropLast().joined(separator: "/"),
                volumeId: volume.id!) ?? "\(volumePath).snap.\(snapshot.id!.uuidString)"

        let message = VolumeSnapshotMessage(
            volumeId: volume.id!.uuidString,
            snapshotId: snapshot.id!.uuidString,
            volumePath: volumePath,
            snapshotPath: snapshotPath
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

    /// Request an agent to clone a volume and await its confirmation.
    /// Returns the target volume's storage path as reported by the agent.
    func requestVolumeClone(
        sourceVolume: Volume,
        targetVolume: Volume
    ) async throws -> String? {
        guard let hypervisorId = sourceVolume.hypervisorId else {
            throw VolumeServiceError.volumeNotOnAgent
        }

        guard let sourceVolumePath = sourceVolume.storagePath else {
            throw VolumeServiceError.volumeNotOnAgent
        }

        // Build target volume path based on volume storage convention
        let targetVolumePath =
            targetVolume.buildStoragePath(
                basePath: sourceVolumePath.components(separatedBy: "/").dropLast(2).joined(separator: "/"))
            ?? "\(sourceVolumePath).clone.\(targetVolume.id!.uuidString)"

        let message = VolumeCloneMessage(
            sourceVolumeId: sourceVolume.id!.uuidString,
            sourceVolumePath: sourceVolumePath,
            targetVolumeId: targetVolume.id!.uuidString,
            targetVolumePath: targetVolumePath
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

    // MARK: - Message Handling

    /// Handle a volume info response from an agent
    /// This is used to update volume status after operations complete
    func handleVolumeInfoResponse(_ response: VolumeInfoResponse) async {
        guard let volumeId = UUID(uuidString: response.volumeId) else {
            logger.warning(
                "Invalid volume ID in info response",
                metadata: [
                    "volumeId": .string(response.volumeId)
                ])
            return
        }

        do {
            guard let volume = try await Volume.find(volumeId, on: app.db) else {
                logger.warning(
                    "Volume not found for info response",
                    metadata: [
                        "volumeId": .string(response.volumeId)
                    ])
                return
            }

            // Update volume size info from agent
            // The virtualSize is the provisioned size, actualSize is the real disk usage
            logger.info(
                "Received volume info from agent",
                metadata: [
                    "volumeId": .string(response.volumeId),
                    "virtualSize": .stringConvertible(response.virtualSize),
                    "actualSize": .stringConvertible(response.actualSize),
                    "format": .string(response.format),
                ])

            // Volume info doesn't change the status - that's handled by operation-specific callbacks
            try await volume.save(on: app.db)
        } catch {
            logger.error(
                "Failed to process volume info response",
                metadata: [
                    "volumeId": .string(response.volumeId),
                    "error": .string(error.localizedDescription),
                ])
        }
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
