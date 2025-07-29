import Foundation
import Vapor
import StratoShared
import NIOWebSocket

actor AgentService {
    private let app: Application
    private var agents: [String: AgentInfo] = [:]
    private var vmToAgentMapping: [String: String] = [:] // VM ID -> Agent ID
    private var pendingRequests: [String: CheckedContinuation<AgentResponse, Error>] = [:]

    init(app: Application) {
        self.app = app
    }

    // MARK: - Agent Registration

    func registerAgent(_ message: AgentRegisterMessage, websocket: WebSocket) {
        let agentInfo = AgentInfo(
            id: message.agentId,
            hostname: message.hostname,
            version: message.version,
            capabilities: message.capabilities,
            resources: message.resources,
            websocket: websocket,
            lastHeartbeat: Date()
        )

        agents[message.agentId] = agentInfo
        app.logger.info("Agent registered", metadata: [
            "agentId": .string(message.agentId),
            "hostname": .string(message.hostname),
            "version": .string(message.version)
        ])
    }

    func unregisterAgent(_ agentId: String) {
        agents.removeValue(forKey: agentId)

        // Remove VM mappings for this agent
        let vmIds = vmToAgentMapping.compactMap { (vmId, mappedAgentId) in
            mappedAgentId == agentId ? vmId : nil
        }

        for vmId in vmIds {
            vmToAgentMapping.removeValue(forKey: vmId)
        }

        app.logger.info("Agent unregistered", metadata: ["agentId": .string(agentId)])
    }

    func updateAgentHeartbeat(_ message: AgentHeartbeatMessage) {
        guard var agentInfo = agents[message.agentId] else {
            app.logger.warning("Received heartbeat from unknown agent", metadata: ["agentId": .string(message.agentId)])
            return
        }

        agentInfo.resources = message.resources
        agentInfo.lastHeartbeat = Date()
        agents[message.agentId] = agentInfo

        app.logger.debug("Agent heartbeat updated", metadata: ["agentId": .string(message.agentId)])
    }

    // MARK: - VM Operations

    func createVM(vm: VM, vmConfig: VmConfig) async throws {
        // Select best agent for this VM
        guard let agentId = selectAgentForVM(vm: vm) else {
            throw AgentServiceError.noAvailableAgent
        }

        guard let agent = agents[agentId] else {
            throw AgentServiceError.agentNotFound(agentId)
        }

        let message = VMCreateMessage(
            vmData: vm.toVMData(),
            vmConfig: vmConfig
        )

        try await sendMessageToAgent(message, agent: agent)

        // Map VM to agent
        vmToAgentMapping[vm.id?.uuidString ?? ""] = agentId

        app.logger.info("VM creation requested", metadata: [
            "vmId": .string(vm.id?.uuidString ?? ""),
            "agentId": .string(agentId)
        ])
    }

    func performVMOperation(_ operation: MessageType, vmId: String) async throws {
        guard let agentId = vmToAgentMapping[vmId] else {
            throw AgentServiceError.vmNotMapped(vmId)
        }

        guard let agent = agents[agentId] else {
            throw AgentServiceError.agentNotFound(agentId)
        }

        let message = VMOperationMessage(type: operation, vmId: vmId)
        try await sendMessageToAgent(message, agent: agent)

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

        guard let agent = agents[agentId] else {
            throw AgentServiceError.agentNotFound(agentId)
        }

        let message = VMInfoRequestMessage(vmId: vmId)
        let response = try await sendMessageToAgentWithResponse(message, agent: agent)

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

        guard let agent = agents[agentId] else {
            throw AgentServiceError.agentNotFound(agentId)
        }

        let message = VMOperationMessage(type: .vmStatus, vmId: vmId)
        let response = try await sendMessageToAgentWithResponse(message, agent: agent)

        guard case .success(let data) = response,
              let status = try? data?.decode(as: VMStatus.self) else {
            throw AgentServiceError.invalidResponse("Failed to decode VM status")
        }

        return status
    }

    // MARK: - Agent Selection

    private func selectAgentForVM(vm: VM) -> String? {
        // Simple selection based on available resources
        // TODO: Implement more sophisticated selection logic

        let availableAgents = agents.values.filter { agent in
            agent.resources.availableCPU >= vm.cpu &&
            agent.resources.availableMemory >= vm.memory &&
            agent.resources.availableDisk >= vm.disk
        }

        // Select agent with most available resources
        return availableAgents.max { agent1, agent2 in
            (agent1.resources.availableCPU + Int(agent1.resources.availableMemory / 1024 / 1024 / 1024)) <
            (agent2.resources.availableCPU + Int(agent2.resources.availableMemory / 1024 / 1024 / 1024))
        }?.id
    }

    // MARK: - Message Sending

    private func sendMessageToAgent<T: WebSocketMessage>(_ message: T, agent: AgentInfo) async throws {
        let envelope = try MessageEnvelope(message: message)
        let data = try JSONEncoder().encode(envelope)

        try await agent.websocket.send(data)
    }

    private func sendMessageToAgentWithResponse<T: WebSocketMessage>(_ message: T, agent: AgentInfo) async throws -> AgentResponse {
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    // Store continuation for response handling
                    await storePendingRequest(message.requestId, continuation: continuation)

                    // Send message
                    try await sendMessageToAgent(message, agent: agent)

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

    private func storePendingRequest(_ requestId: String, continuation: CheckedContinuation<AgentResponse, Error>) {
        pendingRequests[requestId] = continuation
    }

    private func removePendingRequest(_ requestId: String) -> CheckedContinuation<AgentResponse, Error>? {
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

struct AgentInfo {
    let id: String
    let hostname: String
    let version: String
    let capabilities: [String]
    var resources: AgentResources
    let websocket: WebSocket
    var lastHeartbeat: Date
}

enum AgentResponse {
    case success(AnyCodableValue?)
    case error(String, String?)
}

enum AgentServiceError: Error, LocalizedError {
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
