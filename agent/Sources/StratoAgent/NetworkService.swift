import Foundation
import Logging
import StratoShared

#if os(Linux)
import SwiftOVN
#endif

class NetworkService {
    private let logger: Logger
    private let ovnSocketPath: String
    private let ovsSocketPath: String
    
    #if os(Linux)
    private var ovnManager: SwiftOVN?
    private var ovsManager: OVSManager?
    private var isConnected = false
    #else
    // Development mode on macOS - mock network storage
    private var mockNetworks: [String: MockNetwork] = [:]
    private var mockVMNetworks: [String: MockVMNetworkAttachment] = [:]
    #endif
    
    init(
        ovnSocketPath: String = "/var/run/ovn/ovnnb_db.sock",
        ovsSocketPath: String = "/var/run/openvswitch/db.sock",
        logger: Logger
    ) {
        self.ovnSocketPath = ovnSocketPath
        self.ovsSocketPath = ovsSocketPath
        self.logger = logger
        
        #if os(Linux)
        logger.info("Network service initialized with SwiftOVN support")
        #else
        logger.warning("Network service running in development mode - operations will be mocked")
        #endif
    }
    
    // MARK: - Connection Management
    
    func connect() async throws {
        #if os(Linux)
        logger.info("Connecting to OVN/OVS services")
        
        // Initialize OVN manager
        ovnManager = SwiftOVN(socketPath: ovnSocketPath)
        try await ovnManager?.connect()
        logger.info("Connected to OVN database", metadata: ["socket": .string(ovnSocketPath)])
        
        // Initialize OVS manager
        ovsManager = OVSManager(socketPath: ovsSocketPath)
        try await ovsManager?.connect()
        logger.info("Connected to OVS database", metadata: ["socket": .string(ovsSocketPath)])
        
        // Ensure integration bridge exists
        try await ensureIntegrationBridge()
        
        isConnected = true
        logger.info("Network service connected successfully")
        #else
        logger.info("Mock network service connected (development mode)")
        #endif
    }
    
    func disconnect() async {
        #if os(Linux)
        logger.info("Disconnecting from OVN/OVS services")
        
        await ovnManager?.disconnect()
        await ovsManager?.disconnect()
        
        ovnManager = nil
        ovsManager = nil
        isConnected = false
        
        logger.info("Network service disconnected")
        #else
        logger.info("Mock network service disconnected (development mode)")
        #endif
    }
    
    // MARK: - VM Network Lifecycle
    
    func createVMNetwork(vmId: String, config: VMNetworkConfig) async throws -> VMNetworkInfo {
        #if os(Linux)
        guard isConnected else {
            throw NetworkError.notConnected("Network service is not connected")
        }
        
        logger.info("Creating VM network", metadata: ["vmId": .string(vmId)])
        
        // Create logical switch port for the VM
        let portName = "vm-\(vmId)"
        let macAddress = config.macAddress ?? generateMACAddress()
        let ipAddress = config.ipAddress ?? await allocateIPAddress(for: config.networkName)
        
        let logicalPort = OVNLogicalSwitchPort(
            name: portName,
            addresses: ["\(macAddress) \(ipAddress)"],
            port_security: ["\(macAddress) \(ipAddress)"],
            external_ids: [
                "vm-id": vmId,
                "description": "VM network interface"
            ]
        )
        
        // Find or create the logical switch
        let switchUUID = try await findOrCreateLogicalSwitch(name: config.networkName, subnet: config.subnet)
        
        // Create the logical switch port
        let portUUID = try await ovnManager?.createLogicalSwitchPort(logicalPort, on: switchUUID)
        
        // Create TAP interface and connect to OVS bridge
        let tapInterface = try await createTAPInterface(vmId: vmId)
        try await attachTAPToBridge(tapInterface: tapInterface, portName: portName)
        
        let networkInfo = VMNetworkInfo(
            vmId: vmId,
            networkName: config.networkName,
            portName: portName,
            portUUID: portUUID?.uuidString,
            tapInterface: tapInterface,
            macAddress: macAddress,
            ipAddress: ipAddress
        )
        
        logger.info("VM network created successfully", metadata: [
            "vmId": .string(vmId),
            "portName": .string(portName),
            "tapInterface": .string(tapInterface)
        ])
        
        return networkInfo
        #else
        // Development mode
        logger.info("Creating mock VM network (development mode)", metadata: ["vmId": .string(vmId)])
        
        let mockAttachment = MockVMNetworkAttachment(
            vmId: vmId,
            networkName: config.networkName,
            macAddress: config.macAddress ?? "02:00:00:00:00:01",
            ipAddress: config.ipAddress ?? "192.168.1.100"
        )
        mockVMNetworks[vmId] = mockAttachment
        
        return VMNetworkInfo(
            vmId: vmId,
            networkName: config.networkName,
            portName: "mock-vm-\(vmId)",
            portUUID: UUID().uuidString,
            tapInterface: "tap-\(vmId)",
            macAddress: mockAttachment.macAddress,
            ipAddress: mockAttachment.ipAddress
        )
        #endif
    }
    
    func attachVMToNetwork(vmId: String, networkName: String, macAddress: String? = nil) async throws -> VMNetworkInfo {
        let config = VMNetworkConfig(
            networkName: networkName,
            macAddress: macAddress,
            subnet: "192.168.1.0/24" // Default subnet, should be configurable
        )
        return try await createVMNetwork(vmId: vmId, config: config)
    }
    
    func detachVMFromNetwork(vmId: String) async throws {
        #if os(Linux)
        guard isConnected else {
            throw NetworkError.notConnected("Network service is not connected")
        }
        
        logger.info("Detaching VM from network", metadata: ["vmId": .string(vmId)])
        
        let portName = "vm-\(vmId)"
        
        // Remove logical switch port
        if let ovnManager = ovnManager {
            try await ovnManager.deleteLogicalSwitchPort(name: portName)
        }
        
        // Remove TAP interface
        let tapInterface = "tap-\(vmId)"
        try await removeTAPInterface(tapInterface)
        
        logger.info("VM detached from network successfully", metadata: ["vmId": .string(vmId)])
        #else
        // Development mode
        logger.info("Detaching mock VM from network (development mode)", metadata: ["vmId": .string(vmId)])
        mockVMNetworks.removeValue(forKey: vmId)
        #endif
    }
    
    func getVMNetworkInfo(vmId: String) async throws -> VMNetworkInfo? {
        #if os(Linux)
        guard isConnected else {
            throw NetworkError.notConnected("Network service is not connected")
        }
        
        // Query OVN for the VM's network configuration
        // This would involve looking up the logical switch port by VM ID
        // For now, return nil if not found
        return nil
        #else
        // Development mode
        if let mockAttachment = mockVMNetworks[vmId] {
            return VMNetworkInfo(
                vmId: vmId,
                networkName: mockAttachment.networkName,
                portName: "mock-vm-\(vmId)",
                portUUID: UUID().uuidString,
                tapInterface: "tap-\(vmId)",
                macAddress: mockAttachment.macAddress,
                ipAddress: mockAttachment.ipAddress
            )
        }
        return nil
        #endif
    }
    
    // MARK: - Network Topology Management
    
    func createLogicalNetwork(name: String, subnet: String, gateway: String? = nil) async throws -> UUID {
        #if os(Linux)
        guard let ovnManager = ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        
        logger.info("Creating logical network", metadata: ["name": .string(name), "subnet": .string(subnet)])
        
        let logicalSwitch = OVNLogicalSwitch(
            name: name,
            external_ids: [
                "subnet": subnet,
                "gateway": gateway ?? "",
                "description": "Strato managed network"
            ]
        )
        
        let switchUUID = try await ovnManager.createLogicalSwitch(logicalSwitch)
        
        // Configure DHCP if needed
        if let gateway = gateway {
            try await configureDHCP(switchUUID: switchUUID, subnet: subnet, gateway: gateway)
        }
        
        logger.info("Logical network created successfully", metadata: ["name": .string(name), "uuid": .string(switchUUID.uuidString)])
        
        return switchUUID
        #else
        // Development mode
        logger.info("Creating mock logical network (development mode)", metadata: ["name": .string(name)])
        let mockNetwork = MockNetwork(name: name, subnet: subnet, gateway: gateway)
        mockNetworks[name] = mockNetwork
        return UUID()
        #endif
    }
    
    func deleteLogicalNetwork(name: String) async throws {
        #if os(Linux)
        guard let ovnManager = ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        
        logger.info("Deleting logical network", metadata: ["name": .string(name)])
        
        try await ovnManager.deleteLogicalSwitch(name: name)
        
        logger.info("Logical network deleted successfully", metadata: ["name": .string(name)])
        #else
        // Development mode
        logger.info("Deleting mock logical network (development mode)", metadata: ["name": .string(name)])
        mockNetworks.removeValue(forKey: name)
        #endif
    }
    
    func listLogicalNetworks() async throws -> [NetworkInfo] {
        #if os(Linux)
        guard let ovnManager = ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        
        // Query OVN for all logical switches
        // This would involve calling ovnManager to list switches
        return []
        #else
        // Development mode
        return mockNetworks.values.map { mockNetwork in
            NetworkInfo(
                name: mockNetwork.name,
                uuid: UUID().uuidString,
                subnet: mockNetwork.subnet,
                gateway: mockNetwork.gateway
            )
        }
        #endif
    }
    
    // MARK: - Private Helper Methods
    
    #if os(Linux)
    private func ensureIntegrationBridge() async throws {
        guard let ovsManager = ovsManager else {
            throw NetworkError.notConnected("OVS manager not connected")
        }
        
        // Check if br-int exists, create if not
        let bridgeName = "br-int"
        
        let integrationBridge = OVSBridge(
            name: bridgeName,
            fail_mode: "secure",
            protocols: ["OpenFlow13"],
            external_ids: ["description": "OVN integration bridge"]
        )
        
        do {
            let _ = try await ovsManager.createBridge(integrationBridge)
            logger.info("Created integration bridge", metadata: ["bridge": .string(bridgeName)])
        } catch {
            // Bridge might already exist, which is fine
            logger.debug("Integration bridge already exists or creation failed", metadata: ["error": .string(error.localizedDescription)])
        }
    }
    
    private func findOrCreateLogicalSwitch(name: String, subnet: String) async throws -> UUID {
        guard let ovnManager = ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        
        // Try to find existing switch first
        // For now, create new switch - this should be enhanced to check for existing switches
        let logicalSwitch = OVNLogicalSwitch(
            name: name,
            external_ids: [
                "subnet": subnet,
                "description": "Auto-created network for VM"
            ]
        )
        
        return try await ovnManager.createLogicalSwitch(logicalSwitch)
    }
    
    private func createTAPInterface(vmId: String) async throws -> String {
        let tapName = "tap-\(vmId)"
        
        // Create TAP interface using system commands
        // This is a simplified implementation - production would use more robust interface creation
        logger.debug("Creating TAP interface", metadata: ["tapName": .string(tapName)])
        
        return tapName
    }
    
    private func attachTAPToBridge(tapInterface: String, portName: String) async throws {
        guard let ovsManager = ovsManager else {
            throw NetworkError.notConnected("OVS manager not connected")
        }
        
        // Add TAP interface to OVS bridge
        let port = OVSPort(
            name: tapInterface,
            external_ids: [
                "ovn-port-name": portName,
                "description": "TAP interface for VM"
            ]
        )
        
        try await ovsManager.addPortToBridge(port: port, bridge: "br-int")
        logger.debug("Attached TAP interface to bridge", metadata: ["tap": .string(tapInterface), "port": .string(portName)])
    }
    
    private func removeTAPInterface(_ tapInterface: String) async throws {
        // Remove TAP interface from system
        logger.debug("Removing TAP interface", metadata: ["tapName": .string(tapInterface)])
    }
    
    private func generateMACAddress() -> String {
        // Generate a random MAC address with the locally administered bit set
        let bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        var macBytes = bytes
        macBytes[0] = (macBytes[0] & 0xFC) | 0x02 // Set locally administered bit
        
        return macBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
    
    private func allocateIPAddress(for networkName: String) async -> String {
        // Simple IP allocation - in production, this would query DHCP or maintain IP pools
        return "192.168.1.\(Int.random(in: 100...200))"
    }
    
    private func configureDHCP(switchUUID: UUID, subnet: String, gateway: String) async throws {
        // Configure OVN DHCP for the logical switch
        logger.debug("Configuring DHCP for network", metadata: ["subnet": .string(subnet), "gateway": .string(gateway)])
    }
    #endif
}

// MARK: - Development Mode Mock Types

#if !os(Linux)
private struct MockNetwork {
    let name: String
    let subnet: String
    let gateway: String?
}

private struct MockVMNetworkAttachment {
    let vmId: String
    let networkName: String
    let macAddress: String
    let ipAddress: String
}
#endif

// MARK: - Network Error Types

enum NetworkError: Error, LocalizedError {
    case notConnected(String)
    case networkNotFound(String)
    case invalidConfiguration(String)
    case ovnError(String)
    case ovsError(String)
    
    var errorDescription: String? {
        switch self {
        case .notConnected(let message):
            return "Network service not connected: \(message)"
        case .networkNotFound(let name):
            return "Network not found: \(name)"
        case .invalidConfiguration(let message):
            return "Invalid network configuration: \(message)"
        case .ovnError(let message):
            return "OVN error: \(message)"
        case .ovsError(let message):
            return "OVS error: \(message)"
        }
    }
}