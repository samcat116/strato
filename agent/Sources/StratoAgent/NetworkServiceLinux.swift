import Foundation
import Logging
import StratoShared
import StratoAgentCore

#if os(Linux)
import SwiftOVN
#endif

actor NetworkServiceLinux: NetworkServiceProtocol {
    private let logger: Logger
    private let ovnSocketPath: String
    private let ovsSocketPath: String
    
    #if os(Linux)
    private var ovnManager: OVNManager?
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
    
    /// Bridge that OVN's `ovn-controller` binds VM ports onto.
    static let ovnIntegrationBridge = "br-int"

    /// Bound on `ovs-vsctl` so a config change can't hang the network actor
    /// forever when `ovs-vswitchd` is down/overloaded (the default waits forever).
    static let ovsCommandTimeoutSeconds = 10

    // MARK: - Connection Management

    func connect() async throws {
        #if os(Linux)
        logger.info("Connecting to OVN/OVS services")
        
        // Initialize OVN manager
        ovnManager = OVNManager(socketPath: ovnSocketPath, logger: logger)
        try await ovnManager?.connect()
        logger.info("Connected to OVN database", metadata: ["socket": .string(ovnSocketPath)])
        
        // Initialize OVS manager
        ovsManager = OVSManager(socketPath: ovsSocketPath, logger: logger)
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
        
        do {
            try await ovnManager?.disconnect()
            try await ovsManager?.disconnect()
        } catch {
            logger.error("Error disconnecting from OVN/OVS: \(error)")
        }
        
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
        var macAddress = config.macAddress ?? generateMACAddress()
        var ipAddress: String
        if let configIP = config.ipAddress {
            ipAddress = configIP
        } else {
            ipAddress = await allocateIPAddress(for: config.networkName)
        }

        // Find or create the logical switch
        _ = try await findOrCreateLogicalSwitch(name: config.networkName, subnet: config.subnet ?? "10.0.0.0/24")

        // Create the logical switch port (idempotent: reuse on re-attach)
        let portUUID: String?
        if let existingPort = try await ovnManager?.getLogicalSwitchPort(named: portName) {
            portUUID = existingPort.uuid
            // Reuse the existing port's allowed addresses so the VM boots with a
            // MAC/IP that matches OVN's port_security. Otherwise a recovery path
            // (agent restart, or retry after a failed TAP/OVS step) would launch
            // QEMU with freshly generated addresses and OVN would drop its traffic.
            let (existingMAC, existingIP) = Self.parsePortAddress(existingPort.addresses)
            if !existingMAC.isEmpty { macAddress = existingMAC }
            if !existingIP.isEmpty { ipAddress = existingIP }
            logger.debug("Reusing existing logical switch port", metadata: [
                "portName": .string(portName),
                "macAddress": .string(macAddress),
                "ipAddress": .string(ipAddress)
            ])
        } else {
            let logicalPort = OVNLogicalSwitchPort(
                name: portName,
                addresses: ["\(macAddress) \(ipAddress)"],
                port_security: ["\(macAddress) \(ipAddress)"],
                external_ids: [
                    "vm-id": vmId,
                    "network-name": config.networkName,
                    "description": "VM network interface"
                ]
            )
            portUUID = try await ovnManager?.createLogicalSwitchPort(logicalPort)
        }
        
        // Create TAP interface and connect to OVS bridge
        let tapInterface = try await createTAPInterface(vmId: vmId)
        try await attachTAPToBridge(tapInterface: tapInterface, portName: portName)
        
        let networkInfo = VMNetworkInfo(
            vmId: vmId,
            networkName: config.networkName,
            portName: portName,
            portUUID: portUUID,
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
        let tapInterface = tapInterfaceName(for: vmId)

        // Remove logical switch port (OVN northbound). Tolerate absence so a
        // partially-torn-down VM still has its OVS port and TAP cleaned up.
        if let ovnManager = ovnManager {
            do {
                try await ovnManager.deleteLogicalSwitchPort(named: portName)
            } catch {
                logger.warning("Failed to delete logical switch port", metadata: [
                    "portName": .string(portName),
                    "error": .string(error.localizedDescription)
                ])
            }
        }

        // Detach the TAP from the integration bridge (idempotent via --if-exists)
        do {
            try run("ovs-vsctl", [
                "--timeout=\(Self.ovsCommandTimeoutSeconds)",
                "--if-exists", "del-port", Self.ovnIntegrationBridge, tapInterface
            ])
        } catch {
            logger.warning("Failed to remove OVS port", metadata: [
                "tapInterface": .string(tapInterface),
                "error": .string(error.localizedDescription)
            ])
        }

        // Remove the kernel TAP device
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
        guard isConnected, let ovnManager = ovnManager else {
            throw NetworkError.notConnected("Network service is not connected")
        }

        let portName = "vm-\(vmId)"
        guard let port = try await ovnManager.getLogicalSwitchPort(named: portName) else {
            return nil
        }

        // OVN addresses are entries like "<mac> <ip>" (or just "<mac>", or "dynamic").
        let (macAddress, ipAddress) = Self.parsePortAddress(port.addresses)

        return VMNetworkInfo(
            vmId: vmId,
            networkName: port.external_ids?["network-name"] ?? "default",
            portName: portName,
            portUUID: port.uuid,
            tapInterface: tapInterfaceName(for: vmId),
            macAddress: macAddress,
            ipAddress: ipAddress
        )
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
        guard ovnManager != nil else {
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
        
        let switchUUIDString = try await ovnManager!.createLogicalSwitch(logicalSwitch)
        
        guard let switchUUID = UUID(uuidString: switchUUIDString) else {
            throw NetworkError.invalidConfiguration("Invalid UUID returned from OVN: \(switchUUIDString)")
        }
        
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
        guard ovnManager != nil else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        
        logger.info("Deleting logical network", metadata: ["name": .string(name)])
        
        try await ovnManager!.deleteLogicalSwitch(named: name)
        
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

        let switches = try await ovnManager.getLogicalSwitches()
        return switches.map { logicalSwitch in
            NetworkInfo(
                name: logicalSwitch.name,
                uuid: logicalSwitch.uuid ?? "",
                subnet: logicalSwitch.external_ids?["subnet"] ?? "",
                gateway: logicalSwitch.external_ids?["gateway"]
            )
        }
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
            protocols: ["OpenFlow13"],
            fail_mode: "secure",
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

        // Reuse an existing switch to avoid duplicate switches on VM re-attach.
        if let existing = try await ovnManager.getLogicalSwitch(named: name),
           let existingUUIDString = existing.uuid,
           let existingUUID = UUID(uuidString: existingUUIDString) {
            logger.debug("Reusing existing logical switch", metadata: ["name": .string(name)])
            return existingUUID
        }

        let logicalSwitch = OVNLogicalSwitch(
            name: name,
            external_ids: [
                "subnet": subnet,
                "description": "Auto-created network for VM"
            ]
        )

        let uuidString = try await ovnManager.createLogicalSwitch(logicalSwitch)
        guard let uuid = UUID(uuidString: uuidString) else {
            throw NetworkError.invalidConfiguration("Invalid UUID returned from OVN: \(uuidString)")
        }
        return uuid
    }
    
    private func createTAPInterface(vmId: String) async throws -> String {
        let tapName = tapInterfaceName(for: vmId)
        logger.debug("Creating TAP interface", metadata: [
            "tapName": .string(tapName),
            "vmId": .string(vmId)
        ])

        // Idempotent: reuse the device if it already exists (crash recovery, re-attach).
        if tapDeviceExists(tapName) {
            logger.debug("TAP interface already exists, reusing", metadata: ["tapName": .string(tapName)])
        } else {
            // Create a persistent single-queue TAP device. It must exist before QEMU
            // opens it (QEMU is launched with `script=no,ifname=<tap>`), and persistence
            // is what lets QEMU attach to the pre-created device.
            try run("ip", ["tuntap", "add", "dev", tapName, "mode", "tap"])
            logger.info("Created TAP interface", metadata: ["tapName": .string(tapName)])
        }

        // Bring the interface up (idempotent).
        try run("ip", ["link", "set", tapName, "up"])

        return tapName
    }

    private func attachTAPToBridge(tapInterface: String, portName: String) async throws {
        // Attach the TAP to the OVN integration bridge and bind it to the logical
        // switch port. OVN's `ovn-controller` binds a port when the OVS Interface has
        // `external_ids:iface-id` set to the logical switch port name — the previous
        // implementation set `ovn-port-name` on the Port, which OVN ignores.
        // `ovs-vsctl` performs the port + interface insert and the external_ids set
        // atomically and idempotently (`--may-exist`).
        try run("ovs-vsctl", [
            "--timeout=\(Self.ovsCommandTimeoutSeconds)",
            "--may-exist", "add-port", Self.ovnIntegrationBridge, tapInterface,
            "--", "set", "Interface", tapInterface, "external_ids:iface-id=\(portName)"
        ])
        logger.debug("Attached TAP interface to bridge", metadata: [
            "tap": .string(tapInterface),
            "port": .string(portName),
            "bridge": .string(Self.ovnIntegrationBridge)
        ])
    }

    private func removeTAPInterface(_ tapInterface: String) async throws {
        logger.debug("Removing TAP interface", metadata: ["tapName": .string(tapInterface)])

        // Tolerate an already-absent device (double cleanup, crash recovery).
        guard tapDeviceExists(tapInterface) else {
            logger.debug("TAP interface already absent, nothing to remove", metadata: ["tapName": .string(tapInterface)])
            return
        }

        // Best-effort down, then delete.
        _ = try? runProcess("ip", ["link", "set", tapInterface, "down"])
        try run("ip", ["tuntap", "del", "dev", tapInterface, "mode", "tap"])
        logger.info("Removed TAP interface", metadata: ["tapName": .string(tapInterface)])
    }

    // MARK: - Command Execution

    private struct CommandResult {
        let status: Int32
        let output: String
    }

    /// Runs a command via `/usr/bin/env` (PATH resolution) and returns its exit
    /// status and combined stdout/stderr. Mirrors the `Process` usage in
    /// `VolumeService`.
    private func runProcess(_ command: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, output: output)
    }

    /// Runs a command and throws `NetworkError.tapError` on a non-zero exit.
    @discardableResult
    private func run(_ command: String, _ arguments: [String]) throws -> String {
        let result = try runProcess(command, arguments)
        if result.status != 0 {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NetworkError.tapError("`\(command) \(arguments.joined(separator: " "))` failed (exit \(result.status)): \(detail)")
        }
        return result.output
    }

    /// Returns true if a network interface with the given name exists.
    private func tapDeviceExists(_ name: String) -> Bool {
        guard let result = try? runProcess("ip", ["link", "show", name]) else {
            return false
        }
        return result.status == 0
    }

    /// Parses an OVN logical switch port `addresses` entry (`"<mac> <ip>"`, or just
    /// `"<mac>"`, or `"dynamic"`) into a MAC and IP pair.
    static func parsePortAddress(_ addresses: [String]?) -> (mac: String, ip: String) {
        guard let first = addresses?.first(where: { !$0.isEmpty && $0.lowercased() != "dynamic" }) else {
            return ("", "")
        }
        let tokens = first.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let mac = tokens.first ?? ""
        let ip = tokens.count > 1 ? tokens[1] : ""
        return (mac, ip)
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

// MARK: - Network Error Types

enum NetworkError: Error, LocalizedError, Sendable {
    case notConnected(String)
    case networkNotFound(String)
    case bridgeNotFound(String)
    case invalidConfiguration(String)
    case ovnError(String)
    case ovsError(String)
    case tapError(String)
    case platformNotSupported(String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let message):
            return "Network service not connected: \(message)"
        case .networkNotFound(let name):
            return "Network not found: \(name)"
        case .bridgeNotFound(let name):
            return "Bridge not found: \(name)"
        case .invalidConfiguration(let message):
            return "Invalid network configuration: \(message)"
        case .ovnError(let message):
            return "OVN error: \(message)"
        case .ovsError(let message):
            return "OVS error: \(message)"
        case .tapError(let message):
            return "TAP interface error: \(message)"
        case .platformNotSupported(let message):
            return "Platform not supported: \(message)"
        }
    }
}