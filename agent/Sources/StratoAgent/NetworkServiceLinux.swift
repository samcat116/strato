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
    private let chassisConfig: OVNChassisConfig
    /// Site uplink for SNAT egress; nil disables SNAT (issue #342). SNAT needs a
    /// dedicated external IP the host doesn't own, so it is explicit config.
    private let uplinkConfig: OVNUplinkConfig?

    /// Highest network `generation` this agent has applied, per network id. A
    /// full-list sync whose entry for a network is older than what's recorded is
    /// stale (actor-reentrancy reordering of an update push vs. a periodic sync)
    /// and is skipped, so it can't roll the network's L3 realization backward —
    /// the same guard the VM reconciler applies per VM.
    private var networkGenerations: [UUID: Int64] = [:]

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
        chassisConfig: OVNChassisConfig = OVNChassisConfig(),
        uplink: OVNUplinkConfig? = nil,
        logger: Logger
    ) {
        self.ovnSocketPath = ovnSocketPath
        self.ovsSocketPath = ovsSocketPath
        self.chassisConfig = chassisConfig
        self.uplinkConfig = uplink
        self.logger = logger

        #if os(Linux)
        logger.info("Network service initialized with SwiftOVN support")
        #else
        logger.warning("Network service running in development mode - operations will be mocked")
        #endif
    }

    /// Bridge that OVN's `ovn-controller` binds VM ports onto.
    static let ovnIntegrationBridge = "br-int"

    /// External-id ownership marker stamped on every OVN object the reconciler
    /// creates, so teardown can identify its own objects without relying on name
    /// prefixes (which an operator or another feature might also use).
    static let managedKey = "strato-managed"
    static let managedValue = "true"
    /// Distinguishes the external/provider logical switch from tenant switches
    /// (both are `Logical_Switch`es), so only external switches are teardown
    /// candidates.
    static let externalRoleKey = "strato-role"
    static let externalRoleValue = "external"

    /// Whether an OVN object's external-ids mark it as created by this reconciler.
    static func isManaged(_ externalIDs: [String: String]?) -> Bool {
        externalIDs?[managedKey] == managedValue
    }

    /// OVN logical switch port name for one NIC of a VM. NIC 0 keeps the
    /// historical `vm-<vmId>` name so ports created by older agents are still
    /// found and torn down; additional NICs are suffixed with their index.
    static func portName(vmId: String, nicIndex: Int) -> String {
        nicIndex == 0 ? "vm-\(vmId)" : "vm-\(vmId)-\(nicIndex)"
    }

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

        // Ensure the chassis is registered with OVN (ovn-remote/encap
        // external_ids), then prove ovn-controller actually connected — a
        // chassis that never registers means ports get created but no flows
        // are ever programmed, which must gate the capability, not pass
        // silently (issue #328).
        try ensureChassisConfiguration()
        try await verifyOVNControllerConnected()

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

    func createVMNetwork(vmId: String, nicIndex: Int, config: VMNetworkConfig) async throws -> VMNetworkInfo {
        #if os(Linux)
        guard isConnected else {
            throw NetworkError.notConnected("Network service is not connected")
        }

        logger.info(
            "Creating VM network",
            metadata: ["vmId": .string(vmId), "nicIndex": .stringConvertible(nicIndex)])

        // Create logical switch port for the VM's NIC
        let portName = Self.portName(vmId: vmId, nicIndex: nicIndex)
        var macAddress = config.macAddress ?? generateMACAddress()
        // The control plane owns IPAM; an absent IP means the port is bound by
        // MAC only. The old fake allocation (random 192.168.1.x) is gone.
        var ipAddress = config.ipAddress

        // The OVN switch is named after the network's id (matching the network
        // reconciler), never its user-chosen name, so user names can't collide
        // with Strato-managed switches. Falls back to the name for specs from a
        // control plane that predates `networkId` (issue #342).
        let switchName = config.networkId.map { OVNNaming.switchName(networkId: $0) } ?? config.networkName

        // Find or create the logical switch
        _ = try await findOrCreateLogicalSwitch(name: switchName, subnet: config.subnet ?? "10.0.0.0/24")

        // Program OVN's native DHCP responder for this network when enabled, so
        // the guest learns the control-plane-pinned IP, gateway, and DNS over
        // DHCP instead of via cloud-init static config. Nil when DHCP is off or
        // the subnet/gateway aren't known — the static path is used then.
        let dhcpOptionsUUID = try await resolveDHCPOptions(for: config)

        // Create the logical switch port (idempotent: reuse on re-attach). A
        // port only exists to OVN when its UUID is referenced by its switch's
        // `ports` column — ovn-northd ignores unreferenced rows (no
        // Port_Binding, no dataplane). Older agents created exactly such
        // orphans, so a found port is verified and recreated attached when
        // necessary, keeping its addresses.
        let portUUID: String?
        if let existingPort = try await ovnManager?.getLogicalSwitchPort(named: portName) {
            // Reuse the existing port's allowed addresses so the VM boots with a
            // MAC/IP that matches OVN's port_security. Otherwise a recovery path
            // (agent restart, or retry after a failed TAP/OVS step) would launch
            // QEMU with freshly generated addresses and OVN would drop its traffic.
            let (existingMAC, existingIP) = Self.parsePortAddress(existingPort.addresses)
            if !existingMAC.isEmpty { macAddress = existingMAC }
            if !existingIP.isEmpty { ipAddress = existingIP }

            let logicalSwitch = try await ovnManager?.getLogicalSwitch(named: switchName)
            let attachedPorts = logicalSwitch?.ports ?? []
            if let existingUUID = existingPort.uuid, attachedPorts.contains(existingUUID) {
                portUUID = existingPort.uuid
                // Re-assert the DHCP binding on reconvergence. The row encoder
                // omits nil fields, so this updates only dhcpv4_options and
                // leaves the port's addresses/port_security intact.
                if let dhcpOptionsUUID, existingPort.dhcpv4_options != dhcpOptionsUUID {
                    try await ovnManager?.updateLogicalSwitchPort(
                        uuid: existingUUID,
                        OVNLogicalSwitchPort(name: portName, dhcpv4_options: dhcpOptionsUUID))
                }
                logger.debug(
                    "Reusing existing logical switch port",
                    metadata: [
                        "portName": .string(portName),
                        "macAddress": .string(macAddress),
                        "ipAddress": .string(ipAddress ?? "none"),
                    ])
            } else {
                logger.warning(
                    "Existing logical switch port is not attached to its switch (orphaned by an older agent); recreating it attached",
                    metadata: [
                        "portName": .string(portName),
                        "networkName": .string(config.networkName),
                    ])
                try await ovnManager?.deleteLogicalSwitchPort(named: portName)
                portUUID = try await createAttachedLogicalSwitchPort(
                    portName: portName, vmId: vmId, switchName: switchName, networkName: config.networkName,
                    macAddress: macAddress, ipAddress: ipAddress, dhcpOptionsUUID: dhcpOptionsUUID)
            }
        } else {
            portUUID = try await createAttachedLogicalSwitchPort(
                portName: portName, vmId: vmId, switchName: switchName, networkName: config.networkName,
                macAddress: macAddress, ipAddress: ipAddress, dhcpOptionsUUID: dhcpOptionsUUID)
        }

        // Create TAP interface and connect to OVS bridge
        let tapInterface = try await createTAPInterface(vmId: vmId, nicIndex: nicIndex)
        try await attachTAPToBridge(tapInterface: tapInterface, portName: portName)

        let networkInfo = VMNetworkInfo(
            vmId: vmId,
            networkName: config.networkName,
            portName: portName,
            portUUID: portUUID,
            attachment: .tap(interface: tapInterface),
            macAddress: macAddress,
            ipAddress: ipAddress
        )

        logger.info(
            "VM network created successfully",
            metadata: [
                "vmId": .string(vmId),
                "portName": .string(portName),
                "tapInterface": .string(tapInterface),
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
            attachment: .tap(interface: "tap-\(vmId)"),
            macAddress: mockAttachment.macAddress,
            ipAddress: mockAttachment.ipAddress
        )
        #endif
    }

    func attachVMToNetwork(vmId: String, networkName: String, macAddress: String? = nil) async throws -> VMNetworkInfo {
        let config = VMNetworkConfig(
            networkName: networkName,
            macAddress: macAddress,
            subnet: "192.168.1.0/24"  // Default subnet, should be configurable
        )
        return try await createVMNetwork(vmId: vmId, nicIndex: 0, config: config)
    }

    func detachVMFromNetwork(vmId: String, nicIndex: Int) async throws {
        #if os(Linux)
        guard isConnected else {
            throw NetworkError.notConnected("Network service is not connected")
        }

        logger.info(
            "Detaching VM from network",
            metadata: ["vmId": .string(vmId), "nicIndex": .stringConvertible(nicIndex)])

        let portName = Self.portName(vmId: vmId, nicIndex: nicIndex)
        let tapInterface = tapInterfaceName(for: vmId, nicIndex: nicIndex)

        // Remove logical switch port (OVN northbound). Tolerate absence so a
        // partially-torn-down VM still has its OVS port and TAP cleaned up.
        if let ovnManager = ovnManager {
            do {
                try await ovnManager.deleteLogicalSwitchPort(named: portName)
            } catch {
                logger.warning(
                    "Failed to delete logical switch port",
                    metadata: [
                        "portName": .string(portName),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }

        // Detach the TAP from the integration bridge (idempotent via --if-exists)
        do {
            try run(
                "ovs-vsctl",
                [
                    "--timeout=\(Self.ovsCommandTimeoutSeconds)",
                    "--if-exists", "del-port", Self.ovnIntegrationBridge, tapInterface,
                ])
        } catch {
            logger.warning(
                "Failed to remove OVS port",
                metadata: [
                    "tapInterface": .string(tapInterface),
                    "error": .string(error.localizedDescription),
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

        let portName = Self.portName(vmId: vmId, nicIndex: 0)
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
            attachment: .tap(interface: tapInterfaceName(for: vmId)),
            macAddress: macAddress,
            ipAddress: ipAddress.isEmpty ? nil : ipAddress
        )
        #else
        // Development mode
        if let mockAttachment = mockVMNetworks[vmId] {
            return VMNetworkInfo(
                vmId: vmId,
                networkName: mockAttachment.networkName,
                portName: "mock-vm-\(vmId)",
                portUUID: UUID().uuidString,
                attachment: .tap(interface: "tap-\(vmId)"),
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
                "description": "Strato managed network",
            ]
        )

        let switchUUIDString = try await ovnManager!.createLogicalSwitch(logicalSwitch)

        guard let switchUUID = UUID(uuidString: switchUUIDString) else {
            throw NetworkError.invalidConfiguration("Invalid UUID returned from OVN: \(switchUUIDString)")
        }

        // Pre-create the network's DHCP_Options row so the responder is ready
        // before any VM attaches. DNS/lease are filled in per-network when VMs
        // attach with their spec's config (see resolveDHCPOptions).
        if let gateway = gateway {
            _ = try await ensureDHCPOptions(
                networkName: name, subnet: subnet, gateway: gateway,
                dnsServers: [], domainName: nil, leaseTime: nil)
        }

        logger.info(
            "Logical network created successfully",
            metadata: ["name": .string(name), "uuid": .string(switchUUID.uuidString)])

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

        let bridgeName = "br-int"

        // Idempotent: br-int persists in OVSDB across agent restarts, so on
        // every reconnect it already exists. Bridge names are uniquely indexed,
        // so blindly inserting it aborts the whole transaction with a
        // constraint violation — check for it first. A fresh host has none.
        if try await ovsManager.getBridge(named: bridgeName) != nil {
            logger.debug("Integration bridge already present", metadata: ["bridge": .string(bridgeName)])
            return
        }

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
            // A concurrent creator may have won the race between the check
            // above and this insert; tolerate that, but surface anything else.
            if try await ovsManager.getBridge(named: bridgeName) != nil {
                logger.debug("Integration bridge created concurrently", metadata: ["bridge": .string(bridgeName)])
            } else {
                throw error
            }
        }
    }

    /// Ensures the local OVS carries the chassis `external_ids` that
    /// `ovn-controller` needs (`ovn-remote`, `ovn-encap-type`, `ovn-encap-ip`,
    /// and a `system-id`). Idempotent: explicit agent config is reapplied on
    /// every connect, values an operator already set are left alone, and
    /// missing values get defaults (encap IP auto-detected from the default
    /// route). Without these a fresh host looks fully wired but programs no
    /// flows, ever.
    private func ensureChassisConfiguration() throws {
        guard chassisConfig.bootstrapEnabled else {
            logger.info("OVN chassis bootstrap disabled by configuration; assuming operator-managed external_ids")
            return
        }

        let current = try runProcess(
            "ovs-vsctl",
            ["--timeout=\(Self.ovsCommandTimeoutSeconds)", "get", "open_vswitch", ".", "external_ids"])
        guard current.status == 0 else {
            throw NetworkError.ovsError(
                "cannot read chassis external_ids (exit \(current.status)): "
                    + current.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let existing = OVNChassisBootstrap.parseExternalIDs(current.output)

        var detectedEncapIP: String?
        if chassisConfig.encapIP == nil, existing["ovn-encap-ip"] == nil {
            detectedEncapIP = detectEncapIP()
        }

        let plan = OVNChassisBootstrap.plan(
            config: chassisConfig,
            existing: existing,
            detectedEncapIP: detectedEncapIP,
            generatedSystemID: UUID().uuidString.lowercased())

        if plan.encapIPUnresolved {
            throw NetworkError.invalidConfiguration(
                "cannot determine this host's tunnel endpoint IP: the chassis has no ovn-encap-ip, none is "
                    + "configured, and auto-detection from the default route failed. Set ovn_encap_ip in the "
                    + "agent configuration.")
        }

        guard !plan.settings.isEmpty else {
            logger.debug("OVN chassis external_ids already configured")
            return
        }

        let arguments =
            ["--timeout=\(Self.ovsCommandTimeoutSeconds)", "set", "open_vswitch", "."]
            + plan.settings.map(\.vsctlArgument)
        let result = try runProcess("ovs-vsctl", arguments)
        guard result.status == 0 else {
            throw NetworkError.ovsError(
                "failed to set chassis external_ids (exit \(result.status)): "
                    + result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        logger.info(
            "Bootstrapped OVN chassis configuration",
            metadata: [
                "applied": .string(plan.settings.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            ])
    }

    /// The IP the kernel would use as the source for off-host traffic — the
    /// sensible default tunnel endpoint on single-NIC hosts. Multi-homed
    /// hosts must set `ovn_encap_ip` explicitly.
    private func detectEncapIP() -> String? {
        guard let result = try? runProcess("ip", ["-j", "route", "get", "1.1.1.1"]), result.status == 0 else {
            return nil
        }
        return OVNChassisBootstrap.parseRouteSourceIP(result.output)
    }

    /// Confirms `ovn-controller` has an active southbound connection, polling
    /// briefly to ride out a controller that is still dialing after the
    /// chassis was (re)configured. Throwing here keeps `connect()` failed, so
    /// the agent does not advertise `ovn_networking` for a host whose ports
    /// would never get flows; the background retry loop picks it up when the
    /// controller comes up. A missing `ovn-appctl` only logs — we don't gate
    /// the capability on a diagnostic tool (preflight reports it separately).
    private func verifyOVNControllerConnected() async throws {
        let attempts = 5
        var lastDetail = "unknown"

        for attempt in 1...attempts {
            let result: CommandResult
            do {
                result = try runProcess("ovn-appctl", ["-t", "ovn-controller", "connection-status"])
            } catch {
                logger.warning(
                    "Cannot verify ovn-controller connection status: \(error.localizedDescription)")
                return
            }
            if result.status == 127 {
                logger.warning(
                    "ovn-appctl not found; skipping ovn-controller connection verification (install ovn-host to enable it)"
                )
                return
            }

            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.status == 0, output == "connected" {
                logger.info("ovn-controller is connected to the southbound database")
                return
            }

            lastDetail = output.isEmpty ? "exit \(result.status)" : output
            if attempt < attempts {
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }

        throw NetworkError.ovnError(
            "ovn-controller is not connected to the southbound database (last status: \(lastDetail)) — "
                + "check that ovn-controller is running and that external_ids:ovn-remote on the local OVS "
                + "points at the right southbound database. VM ports would come up with no dataplane, so "
                + "OVN networking is not being advertised.")
    }

    /// Creates the VM NIC's logical switch port attached to its switch in one
    /// OVSDB transaction (`ovn-nbctl lsp-add` semantics) — the two steps must
    /// never diverge or the port is an orphan ovn-northd ignores.
    private func createAttachedLogicalSwitchPort(
        portName: String, vmId: String, switchName: String, networkName: String, macAddress: String,
        ipAddress: String?, dhcpOptionsUUID: String? = nil
    ) async throws -> String? {
        let portAddress = ipAddress.map { "\(macAddress) \($0)" } ?? macAddress
        let logicalPort = OVNLogicalSwitchPort(
            name: portName,
            addresses: [portAddress],
            port_security: [portAddress],
            dhcpv4_options: dhcpOptionsUUID,
            external_ids: [
                "vm-id": vmId,
                "network-name": networkName,
                "description": "VM network interface",
            ]
        )
        return try await ovnManager?.createLogicalSwitchPort(logicalPort, onSwitch: switchName)
    }

    private func findOrCreateLogicalSwitch(name: String, subnet: String) async throws -> UUID {
        guard let ovnManager = ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }

        // Reuse an existing switch to avoid duplicate switches on VM re-attach.
        if let existing = try await ovnManager.getLogicalSwitch(named: name),
            let existingUUIDString = existing.uuid,
            let existingUUID = UUID(uuidString: existingUUIDString)
        {
            logger.debug("Reusing existing logical switch", metadata: ["name": .string(name)])
            return existingUUID
        }

        let logicalSwitch = OVNLogicalSwitch(
            name: name,
            external_ids: [
                "subnet": subnet,
                "description": "Auto-created network for VM",
            ]
        )

        let uuidString = try await ovnManager.createLogicalSwitch(logicalSwitch)
        guard let uuid = UUID(uuidString: uuidString) else {
            throw NetworkError.invalidConfiguration("Invalid UUID returned from OVN: \(uuidString)")
        }
        return uuid
    }

    private func createTAPInterface(vmId: String, nicIndex: Int) async throws -> String {
        let tapName = tapInterfaceName(for: vmId, nicIndex: nicIndex)
        logger.debug(
            "Creating TAP interface",
            metadata: [
                "tapName": .string(tapName),
                "vmId": .string(vmId),
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
        try run(
            "ovs-vsctl",
            [
                "--timeout=\(Self.ovsCommandTimeoutSeconds)",
                "--may-exist", "add-port", Self.ovnIntegrationBridge, tapInterface,
                "--", "set", "Interface", tapInterface, "external_ids:iface-id=\(portName)",
            ])
        logger.debug(
            "Attached TAP interface to bridge",
            metadata: [
                "tap": .string(tapInterface),
                "port": .string(portName),
                "bridge": .string(Self.ovnIntegrationBridge),
            ])
    }

    private func removeTAPInterface(_ tapInterface: String) async throws {
        logger.debug("Removing TAP interface", metadata: ["tapName": .string(tapInterface)])

        // Tolerate an already-absent device (double cleanup, crash recovery).
        guard tapDeviceExists(tapInterface) else {
            logger.debug(
                "TAP interface already absent, nothing to remove", metadata: ["tapName": .string(tapInterface)])
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
    /// `FileSystemStorageBackend`.
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

    /// Runs a command and throws `NetworkError.tapError` on a non-zero exit,
    /// appending the remediation when the output points at a host problem
    /// (missing privileges) rather than a bad invocation.
    @discardableResult
    private func run(_ command: String, _ arguments: [String]) throws -> String {
        let result = try runProcess(command, arguments)
        if result.status != 0 {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            var message = "`\(command) \(arguments.joined(separator: " "))` failed (exit \(result.status)): \(detail)"
            if detail.contains("Operation not permitted") || detail.contains("Permission denied") {
                message +=
                    " — the agent needs root or CAP_NET_ADMIN to manage TAP devices and OVS ports; "
                    + "run it as root or grant the capability (e.g. systemd AmbientCapabilities=CAP_NET_ADMIN)."
            }
            throw NetworkError.tapError(message)
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
        macBytes[0] = (macBytes[0] & 0xFC) | 0x02  // Set locally administered bit

        return macBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Resolves the OVN `DHCP_Options` UUID a VM's port should bind to, or nil
    /// when DHCP is disabled for the network or the subnet/gateway aren't known
    /// (OVN needs both a CIDR and a `server_id`/`router` to answer). A nil result
    /// leaves the guest on the static cloud-init path.
    private func resolveDHCPOptions(for config: VMNetworkConfig) async throws -> String? {
        guard config.dhcpEnabled else { return nil }
        guard let subnet = config.subnet, let gateway = config.gateway else {
            logger.warning(
                "DHCP enabled but subnet/gateway unknown; using static guest config",
                metadata: ["network": .string(config.networkName)])
            return nil
        }
        return try await ensureDHCPOptions(
            networkName: config.networkName, subnet: subnet, gateway: gateway,
            dnsServers: config.dnsServers, domainName: config.domainName, leaseTime: config.leaseTime)
    }

    /// Find-or-update the `DHCP_Options` row for `subnet` and return its UUID.
    /// Idempotent across restarts and reconvergence: an existing row for the
    /// same CIDR is updated in place (so DNS/lease edits converge) rather than
    /// duplicated.
    private func ensureDHCPOptions(
        networkName: String, subnet: String, gateway: String,
        dnsServers: [String], domainName: String?, leaseTime: Int?
    ) async throws -> String? {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let options = OVNDHCPOptionsBuilder.v4Options(
            gateway: gateway, dnsServers: dnsServers, domainName: domainName, leaseTime: leaseTime,
            subnet: subnet)
        let dhcp = OVNDHCPOptions(
            cidr: subnet, options: options,
            external_ids: ["network-name": networkName, "strato-managed": "true"])

        if let existing = try await ovnManager.getDHCPOptions().first(where: { $0.cidr == subnet }),
            let uuid = existing.uuid
        {
            if existing.options != options {
                try await ovnManager.updateDHCPOptions(uuid: uuid, dhcp)
            }
            return uuid
        }
        return try await ovnManager.createDHCPOptions(dhcp)
    }
    #endif
}

// MARK: - L3 Network Reconciliation (issue #342)

extension NetworkServiceLinux {
    /// Converge this host's OVN L3 topology (per-project routers, router ports,
    /// SNAT uplinks) toward the control plane's desired network set. Delegates
    /// the diff to the pure `NetworkReconciler`, driving the OVSDB side effects
    /// through `self` as the actuator. No-op until the service is connected.
    func reconcileNetworks(_ networks: [DesiredNetworkState]) async {
        #if os(Linux)
        guard isConnected else {
            logger.debug("Network service not connected; skipping network reconciliation")
            return
        }
        #endif

        // Generation guard: apply only entries at least as new as what we last
        // applied for each network, so a reordered stale sync can't re-address
        // ports or re-add/remove SNAT with an outdated spec. A network skipped as
        // stale is still present, so its live objects are protected from teardown
        // (left exactly as-is); current networks are governed by the plan, so
        // their dropped objects — e.g. SNAT after externalAccess is turned off —
        // are still torn down. Only networks absent from the sync are torn down.
        var current: [DesiredNetworkState] = []
        var stale: [DesiredNetworkState] = []
        for network in networks {
            if let applied = networkGenerations[network.networkId], network.generation < applied {
                logger.debug(
                    "Skipping stale network desired state",
                    metadata: [
                        "network": .string(network.name),
                        "generation": .stringConvertible(network.generation),
                        "applied": .stringConvertible(applied),
                    ])
                stale.append(network)
                continue
            }
            networkGenerations[network.networkId] = network.generation
            current.append(network)
        }
        let protected = NetworkReconciler.protectedTopology(forStale: stale)

        do {
            try await NetworkReconciler.reconcile(
                networks: current, actuator: self, logger: logger, protected: protected)
        } catch {
            // observeTopology failed (can't compute teardown safely); the
            // periodic level-triggered sync retries. Ensures already applied.
            logger.error(
                "Network reconciliation could not complete",
                metadata: ["error": .string(error.localizedDescription)])
        }
    }
}

extension NetworkServiceLinux: NetworkActuator {
    func observeTopology() async throws -> ObservedNetworkTopology {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let routers = try await ovnManager.getLogicalRouters()
        let routerPorts = try await ovnManager.getLogicalRouterPorts()
        let switchPorts = try await ovnManager.getLogicalSwitchPorts()
        let switches = try await ovnManager.getLogicalSwitches()
        let nats = try await ovnManager.getNATRules()

        // Only consider objects this reconciler owns, keyed off the
        // `strato-managed` external-id it stamps on everything it creates — never
        // a name prefix, so an operator's or another feature's `lr-*`/`ls-ext-*`
        // objects are never mistaken for Strato's and torn down.
        let managedRouters = routers.filter { Self.isManaged($0.external_ids) }
        let natByUUID = Dictionary(uniqueKeysWithValues: nats.compactMap { nat in nat.uuid.map { ($0, nat) } })
        var snatRules = Set<SNATRuleKey>()
        for router in managedRouters {
            for uuid in router.nat ?? [] {
                if let nat = natByUUID[uuid], nat.natType == "snat", Self.isManaged(nat.external_ids) {
                    snatRules.insert(SNATRuleKey(router: router.name, logicalIP: nat.logical_ip))
                }
            }
        }

        return ObservedNetworkTopology(
            routerNames: Set(managedRouters.map(\.name)),
            routerPortNames: Set(routerPorts.filter { Self.isManaged($0.external_ids) }.map(\.name)),
            switchRouterPortNames: Set(
                switchPorts.filter { $0.portType == "router" && Self.isManaged($0.external_ids) }.map(\.name)),
            externalSwitchNames: Set(
                switches.filter { $0.external_ids?[Self.externalRoleKey] == Self.externalRoleValue }.map(
                    \.name)),
            snatRules: snatRules)
        #else
        return ObservedNetworkTopology()
        #endif
    }

    func ensureSwitch(_ desired: DesiredSwitch) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        // Already on the UUID scheme.
        if try await ovnManager.getLogicalSwitch(named: desired.name) != nil { return }

        // Upgrade migration: an older agent named this switch after the network's
        // user-facing name. Rename it in place to the UUID name — a rename keeps
        // the same OVSDB row (and UUID), so existing VM ports and their dataplane
        // bindings move to the new scheme without re-creation, and new VMs + the
        // router port land on the same switch. issue #342.
        if !desired.legacyName.isEmpty, desired.legacyName != desired.name,
            let legacy = try await ovnManager.getLogicalSwitch(named: desired.legacyName),
            let legacyUUID = legacy.uuid
        {
            // Only `name` is set, so the row encoder leaves ports/external_ids intact.
            try await ovnManager.updateLogicalSwitch(uuid: legacyUUID, OVNLogicalSwitch(name: desired.name))
            logger.info(
                "Migrated legacy network switch to UUID name",
                metadata: ["from": .string(desired.legacyName), "to": .string(desired.name)])
            return
        }

        _ = try await findOrCreateLogicalSwitch(name: desired.name, subnet: desired.subnet)
        #endif
    }

    func ensureRouter(_ router: DesiredRouter) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        if try await ovnManager.getLogicalRouter(named: router.name) != nil { return }
        let logicalRouter = OVNLogicalRouter(
            name: router.name,
            external_ids: ["strato-managed": "true", "router-key": router.routerKey])
        do {
            _ = try await ovnManager.createLogicalRouter(logicalRouter)
        } catch {
            // Tolerate a concurrent creator that won the check→insert race.
            if try await ovnManager.getLogicalRouter(named: router.name) == nil { throw error }
        }
        #endif
    }

    func ensureRouterPort(_ port: DesiredRouterPort, onRouter routerName: String) async throws {
        #if os(Linux)
        try await ensureRouterPort(
            name: port.name, mac: port.mac, cidr: port.cidr,
            switchName: port.switchName, switchPortName: port.switchPortName, router: routerName)
        #endif
    }

    func ensureUplink(for router: DesiredRouter) async throws -> Bool {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        // SNAT requires an operator-configured dedicated external IP: the OVN
        // router port claims this address on the provider network, so it must be
        // one the host itself does not own (otherwise host and router conflict).
        // Without it we realize the router + east-west but no uplink/SNAT.
        guard let uplink = uplinkConfig else {
            logger.info(
                "No OVN uplink configured; realizing router without SNAT egress",
                metadata: ["router": .string(router.name)])
            return false
        }
        guard let externalIP = uplink.externalIP,
            let uplinkMAC = OVNNaming.routerPortMAC(gateway: externalIP)
        else {
            logger.error(
                "OVN uplink external_cidr is not a valid ip/prefix; skipping SNAT",
                metadata: ["externalCIDR": .string(uplink.externalCIDR)])
            return false
        }

        // Provider bridge + physnet mapping. The operator connects the bridge to
        // the external network out of band; the agent only wires the OVN side.
        try await ensureProviderBridge(uplink.bridge)
        try ensureBridgeMapping(physnet: uplink.physnet, bridge: uplink.bridge)

        // External logical switch + localnet port (the provider attachment).
        // Created with the external role marker so observeTopology can tell it
        // apart from tenant switches and no operator switch is a candidate.
        if try await ovnManager.getLogicalSwitch(named: router.externalSwitchName) == nil {
            let externalSwitch = OVNLogicalSwitch(
                name: router.externalSwitchName,
                external_ids: [
                    Self.managedKey: Self.managedValue,
                    Self.externalRoleKey: Self.externalRoleValue,
                    "description": "Strato external/provider switch",
                ])
            do {
                _ = try await ovnManager.createLogicalSwitch(externalSwitch)
            } catch {
                if try await ovnManager.getLogicalSwitch(named: router.externalSwitchName) == nil { throw error }
            }
        }
        if try await ovnManager.getLogicalSwitchPort(named: router.localnetPortName) == nil {
            let localnet = OVNLogicalSwitchPort(
                name: router.localnetPortName,
                portType: "localnet",
                options: ["network_name": uplink.physnet],
                addresses: ["unknown"],
                external_ids: [Self.managedKey: Self.managedValue])
            _ = try await ovnManager.createLogicalSwitchPort(localnet, onSwitch: router.externalSwitchName)
        }

        // Gateway router port on the external switch, at the configured
        // dedicated external address.
        try await ensureRouterPort(
            name: router.externalRouterPortName, mac: uplinkMAC, cidr: uplink.externalCIDR,
            switchName: router.externalSwitchName, switchPortName: router.externalSwitchRouterPortName,
            router: router.name)

        // Default route out the uplink, so SNAT'd traffic to off-subnet
        // destinations actually has a route (the NAT rule alone is not enough).
        if let nextHop = uplink.gateway {
            try ensureDefaultRoute(router: router.name, nextHop: nextHop)
        } else {
            let message =
                "OVN uplink has no gateway; skipping the router default route "
                + "(SNAT egress limited to the external subnet)"
            logger.warning("\(message)", metadata: ["router": .string(router.name)])
        }

        return true
        #else
        return false
        #endif
    }

    func ensureSNAT(router routerName: String, logicalIP: String) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        // SNAT to the configured dedicated external IP (reconcile only calls this
        // after ensureUplink returned true, so the uplink config is present/valid).
        guard let externalIP = uplinkConfig?.externalIP else {
            throw NetworkError.invalidConfiguration(
                "SNAT for \(logicalIP) requested without a configured uplink external IP")
        }
        // Idempotent: reuse a matching rule; re-point one whose external IP drifted.
        for rule in try await snatRules(onRouter: routerName)
        where rule.natType == "snat" && rule.logical_ip == logicalIP {
            if rule.external_ip == externalIP { return }
            if let uuid = rule.uuid { try await ovnManager.deleteNATRule(uuid: uuid) }
        }
        let nat = OVNNAT(
            natType: "snat", external_ip: externalIP, logical_ip: logicalIP,
            external_ids: [Self.managedKey: Self.managedValue])
        _ = try await ovnManager.createNATRule(nat, onRouter: routerName)
        #endif
    }

    func removeSNAT(router routerName: String, logicalIP: String) async throws {
        #if os(Linux)
        guard let ovnManager else { return }
        for rule in try await snatRules(onRouter: routerName)
        where rule.natType == "snat" && rule.logical_ip == logicalIP {
            if let uuid = rule.uuid { try await ovnManager.deleteNATRule(uuid: uuid) }
        }
        #endif
    }

    func removeSwitchRouterPort(name: String) async throws {
        #if os(Linux)
        try? await ovnManager?.deleteLogicalSwitchPort(named: name)
        #endif
    }

    func removeRouterPort(name: String) async throws {
        #if os(Linux)
        try? await ovnManager?.deleteLogicalRouterPort(named: name)
        #endif
    }

    func removeExternalSwitch(name: String) async throws {
        #if os(Linux)
        guard let ovnManager else { return }
        // Delete the switch's localnet port first (deleting the switch alone can
        // orphan it); its name is derived from the switch's router key.
        if name.hasPrefix("ls-ext-") {
            let key = String(name.dropFirst("ls-ext-".count))
            try? await ovnManager.deleteLogicalSwitchPort(named: OVNNaming.localnetPortName(routerKey: key))
        }
        try? await ovnManager.deleteLogicalSwitch(named: name)
        #endif
    }

    func removeRouter(name: String) async throws {
        #if os(Linux)
        try? await ovnManager?.deleteLogicalRouter(named: name)
        #endif
    }
}

#if os(Linux)
extension NetworkServiceLinux {
    /// Create a router port and its peering `type=router` switch port in an
    /// idempotent pair (both, or neither, so the switch never has a dangling
    /// router peer). Shared by tenant ports and the external gateway port.
    fileprivate func ensureRouterPort(
        name: String, mac: String, cidr: String, switchName: String, switchPortName: String, router: String
    ) async throws {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let desiredPort = OVNLogicalRouterPort(
            name: name, mac: mac, networks: [cidr],
            external_ids: ["strato-managed": "true"])
        if let existing = try await ovnManager.getLogicalRouterPort(named: name) {
            // Re-address in place when the network's gateway/subnet changed: the
            // port name is stable (derived from the network), so without this a
            // subnet/gateway edit would leave a stale CIDR/MAC and break L3.
            if existing.networks != [cidr] || existing.mac != mac, let uuid = existing.uuid {
                try await ovnManager.updateLogicalRouterPort(uuid: uuid, desiredPort)
                logger.info(
                    "Updated logical router port addressing",
                    metadata: ["port": .string(name), "cidr": .string(cidr)])
            }
        } else {
            _ = try await ovnManager.createLogicalRouterPort(desiredPort, onRouter: router)
        }
        if try await ovnManager.getLogicalSwitchPort(named: switchPortName) == nil {
            let switchPort = OVNLogicalSwitchPort(
                name: switchPortName,
                portType: "router",
                options: ["router-port": name],
                addresses: ["router"],
                external_ids: ["strato-managed": "true"])
            _ = try await ovnManager.createLogicalSwitchPort(switchPort, onSwitch: switchName)
        }
    }

    /// The SNAT/DNAT rules attached to a router, resolved from its `nat` refs.
    fileprivate func snatRules(onRouter routerName: String) async throws -> [OVNNAT] {
        guard let ovnManager,
            let router = try await ovnManager.getLogicalRouter(named: routerName),
            let natUUIDs = router.nat
        else { return [] }
        let byUUID = Dictionary(
            uniqueKeysWithValues: try await ovnManager.getNATRules().compactMap { nat in
                nat.uuid.map { ($0, nat) }
            })
        return natUUIDs.compactMap { byUUID[$0] }
    }

    /// Ensure the external provider bridge exists, mirroring `ensureIntegrationBridge`.
    fileprivate func ensureProviderBridge(_ bridgeName: String) async throws {
        guard let ovsManager else {
            throw NetworkError.notConnected("OVS manager not connected")
        }
        if try await ovsManager.getBridge(named: bridgeName) != nil { return }
        let bridge = OVSBridge(
            name: bridgeName,
            external_ids: ["description": "Strato OVN external/provider bridge"])
        do {
            _ = try await ovsManager.createBridge(bridge)
            logger.info("Created provider bridge", metadata: ["bridge": .string(bridgeName)])
        } catch {
            if try await ovsManager.getBridge(named: bridgeName) == nil { throw error }
        }
    }

    /// Ensure the local OVS carries `ovn-bridge-mappings=<physnet>:<bridge>` for
    /// the provider network, merged with any mappings already present.
    fileprivate func ensureBridgeMapping(physnet: String, bridge: String) throws {
        let current = try runProcess(
            "ovs-vsctl",
            ["--timeout=\(Self.ovsCommandTimeoutSeconds)", "get", "open_vswitch", ".", "external_ids"])
        let existing = OVNChassisBootstrap.parseExternalIDs(current.output)["ovn-bridge-mappings"]
        guard let merged = OVNBridgeMappings.merged(existing: existing, physnet: physnet, bridge: bridge) else {
            return  // already mapped
        }
        try run(
            "ovs-vsctl",
            [
                "--timeout=\(Self.ovsCommandTimeoutSeconds)", "set", "open_vswitch", ".",
                "external_ids:ovn-bridge-mappings=\(merged)",
            ])
        logger.info("Set OVN bridge mapping", metadata: ["mapping": .string(merged)])
    }

    /// Install (or update) the logical router's default route to the uplink next
    /// hop, so SNAT'd traffic to addresses outside the provider subnet has a
    /// route out. SwiftOVN has no `Logical_Router_Static_Route` model yet, so
    /// this shells `ovn-nbctl` (present on OVN hosts); `--may-exist` makes it
    /// idempotent and updates the next hop if it drifts.
    fileprivate func ensureDefaultRoute(router: String, nextHop: String) throws {
        let result = try runProcess(
            "ovn-nbctl",
            ["--db=unix:\(ovnSocketPath)", "--may-exist", "lr-route-add", router, "0.0.0.0/0", nextHop])
        if result.status == 127 {
            let message =
                "ovn-nbctl not found; cannot install the default route for SNAT egress "
                + "(install ovn-common). East-west and the uplink subnet still work."
            logger.warning("\(message)")
            return
        }
        guard result.status == 0 else {
            throw NetworkError.ovnError(
                "failed to add default route on \(router) via \(nextHop) (exit \(result.status)): "
                    + result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        logger.info(
            "Installed default route on logical router",
            metadata: ["router": .string(router), "nextHop": .string(nextHop)])
    }
}
#endif

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

extension NetworkError: ClassifiableError {
    var failureClassification: FailureClassification {
        switch self {
        case .platformNotSupported, .invalidConfiguration:
            return .permanent
        case .tapError(let message):
            // A privilege problem can only be fixed by an operator; a plain
            // command failure might be a transient device/OVS hiccup.
            let isPrivilegeProblem =
                message.contains("Operation not permitted") || message.contains("Permission denied")
            return isPrivilegeProblem ? .permanent : .transient
        case .notConnected, .networkNotFound, .bridgeNotFound, .ovnError, .ovsError:
            // OVN/OVS may come back (the agent reconnects in the background),
            // so these stay retryable.
            return .transient
        }
    }
}
