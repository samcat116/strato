import Foundation
import Logging
import StratoShared

class CloudHypervisorService {
    private let socketPath: String
    private let logger: Logger
    
    init(socketPath: String, logger: Logger) {
        self.socketPath = socketPath
        self.logger = logger
    }
    
    // MARK: - VM Lifecycle Operations
    
    func createVM(config: VmConfig) async throws {
        let url = "/vm.create"
        
        _ = try await makeRequest(
            method: "PUT",
            path: url,
            body: config
        )
    }
    
    func bootVM() async throws {
        let url = "/vm.boot"
        
        _ = try await makeRequest(
            method: "PUT",
            path: url,
            body: EmptyBody()
        )
    }
    
    func shutdownVM() async throws {
        let url = "/vm.shutdown"
        
        _ = try await makeRequest(
            method: "PUT",
            path: url,
            body: EmptyBody()
        )
    }
    
    func rebootVM() async throws {
        let url = "/vm.reboot"
        
        _ = try await makeRequest(
            method: "PUT",
            path: url,
            body: EmptyBody()
        )
    }
    
    func pauseVM() async throws {
        let url = "/vm.pause"
        
        _ = try await makeRequest(
            method: "PUT",
            path: url,
            body: EmptyBody()
        )
    }
    
    func resumeVM() async throws {
        let url = "/vm.resume"
        
        _ = try await makeRequest(
            method: "PUT",
            path: url,
            body: EmptyBody()
        )
    }
    
    func deleteVM() async throws {
        let url = "/vm.delete"
        
        _ = try await makeRequest(
            method: "PUT",
            path: url,
            body: EmptyBody()
        )
    }
    
    // MARK: - VM Information
    
    func getVMInfo() async throws -> VmInfo {
        let url = "/vm.info"
        
        let response = try await makeRequest(
            method: "GET",
            path: url,
            body: EmptyBody()
        )
        
        return try JSONDecoder().decode(VmInfo.self, from: response)
    }
    
    func getVMCounters() async throws -> VmCounters {
        let url = "/vm.counters"
        
        let response = try await makeRequest(
            method: "GET",
            path: url,
            body: EmptyBody()
        )
        
        return try JSONDecoder().decode(VmCounters.self, from: response)
    }
    
    // MARK: - VMM Operations
    
    func pingVMM() async throws -> VmmPingResponse {
        let url = "/vmm.ping"
        
        let response = try await makeRequest(
            method: "GET",
            path: url,
            body: EmptyBody()
        )
        
        return try JSONDecoder().decode(VmmPingResponse.self, from: response)
    }
    
    func shutdownVMM() async throws {
        let url = "/vmm.shutdown"
        
        _ = try await makeRequest(
            method: "PUT",
            path: url,
            body: EmptyBody()
        )
    }
    
    func syncVMStatus() async throws -> VMStatus {
        do {
            let info = try await getVMInfo()
            switch info.state.lowercased() {
            case "created":
                return .created
            case "running":
                return .running
            case "shutdown":
                return .shutdown
            case "paused":
                return .paused
            default:
                return .shutdown
            }
        } catch {
            // If we can't get VM info, assume it's shutdown
            return .shutdown
        }
    }
    
    // MARK: - VM Management Helpers
    
    func createAndStartVM(config: VmConfig) async throws {
        // Create VM
        try await createVM(config: config)
        
        // Boot VM
        try await bootVM()
    }
    
    func stopAndDeleteVM() async throws {
        do {
            // Try graceful shutdown first
            try await shutdownVM()
        } catch {
            // If shutdown fails, force delete
            logger.warning("VM shutdown failed, forcing delete: \(error)")
        }
        
        // Delete VM
        try await deleteVM()
    }
    
    // MARK: - Private HTTP Communication
    
    private func makeRequest<T: Codable>(
        method: String,
        path: String,
        body: T
    ) async throws -> Data {
        // For now, simulate the API call
        // In a real implementation, we would use unix domain socket HTTP client
        logger.info("CloudHypervisor API call: \(method) \(path)")
        
        // Simulate success response
        if method == "GET" {
            let mockResponse = "{\"state\": \"Created\"}"
            return mockResponse.data(using: .utf8) ?? Data()
        } else {
            // For PUT requests, return empty success
            return Data()
        }
    }
}

// MARK: - Empty Body for Requests Without Payload

private struct EmptyBody: Codable {}