import Foundation
import Logging
import StratoAgentCore
import StratoShared

/// macOS network service implementation using user-mode (SLIRP) networking
/// OVN/OVS are not supported on macOS, so we use QEMU's built-in user-mode networking
actor NetworkServiceMacOS: NetworkServiceProtocol {
    private let logger: Logger
    private let maxMACGenerationAttempts = 100

    // Track VM network configurations for info queries, keyed by "<vmId>#<nicIndex>"
    private var vmNetworks: [String: VMNetworkInfo] = [:]
    private var logicalNetworks: [String: NetworkInfo] = [:]
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

    func createVMNetwork(vmId: String, nicIndex: Int, config: VMNetworkConfig) async throws -> VMNetworkInfo {
        logger.info(
            "Creating VM network with user-mode networking",
            metadata: ["vmId": .string(vmId), "nicIndex": .stringConvertible(nicIndex)])

        let macAddress = config.macAddress ?? generateMACAddress()

        // User-mode networking provides automatic DHCP: VMs get addresses in the
        // 10.0.2.0/24 range from QEMU's SLIRP, so no IP is allocated (or honored)
        // here — reporting one would just be fiction.
        let networkInfo = VMNetworkInfo(
            vmId: vmId,
            networkName: config.networkName,
            portName: "user-\(vmId)-\(nicIndex)",
            portUUID: nil,  // Not applicable for user-mode networking
            attachment: .userMode,
            macAddress: macAddress,
            ipAddress: nil
        )

        vmNetworks[Self.nicKey(vmId: vmId, nicIndex: nicIndex)] = networkInfo

        logger.info(
            "VM network created with user-mode networking",
            metadata: [
                "vmId": .string(vmId),
                "macAddress": .string(macAddress),
            ])

        return networkInfo
    }

    func attachVMToNetwork(vmId: String, networkName: String, macAddress: String? = nil) async throws -> VMNetworkInfo {
        let config = VMNetworkConfig(
            networkName: networkName,
            macAddress: macAddress,
            subnet: "10.0.2.0/24"  // QEMU user-mode default
        )
        return try await createVMNetwork(vmId: vmId, nicIndex: 0, config: config)
    }

    func detachVMFromNetwork(vmId: String, nicIndex: Int) async throws {
        logger.info(
            "Detaching VM from user-mode network",
            metadata: ["vmId": .string(vmId), "nicIndex": .stringConvertible(nicIndex)])
        vmNetworks.removeValue(forKey: Self.nicKey(vmId: vmId, nicIndex: nicIndex))
    }

    func getVMNetworkInfo(vmId: String) async throws -> VMNetworkInfo? {
        return vmNetworks[Self.nicKey(vmId: vmId, nicIndex: 0)]
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
            dnsServers: ["10.0.2.3"]  // QEMU user-mode DNS server
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

    private static func nicKey(vmId: String, nicIndex: Int) -> String {
        "\(vmId)#\(nicIndex)"
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
                macAddress = String(
                    format: "52:54:00:%02x:%02x:%02x",
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
