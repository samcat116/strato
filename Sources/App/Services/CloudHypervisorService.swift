import Foundation
import Vapor

struct CloudHypervisorService {
    private let app: Application
    private let socketPath: String
    
    init(app: Application, socketPath: String) {
        self.app = app
        self.socketPath = socketPath
    }
    
    // MARK: - VM Lifecycle Operations
    
    func createVM(config: VmConfig) async throws {
        let url = "/vm.create"
        
        _ = try await makeRequest(
            method: .PUT,
            path: url,
            body: config
        )
    }
    
    func bootVM() async throws {
        let url = "/vm.boot"
        
        _ = try await makeRequest(
            method: .PUT,
            path: url,
            body: EmptyBody()
        )
    }
    
    func shutdownVM() async throws {
        let url = "/vm.shutdown"
        
        _ = try await makeRequest(
            method: .PUT,
            path: url,
            body: EmptyBody()
        )
    }
    
    func rebootVM() async throws {
        let url = "/vm.reboot"
        
        _ = try await makeRequest(
            method: .PUT,
            path: url,
            body: EmptyBody()
        )
    }
    
    func pauseVM() async throws {
        let url = "/vm.pause"
        
        _ = try await makeRequest(
            method: .PUT,
            path: url,
            body: EmptyBody()
        )
    }
    
    func resumeVM() async throws {
        let url = "/vm.resume"
        
        _ = try await makeRequest(
            method: .PUT,
            path: url,
            body: EmptyBody()
        )
    }
    
    func deleteVM() async throws {
        let url = "/vm.delete"
        
        _ = try await makeRequest(
            method: .PUT,
            path: url,
            body: EmptyBody()
        )
    }
    
    // MARK: - VM Information
    
    func getVMInfo() async throws -> VmInfo {
        let url = "/vm.info"
        
        let response = try await makeRequest(
            method: .GET,
            path: url,
            body: EmptyBody()
        )
        
        return try JSONDecoder().decode(VmInfo.self, from: response)
    }
    
    func getVMCounters() async throws -> VmCounters {
        let url = "/vm.counters"
        
        let response = try await makeRequest(
            method: .GET,
            path: url,
            body: EmptyBody()
        )
        
        return try JSONDecoder().decode(VmCounters.self, from: response)
    }
    
    // MARK: - VMM Operations
    
    func pingVMM() async throws -> VmmPingResponse {
        let url = "/vmm.ping"
        
        let response = try await makeRequest(
            method: .GET,
            path: url,
            body: EmptyBody()
        )
        
        return try JSONDecoder().decode(VmmPingResponse.self, from: response)
    }
    
    func shutdownVMM() async throws {
        let url = "/vmm.shutdown"
        
        _ = try await makeRequest(
            method: .PUT,
            path: url,
            body: EmptyBody()
        )
    }
    
    // MARK: - VM Configuration Builders
    
    func buildVMConfig(from vm: VM, template: VMTemplate) async throws -> VmConfig {
        // Payload configuration
        let payload = PayloadConfig(
            firmware: vm.firmwarePath ?? template.firmwarePath,
            kernel: vm.kernelPath ?? template.kernelPath,
            cmdline: vm.cmdline ?? template.defaultCmdline,
            initramfs: vm.initramfsPath ?? template.initramfsPath
        )
        
        // CPU configuration
        let cpus = CpusConfig(
            bootVcpus: vm.cpu,
            maxVcpus: vm.maxCpu,
            kvmHyperv: false
        )
        
        // Memory configuration
        let memory = MemoryConfig(
            size: vm.memory,
            mergeable: false,
            shared: vm.sharedMemory,
            hugepages: vm.hugepages,
            thp: true
        )
        
        // Disk configuration
        var disks: [DiskConfig] = []
        if let diskPath = vm.diskPath {
            let disk = DiskConfig(
                path: diskPath,
                readonly: vm.readonlyDisk,
                direct: false,
                id: "disk0"
            )
            disks.append(disk)
        }
        
        // Network configuration
        var networks: [NetConfig] = []
        if let macAddress = vm.macAddress {
            let network = NetConfig(
                ip: vm.ipAddress ?? "192.168.249.1",
                mask: vm.networkMask ?? "255.255.255.0",
                mac: macAddress,
                numQueues: 2,
                queueSize: 256,
                id: "net0"
            )
            networks.append(network)
        }
        
        // Console configuration
        let console = ConsoleConfig(
            socket: vm.consoleSocket,
            mode: vm.consoleMode.rawValue
        )
        
        let serial = ConsoleConfig(
            socket: vm.serialSocket,
            mode: vm.serialMode.rawValue
        )
        
        // RNG configuration
        let rng = RngConfig(src: "/dev/urandom")
        
        return VmConfig(
            cpus: cpus,
            memory: memory,
            payload: payload,
            disks: disks.isEmpty ? nil : disks,
            net: networks.isEmpty ? nil : networks,
            rng: rng,
            serial: serial,
            console: console,
            iommu: false,
            watchdog: false,
            pvpanic: false
        )
    }
    
    // MARK: - VM Management Helpers
    
    func createAndStartVM(vm: VM, template: VMTemplate) async throws {
        let config = try await buildVMConfig(from: vm, template: template)
        
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
            app.logger.warning("VM shutdown failed, forcing delete: \(error)")
        }
        
        // Delete VM
        try await deleteVM()
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
    
    // MARK: - Private HTTP Communication
    
    private func makeRequest<T: Content>(
        method: HTTPMethod,
        path: String,
        body: T
    ) async throws -> Data {
        // For now, simulate the API call
        // In a real implementation, we would use unix domain socket HTTP client
        app.logger.info("CloudHypervisor API call: \(method) \(path)")
        
        // Simulate success response
        if method == .GET {
            let mockResponse = "{\"state\": \"Created\"}"
            return mockResponse.data(using: .utf8) ?? Data()
        } else {
            // For PUT requests, return empty success
            return Data()
        }
    }
}

// MARK: - Empty Body for Requests Without Payload

private struct EmptyBody: Content {}

// MARK: - Application Extension

extension Application {
    var cloudHypervisor: CloudHypervisorService {
        guard let socketPath = Environment.get("CLOUD_HYPERVISOR_SOCKET") else {
            fatalError("CLOUD_HYPERVISOR_SOCKET environment variable is required")
        }
        return CloudHypervisorService(app: self, socketPath: socketPath)
    }
}

extension Request {
    var cloudHypervisor: CloudHypervisorService {
        return self.application.cloudHypervisor
    }
}