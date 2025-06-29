import Foundation
import Logging
import NIOCore
import NIOPosix
import StratoShared

actor Agent {
    private let agentID: String
    private let controlPlaneURL: String
    private let hypervisorSocket: String
    private let logger: Logger
    
    private var websocketClient: WebSocketClient?
    private var cloudHypervisorService: CloudHypervisorService?
    private var heartbeatTask: Task<Void, Error>?
    private var isRunning = false
    
    init(
        agentID: String,
        controlPlaneURL: String,
        hypervisorSocket: String,
        logger: Logger
    ) {
        self.agentID = agentID
        self.controlPlaneURL = controlPlaneURL
        self.hypervisorSocket = hypervisorSocket
        self.logger = logger
    }
    
    func start() async throws {
        guard !isRunning else {
            logger.warning("Agent is already running")
            return
        }
        
        logger.info("Initializing cloud-hypervisor service")
        cloudHypervisorService = CloudHypervisorService(socketPath: hypervisorSocket, logger: logger)
        
        logger.info("Connecting to control plane", metadata: ["url": .string(controlPlaneURL)])
        websocketClient = WebSocketClient(url: controlPlaneURL, agent: self, logger: logger)
        
        try await websocketClient?.connect()
        
        // Register with control plane
        try await registerWithControlPlane()
        
        // Start heartbeat
        startHeartbeat()
        
        isRunning = true
        logger.info("Agent started successfully")
        
        // Keep the agent running
        try await Task.sleep(for: .seconds(Int.max))
    }
    
    func stop() async {
        logger.info("Stopping agent")
        isRunning = false
        
        heartbeatTask?.cancel()
        heartbeatTask = nil
        
        // Unregister from control plane
        do {
            try await unregisterFromControlPlane()
        } catch {
            logger.error("Failed to unregister from control plane: \(error)")
        }
        
        await websocketClient?.disconnect()
        websocketClient = nil
        cloudHypervisorService = nil
        
        logger.info("Agent stopped")
    }
    
    private func registerWithControlPlane() async throws {
        let resources = await getAgentResources()
        let message = AgentRegisterMessage(
            agentId: agentID,
            hostname: ProcessInfo.processInfo.hostName,
            version: "1.0.0",
            capabilities: ["vm_management", "cloud_hypervisor"],
            resources: resources
        )
        
        try await websocketClient?.sendMessage(message)
        logger.info("Registration message sent to control plane")
    }
    
    private func unregisterFromControlPlane() async throws {
        let message = AgentUnregisterMessage(
            agentId: agentID,
            reason: "Agent shutdown"
        )
        
        try await websocketClient?.sendMessage(message)
        logger.info("Unregistration message sent to control plane")
    }
    
    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await self?.sendHeartbeat()
                    try await Task.sleep(for: .seconds(30)) // Heartbeat every 30 seconds
                } catch {
                    self?.logger.error("Heartbeat failed: \(error)")
                    try await Task.sleep(for: .seconds(10)) // Retry after 10 seconds
                }
            }
        }
    }
    
    private func sendHeartbeat() async throws {
        let resources = await getAgentResources()
        let runningVMs = await getRunningVMList()
        
        let message = AgentHeartbeatMessage(
            agentId: agentID,
            resources: resources,
            runningVMs: runningVMs
        )
        
        try await websocketClient?.sendMessage(message)
        logger.debug("Heartbeat sent")
    }
    
    private func getAgentResources() async -> AgentResources {
        // TODO: Implement actual resource detection
        // For now, return mock values
        return AgentResources(
            totalCPU: 8,
            availableCPU: 6,
            totalMemory: 16 * 1024 * 1024 * 1024, // 16GB
            availableMemory: 12 * 1024 * 1024 * 1024, // 12GB
            totalDisk: 1000 * 1024 * 1024 * 1024, // 1TB
            availableDisk: 800 * 1024 * 1024 * 1024 // 800GB
        )
    }
    
    private func getRunningVMList() async -> [String] {
        // TODO: Get actual running VMs from cloud-hypervisor
        return []
    }
}

// MARK: - Message Handling

extension Agent {
    func handleMessage(_ envelope: MessageEnvelope) async {
        do {
            switch envelope.type {
            case .vmCreate:
                let message = try envelope.decode(as: VMCreateMessage.self)
                await handleVMCreate(message)
            case .vmBoot:
                let message = try envelope.decode(as: VMOperationMessage.self)
                await handleVMBoot(message)
            case .vmShutdown:
                let message = try envelope.decode(as: VMOperationMessage.self)
                await handleVMShutdown(message)
            case .vmReboot:
                let message = try envelope.decode(as: VMOperationMessage.self)
                await handleVMReboot(message)
            case .vmPause:
                let message = try envelope.decode(as: VMOperationMessage.self)
                await handleVMPause(message)
            case .vmResume:
                let message = try envelope.decode(as: VMOperationMessage.self)
                await handleVMResume(message)
            case .vmDelete:
                let message = try envelope.decode(as: VMOperationMessage.self)
                await handleVMDelete(message)
            case .vmInfo:
                let message = try envelope.decode(as: VMInfoRequestMessage.self)
                await handleVMInfo(message)
            case .vmStatus:
                let message = try envelope.decode(as: VMOperationMessage.self)
                await handleVMStatus(message)
            default:
                logger.warning("Received unknown message type: \(envelope.type)")
            }
        } catch {
            logger.error("Failed to handle message: \(error)")
        }
    }
    
    private func handleVMCreate(_ message: VMCreateMessage) async {
        logger.info("Creating VM", metadata: ["vmId": .string(message.vmData.id.uuidString)])
        
        do {
            try await cloudHypervisorService?.createVM(config: message.vmConfig)
            await sendSuccess(for: message.requestId, message: "VM created successfully")
            logger.info("VM created successfully", metadata: ["vmId": .string(message.vmData.id.uuidString)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to create VM: \(error.localizedDescription)")
            logger.error("Failed to create VM", metadata: ["vmId": .string(message.vmData.id.uuidString), "error": .string(error.localizedDescription)])
        }
    }
    
    private func handleVMBoot(_ message: VMOperationMessage) async {
        logger.info("Booting VM", metadata: ["vmId": .string(message.vmId)])
        
        do {
            try await cloudHypervisorService?.bootVM()
            await sendSuccess(for: message.requestId, message: "VM booted successfully")
            await sendStatusUpdate(vmId: message.vmId, status: .running)
            logger.info("VM booted successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to boot VM: \(error.localizedDescription)")
            logger.error("Failed to boot VM", metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }
    
    private func handleVMShutdown(_ message: VMOperationMessage) async {
        logger.info("Shutting down VM", metadata: ["vmId": .string(message.vmId)])
        
        do {
            try await cloudHypervisorService?.shutdownVM()
            await sendSuccess(for: message.requestId, message: "VM shut down successfully")
            await sendStatusUpdate(vmId: message.vmId, status: .shutdown)
            logger.info("VM shut down successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to shutdown VM: \(error.localizedDescription)")
            logger.error("Failed to shutdown VM", metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }
    
    private func handleVMReboot(_ message: VMOperationMessage) async {
        logger.info("Rebooting VM", metadata: ["vmId": .string(message.vmId)])
        
        do {
            try await cloudHypervisorService?.rebootVM()
            await sendSuccess(for: message.requestId, message: "VM rebooted successfully")
            logger.info("VM rebooted successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to reboot VM: \(error.localizedDescription)")
            logger.error("Failed to reboot VM", metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }
    
    private func handleVMPause(_ message: VMOperationMessage) async {
        logger.info("Pausing VM", metadata: ["vmId": .string(message.vmId)])
        
        do {
            try await cloudHypervisorService?.pauseVM()
            await sendSuccess(for: message.requestId, message: "VM paused successfully")
            await sendStatusUpdate(vmId: message.vmId, status: .paused)
            logger.info("VM paused successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to pause VM: \(error.localizedDescription)")
            logger.error("Failed to pause VM", metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }
    
    private func handleVMResume(_ message: VMOperationMessage) async {
        logger.info("Resuming VM", metadata: ["vmId": .string(message.vmId)])
        
        do {
            try await cloudHypervisorService?.resumeVM()
            await sendSuccess(for: message.requestId, message: "VM resumed successfully")
            await sendStatusUpdate(vmId: message.vmId, status: .running)
            logger.info("VM resumed successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to resume VM: \(error.localizedDescription)")
            logger.error("Failed to resume VM", metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }
    
    private func handleVMDelete(_ message: VMOperationMessage) async {
        logger.info("Deleting VM", metadata: ["vmId": .string(message.vmId)])
        
        do {
            try await cloudHypervisorService?.deleteVM()
            await sendSuccess(for: message.requestId, message: "VM deleted successfully")
            logger.info("VM deleted successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to delete VM: \(error.localizedDescription)")
            logger.error("Failed to delete VM", metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }
    
    private func handleVMInfo(_ message: VMInfoRequestMessage) async {
        logger.info("Getting VM info", metadata: ["vmId": .string(message.vmId)])
        
        do {
            let vmInfo = try await cloudHypervisorService?.getVMInfo()
            let data = try AnyCodableValue(vmInfo)
            await sendSuccess(for: message.requestId, message: "VM info retrieved", data: data)
            logger.info("VM info retrieved successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to get VM info: \(error.localizedDescription)")
            logger.error("Failed to get VM info", metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }
    
    private func handleVMStatus(_ message: VMOperationMessage) async {
        logger.info("Getting VM status", metadata: ["vmId": .string(message.vmId)])
        
        do {
            let status = try await cloudHypervisorService?.syncVMStatus() ?? .shutdown
            let data = try AnyCodableValue(status)
            await sendSuccess(for: message.requestId, message: "VM status retrieved", data: data)
            logger.info("VM status retrieved successfully", metadata: ["vmId": .string(message.vmId), "status": .string(status.rawValue)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to get VM status: \(error.localizedDescription)")
            logger.error("Failed to get VM status", metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }
    
    private func sendSuccess(for requestId: String, message: String? = nil, data: AnyCodableValue? = nil) async {
        let successMessage = SuccessMessage(requestId: requestId, message: message, data: data)
        do {
            try await websocketClient?.sendMessage(successMessage)
        } catch {
            logger.error("Failed to send success message: \(error)")
        }
    }
    
    private func sendError(for requestId: String, error: String, details: String? = nil) async {
        let errorMessage = ErrorMessage(requestId: requestId, error: error, details: details)
        do {
            try await websocketClient?.sendMessage(errorMessage)
        } catch {
            logger.error("Failed to send error message: \(error)")
        }
    }
    
    private func sendStatusUpdate(vmId: String, status: VMStatus, details: String? = nil) async {
        let statusMessage = StatusUpdateMessage(vmId: vmId, status: status, details: details)
        do {
            try await websocketClient?.sendMessage(statusMessage)
        } catch {
            logger.error("Failed to send status update: \(error)")
        }
    }
}