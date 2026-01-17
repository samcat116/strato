import Foundation
import Vapor
import StratoShared
import NIOWebSocket
import Fluent
import NIOCore
import NIOConcurrencyHelpers

/// Thread-safe WebSocket connection manager
/// This is NOT an actor to avoid event loop conflicts with NIO
/// WebSocket objects are event-loop-bound and must only be accessed from their event loop
final class WebSocketManager: @unchecked Sendable {
    private let lock = NIOLock()
    private var connections: [String: WebSocket] = [:] // Agent name -> WebSocket

    /// Must be called from the WebSocket's event loop
    func setConnection(agentName: String, websocket: WebSocket) {
        lock.withLock {
            connections[agentName] = websocket
        }
    }

    /// Returns the WebSocket for an agent - must be used on WebSocket's event loop
    func getConnection(agentName: String) -> WebSocket? {
        lock.withLock {
            connections[agentName]
        }
    }

    /// Remove connection by agent name
    func removeConnection(agentName: String) {
        lock.withLock {
            connections.removeValue(forKey: agentName)
        }
    }

    /// Get all agent names (for diagnostics)
    func getAllAgentNames() -> [String] {
        lock.withLock {
            Array(connections.keys)
        }
    }
}

actor AgentService {
    private let app: Application
    private var agents: [String: AgentInfo] = [:]
    private var vmToAgentMapping: [String: String] = [:] // VM ID -> Agent ID
    private var pendingRequests: [String: CheckedContinuation<AgentServiceResponse, Error>] = [:]
    private var heartbeatTask: Task<Void, Never>?

    init(app: Application) {
        self.app = app
        // Start heartbeat monitoring and restore VM mappings after initialization
        Task {
            await startHeartbeatMonitoring()
            await restoreVMToAgentMappings()
        }
    }

    // MARK: - VM-to-Agent Mapping Recovery

    /// Restore VM-to-agent mappings from database on startup
    /// This ensures that if the control plane restarts, we don't lose track of which VMs are on which agents
    private func restoreVMToAgentMappings() async {
        do {
            let db = app.db
            let vms = try await VM.query(on: db)
                .filter(\.$hypervisorId != nil)
                .all()

            for vm in vms {
                if let vmId = vm.id?.uuidString, let hypervisorId = vm.hypervisorId {
                    vmToAgentMapping[vmId] = hypervisorId
                }
            }

            app.logger.info("Restored VM-to-agent mappings for \(vms.count) VMs from database")
        } catch {
            app.logger.error("Failed to restore VM-to-agent mappings from database: \(error)")
        }
    }

    // MARK: - Agent Registration

    /// Registers an agent and returns its database UUID
    func registerAgent(_ message: AgentRegisterMessage, agentName: String) async throws -> UUID {
        let db = app.db

        // Find existing agent or create new one
        let agent: Agent
        if let existingAgent = try await Agent.query(on: db)
            .filter(\.$name == agentName)
            .first() {
            // Update existing agent
            agent = existingAgent
            agent.hostname = message.hostname
            agent.version = message.version
            agent.capabilities = message.capabilities
            agent.updateResources(message.resources)
            agent.status = .online
        } else {
            // Create new agent
            agent = Agent.from(registration: message, name: agentName)
            agent.status = .online
        }

        try await agent.save(on: db)

        guard let agentUUID = agent.id else {
            throw AgentServiceError.invalidResponse("Failed to get agent ID after save")
        }

        // Update in-memory tracking using UUID as the key
        let agentInfo = AgentInfo(
            id: agentUUID.uuidString,
            name: agentName,
            hostname: message.hostname,
            version: message.version,
            capabilities: message.capabilities,
            resources: message.resources,
            lastHeartbeat: Date(),
            status: .online
        )

        agents[agentUUID.uuidString] = agentInfo

        app.logger.info("Agent registered", metadata: [
            "agentId": .string(agentUUID.uuidString),
            "agentName": .string(agentName),
            "hostname": .string(message.hostname),
            "version": .string(message.version)
        ])

        return agentUUID
    }

    /// Find agent UUID by name in the in-memory agents dictionary
    private func findAgentIdByName(_ agentName: String) -> String? {
        return agents.first(where: { $0.value.name == agentName })?.key
    }

    func unregisterAgent(_ agentId: String) async throws {
        let db = app.db

        // Update database using UUID
        if let agentUUID = UUID(uuidString: agentId),
           let agent = try await Agent.find(agentUUID, on: db) {
            agent.status = .offline
            try await agent.save(on: db)
        }

        // Get agent name for WebSocket cleanup
        let agentName = agents[agentId]?.name

        // Remove from in-memory tracking
        agents.removeValue(forKey: agentId)
        if let name = agentName {
            app.websocketManager.removeConnection(agentName: name)
        }

        // Remove VM mappings for this agent
        let vmIds = vmToAgentMapping.compactMap { (vmId, mappedAgentId) in
            mappedAgentId == agentId ? vmId : nil
        }

        for vmId in vmIds {
            vmToAgentMapping.removeValue(forKey: vmId)
        }

        app.logger.info("Agent unregistered", metadata: ["agentId": .string(agentId)])
    }

    func forceUnregisterAgent(_ agentName: String) async {
        // Find agent UUID by name
        guard let agentId = findAgentIdByName(agentName) else {
            app.logger.warning("Cannot force unregister: agent not found by name", metadata: ["agentName": .string(agentName)])
            return
        }

        // Remove from in-memory tracking
        agents.removeValue(forKey: agentId)
        app.websocketManager.removeConnection(agentName: agentName)

        // Remove VM mappings for this agent
        let vmIds = vmToAgentMapping.compactMap { (vmId, mappedAgentId) in
            mappedAgentId == agentId ? vmId : nil
        }

        for vmId in vmIds {
            vmToAgentMapping.removeValue(forKey: vmId)
        }

        app.logger.info("Agent force unregistered from memory", metadata: ["agentId": .string(agentId), "agentName": .string(agentName)])
    }

    func removeAgent(_ agentName: String) async {
        // Find agent UUID by name
        guard let agentId = findAgentIdByName(agentName) else {
            app.logger.debug("Cannot remove agent: not found by name", metadata: ["agentName": .string(agentName)])
            return
        }

        // Mark agent as offline in memory
        agents.removeValue(forKey: agentId)

        // Update database status asynchronously
        Task {
            do {
                let db = self.app.db
                if let agentUUID = UUID(uuidString: agentId),
                   let agent = try await Agent.find(agentUUID, on: db) {
                    agent.status = .offline
                    try await agent.save(on: db)
                }
            } catch {
                self.app.logger.error("Failed to update agent offline status in database: \(error)")
            }
        }
    }

    func updateAgentHeartbeat(_ message: AgentHeartbeatMessage) async throws {
        guard var agentInfo = agents[message.agentId] else {
            app.logger.warning("Received heartbeat from unknown agent", metadata: ["agentId": .string(message.agentId)])
            return
        }

        // Update in-memory tracking
        agentInfo.resources = message.resources
        agentInfo.lastHeartbeat = Date()
        agentInfo.status = .online
        agents[message.agentId] = agentInfo

        // Update database asynchronously using UUID
        Task {
            do {
                let db = self.app.db
                guard let agentUUID = UUID(uuidString: message.agentId) else {
                    self.app.logger.error("Invalid agent UUID in heartbeat: \(message.agentId)")
                    return
                }
                if let agent = try await Agent.find(agentUUID, on: db) {
                    agent.updateResources(message.resources)
                    agent.status = .online
                    try await agent.save(on: db)
                }
            } catch {
                self.app.logger.error("Failed to update agent heartbeat in database: \(error)")
            }
        }

        app.logger.debug("Agent heartbeat updated", metadata: ["agentId": .string(message.agentId)])
    }
    
    // MARK: - Heartbeat Monitoring
    
    private func startHeartbeatMonitoring() {
        heartbeatTask = Task {
            while !Task.isCancelled {
                do {
                    // Sleep for 30 seconds
                    try await Task.sleep(for: .seconds(30))
                    
                    // Check for stale agents
                    await checkStaleAgents()
                } catch {
                    if !Task.isCancelled {
                        app.logger.error("Error in heartbeat monitoring task: \(error)")
                    }
                }
            }
        }
    }
    
    private func checkStaleAgents() async {
        let now = Date()
        let staleThreshold: TimeInterval = 60 // 60 seconds

        let staleAgents = agents.values.compactMap { agentInfo -> String? in
            if now.timeIntervalSince(agentInfo.lastHeartbeat) > staleThreshold {
                return agentInfo.id  // This is the UUID
            }
            return nil
        }

        if !staleAgents.isEmpty {
            app.logger.info("Found \(staleAgents.count) stale agents, marking as offline")

            for agentId in staleAgents {
                // Remove from memory
                agents.removeValue(forKey: agentId)

                // Update database using UUID
                Task {
                    do {
                        let db = self.app.db
                        if let agentUUID = UUID(uuidString: agentId),
                           let agent = try await Agent.find(agentUUID, on: db) {
                            agent.status = .offline
                            try await agent.save(on: db)
                        }
                    } catch {
                        self.app.logger.error("Failed to update stale agent status in database: \(error)")
                    }
                }
            }
        }
    }

    // MARK: - VM Operations

    /// Creates a VM on an agent selected by the scheduler
    /// - Parameters:
    ///   - vm: The VM to create
    ///   - vmConfig: VM configuration for QEMU
    ///   - db: Database connection
    ///   - strategy: Optional scheduling strategy override
    ///   - image: Optional image for image-based VM creation (will generate signed download URL)
    func createVM(vm: VM, vmConfig: VmConfig, db: Database, strategy: SchedulingStrategy? = nil, image: Image? = nil) async throws {
        // Convert agents to schedulable format
        let schedulableAgents = getSchedulableAgents()

        // Use scheduler to select best agent
        let agentId: String
        do {
            agentId = try app.scheduler.selectAgent(
                for: vm,
                from: schedulableAgents,
                strategy: strategy
            )
        } catch let error as SchedulerError {
            app.logger.error("Scheduler failed to find suitable agent: \(error)")
            throw AgentServiceError.noAvailableAgent
        }

        guard agents[agentId] != nil else {
            throw AgentServiceError.agentNotFound(agentId)
        }

        // Build ImageInfo with signed URL now that we know the agent
        var imageInfo: ImageInfo?
        if let image = image {
            do {
                let controlPlaneURL = Environment.get("CONTROL_PLANE_URL") ?? "http://localhost:8080"
                let signingKey = try URLSigningService.getSigningKey(from: app)
                imageInfo = try VMConfigBuilder.buildImageInfo(
                    from: image,
                    controlPlaneURL: controlPlaneURL,
                    agentName: agentId,
                    signingKey: signingKey
                )
            } catch {
                app.logger.error("Failed to build image info: \(error)")
                throw error
            }
        }

        let message = VMCreateMessage(
            vmData: vm.toVMData(),
            vmConfig: vmConfig,
            imageInfo: imageInfo
        )

        try await sendMessageToAgent(message, agentId: agentId)

        // Map VM to agent (in-memory)
        vmToAgentMapping[vm.id?.uuidString ?? ""] = agentId

        // Persist hypervisor assignment to database
        vm.hypervisorId = agentId
        try await vm.save(on: db)

        app.logger.info("VM creation requested", metadata: [
            "vmId": .string(vm.id?.uuidString ?? ""),
            "agentId": .string(agentId),
            "hasImageInfo": .string(imageInfo != nil ? "yes" : "no")
        ])
    }

    func performVMOperation(_ operation: MessageType, vmId: String) async throws {
        guard let agentId = vmToAgentMapping[vmId] else {
            throw AgentServiceError.vmNotMapped(vmId)
        }

        guard agents[agentId] != nil else {
            throw AgentServiceError.agentNotFound(agentId)
        }

        let message = VMOperationMessage(type: operation, vmId: vmId)
        try await sendMessageToAgent(message, agentId: agentId)

        app.logger.info("VM operation requested", metadata: [
            "operation": .string(operation.rawValue),
            "vmId": .string(vmId),
            "agentId": .string(agentId)
        ])
    }

    func getVMInfo(vmId: String) async throws -> VmInfo {
        guard let agentId = vmToAgentMapping[vmId] else {
            throw AgentServiceError.vmNotMapped(vmId)
        }

        guard agents[agentId] != nil else {
            throw AgentServiceError.agentNotFound(agentId)
        }

        let message = VMInfoRequestMessage(vmId: vmId)
        let response = try await sendMessageToAgentWithResponse(message, agentId: agentId)

        guard case .success(let data) = response,
              let vmInfo = try? data?.decode(as: VmInfo.self) else {
            throw AgentServiceError.invalidResponse("Failed to decode VM info")
        }

        return vmInfo
    }

    func getVMStatus(vmId: String) async throws -> VMStatus {
        guard let agentId = vmToAgentMapping[vmId] else {
            throw AgentServiceError.vmNotMapped(vmId)
        }

        guard agents[agentId] != nil else {
            throw AgentServiceError.agentNotFound(agentId)
        }

        let message = VMOperationMessage(type: .vmStatus, vmId: vmId)
        let response = try await sendMessageToAgentWithResponse(message, agentId: agentId)

        guard case .success(let data) = response,
              let status = try? data?.decode(as: VMStatus.self) else {
            throw AgentServiceError.invalidResponse("Failed to decode VM status")
        }

        return status
    }

    // MARK: - Agent Selection

    /// Convert in-memory agents to schedulable format for the scheduler service
    private func getSchedulableAgents() -> [SchedulableAgent] {
        return agents.values.map { agentInfo in
            SchedulableAgent(
                id: agentInfo.id,       // UUID
                name: agentInfo.name,   // Human-readable name
                totalCPU: agentInfo.resources.totalCPU,
                availableCPU: agentInfo.resources.availableCPU,
                totalMemory: agentInfo.resources.totalMemory,
                availableMemory: agentInfo.resources.availableMemory,
                totalDisk: agentInfo.resources.totalDisk,
                availableDisk: agentInfo.resources.availableDisk,
                status: agentInfo.status,
                runningVMCount: vmToAgentMapping.values.filter { $0 == agentInfo.id }.count
            )
        }
    }

    /// Get VM-to-agent mapping (for diagnostics and recovery)
    func getVMToAgentMapping() -> [String: String] {
        return vmToAgentMapping
    }

    /// Manually set VM-to-agent mapping (for recovery scenarios)
    func setVMToAgentMapping(vmId: String, agentId: String) {
        vmToAgentMapping[vmId] = agentId
    }

    // MARK: - Message Sending

    private func sendMessageToAgent<T: WebSocketMessage>(_ message: T, agentId: String) async throws {
        // Look up agent info to get the name for WebSocket lookup
        guard let agentInfo = agents[agentId] else {
            throw AgentServiceError.agentNotFound(agentId)
        }

        guard let websocket = app.websocketManager.getConnection(agentName: agentInfo.name) else {
            throw AgentServiceError.agentNotFound(agentId)
        }

        let envelope = try MessageEnvelope(message: message)
        let data = try JSONEncoder().encode(envelope)

        websocket.send(data)
    }

    private func sendMessageToAgentWithResponse<T: WebSocketMessage>(_ message: T, agentId: String) async throws -> AgentServiceResponse {
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    // Store continuation for response handling
                    await storePendingRequest(message.requestId, continuation: continuation)

                    // Send message
                    try await sendMessageToAgent(message, agentId: agentId)

                    // Set timeout
                    Task {
                        try await Task.sleep(for: .seconds(30))
                        await timeoutRequest(message.requestId)
                    }
                } catch {
                    await removePendingRequest(message.requestId)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func storePendingRequest(_ requestId: String, continuation: CheckedContinuation<AgentServiceResponse, Error>) {
        pendingRequests[requestId] = continuation
    }

    private func removePendingRequest(_ requestId: String) -> CheckedContinuation<AgentServiceResponse, Error>? {
        return pendingRequests.removeValue(forKey: requestId)
    }

    private func timeoutRequest(_ requestId: String) {
        if let continuation = removePendingRequest(requestId) {
            continuation.resume(throwing: AgentServiceError.requestTimeout)
        }
    }

    // MARK: - Response Handling

    func handleAgentResponse(_ envelope: MessageEnvelope) {
        Task {
            guard let continuation = await removePendingRequest(envelope.payload.base64EncodedString()) else {
                return
            }

            do {
                switch envelope.type {
                case .success:
                    let message = try envelope.decode(as: SuccessMessage.self)
                    continuation.resume(returning: .success(message.data))
                case .error:
                    let message = try envelope.decode(as: ErrorMessage.self)
                    continuation.resume(returning: .error(message.error, message.details))
                default:
                    continuation.resume(throwing: AgentServiceError.invalidResponse("Unexpected response type"))
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Agent Status

    func getAgentList() -> [AgentInfo] {
        return Array(agents.values)
    }

    func getAgentInfo(_ agentId: String) -> AgentInfo? {
        return agents[agentId]
    }
}

// MARK: - Supporting Types

struct AgentInfo: Sendable {
    let id: String      // Database UUID
    let name: String    // Human-readable name
    let hostname: String
    let version: String
    let capabilities: [String]
    var resources: AgentResources
    var lastHeartbeat: Date
    var status: AgentStatus
}

enum AgentServiceResponse: Sendable {
    case success(AnyCodableValue?)
    case error(String, String?)
}

enum AgentServiceError: Error, LocalizedError, Sendable {
    case noAvailableAgent
    case agentNotFound(String)
    case vmNotMapped(String)
    case requestTimeout
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .noAvailableAgent:
            return "No available agent found for VM deployment"
        case .agentNotFound(let agentId):
            return "Agent not found: \(agentId)"
        case .vmNotMapped(let vmId):
            return "VM not mapped to any agent: \(vmId)"
        case .requestTimeout:
            return "Request to agent timed out"
        case .invalidResponse(let message):
            return "Invalid response from agent: \(message)"
        }
    }
}

// MARK: - Application Extension

extension Application {
    private struct WebSocketManagerKey: StorageKey {
        typealias Value = WebSocketManager
    }

    var websocketManager: WebSocketManager {
        get {
            if let existing = storage[WebSocketManagerKey.self] {
                return existing
            }
            let new = WebSocketManager()
            storage[WebSocketManagerKey.self] = new
            return new
        }
        set {
            storage[WebSocketManagerKey.self] = newValue
        }
    }

    private struct AgentServiceKey: StorageKey {
        typealias Value = AgentService
    }

    var agentService: AgentService {
        get {
            if let existing = storage[AgentServiceKey.self] {
                return existing
            }
            let new = AgentService(app: self)
            storage[AgentServiceKey.self] = new
            return new
        }
        set {
            storage[AgentServiceKey.self] = newValue
        }
    }
}

extension Request {
    var agentService: AgentService {
        return application.agentService
    }
}
