import Foundation
import Logging
import StratoShared

/// macOS network service implementation using user-mode (SLIRP) networking
/// OVN/OVS are not supported on macOS, so we use QEMU's built-in user-mode networking
actor NetworkServiceMacOS: NetworkServiceProtocol {
    private let logger: Logger
    private let maxMACGenerationAttempts = 100

    // Track VM network configurations for info queries
    private var vmNetworks: [String: VMNetworkInfo] = [:]
    private var logicalNetworks: [String: NetworkInfo] = [:]
    private var nextIPSuffix: UInt8 = 15 // Start from 10.0.2.15 (QEMU default)
    private var usedMACs: Set<String> = []

    init(logger: Logger) {
        self.logger = logger
        logger.info("Network service initialized with user-mode (SLIRP) networking for macOS")
    }

    // MARK: - Connection Management

    func connect() async throws {
        logger.info("User-mode network service ready (no external service required)")
    }

    func disconnect() async {
        logger.info("User-mode network service disconnected")
        vmNetworks.removeAll()
        logicalNetworks.removeAll()
    }

    // MARK: - VM Network Lifecycle

    func createVMNetwork(vmId: String, config: VMNetworkConfig) async throws -> VMNetworkInfo {
        logger.info("Creating VM network with user-mode networking", metadata: ["vmId": .string(vmId)])

        let macAddress = config.macAddress ?? generateMACAddress()

        // User-mode networking provides automatic DHCP
        // VMs get IP addresses in the 10.0.2.0/24 range (QEMU default)
        // Allocate unique IPs for tracking purposes (actual IPs assigned by QEMU)
        let ipAddress = config.ipAddress ?? allocateNextIP()

        let networkInfo = VMNetworkInfo(
            vmId: vmId,
            networkName: config.networkName,
            portName: "user-\(vmId)",
            portUUID: nil, // Not applicable for user-mode networking
            tapInterface: "n/a", // User-mode doesn't use TAP
            macAddress: macAddress,
            ipAddress: ipAddress
        )

        vmNetworks[vmId] = networkInfo

        logger.info("VM network created with user-mode networking", metadata: [
            "vmId": .string(vmId),
            "macAddress": .string(macAddress),
            "ipAddress": .string(ipAddress)
        ])

        return networkInfo
    }

    func attachVMToNetwork(vmId: String, networkName: String, macAddress: String? = nil) async throws -> VMNetworkInfo {
        let config = VMNetworkConfig(
            networkName: networkName,
            macAddress: macAddress,
            subnet: "10.0.2.0/24" // QEMU user-mode default
        )
        return try await createVMNetwork(vmId: vmId, config: config)
    }

    func detachVMFromNetwork(vmId: String) async throws {
        logger.info("Detaching VM from user-mode network", metadata: ["vmId": .string(vmId)])
        vmNetworks.removeValue(forKey: vmId)
        logger.info("VM detached from network", metadata: ["vmId": .string(vmId)])
    }

    func getVMNetworkInfo(vmId: String) async throws -> VMNetworkInfo? {
        return vmNetworks[vmId]
    }

    // MARK: - Network Topology Management

    func createLogicalNetwork(name: String, subnet: String, gateway: String? = nil) async throws -> UUID {
        logger.info("Creating logical network (user-mode simulation)", metadata: ["name": .string(name)])

        let networkUUID = UUID()
        let networkInfo = NetworkInfo(
            name: name,
            uuid: networkUUID.uuidString,
            subnet: subnet,
            gateway: gateway,
            dhcpEnabled: true,
            dnsServers: ["10.0.2.3"] // QEMU user-mode DNS server
        )

        logicalNetworks[name] = networkInfo

        logger.info("Logical network created (simulated)", metadata: ["name": .string(name)])
        logger.warning("Note: User-mode networking on macOS provides limited network isolation")

        return networkUUID
    }

    func deleteLogicalNetwork(name: String) async throws {
        logger.info("Deleting logical network (user-mode simulation)", metadata: ["name": .string(name)])
        logicalNetworks.removeValue(forKey: name)
        logger.info("Logical network deleted", metadata: ["name": .string(name)])
    }

    func listLogicalNetworks() async throws -> [NetworkInfo] {
        return Array(logicalNetworks.values)
    }

    // MARK: - Helper Methods

    private func allocateNextIP() -> String {
        // Allocate sequential IPs starting from 10.0.2.15
        // Note: This is for informational/tracking purposes only.
        // QEMU's SLIRP will assign actual IPs via DHCP
        let ip = "10.0.2.\(nextIPSuffix)"
        nextIPSuffix += 1
        if nextIPSuffix > 254 {
            nextIPSuffix = 15 // Wrap around, skip network/broadcast
        }
        return ip
    }

    private func generateMACAddress() -> String {
        // Generate a unique MAC address with collision detection
        // Use QEMU's OUI (52:54:00) for better compatibility
        var macAddress: String
        var attempts = 0
        
        repeat {
            let bytes = (0..<3).map { _ in UInt8.random(in: 0...255) }
            macAddress = "52:54:00:" + bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
            attempts += 1
            
            if attempts > maxMACGenerationAttempts {
                // Fallback to deterministic MAC if we can't find a unique one
                let timestamp = UInt32(Date().timeIntervalSince1970)
                macAddress = String(format: "52:54:00:%02x:%02x:%02x", 
                                   UInt8(timestamp >> 16 & 0xFF),
                                   UInt8(timestamp >> 8 & 0xFF),
                                   UInt8(timestamp & 0xFF))
                break
            }
        } while usedMACs.contains(macAddress)
        
        usedMACs.insert(macAddress)
        return macAddress
    }
}
