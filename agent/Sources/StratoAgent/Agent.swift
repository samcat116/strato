import Foundation
import Logging
import NIOCore
import NIOPosix
import StratoShared
import StratoAgentCore

enum AgentError: Error, LocalizedError {
    case registrationTimeout
    case notRegistered

    var errorDescription: String? {
        switch self {
        case .registrationTimeout:
            return "Registration timed out waiting for control plane response"
        case .notRegistered:
            return "Agent is not registered with control plane"
        }
    }
}

actor Agent {
    private let initialAgentID: String  // ID used for registration (hostname or CLI arg)
    private var assignedAgentID: String?  // UUID assigned by control plane after registration
    private let webSocketURL: String
    private let qemuSocketDir: String
    private let isRegistrationMode: Bool
    private let logger: Logger

    private var websocketClient: WebSocketClient?
    private var qemuService: QEMUService?
    private var networkService: (any NetworkServiceProtocol)?
    private var imageCacheService: ImageCacheService?
    private var consoleSocketManager: ConsoleSocketManager?
    private var heartbeatTask: Task<Void, Error>?
    private var isRunning = false
    private var registrationContinuation: CheckedContinuation<String, Error>?
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)

    private let networkMode: NetworkMode?
    private let imageCachePath: String?
    private let vmStoragePath: String
    private let qemuBinaryPath: String

    init(
        agentID: String,
        webSocketURL: String,
        qemuSocketDir: String,
        networkMode: NetworkMode?,
        isRegistrationMode: Bool,
        logger: Logger,
        imageCachePath: String? = nil,
        vmStoragePath: String,
        qemuBinaryPath: String
    ) {
        self.initialAgentID = agentID
        self.webSocketURL = webSocketURL
        self.qemuSocketDir = qemuSocketDir
        self.networkMode = networkMode
        self.isRegistrationMode = isRegistrationMode
        self.logger = logger
        self.imageCachePath = imageCachePath
        self.vmStoragePath = vmStoragePath
        self.qemuBinaryPath = qemuBinaryPath
    }

    /// Returns the effective agent ID (assigned UUID if registered, initial ID otherwise)
    private var effectiveAgentID: String {
        return assignedAgentID ?? initialAgentID
    }
    
    func start() async throws {
        guard !isRunning else {
            logger.warning("Agent is already running")
            return
        }
        
        logger.info("Initializing network service")

        // Initialize network service based on config, falling back to platform defaults
        let selectedMode = networkMode ?? {
            #if os(Linux)
            return .ovn
            #else
            return .user
            #endif
        }()

        switch selectedMode {
        case .ovn:
            #if os(Linux)
            logger.info("Network service initialized with SwiftOVN support")
            networkService = NetworkServiceLinux(logger: logger)
            #else
            logger.warning("OVN mode requested but not supported on macOS, falling back to user mode")
            networkService = NetworkServiceMacOS(logger: logger)
            #endif
        case .user:
            logger.info("Network service initialized with user-mode networking")
            networkService = NetworkServiceMacOS(logger: logger)
        }

        do {
            if let service = networkService {
                try await service.connect()
                logger.info("Network service connected successfully")
            }
        } catch {
            logger.warning("Failed to connect to network service: \(error.localizedDescription)")
            logger.warning("VM networking will be limited")
        }
        
        // Initialize image cache service
        logger.info("Initializing image cache service")
        imageCacheService = ImageCacheService(
            logger: logger,
            cachePath: imageCachePath,
            controlPlaneURL: webSocketURL.replacingOccurrences(of: "ws://", with: "http://")
                .replacingOccurrences(of: "wss://", with: "https://")
                .replacingOccurrences(of: "/agent/ws", with: "")
        )

        logger.info("Initializing QEMU service")
        qemuService = QEMUService(logger: logger, networkService: networkService, imageCacheService: imageCacheService, vmStoragePath: vmStoragePath, qemuBinaryPath: qemuBinaryPath)

        logger.info("Initializing console socket manager")
        consoleSocketManager = ConsoleSocketManager(logger: logger, eventLoopGroup: eventLoopGroup)
        await consoleSocketManager?.setOnConsoleData { [weak self] vmId, sessionId, data in
            await self?.sendConsoleData(vmId: vmId, sessionId: sessionId, data: data)
        }
        
        if isRegistrationMode {
            logger.info("Connecting for agent registration", metadata: ["url": .string(webSocketURL)])
        } else {
            logger.info("Connecting to control plane", metadata: ["url": .string(webSocketURL)])
        }
        websocketClient = WebSocketClient(url: webSocketURL, agent: self, logger: logger)
        
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
            agentId: initialAgentID,
            hostname: ProcessInfo.processInfo.hostName,
            version: "1.0.0",
            capabilities: capabilities,
            resources: resources
        )

        if let client = websocketClient {
            try await client.sendMessage(message)
        }
        logger.info("Registration message sent to control plane, waiting for response...")

        // Wait for registration response with timeout
        let assignedId = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            self.registrationContinuation = continuation

            // Set up timeout
            Task {
                try await Task.sleep(for: .seconds(30))
                if self.registrationContinuation != nil {
                    self.registrationContinuation?.resume(throwing: AgentError.registrationTimeout)
                    self.registrationContinuation = nil
                }
            }
        }

        self.assignedAgentID = assignedId
        logger.info("Registration complete, assigned ID: \(assignedId)")
    }

    /// Handle registration response from control plane
    func handleRegistrationResponse(_ response: AgentRegisterResponseMessage) {
        guard let continuation = registrationContinuation else {
            logger.warning("Received registration response but no continuation waiting")
            return
        }
        registrationContinuation = nil
        continuation.resume(returning: response.agentId)
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
            agentId: effectiveAgentID,
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
        // Only send heartbeat if we have an assigned ID from registration
        guard assignedAgentID != nil else {
            logger.debug("Skipping heartbeat - not yet registered")
            return
        }

        let resources = await getAgentResources()
        let runningVMs = await getRunningVMList()

        let message = AgentHeartbeatMessage(
            agentId: effectiveAgentID,
            resources: resources,
            runningVMs: runningVMs
        )

        if let client = websocketClient {
            try await client.sendMessage(message)
        }
        logger.debug("Heartbeat sent", metadata: ["agentId": .string(effectiveAgentID)])
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
        logger.debug("Handling message from control plane", metadata: [
            "type": .string(envelope.type.rawValue)
        ])

        do {
            switch envelope.type {
            case .agentRegisterResponse:
                let message = try envelope.decode(as: AgentRegisterResponseMessage.self)
                handleRegistrationResponse(message)
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
            case .consoleConnect:
                let message = try envelope.decode(as: ConsoleConnectMessage.self)
                await handleConsoleConnect(message)
            case .consoleDisconnect:
                let message = try envelope.decode(as: ConsoleDisconnectMessage.self)
                await handleConsoleDisconnect(message)
            case .consoleData:
                let message = try envelope.decode(as: ConsoleDataMessage.self)
                await handleConsoleData(message)
            default:
                logger.warning("Received unknown message type: \(envelope.type)")
            }
        } catch {
            logger.error("Failed to handle message: \(error)")
        }
    }
    
    private func handleVMCreate(_ message: VMCreateMessage) async {
        logger.info("Creating VM", metadata: ["vmId": .string(message.vmData.id.uuidString)])

        // Log image info if provided
        if let imageInfo = message.imageInfo {
            logger.info("VM creation includes image info", metadata: [
                "vmId": .string(message.vmData.id.uuidString),
                "imageId": .string(imageInfo.imageId.uuidString),
                "filename": .string(imageInfo.filename)
            ])
        }

        do {
            try await qemuService?.createVM(
                vmId: message.vmData.id.uuidString,
                config: message.vmConfig,
                imageInfo: message.imageInfo
            )
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
            try await qemuService?.bootVM(vmId: message.vmId)
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

    // MARK: - Console Message Handlers

    private func handleConsoleConnect(_ message: ConsoleConnectMessage) async {
        logger.info("Console connect request received", metadata: [
            "vmId": .string(message.vmId),
            "sessionId": .string(message.sessionId),
            "requestId": .string(message.requestId)
        ])

        guard let qemuService = qemuService else {
            logger.error("QEMU service not available for console connect")
            await sendError(for: message.requestId, error: "QEMU service not available")
            return
        }

        // Try serial socket first, then fall back to virtio-console if connect fails.
        logger.debug("Looking up serial socket path", metadata: ["vmId": .string(message.vmId)])
        let serialPath = await qemuService.getSerialSocketPath(vmId: message.vmId)
        let consolePath = await qemuService.getConsoleSocketPath(vmId: message.vmId)

        guard serialPath != nil || consolePath != nil else {
            logger.error("No console socket found (tried serial and virtio-console)", metadata: ["vmId": .string(message.vmId)])
            await sendError(for: message.requestId, error: "Console socket not found for VM \(message.vmId)")
            return
        }

        guard let consoleManager = consoleSocketManager else {
            logger.error("Console manager not available")
            await sendError(for: message.requestId, error: "Console manager not available")
            return
        }

        var connectedPath: String?
        var lastError: Error?

        if let serialPath = serialPath {
            do {
                try await consoleManager.connect(vmId: message.vmId, sessionId: message.sessionId, socketPath: serialPath)
                connectedPath = serialPath
                logger.debug("Connected to serial console socket", metadata: ["socketPath": .string(serialPath)])
            } catch {
                lastError = error
                logger.warning("Failed to connect to serial socket, will try virtio-console", metadata: [
                    "vmId": .string(message.vmId),
                    "sessionId": .string(message.sessionId),
                    "error": .string(error.localizedDescription)
                ])
            }
        }

        if connectedPath == nil, let consolePath = consolePath {
            do {
                try await consoleManager.connect(vmId: message.vmId, sessionId: message.sessionId, socketPath: consolePath)
                connectedPath = consolePath
                logger.debug("Connected to virtio-console socket", metadata: ["socketPath": .string(consolePath)])
            } catch {
                lastError = error
            }
        }

        guard connectedPath != nil else {
            let errorMessage = "Failed to connect to console: \(lastError?.localizedDescription ?? "unknown error")"
            await sendError(for: message.requestId, error: errorMessage)
            logger.error("Failed to connect to console", metadata: [
                "vmId": .string(message.vmId),
                "sessionId": .string(message.sessionId),
                "error": .string(lastError?.localizedDescription ?? "unknown")
            ])
            return
        }

        // Send connected confirmation
        let connectedMessage = ConsoleConnectedMessage(
            requestId: message.requestId,
            vmId: message.vmId,
            sessionId: message.sessionId
        )
        do {
            try await websocketClient?.sendMessage(connectedMessage)
        } catch {
            logger.error("Failed to send console connected message: \(error)")
        }

        logger.info("Console connected", metadata: [
            "vmId": .string(message.vmId),
            "sessionId": .string(message.sessionId),
            "socketPath": .string(connectedPath ?? "unknown")
        ])
    }

    private func handleConsoleDisconnect(_ message: ConsoleDisconnectMessage) async {
        logger.info("Console disconnect request", metadata: [
            "vmId": .string(message.vmId),
            "sessionId": .string(message.sessionId)
        ])

        guard let consoleManager = consoleSocketManager else {
            await sendError(for: message.requestId, error: "Console manager not available")
            return
        }

        await consoleManager.disconnect(sessionId: message.sessionId)

        // Send disconnected confirmation
        let disconnectedMessage = ConsoleDisconnectedMessage(
            requestId: message.requestId,
            vmId: message.vmId,
            sessionId: message.sessionId,
            reason: "User requested disconnect"
        )
        do {
            try await websocketClient?.sendMessage(disconnectedMessage)
        } catch {
            logger.error("Failed to send disconnected message: \(error)")
        }

        logger.info("Console disconnected", metadata: [
            "vmId": .string(message.vmId),
            "sessionId": .string(message.sessionId)
        ])
    }

    private func handleConsoleData(_ message: ConsoleDataMessage) async {
        // User input from frontend - write to console socket
        guard let consoleManager = consoleSocketManager else {
            logger.warning("Console manager not available for data write")
            return
        }

        guard let data = message.rawData else {
            logger.warning("Invalid console data received (failed to decode base64)")
            return
        }

        do {
            try await consoleManager.write(sessionId: message.sessionId, data: data)
        } catch {
            logger.error("Failed to write to console", metadata: [
                "sessionId": .string(message.sessionId),
                "error": .string(error.localizedDescription)
            ])
        }
    }

    /// Called by ConsoleSocketManager when data arrives from VM console
    func sendConsoleData(vmId: String, sessionId: String, data: Data) async {
        let message = ConsoleDataMessage(
            vmId: vmId,
            sessionId: sessionId,
            rawData: data
        )
        do {
            try await websocketClient?.sendMessage(message)
        } catch {
            logger.error("Failed to send console data: \(error)")
        }
    }
}
