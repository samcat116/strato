import Foundation
import Vapor
import Fluent
import StratoShared

/// Service for managing volume operations across agents
/// Coordinates between the database, SpiceDB, and AgentService
actor VolumeService {
    private let app: Application
    private let logger: Logger

    init(app: Application) {
        self.app = app
        self.logger = app.logger
    }

    // MARK: - Volume Creation

    /// Request an agent to create a volume
    /// Returns the agent ID that will handle the volume
    func requestVolumeCreation(
        volume: Volume,
        sourceImageInfo: ImageInfo? = nil
    ) async throws -> String {
        // For now, select an agent using the scheduler
        // In the future, we might want to consider storage locality
        let agentService = app.agentService

        // Get list of online agents
        let agents = await agentService.getAgentList()
        let onlineAgents = agents.filter { $0.status == .online }

        guard !onlineAgents.isEmpty else {
            throw VolumeServiceError.noAgentsAvailable
        }

        // Select the first available agent (could use scheduler for smarter selection)
        guard let selectedAgent = onlineAgents.first else {
            throw VolumeServiceError.noAgentsAvailable
        }

        // Create the message with proper format
        let message = VolumeCreateMessage(
            volumeId: volume.id!.uuidString,
            size: volume.size,
            format: volume.format.rawValue,
            sourceImageInfo: sourceImageInfo
        )

        // Send message to agent
        try await sendVolumeMessage(message, toAgent: selectedAgent.id)

        logger.info("Requested volume creation on agent", metadata: [
            "volumeId": .string(volume.id!.uuidString),
            "agentId": .string(selectedAgent.id),
            "hasSourceImage": .stringConvertible(sourceImageInfo != nil)
        ])

        return selectedAgent.id
    }

    /// Request an agent to delete a volume
    func requestVolumeDeletion(volume: Volume) async throws {
        guard let hypervisorId = volume.hypervisorId else {
            // Volume was never created on an agent, just delete from DB
            logger.info("Volume has no hypervisor, skipping agent deletion", metadata: [
                "volumeId": .string(volume.id!.uuidString)
            ])
            return
        }

        guard let volumePath = volume.storagePath else {
            logger.info("Volume has no storage path, skipping agent deletion", metadata: [
                "volumeId": .string(volume.id!.uuidString)
            ])
            return
        }

        let message = VolumeDeleteMessage(
            volumeId: volume.id!.uuidString,
            volumePath: volumePath
        )

        try await sendVolumeMessage(message, toAgent: hypervisorId)

        logger.info("Requested volume deletion on agent", metadata: [
            "volumeId": .string(volume.id!.uuidString),
            "agentId": .string(hypervisorId)
        ])
    }

    // MARK: - Volume Attachment

    /// Request an agent to attach a volume to a VM
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

        try await sendVolumeMessage(message, toAgent: hypervisorId)

        logger.info("Requested volume attachment on agent", metadata: [
            "volumeId": .string(volume.id!.uuidString),
            "vmId": .string(vm.id!.uuidString),
            "deviceName": .string(deviceName),
            "agentId": .string(hypervisorId)
        ])
    }

    /// Request an agent to detach a volume from a VM
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

        try await sendVolumeMessage(message, toAgent: hypervisorId)

        logger.info("Requested volume detachment on agent", metadata: [
            "volumeId": .string(volume.id!.uuidString),
            "vmId": .string(vm.id!.uuidString),
            "deviceName": .string(deviceName),
            "agentId": .string(hypervisorId)
        ])
    }

    // MARK: - Volume Operations

    /// Request an agent to resize a volume
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

        try await sendVolumeMessage(message, toAgent: hypervisorId)

        logger.info("Requested volume resize on agent", metadata: [
            "volumeId": .string(volume.id!.uuidString),
            "newSizeBytes": .stringConvertible(newSizeBytes),
            "agentId": .string(hypervisorId)
        ])
    }

    /// Request an agent to create a snapshot of a volume
    func requestVolumeSnapshot(
        volume: Volume,
        snapshot: VolumeSnapshot
    ) async throws {
        guard let hypervisorId = volume.hypervisorId else {
            throw VolumeServiceError.volumeNotOnAgent
        }

        guard let volumePath = volume.storagePath else {
            throw VolumeServiceError.volumeNotOnAgent
        }

        // Build snapshot path based on volume path
        let snapshotPath = snapshot.buildStoragePath(basePath: volumePath.components(separatedBy: "/").dropLast().joined(separator: "/"), volumeId: volume.id!) ?? "\(volumePath).snap.\(snapshot.id!.uuidString)"

        let message = VolumeSnapshotMessage(
            volumeId: volume.id!.uuidString,
            snapshotId: snapshot.id!.uuidString,
            volumePath: volumePath,
            snapshotPath: snapshotPath
        )

        try await sendVolumeMessage(message, toAgent: hypervisorId)

        logger.info("Requested volume snapshot on agent", metadata: [
            "volumeId": .string(volume.id!.uuidString),
            "snapshotId": .string(snapshot.id!.uuidString),
            "agentId": .string(hypervisorId)
        ])
    }

    /// Request an agent to clone a volume
    func requestVolumeClone(
        sourceVolume: Volume,
        targetVolume: Volume
    ) async throws -> String {
        guard let hypervisorId = sourceVolume.hypervisorId else {
            throw VolumeServiceError.volumeNotOnAgent
        }

        guard let sourceVolumePath = sourceVolume.storagePath else {
            throw VolumeServiceError.volumeNotOnAgent
        }

        // Build target volume path based on volume storage convention
        let targetVolumePath = targetVolume.buildStoragePath(basePath: sourceVolumePath.components(separatedBy: "/").dropLast(2).joined(separator: "/")) ?? "\(sourceVolumePath).clone.\(targetVolume.id!.uuidString)"

        let message = VolumeCloneMessage(
            sourceVolumeId: sourceVolume.id!.uuidString,
            sourceVolumePath: sourceVolumePath,
            targetVolumeId: targetVolume.id!.uuidString,
            targetVolumePath: targetVolumePath
        )

        try await sendVolumeMessage(message, toAgent: hypervisorId)

        logger.info("Requested volume clone on agent", metadata: [
            "sourceVolumeId": .string(sourceVolume.id!.uuidString),
            "targetVolumeId": .string(targetVolume.id!.uuidString),
            "agentId": .string(hypervisorId)
        ])

        return hypervisorId
    }

    // MARK: - Message Handling

    /// Handle a volume info response from an agent
    /// This is used to update volume status after operations complete
    func handleVolumeInfoResponse(_ response: VolumeInfoResponse) async {
        guard let volumeId = UUID(uuidString: response.volumeId) else {
            logger.warning("Invalid volume ID in info response", metadata: [
                "volumeId": .string(response.volumeId)
            ])
            return
        }

        do {
            guard let volume = try await Volume.find(volumeId, on: app.db) else {
                logger.warning("Volume not found for info response", metadata: [
                    "volumeId": .string(response.volumeId)
                ])
                return
            }

            // Update volume size info from agent
            // The virtualSize is the provisioned size, actualSize is the real disk usage
            logger.info("Received volume info from agent", metadata: [
                "volumeId": .string(response.volumeId),
                "virtualSize": .stringConvertible(response.virtualSize),
                "actualSize": .stringConvertible(response.actualSize),
                "format": .string(response.format)
            ])

            // Volume info doesn't change the status - that's handled by operation-specific callbacks
            try await volume.save(on: app.db)
        } catch {
            logger.error("Failed to process volume info response", metadata: [
                "volumeId": .string(response.volumeId),
                "error": .string(error.localizedDescription)
            ])
        }
    }

    // MARK: - Private Helpers

    private func sendVolumeMessage<T: WebSocketMessage>(_ message: T, toAgent agentId: String) async throws {
        let agentService = app.agentService

        logger.info("Sending volume message to agent", metadata: [
            "agentId": .string(agentId),
            "messageType": .string(message.type.rawValue)
        ])

        // Get agent info
        guard let agentInfo = await agentService.getAgentInfo(agentId) else {
            logger.error("Agent not found for volume message", metadata: ["agentId": .string(agentId)])
            throw VolumeServiceError.agentNotFound(agentId)
        }

        logger.info("Found agent info", metadata: [
            "agentId": .string(agentId),
            "agentName": .string(agentInfo.name),
            "agentStatus": .string(agentInfo.status.rawValue)
        ])

        guard agentInfo.status == .online else {
            logger.error("Agent is offline", metadata: ["agentId": .string(agentId)])
            throw VolumeServiceError.agentOffline(agentId)
        }

        // Use the MessageEnvelope to properly encode the message
        let envelope = try MessageEnvelope(message: message)
        let encoder = JSONEncoder()
        let data = try encoder.encode(envelope)
        let json = String(data: data, encoding: .utf8) ?? ""

        logger.info("Encoded message", metadata: [
            "agentId": .string(agentId),
            "jsonPreview": .string(String(json.prefix(200)))
        ])

        // Get the WebSocket connection and send using the Application's websocketManager
        let wsManager = app.websocketManager
        guard let ws = wsManager.getConnection(agentName: agentInfo.name) else {
            logger.error("No WebSocket connection to agent", metadata: [
                "agentId": .string(agentId),
                "agentName": .string(agentInfo.name)
            ])
            throw VolumeServiceError.noConnectionToAgent(agentId)
        }

        logger.info("Sending message via WebSocket", metadata: [
            "agentId": .string(agentId),
            "agentName": .string(agentInfo.name)
        ])

        try await ws.send(json)

        logger.info("Message sent successfully", metadata: [
            "agentId": .string(agentId),
            "messageType": .string(message.type.rawValue)
        ])
    }
}

// MARK: - Errors

enum VolumeServiceError: Error, LocalizedError {
    case noAgentsAvailable
    case agentNotFound(String)
    case agentOffline(String)
    case noConnectionToAgent(String)
    case vmNotScheduled
    case volumeNotOnAgent
    case volumeNotAttached
    case firecrackerNotSupported

    var errorDescription: String? {
        switch self {
        case .noAgentsAvailable:
            return "No agents available to handle volume operation"
        case .agentNotFound(let id):
            return "Agent '\(id)' not found"
        case .agentOffline(let id):
            return "Agent '\(id)' is offline"
        case .noConnectionToAgent(let id):
            return "No WebSocket connection to agent '\(id)'"
        case .vmNotScheduled:
            return "VM is not scheduled on any hypervisor"
        case .volumeNotOnAgent:
            return "Volume is not stored on any agent"
        case .volumeNotAttached:
            return "Volume is not attached to any VM"
        case .firecrackerNotSupported:
            return "Volume operations are not supported for Firecracker VMs"
        }
    }
}

// MARK: - Application Extension

extension Application {
    private struct VolumeServiceKey: StorageKey {
        typealias Value = VolumeService
    }

    var volumeService: VolumeService {
        get {
            if let existing = storage[VolumeServiceKey.self] {
                return existing
            }
            let service = VolumeService(app: self)
            storage[VolumeServiceKey.self] = service
            return service
        }
        set {
            storage[VolumeServiceKey.self] = newValue
        }
    }
}
