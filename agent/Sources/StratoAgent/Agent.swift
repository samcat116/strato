import Foundation
import Logging
import NIOCore
import NIOPosix
import StratoShared

actor Agent {
    private let agentID: String
    private let webSocketURL: String
    private let qemuSocketDir: String
    private let isRegistrationMode: Bool
    private let logger: Logger
    
    private var websocketClient: WebSocketClient?
    private var qemuService: QEMUService?
    private var networkService: (any NetworkServiceProtocol)?
    private var heartbeatTask: Task<Void, Error>?
    private var isRunning = false
    
    init(
        agentID: String,
        webSocketURL: String,
        qemuSocketDir: String,
        isRegistrationMode: Bool,
        logger: Logger
    ) {
        self.agentID = agentID
        self.webSocketURL = webSocketURL
        self.qemuSocketDir = qemuSocketDir
        self.isRegistrationMode = isRegistrationMode
        self.logger = logger
    }
    
    func start() async throws {
        guard !isRunning else {
            logger.warning("Agent is already running")
            return
        }
        
        logger.info("Initializing network service")

        // Initialize platform-specific network service
        #if os(Linux)
        networkService = NetworkServiceLinux(logger: logger)
        #else
        networkService = NetworkServiceMacOS(logger: logger)
        #endif

        do {
            if let service = networkService {
                try await service.connect()
                logger.info("Network service connected successfully")
            }
        } catch {
            logger.warning("Failed to connect to network service: \(error.localizedDescription)")
            logger.warning("VM networking will be limited")
        }
        
        logger.info("Initializing QEMU service")
        qemuService = QEMUService(logger: logger, networkService: networkService)
        
        if isRegistrationMode {
            logger.info("Connecting for agent registration", metadata: ["url": .string(webSocketURL)])
        } else {
            logger.info("Connecting to control plane", metadata: ["url": .string(webSocketURL)])
        }
        websocketClient = await WebSocketClient(url: webSocketURL, agent: self, logger: logger)
        
        if let client = websocketClient {
            try await client.connect()
        }
        
        // Register with control plane
        try await registerWithControlPlane()
        
        // Start heartbeat
        startHeartbeat()
        
        isRunning = true
        logger.info("Agent started successfully")
        
        // Keep the agent running indefinitely
        while isRunning {
            try await Task.sleep(for: .seconds(3600)) // Sleep for 1 hour at a time
        }
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
        
        if let client = websocketClient {
            await client.disconnect()
        }
        websocketClient = nil
        qemuService = nil
        
        if let service = networkService {
            await service.disconnect()
        }
        networkService = nil
        
        logger.info("Agent stopped")
    }
    
    private func registerWithControlPlane() async throws {
        let resources = await getAgentResources()
        let capabilities = getAgentCapabilities()
        let message = AgentRegisterMessage(
            agentId: agentID,
            hostname: ProcessInfo.processInfo.hostName,
            version: "1.0.0",
            capabilities: capabilities,
            resources: resources
        )

        if let client = websocketClient {
            try await client.sendMessage(message)
        }
        logger.info("Registration message sent to control plane")
    }

    private func getAgentCapabilities() -> [String] {
        var capabilities = ["vm_management", "qemu"]

        #if canImport(SwiftQEMU)
        #if os(Linux)
        capabilities.append(contentsOf: ["kvm", "ovn_networking"])
        #elseif os(macOS)
        capabilities.append(contentsOf: ["hvf", "user_networking"])
        #endif
        #endif

        return capabilities
    }
    
    private func unregisterFromControlPlane() async throws {
        let message = AgentUnregisterMessage(
            agentId: agentID,
            reason: "Agent shutdown"
        )
        
        if let client = websocketClient {
            try await client.sendMessage(message)
        }
        logger.info("Unregistration message sent to control plane")
    }
    
    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await self?._sendHeartbeat()
                    try await Task.sleep(for: .seconds(30)) // Heartbeat every 30 seconds
                } catch {
                    self?.logger.error("Heartbeat failed: \(error)")
                    try await Task.sleep(for: .seconds(10)) // Retry after 10 seconds
                }
            }
        }
    }
    
    func sendHeartbeat() async {
        do {
            try await _sendHeartbeat()
        } catch {
            logger.error("Failed to send heartbeat: \(error)")
        }
    }
    
    private func _sendHeartbeat() async throws {
        let resources = await getAgentResources()
        let runningVMs = await getRunningVMList()
        
        let message = AgentHeartbeatMessage(
            agentId: agentID,
            resources: resources,
            runningVMs: runningVMs
        )
        
        if let client = websocketClient {
            try await client.sendMessage(message)
        }
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
        // TODO: Get actual running VMs from QEMU
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
            case .networkCreate:
                let message = try envelope.decode(as: NetworkCreateMessage.self)
                await handleNetworkCreate(message)
            case .networkDelete:
                let message = try envelope.decode(as: NetworkDeleteMessage.self)
                await handleNetworkDelete(message)
            case .networkList:
                let message = try envelope.decode(as: NetworkListMessage.self)
                await handleNetworkList(message)
            case .networkInfo:
                let message = try envelope.decode(as: NetworkInfoMessage.self)
                await handleNetworkInfo(message)
            case .networkAttach:
                let message = try envelope.decode(as: NetworkAttachMessage.self)
                await handleNetworkAttach(message)
            case .networkDetach:
                let message = try envelope.decode(as: NetworkDetachMessage.self)
                await handleNetworkDetach(message)
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
            try await qemuService?.createVM(config: message.vmConfig)
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
            try await qemuService?.bootVM()
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
            try await qemuService?.shutdownVM()
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
            try await qemuService?.rebootVM()
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
            try await qemuService?.pauseVM()
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
            try await qemuService?.resumeVM()
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
            try await qemuService?.deleteVM()
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
            let vmInfo = try await qemuService?.getVMInfo()
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
            let status = try await qemuService?.syncVMStatus() ?? .shutdown
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
    
    // MARK: - Network Message Handlers
    
    private func handleNetworkCreate(_ message: NetworkCreateMessage) async {
        logger.info("Creating network", metadata: ["networkName": .string(message.networkName)])
        
        guard let networkService = networkService else {
            await sendError(for: message.requestId, error: "Network service not available")
            return
        }
        
        do {
            let networkUUID = try await networkService.createLogicalNetwork(
                name: message.networkName,
                subnet: message.subnet,
                gateway: message.gateway
            )
            
            let networkInfo = NetworkInfo(
                name: message.networkName,
                uuid: networkUUID.uuidString,
                subnet: message.subnet,
                gateway: message.gateway,
                vlanId: message.vlanId,
                dhcpEnabled: message.dhcpEnabled,
                dnsServers: message.dnsServers
            )
            
            let data = try AnyCodableValue(networkInfo)
            await sendSuccess(for: message.requestId, message: "Network created successfully", data: data)
            logger.info("Network created successfully", metadata: ["networkName": .string(message.networkName)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to create network: \(error.localizedDescription)")
            logger.error("Failed to create network", metadata: ["networkName": .string(message.networkName), "error": .string(error.localizedDescription)])
        }
    }
    
    private func handleNetworkDelete(_ message: NetworkDeleteMessage) async {
        logger.info("Deleting network", metadata: ["networkName": .string(message.networkName)])
        
        guard let networkService = networkService else {
            await sendError(for: message.requestId, error: "Network service not available")
            return
        }
        
        do {
            try await networkService.deleteLogicalNetwork(name: message.networkName)
            await sendSuccess(for: message.requestId, message: "Network deleted successfully")
            logger.info("Network deleted successfully", metadata: ["networkName": .string(message.networkName)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to delete network: \(error.localizedDescription)")
            logger.error("Failed to delete network", metadata: ["networkName": .string(message.networkName), "error": .string(error.localizedDescription)])
        }
    }
    
    private func handleNetworkList(_ message: NetworkListMessage) async {
        logger.info("Listing networks")
        
        guard let networkService = networkService else {
            await sendError(for: message.requestId, error: "Network service not available")
            return
        }
        
        do {
            let networks = try await networkService.listLogicalNetworks()
            let data = try AnyCodableValue(networks)
            await sendSuccess(for: message.requestId, message: "Networks retrieved successfully", data: data)
            logger.info("Networks listed successfully", metadata: ["count": .stringConvertible(networks.count)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to list networks: \(error.localizedDescription)")
            logger.error("Failed to list networks", metadata: ["error": .string(error.localizedDescription)])
        }
    }
    
    private func handleNetworkInfo(_ message: NetworkInfoMessage) async {
        logger.info("Getting network info", metadata: ["networkName": .string(message.networkName)])
        
        guard let networkService = networkService else {
            await sendError(for: message.requestId, error: "Network service not available")
            return
        }
        
        do {
            let networks = try await networkService.listLogicalNetworks()
            if let network = networks.first(where: { $0.name == message.networkName }) {
                let data = try AnyCodableValue(network)
                await sendSuccess(for: message.requestId, message: "Network info retrieved successfully", data: data)
                logger.info("Network info retrieved successfully", metadata: ["networkName": .string(message.networkName)])
            } else {
                await sendError(for: message.requestId, error: "Network not found: \(message.networkName)")
                logger.warning("Network not found", metadata: ["networkName": .string(message.networkName)])
            }
        } catch {
            await sendError(for: message.requestId, error: "Failed to get network info: \(error.localizedDescription)")
            logger.error("Failed to get network info", metadata: ["networkName": .string(message.networkName), "error": .string(error.localizedDescription)])
        }
    }
    
    private func handleNetworkAttach(_ message: NetworkAttachMessage) async {
        logger.info("Attaching VM to network", metadata: ["vmId": .string(message.vmId), "networkName": .string(message.networkName)])
        
        guard let networkService = networkService else {
            await sendError(for: message.requestId, error: "Network service not available")
            return
        }
        
        do {
            let networkInfo = try await networkService.attachVMToNetwork(
                vmId: message.vmId,
                networkName: message.networkName,
                macAddress: message.config?.macAddress
            )
            
            let data = try AnyCodableValue(networkInfo)
            await sendSuccess(for: message.requestId, message: "VM attached to network successfully", data: data)
            logger.info("VM attached to network successfully", metadata: ["vmId": .string(message.vmId), "networkName": .string(message.networkName)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to attach VM to network: \(error.localizedDescription)")
            logger.error("Failed to attach VM to network", metadata: ["vmId": .string(message.vmId), "networkName": .string(message.networkName), "error": .string(error.localizedDescription)])
        }
    }
    
    private func handleNetworkDetach(_ message: NetworkDetachMessage) async {
        logger.info("Detaching VM from network", metadata: ["vmId": .string(message.vmId)])
        
        guard let networkService = networkService else {
            await sendError(for: message.requestId, error: "Network service not available")
            return
        }
        
        do {
            try await networkService.detachVMFromNetwork(vmId: message.vmId)
            await sendSuccess(for: message.requestId, message: "VM detached from network successfully")
            logger.info("VM detached from network successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to detach VM from network: \(error.localizedDescription)")
            logger.error("Failed to detach VM from network", metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }
}