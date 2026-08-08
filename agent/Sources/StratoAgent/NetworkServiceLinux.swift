import Foundation
import Logging
import StratoShared
import StratoAgentCore

#if os(Linux)
import SwiftOVN
#endif

actor NetworkServiceLinux: NetworkServiceProtocol {
    private let logger: Logger
    /// OVN NB connection string in OVN syntax (`unix:<path>`, `tcp:<host>:<port>`,
    /// `ssl:<host>:<port>`). Defaults to the legacy per-node local socket; a
    /// site's agents all point it at the site's shared ovn-central (issue #343).
    private let ovnNBConnection: String
    /// TLS material for an `ssl:` NB endpoint (CA, client cert/key). Nil for
    /// `unix:`/`tcp:` connections, or for `ssl:` with system trust roots.
    private let ovnNBTLS: OVNNorthboundTLSConfig?
    private let ovsSocketPath: String
    private let chassisConfig: OVNChassisConfig
    /// Site uplink for SNAT egress; nil disables SNAT (issue #342). SNAT needs a
    /// dedicated external IP the host doesn't own, so it is explicit config.
    private let uplinkConfig: OVNUplinkConfig?
    /// OVN native dynamic routing (issue #344): BGP advertisement of floating
    /// IPs / tenant routes via FRR. Nil or disabled strips any previously
    /// applied `dynamic-routing*` options during reconcile.
    private let dynamicRoutingConfig: OVNDynamicRoutingConfig?
    /// Absolute paths to iproute2's `ip` and `tc`, resolved once at agent start
    /// (`SandboxJailerResolver`). The sandbox netns path invokes them directly
    /// rather than through `/usr/bin/env` like the host-namespace path does: a
    /// service manager's stripped `PATH` must not break namespace attachment on
    /// a host the start-time probe already declared usable. Nil means the host
    /// has no such binary, and networked sandboxes are refused with that reason
    /// instead of failing halfway through wiring one up.
    private let ipBinaryPath: String?
    private let tcBinaryPath: String?
    /// Aggregate ingress packet-rate cap on each of a network's link-local
    /// service interfaces (STR-40); 0 disables the policer. Applied to *both*
    /// feet — the metadata one in the network's chassis namespace and the
    /// resolver one in the host's — because since ADR 0008 they are separate
    /// devices and each carries its own traffic. Operator-configurable
    /// (`[resolver] rate_limit_pps`) because the right ceiling depends on how
    /// many guests share a hypervisor.
    private let linkLocalServiceRatePPS: Int
    /// Runs the host's CoreDNS, which serves every resolver-enabled network this
    /// host has a NIC on (STR-40). Nil when the host has no usable CoreDNS
    /// binary, in which case the agent also registers `resolverCapable: false`
    /// and the control plane withholds the resolver from every network in the
    /// site — so this being nil while networks still want a resolver is a
    /// mixed-version window, not a steady state.
    private let resolverSupervisor: ResolverSupervisor?

    /// Whether this agent may author NB topology (switches, routers, NAT,
    /// teardown), per the control plane's last sync. False on agents sharing a
    /// site NB that another agent (the site's network controller) writes; such
    /// agents only bind their own VMs' ports. Defaults true: an agent that has
    /// never received a sync owns its local NB (the legacy model).
    private var topologyAuthority = true

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
    #endif

    init(
        nbConnection: String? = nil,
        nbTLS: OVNNorthboundTLSConfig? = nil,
        ovsSocketPath: String = "/var/run/openvswitch/db.sock",
        chassisConfig: OVNChassisConfig = OVNChassisConfig(),
        uplink: OVNUplinkConfig? = nil,
        dynamicRouting: OVNDynamicRoutingConfig? = nil,
        ipBinaryPath: String? = nil,
        tcBinaryPath: String? = nil,
        linkLocalServiceRatePPS: Int = NetworkResolverDefaults.rateLimitPPS,
        resolverSupervisor: ResolverSupervisor? = nil,
        logger: Logger
    ) {
        self.ovnNBConnection = nbConnection ?? "unix:/var/run/ovn/ovnnb_db.sock"
        self.ovnNBTLS = nbTLS
        self.ovsSocketPath = ovsSocketPath
        self.chassisConfig = chassisConfig
        self.uplinkConfig = uplink
        self.dynamicRoutingConfig = dynamicRouting
        self.ipBinaryPath = ipBinaryPath
        self.tcBinaryPath = tcBinaryPath
        self.linkLocalServiceRatePPS = linkLocalServiceRatePPS
        self.resolverSupervisor = resolverSupervisor
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
    /// OVN port type for the metadata port (STR-49). `localport` is instantiated
    /// on every chassis by `ovn-controller` and never forwarded across geneve
    /// tunnels, which is what lets one address be published on every switch in a
    /// site and still reach the guest's own host.
    static let localPortType = "localport"

    /// Whether an OVN object's external-ids mark it as created by this reconciler.
    static func isManaged(_ externalIDs: [String: String]?) -> Bool {
        externalIDs?[managedKey] == managedValue
    }

    /// OVN logical switch port name for one NIC of a VM. Delegates to
    /// `OVNNaming` so the control-plane-driven floating IP path derives the
    /// same name for a NIC's port (issue #344).
    static func portName(vmId: String, nicIndex: Int) -> String {
        OVNNaming.vmPortName(vmId: vmId, nicIndex: nicIndex)
    }

    /// OVN logical switch port name for one NIC of any workload. Sandbox NICs
    /// take the disjoint `sbx-` namespace so the two kinds of port are
    /// distinguishable in OVN and OVS (issue STR-100).
    static func portName(workloadId: String, nicIndex: Int, placement: NICPlacement) -> String {
        OVNNaming.portName(workloadId: workloadId, nicIndex: nicIndex, placement: placement)
    }

    /// Bound on `ovs-vsctl` so a config change can't hang the network actor
    /// forever when `ovs-vswitchd` is down/overloaded (the default waits forever).
    static let ovsCommandTimeoutSeconds = 10

    /// How many times to re-read a freshly attached port's `ofport` before
    /// giving up, and the pause between attempts. Small: `ovs-vsctl` already
    /// waits for `ovs-vswitchd`, so this only covers a narrow assignment window.
    static let ovsBindingReadbackAttempts = 3
    static let ovsBindingReadbackDelay: Duration = .milliseconds(50)

    /// Bound on each `ip`/`tc` invocation in the sandbox namespace path, so a
    /// wedged child cannot park the attach forever. Generous: these are local
    /// netlink operations that answer in milliseconds.
    static let netnsCommandTimeout: Duration = .seconds(15)

    // MARK: - Connection Management

    func connect() async throws {
        #if os(Linux)
        logger.info("Connecting to OVN/OVS services")

        // Initialize OVN manager. The string form can't express TLS options
        // (CA, client cert), so an ssl: endpoint is re-created with the
        // configured material when the operator supplied any.
        var nbEndpoint = try OVSDBEndpoint(parsing: ovnNBConnection)
        if case .ssl(let host, let port, _) = nbEndpoint, let tls = ovnNBTLS {
            nbEndpoint = .ssl(
                host: host, port: port,
                tls: OVSDBTLSConfiguration(
                    caCertificatePath: tls.caCertPath,
                    clientCertificatePath: tls.clientCertPath,
                    clientPrivateKeyPath: tls.clientKeyPath,
                    verifiesServerCertificate: tls.verifyServerCertificate,
                    serverHostname: tls.serverHostname
                ))
        }
        ovnManager = OVNManager(endpoint: nbEndpoint, logger: logger)
        try await ovnManager?.connect()
        logger.info("Connected to OVN database", metadata: ["endpoint": .string(ovnNBConnection)])

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

    func createVMNetwork(
        vmId: String, nicIndex: Int, config: VMNetworkConfig, placement: NICPlacement
    ) async throws -> VMNetworkInfo {
        #if os(Linux)
        guard isConnected else {
            throw NetworkError.notConnected("Network service is not connected")
        }

        logger.info(
            "Creating VM network",
            metadata: ["vmId": .string(vmId), "nicIndex": .stringConvertible(nicIndex)])

        // Create logical switch port for the workload's NIC. Everything down to
        // the TAP/veth step below is identical for VMs and sandboxes — only the
        // port's namespace and how the device is realized differ.
        let portName = Self.portName(workloadId: vmId, nicIndex: nicIndex, placement: placement)
        var macAddress = config.macAddress ?? generateMACAddress()
        // The control plane owns IPAM; an absent IP means the port is bound by
        // MAC only. The old fake allocation (random 192.168.1.x) is gone.
        var ipAddress = config.ipAddress
        var ip6Address = config.ip6Address

        // The OVN switch is named after the network's id (matching the network
        // reconciler), never its user-chosen name — which cannot identify a
        // network anyway, being unique only within a project (issue #765).
        let switchName = OVNNaming.switchName(networkId: config.networkId)

        // Find or create the logical switch. A non-authoritative agent must
        // not create it — on a shared site NB the switch belongs to the
        // network controller, and creating a second same-named switch here
        // would split the network. Failing is safe: the VM's reconcile lane
        // retries after the controller's level-triggered sync realizes it.
        if topologyAuthority {
            _ = try await findOrCreateLogicalSwitch(name: switchName, subnet: config.subnet ?? "10.0.0.0/24")
        } else if try await ovnManager?.getLogicalSwitch(named: switchName) == nil {
            // Waiting, not failing: the reconciler must not report this as an
            // error (that would fail the pending create operation before the
            // controller's own sync — which the control plane sends alongside
            // this VM's — has realized the switch). See issue #343.
            throw DependencyPendingError(
                "logical switch \(switchName) does not exist yet; waiting for the site's network controller to realize it"
            )
        }

        // Program OVN's native DHCP responder for this network when enabled, so
        // the guest learns the control-plane-pinned IP, gateway, and DNS over
        // DHCP instead of via cloud-init static config. Nil when DHCP is off or
        // that family's subnet/gateway aren't known — the static path is used
        // then. Dual-stack networks get both a DHCPv4 and a DHCPv6 row.
        let (dhcpOptionsUUID, dhcpV6OptionsUUID) = try await resolveDHCPOptions(for: config)

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
            // Per family: an existing address wins over the spec, but a family
            // the port never had (e.g. IPv6 just enabled on the network) is
            // taken from the spec so the port upgrades in place.
            let (existingMAC, existingIPs) = Self.parsePortAddress(existingPort.addresses)
            if !existingMAC.isEmpty { macAddress = existingMAC }
            if let existingV4 = existingIPs.first(where: { IPv4Address($0) != nil }) {
                ipAddress = existingV4
            }
            if let existingV6 = existingIPs.first(where: { IPv6Address($0) != nil }) {
                ip6Address = existingV6
            }
            let desiredIPs = [ipAddress, ip6Address].compactMap { $0 }

            let logicalSwitch = try await ovnManager?.getLogicalSwitch(named: switchName)
            let attachedPorts = logicalSwitch?.ports ?? []
            if let existingUUID = existingPort.uuid, attachedPorts.contains(existingUUID) {
                portUUID = existingPort.uuid
                // Re-assert addressing and DHCP bindings on reconvergence, so a
                // port created before the network gained IPv6 (or before a DHCP
                // edit) upgrades in place instead of keeping its old shape
                // forever. The row encoder omits nil/unset fields, so only the
                // listed columns are written.
                let desiredAddresses = [Self.portAddressEntry(mac: macAddress, ips: desiredIPs)]
                let desiredSecurity = [Self.portSecurityEntry(mac: macAddress, ips: desiredIPs)]
                let addressingDrifted =
                    existingPort.addresses != desiredAddresses
                    || existingPort.port_security != desiredSecurity
                let dhcpDrifted =
                    (dhcpOptionsUUID != nil && existingPort.dhcpv4_options != dhcpOptionsUUID)
                    || (dhcpV6OptionsUUID != nil && existingPort.dhcpv6_options != dhcpV6OptionsUUID)
                if addressingDrifted || dhcpDrifted {
                    try await ovnManager?.updateLogicalSwitchPort(
                        uuid: existingUUID,
                        OVNLogicalSwitchPort(
                            name: portName,
                            addresses: desiredAddresses,
                            port_security: desiredSecurity,
                            dhcpv4_options: dhcpOptionsUUID,
                            dhcpv6_options: dhcpV6OptionsUUID))
                }
                logger.debug(
                    "Reusing existing logical switch port",
                    metadata: [
                        "portName": .string(portName),
                        "macAddress": .string(macAddress),
                        "ipAddress": .string(ipAddress ?? "none"),
                        "ip6Address": .string(ip6Address ?? "none"),
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
                    portName: portName, vmId: vmId, placement: placement, switchName: switchName,
                    networkId: config.networkId,
                    networkName: config.networkName, macAddress: macAddress, ipAddresses: desiredIPs,
                    dhcpOptionsUUID: dhcpOptionsUUID, dhcpV6OptionsUUID: dhcpV6OptionsUUID)
            }
        } else {
            portUUID = try await createAttachedLogicalSwitchPort(
                portName: portName, vmId: vmId, placement: placement, switchName: switchName,
                networkId: config.networkId,
                networkName: config.networkName, macAddress: macAddress,
                ipAddresses: [ipAddress, ip6Address].compactMap { $0 },
                dhcpOptionsUUID: dhcpOptionsUUID, dhcpV6OptionsUUID: dhcpV6OptionsUUID)
        }

        // Join the NIC's security groups (plus the drop group) before the TAP
        // goes live, so a fresh VM is never even briefly unfiltered. A port
        // group the topology authority hasn't realized yet parks the create
        // on DependencyPendingError (the missing-switch semantics above); the
        // per-sync membership pass keeps the port converged afterwards.
        if let groupIds = config.securityGroupIds {
            try await joinSecurityGroups(portName: portName, portUUID: portUUID, groupIds: groupIds)
        }

        // Realize the device and bind it to the logical port. A VM's VMM runs in
        // the host namespace, so its TAP goes straight onto the integration
        // bridge; a jailed sandbox's does not, so its device is realized through
        // a veth pair into the jail's namespace (issue STR-100).
        let tapInterface: String
        switch placement {
        case .hostNamespace:
            tapInterface = try await createTAPInterface(vmId: vmId, nicIndex: nicIndex, mtu: config.mtu)
            try await attachTAPToBridge(tapInterface: tapInterface, portName: portName)
        case .sandboxNetns(let netnsName, let owner):
            // A teardown placement (no owner) cannot create devices: the TAP has
            // to be created owned by the jail uid, because a jailed Firecracker
            // has dropped CAP_NET_ADMIN before it opens it. Unreachable — every
            // create path derives the owner from the jail plan.
            guard let owner else {
                throw NetworkError.invalidConfiguration(
                    "a sandbox NIC cannot be realized without the jail's uid/gid; this placement was "
                        + "built for teardown")
            }
            tapInterface = try await attachSandboxNICIntoNetns(
                sandboxId: vmId, nicIndex: nicIndex, netnsName: netnsName,
                owner: owner, portName: portName, mtu: config.mtu)
        }

        let networkInfo = VMNetworkInfo(
            vmId: vmId,
            networkName: config.networkName,
            portName: portName,
            portUUID: portUUID,
            attachment: .tap(interface: tapInterface),
            macAddress: macAddress,
            ipAddress: ipAddress,
            ip6Address: ip6Address
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

        return VMNetworkInfo(
            vmId: vmId,
            networkName: config.networkName,
            portName: "mock-vm-\(vmId)",
            portUUID: UUID().uuidString,
            attachment: .tap(interface: "tap-\(vmId)"),
            macAddress: config.macAddress ?? "02:00:00:00:00:01",
            ipAddress: config.ipAddress ?? "192.168.1.100"
        )
        #endif
    }

    func detachVMFromNetwork(vmId: String, nicIndex: Int, placement: NICPlacement) async throws {
        #if os(Linux)
        guard isConnected else {
            throw NetworkError.notConnected("Network service is not connected")
        }

        logger.info(
            "Detaching VM from network",
            metadata: ["vmId": .string(vmId), "nicIndex": .stringConvertible(nicIndex)])

        let portName = Self.portName(workloadId: vmId, nicIndex: nicIndex, placement: placement)

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

        switch placement {
        case .hostNamespace:
            let tapInterface = tapInterfaceName(for: vmId, nicIndex: nicIndex)

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
        case .sandboxNetns(let netnsName, _):
            try await detachSandboxNICFromNetns(
                sandboxId: vmId, nicIndex: nicIndex, netnsName: netnsName, portName: portName)
        }

        logger.info("VM detached from network successfully", metadata: ["vmId": .string(vmId)])
        #else
        // Development mode
        logger.info("Detaching mock VM from network (development mode)", metadata: ["vmId": .string(vmId)])
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
        } else {
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
                    logger.debug(
                        "Integration bridge created concurrently", metadata: ["bridge": .string(bridgeName)])
                } else {
                    throw error
                }
            }
        }

        try await ensureBridgeLocalPort(bridgeName)
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

    /// The `addresses` entry for a VM port: the MAC followed by its per-family
    /// IPs (`"<mac> <ip4> <ip6>"`), or just the MAC when nothing is allocated.
    static func portAddressEntry(mac: String, ips: [String]) -> String {
        ([mac] + ips).joined(separator: " ")
    }

    /// The `port_security` entry for a VM port: the addresses entry plus —
    /// when the port carries any IPv6 address — the EUI-64 link-local address
    /// derived from the MAC. Port security with explicit IPs restricts ND/NA
    /// and DHCPv6-client traffic to the listed sources, and guests source
    /// those from their link-local address: omit it and IPv6 silently dies.
    /// (Guests are configured with `ipv6-address-generation: eui64` so their
    /// link-local matches this derivation.)
    static func portSecurityEntry(mac: String, ips: [String]) -> String {
        var entries = [mac] + ips
        let hasIPv6 = ips.contains { IPv6Address($0) != nil }
        if hasIPv6, let linkLocal = IPv6Address.linkLocalEUI64(fromMAC: mac) {
            entries.append(linkLocal.description)
        }
        return entries.joined(separator: " ")
    }

    /// Creates the VM NIC's logical switch port attached to its switch in one
    /// OVSDB transaction (`ovn-nbctl lsp-add` semantics) — the two steps must
    /// never diverge or the port is an orphan ovn-northd ignores.
    private func createAttachedLogicalSwitchPort(
        portName: String, vmId: String, placement: NICPlacement, switchName: String, networkId: UUID,
        networkName: String,
        macAddress: String,
        ipAddresses: [String], dhcpOptionsUUID: String? = nil, dhcpV6OptionsUUID: String? = nil
    ) async throws -> String? {
        // Which kind of workload owns the port, for humans reading
        // `ovn-nbctl list` and for anyone correlating a port back to a resource.
        let (ownerKey, description): (String, String) = {
            switch placement {
            case .hostNamespace: return ("vm-id", "VM network interface")
            case .sandboxNetns: return ("sandbox-id", "Sandbox network interface")
            }
        }()
        let logicalPort = OVNLogicalSwitchPort(
            name: portName,
            addresses: [Self.portAddressEntry(mac: macAddress, ips: ipAddresses)],
            port_security: [Self.portSecurityEntry(mac: macAddress, ips: ipAddresses)],
            dhcpv4_options: dhcpOptionsUUID,
            dhcpv6_options: dhcpV6OptionsUUID,
            // The name is a label for humans reading `ovn-nbctl list`; the id is
            // what identifies the network (issue #765). Ports are found by port
            // name, so neither is ever matched on.
            external_ids: [
                ownerKey: vmId,
                DHCPRowIdentity.networkIDKey: networkId.uuidString.lowercased(),
                DHCPRowIdentity.networkNameKey: networkName,
                "description": description,
            ]
        )
        return try await ovnManager?.createLogicalSwitchPort(logicalPort, onSwitch: switchName)
    }

    /// Adds a freshly created/reused LSP to its security groups' port groups
    /// plus the drop group. Throws `DependencyPendingError` when a group's
    /// port group doesn't exist — or exists without its generation stamp,
    /// i.e. its ACLs aren't realized yet (rows and ACLs commit in separate
    /// transactions) — the authority's sync realizes it and the VM create
    /// retries, so a managed NIC can never come up filtered by nothing. The
    /// drop group joins first: if a later add fails, the port is already
    /// default-deny rather than allow-only.
    private func joinSecurityGroups(portName: String, portUUID: String?, groupIds: [UUID]) async throws {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let groups =
            [OVNNaming.dropPortGroupName] + groupIds.map { OVNNaming.portGroupName(securityGroupId: $0) }.sorted()
        for group in groups {
            guard let portGroup = try await ovnManager.getPortGroup(named: group) else {
                throw DependencyPendingError(
                    "port group \(group) does not exist yet; waiting for the site's network controller to realize it"
                )
            }
            guard portGroup.external_ids?[Self.generationKey] != nil else {
                throw DependencyPendingError(
                    "port group \(group) exists but its ACLs are not realized yet; waiting for the site's network controller"
                )
            }
            guard let portUUID else { continue }
            if !(portGroup.ports ?? []).contains(portUUID) {
                try await ovnManager.addPorts([portUUID], toPortGroup: group)
            }
        }
        logger.debug(
            "Workload port joined security groups",
            metadata: [
                "portName": .string(portName),
                "groups": .stringConvertible(groups.count),
            ])
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

    private func createTAPInterface(vmId: String, nicIndex: Int, mtu: Int?) async throws -> String {
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

        // Match the host device to the MTU the guest is configured with. A
        // non-positive value is a bad row rather than a smaller MTU: skip it
        // rather than fail every create on that network.
        //
        // Two things to know about the blast radius (issue STR-100). This runs
        // on every reconcile, not just create, so it reaches VMs that have been
        // up since before it existed — a stale or wrong stored MTU surfaces
        // here. And OVS derives a bridge's internal-port MTU from the minimum
        // over its non-internal ports, so the first VM on a lowered-MTU network
        // pulls `br-int`'s own MTU down host-wide. That is inert in a standard
        // OVN deployment (nothing routes via the br-int internal port), but it
        // is a host-scoped effect of a per-VM setting.
        if let mtu, mtu > 0 {
            try run("ip", ["link", "set", tapName, "mtu", String(mtu)])
        }

        // Bring the interface up (idempotent).
        try run("ip", ["link", "set", tapName, "up"])

        return tapName
    }

    /// Realizes one sandbox NIC into a jailed VMM's network namespace and binds
    /// it to `portName` on the integration bridge, returning the name of the TAP
    /// the jailed Firecracker will open (issue STR-100).
    ///
    /// The recipe (`SandboxNetnsAttachmentPlan`) is a veth pair straddling the
    /// namespace with `tc` redirects splicing the in-namespace end to a TAP,
    /// *not* the obvious "move the TAP in" — that was measured to silently kill
    /// the OVS port while leaving its OVSDB rows intact (STR-99).
    private func attachSandboxNICIntoNetns(
        sandboxId: String, nicIndex: Int, netnsName: String, owner: JailOwner,
        portName: String, mtu: Int?
    ) async throws -> String {
        guard let ipBinaryPath else {
            throw NetworkError.invalidConfiguration(
                "sandbox networking needs the iproute2 `ip` tool, which was not found on this host "
                    + "(looked in \(SandboxJailerResolver.ipBinaryCandidates.joined(separator: ", ")))")
        }
        guard let tcBinaryPath else {
            throw NetworkError.invalidConfiguration(
                "sandbox networking needs the iproute2 `tc` tool, which was not found on this host "
                    + "(looked in \(SandboxJailerResolver.tcBinaryCandidates.joined(separator: ", ")))")
        }

        let started = ContinuousClock.now
        let plan = SandboxNetnsAttachmentPlan.plan(
            sandboxId: sandboxId, nicIndex: nicIndex, netnsName: netnsName,
            owner: owner, logicalPortName: portName, mtu: mtu,
            ipBinaryPath: ipBinaryPath, tcBinaryPath: tcBinaryPath,
            bridge: Self.ovnIntegrationBridge, ovsTimeoutSeconds: Self.ovsCommandTimeoutSeconds)

        for command in plan.hostSetup {
            try await runNetnsCommand(command)
        }
        try run("ovs-vsctl", plan.ovsAttach)

        _ = try await verifyOVSBinding(
            verify: plan.ovsVerify, device: plan.vethHostName, portName: portName, stage: "attach")

        for command in plan.namespaceSetup {
            try await runNetnsCommand(command)
        }

        // Re-read after the namespace work. The veth host end never leaves the
        // host namespace, so in theory nothing above can have disturbed it —
        // but "moving a device out from under OVS silently kills its port while
        // the rows survive" is precisely what STR-99 measured, and proving the
        // binding *after* the move is what actually closes that loop. One
        // `ovs-vsctl get` against ~15 other spawns.
        let binding = try await verifyOVSBinding(
            verify: plan.ovsVerify, device: plan.vethHostName, portName: portName,
            stage: "namespace-setup")

        // Sandboxes are churn-heavy and cold start is a headline property, so
        // the cost of this path is measured rather than assumed.
        let elapsed = ContinuousClock.now - started
        let elapsedMs =
            elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        logger.info(
            "Sandbox NIC attached into namespace",
            metadata: [
                "sandboxId": .string(sandboxId),
                "nicIndex": .stringConvertible(nicIndex),
                "netns": .string(netnsName),
                "portName": .string(portName),
                "tap": .string(plan.tapName),
                "vethHost": .string(plan.vethHostName),
                "ofport": .string(binding.ofport.map(String.init) ?? "unset"),
                "elapsedMs": .stringConvertible(elapsedMs),
            ])

        return plan.tapName
    }

    /// Proves the veth host end is really bound on the integration bridge.
    ///
    /// Row existence is not evidence: OVS keeps the `Port` and `Interface` rows
    /// — same UUID, `iface-id` still set — even when the device behind them is
    /// unusable, so a check that looks the port up by name sees health where
    /// there are no packets. `ofport` and the `error` column are the only honest
    /// signals, and the result is never cached: `ofport` is not stable across a
    /// device's disappearance and return, observed 3 -> 4 (STR-99).
    ///
    /// `ovs-vsctl` waits for `ovs-vswitchd` to catch up before returning, so
    /// `ofport` should already be populated; the bounded retry covers the case
    /// where it isn't, because failing there would unwind an otherwise healthy
    /// create.
    ///
    /// Shared by the sandbox NIC path and the metadata namespace path (STR-49):
    /// both move a device that OVS has a port for, and both fail the same silent
    /// way, so they check the same way.
    private func verifyOVSBinding(
        verify: [String], device: String, portName: String, stage: String
    ) async throws -> OVSInterfaceBinding {
        var binding = OVSInterfaceBinding(ofport: nil, error: nil)
        for attempt in 1...Self.ovsBindingReadbackAttempts {
            binding = OVSInterfaceBinding.parse(try run("ovs-vsctl", verify))
            if binding.isBound { return binding }
            // An `error` is a verdict, not a race — retrying cannot clear it.
            if binding.error != nil { break }
            if attempt < Self.ovsBindingReadbackAttempts {
                try await Task.sleep(for: Self.ovsBindingReadbackDelay)
            }
        }
        throw NetworkError.ovsError(
            "OVS did not bind \(device) on \(Self.ovnIntegrationBridge) for port \(portName) "
                + "after \(stage) (ofport=\(binding.ofport.map(String.init) ?? "unset"), "
                + "error=\(binding.error ?? "none")) — the interface would report healthy and carry no packets")
    }

    /// Removes the host-side half of a sandbox NIC. Needs neither the namespace
    /// nor anything inside it: deleting the host veth end destroys its peer, and
    /// the peer's death takes the `tc` filters with it.
    ///
    /// Derived from the sandbox id alone — no jailer config, no ownership — so
    /// cleanup works on an agent that can no longer create what it is deleting.
    /// `deletesNamespace` is false for any NIC but the first: namespace lifetime
    /// belongs to the jail, not to one NIC.
    private func detachSandboxNICFromNetns(
        sandboxId: String, nicIndex: Int, netnsName: String, portName: String
    ) async throws {
        // Teardown must work on a host whose iproute2 has since been removed, or
        // was never resolved because the network service came up before the
        // probe. Falling back to the PATH-resolved name re-introduces a `PATH`
        // dependency the create path deliberately avoids — the right trade for
        // cleanup, which must attempt something rather than refuse.
        let usingPATHFallback = ipBinaryPath == nil
        let removal = SandboxNetnsAttachmentPlan.teardownCommands(
            sandboxId: sandboxId, nicIndex: nicIndex, netnsName: netnsName,
            ipBinaryPath: ipBinaryPath ?? "ip",
            bridge: Self.ovnIntegrationBridge, ovsTimeoutSeconds: Self.ovsCommandTimeoutSeconds,
            deletesNamespace: nicIndex == 0)

        do {
            try run("ovs-vsctl", removal.ovsDetach)
        } catch {
            logger.warning(
                "Failed to remove OVS port",
                metadata: [
                    "sandboxId": .string(sandboxId),
                    "error": .string(error.localizedDescription),
                ])
        }

        // Each remaining step is independently tolerant so a partial teardown
        // still removes everything it can.
        for command in removal.commands {
            do {
                try await runNetnsCommand(command)
            } catch {
                logger.warning(
                    "Failed to tear down sandbox NIC device",
                    metadata: [
                        "sandboxId": .string(sandboxId),
                        "command": .string(command.arguments.joined(separator: " ")),
                        "error": .string(error.localizedDescription),
                        // Without an absolute path this ran through `PATH`, which
                        // a service manager may have stripped — the likeliest
                        // cause of a failure that says only "not found".
                        "resolvedVia": .string(usingPATHFallback ? "PATH" : "absolute path"),
                    ])
            }
        }
    }

    /// Runs one planned `ip`/`tc` invocation, swallowing exactly the failures the
    /// plan declared benign (the state it establishes already holds).
    ///
    /// Uses the async `ProcessRunner` rather than this file's blocking `Process`
    /// shim: a sandbox attach spawns ~15 children, and blocking a cooperative
    /// thread for each would serialize the whole actor against a path whose
    /// latency *is* sandbox cold start. It also matches
    /// `FirecrackerSandboxRuntime.createNetns`, which creates the same namespace.
    private func runNetnsCommand(_ command: NetnsCommand) async throws {
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: command.executable),
            arguments: command.arguments,
            timeout: Self.netnsCommandTimeout)
        guard result.terminationStatus != 0 else { return }
        let detail = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.tolerates(detail) {
            logger.debug(
                "Namespace command already satisfied",
                metadata: [
                    "command": .string(command.arguments.joined(separator: " ")),
                    "output": .string(detail),
                ])
            return
        }
        throw NetworkError.tapError(
            networkCommandFailure(
                command.executable, command.arguments,
                CommandResult(status: result.terminationStatus, output: detail)))
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
        try runProcessAt("/usr/bin/env", [command] + arguments)
    }

    /// Runs an already-resolved executable, with no `PATH` lookup. The sandbox
    /// namespace path uses this: its binaries were located at agent start, and a
    /// stripped service-manager `PATH` must not be able to break a host the
    /// start-time probe declared usable.
    private func runProcessAt(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

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
            throw NetworkError.tapError(networkCommandFailure(command, arguments, result))
        }
        return result.output
    }

    /// The failure message for a network command, with a remediation appended
    /// when the output points at a host problem rather than a bad invocation.
    private func networkCommandFailure(
        _ command: String, _ arguments: [String], _ result: CommandResult
    ) -> String {
        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = "`\(command) \(arguments.joined(separator: " "))` failed (exit \(result.status)): \(detail)"
        if detail.contains("Operation not permitted") || detail.contains("Permission denied") {
            message +=
                " — the agent needs root or CAP_NET_ADMIN to manage TAP devices and OVS ports; "
                + "run it as root or grant the capability (e.g. systemd AmbientCapabilities=CAP_NET_ADMIN)."
        }
        // The sandbox namespace path is the only user of clsact/matchall/mirred,
        // and a kernel without those modules fails here rather than at load time.
        if detail.contains("Unknown qdisc") || detail.contains("Specified filter type not supported")
            || detail.contains("Unknown action")
        {
            message +=
                " — sandbox NICs need the kernel's traffic-control modules (sch_clsact, cls_matchall, "
                + "act_mirred); install the distribution's extra/modules package for the running kernel."
        }
        return message
    }

    /// Returns true if a network interface with the given name exists.
    private func tapDeviceExists(_ name: String) -> Bool {
        guard let result = try? runProcess("ip", ["link", "show", name]) else {
            return false
        }
        return result.status == 0
    }

    /// Parses an OVN logical switch port `addresses` entry (`"<mac> <ip>..."`
    /// with any number of per-family IPs, or just `"<mac>"`, or `"dynamic"`)
    /// into a MAC and its IP list. Both IPs of a dual-stack port must be
    /// recovered — dropping one on the re-attach path would silently strip
    /// that family from the port.
    static func parsePortAddress(_ addresses: [String]?) -> (mac: String, ips: [String]) {
        guard let first = addresses?.first(where: { !$0.isEmpty && $0.lowercased() != "dynamic" }) else {
            return ("", [])
        }
        let tokens = first.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let mac = tokens.first ?? ""
        return (mac, Array(tokens.dropFirst()))
    }

    private func generateMACAddress() -> String {
        // Generate a random MAC address with the locally administered bit set
        let bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        var macBytes = bytes
        macBytes[0] = (macBytes[0] & 0xFC) | 0x02  // Set locally administered bit

        return macBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Resolves the OVN `DHCP_Options` UUIDs a VM's port should bind to, per
    /// family. Nil when DHCP is disabled for the network or that family's
    /// subnet/gateway aren't known (OVN needs a CIDR and a server identity to
    /// answer). A nil member leaves the guest on the static cloud-init path
    /// for that family.
    private func resolveDHCPOptions(for config: VMNetworkConfig) async throws -> (v4: String?, v6: String?) {
        guard config.dhcpEnabled else {
            // DHCP was turned off for the network: delete its managed
            // DHCP_Options rows. The port columns are weak refs in the OVN
            // schema, so the deletion clears the binding on every port of the
            // network at once — a port update cannot do it (the row encoder
            // omits nil fields, so nil can never overwrite a stale binding).
            try await removeDHCPOptions(networkId: config.networkId, networkName: config.networkName)
            return (nil, nil)
        }

        let v4: String?
        if let subnet = config.subnet, let gateway = config.gateway {
            v4 = try await ensureDHCPOptions(
                networkId: config.networkId, networkName: config.networkName, subnet: subnet,
                gateway: gateway,
                dnsServers: config.dnsServers, domainName: config.domainName, leaseTime: config.leaseTime,
                metadataEnabled: config.metadataEnabled, resolverAddresses: config.resolverAddresses)
        } else {
            logger.warning(
                "DHCP enabled but subnet/gateway unknown; using static guest config",
                metadata: ["network": .string(config.networkName)])
            v4 = nil
        }

        let v6: String?
        if let subnet6 = config.subnet6 {
            v6 = try await ensureDHCPOptions6(
                networkId: config.networkId, networkName: config.networkName, subnet6: subnet6,
                dnsServers: config.dnsServers, domainName: config.domainName,
                resolverAddresses: config.resolverAddresses)
        } else {
            v6 = nil
        }

        return (v4, v6)
    }

    /// Deletes every strato-managed `DHCP_Options` row stamped with this
    /// network's name (both families, and any stale-subnet leftovers).
    /// Matching by the external-id rather than CIDR means renumbered networks
    /// are cleaned up too, and rows other networks own are never touched.
    private func removeDHCPOptions(networkId: UUID, networkName: String) async throws {
        guard let ovnManager else { return }
        let ownedID = DHCPRowIdentity.externalIDs(networkId: networkId, networkName: networkName)[
            DHCPRowIdentity.networkIDKey]
        for row in try await ovnManager.getDHCPOptions() {
            // Rows this network owns at any CIDR, plus any pre-upgrade row of
            // its own that was never stamped with an id — otherwise a network
            // whose DHCP was disabled before its first post-upgrade converge
            // would keep answering leases from a row nothing tracks.
            let owned =
                row.external_ids?[DHCPRowIdentity.managedKey] == DHCPRowIdentity.managedValue
                && row.external_ids?[DHCPRowIdentity.networkIDKey] == ownedID
            let legacy = DHCPRowIdentity.isLegacyOwned(row.external_ids, networkName: networkName)
            guard owned || legacy, let uuid = row.uuid else { continue }
            try await ovnManager.deleteDHCPOptions(uuid: uuid)
            logger.info(
                "Removed DHCP options for network with DHCP disabled",
                metadata: [
                    "network": .string(networkName),
                    "networkId": .string(networkId.uuidString),
                    "cidr": .string(row.cidr),
                ])
        }
    }

    /// This network's `DHCP_Options` row for `cidr`, adopting a pre-upgrade row
    /// that carries only the network's name. See `DHCPRowIdentity` for why the
    /// match is on the id and why adoption beats orphaning.
    private static func ownDHCPRow(
        in rows: [OVNDHCPOptions], networkId: UUID, networkName: String, cidr: String
    ) -> OVNDHCPOptions? {
        if let own = rows.first(where: {
            DHCPRowIdentity.isOwn($0.external_ids, rowCIDR: $0.cidr, cidr: cidr, networkId: networkId)
        }) {
            return own
        }
        // Deterministic if a malformed NB somehow holds two candidates: taking
        // the lowest row UUID beats skipping, which would strand a row live
        // ports still reference.
        return
            rows
            .filter {
                DHCPRowIdentity.isAdoptableLegacy(
                    $0.external_ids, rowCIDR: $0.cidr, cidr: cidr, networkName: networkName)
            }
            .min { ($0.uuid ?? "") < ($1.uuid ?? "") }
    }

    /// Find-or-update this network's `DHCP_Options` row for `subnet` and
    /// return its UUID. Idempotent across restarts and reconvergence: the
    /// network's existing row for the same CIDR is updated in place (so
    /// DNS/lease edits converge) rather than duplicated.
    ///
    /// `metadataEnabled` and `resolverEnabled` must be derived from the same
    /// `LogicalNetwork` columns on both callers — the NIC path reads
    /// `NetworkSpec.metadataEnabled`/`.resolverEnabled`, the network path
    /// `DesiredNetworkState`'s — or the two would author different option maps
    /// for one row and rewrite it on every pass.
    private func ensureDHCPOptions(
        networkId: UUID, networkName: String, subnet: String, gateway: String,
        dnsServers: [String], domainName: String?, leaseTime: Int?, metadataEnabled: Bool,
        resolverAddresses: [String]
    ) async throws -> String? {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let options = OVNDHCPOptionsBuilder.v4Options(
            gateway: gateway, dnsServers: dnsServers, domainName: domainName, leaseTime: leaseTime,
            subnet: subnet, metadataEnabled: metadataEnabled, resolverAddresses: resolverAddresses)
        let externalIDs = DHCPRowIdentity.externalIDs(networkId: networkId, networkName: networkName)
        let dhcp = OVNDHCPOptions(cidr: subnet, options: options, external_ids: externalIDs)

        if let existing = Self.ownDHCPRow(
            in: try await ovnManager.getDHCPOptions(), networkId: networkId, networkName: networkName,
            cidr: subnet),
            let uuid = existing.uuid
        {
            // The external-ids are part of what converges, not just the
            // options: an adopted legacy row needs stamping with its
            // `network-id`, and a renamed network needs its label refreshed.
            if existing.options != options || existing.external_ids != externalIDs {
                try await ovnManager.updateDHCPOptions(uuid: uuid, dhcp)
            }
            return uuid
        }
        return try await ovnManager.createDHCPOptions(dhcp)
    }

    /// The DHCPv6 sibling of `ensureDHCPOptions`. OVN keys the DHCP family
    /// off the `DHCP_Options` row's CIDR — an IPv6 CIDR makes it a DHCPv6
    /// row — so the mechanics are identical; only the option grammar differs
    /// (see `OVNDHCPOptionsBuilder.v6Options`).
    private func ensureDHCPOptions6(
        networkId: UUID, networkName: String, subnet6: String, dnsServers: [String],
        domainName: String?, resolverAddresses: [String]
    ) async throws -> String? {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let options = OVNDHCPOptionsBuilder.v6Options(
            dnsServers: dnsServers, domainName: domainName, subnet6: subnet6,
            resolverAddresses: resolverAddresses)
        let externalIDs = DHCPRowIdentity.externalIDs(networkId: networkId, networkName: networkName)
        let dhcp = OVNDHCPOptions(cidr: subnet6, options: options, external_ids: externalIDs)

        if let existing = Self.ownDHCPRow(
            in: try await ovnManager.getDHCPOptions(), networkId: networkId, networkName: networkName,
            cidr: subnet6),
            let uuid = existing.uuid
        {
            if existing.options != options || existing.external_ids != externalIDs {
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
    ///
    /// `authoritative: false` means another agent (the site's network
    /// controller) authors the shared NB this agent writes its ports to
    /// (issue #343): topology is left entirely alone — reconciling here, even
    /// with an empty list, would tear down the controller's objects.
    func reconcileNetworks(
        _ networks: [DesiredNetworkState], authoritative: Bool,
        securityGroups: [DesiredSecurityGroup]?, portMemberships: [DesiredPortMembership],
        metadataNetworks: [UUID]?, resolverNetworks: [ResolverNetworkConfig]?,
        dnsZones: [DesiredDNSZone]?
    ) async {
        topologyAuthority = authoritative

        #if os(Linux)
        guard isConnected else {
            logger.debug("Network service not connected; skipping network reconciliation")
            return
        }
        #endif

        // The chassis half of the link-local services — instance metadata
        // (STR-49) and the network's resolver (STR-40) — converged before the
        // authority guard because it is per-host state this agent owns even when
        // it may not author topology, the `portMemberships` pattern. A sited
        // non-controller agent gets an empty `networks` list by design, yet its
        // guests need those addresses materialized locally just the same, so the
        // input is its own workloads' NIC specs.
        await reconcileChassisServicePorts(metadataNetworks)

        // The resolver's own host-namespace feet and the CoreDNS that binds
        // them, converged here for the chassis ports' reason and immediately
        // after them. Also before the authority guard — a resolver serves the
        // guests on *this* host, so it runs wherever they do. It does not
        // depend on the chassis namespace above: since ADR 0008 the two
        // services have separate ports and separate namespaces.
        await reconcileResolvers(resolverNetworks, dnsZones: dnsZones)

        guard authoritative else {
            logger.debug("Not the site's network topology authority; skipping network reconciliation")
            // Membership is per-VM state this host owns even without topology
            // authority — its ports join the port groups the site's
            // controller authors (the LSP-binding pattern, issue #343).
            await SecurityGroupReconciler.reconcileMembership(
                memberships: portMemberships, actuator: self, logger: logger)
            return
        }

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
        var protected = NetworkReconciler.protectedTopology(forStale: stale)
        // A control plane that predates `metadataEnabled` says nothing about
        // metadata ports, and teardown is a set difference — so without this a
        // rollback would delete every live port on the next sync. See
        // `serviceLocalPortProtection(for:)`.
        protected.formUnion(NetworkReconciler.serviceLocalPortProtection(for: current))

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

        // Converge each network's DHCP_Options rows here, level-triggered,
        // not only when a NIC is realized: DHCP edits don't bump VM or
        // network generations, and converged VMs never re-run createVMNetwork,
        // so this is the only path that reaches a live network whose DHCP
        // config changed — including deleting its rows when DHCP is turned
        // off (their weak refs clear every port's binding). A nil dhcpEnabled
        // means the control plane predates the field; leave the rows to the
        // NIC-driven path exactly as before.
        for network in current {
            guard let dhcpEnabled = network.dhcpEnabled else { continue }
            await attemptDHCPConvergence(for: network, dhcpEnabled: dhcpEnabled)
        }

        // DNS zones (STR-39), converged here for the DHCP rows' reason and on
        // the same terms: records change when a VM anywhere in the site is
        // created, renamed, or deleted, none of which bumps this network's
        // generation, so the level-triggered network reconcile is the only path
        // that reaches them. After the topology pass, because a zone attaches
        // to switches that pass is what creates. Nil means the control plane
        // has no DNS opinion — leave every managed row alone, exactly like a
        // nil `dhcpEnabled`.
        if let dnsZones {
            do {
                try await DNSZoneReconciler.reconcile(zones: dnsZones, actuator: self, logger: logger)
            } catch {
                // The row snapshot couldn't be read, so teardown can't be
                // computed safely; the periodic sync retries.
                logger.error(
                    "DNS zone reconciliation could not complete",
                    metadata: ["error": .string(error.localizedDescription)])
            }
        }

        // Security groups (authority side): converge port groups + ACLs, then
        // this host's own ports' membership. Nil means the control plane has
        // no security-group opinion (predates the feature, or omits the field
        // for this pre-v20-registered agent — impossible here, but the
        // contract stands): touch nothing, exactly like the `networks` list's
        // absence semantics.
        if let securityGroups {
            do {
                try await SecurityGroupReconciler.reconcile(
                    securityGroups: securityGroups, actuator: self, logger: logger)
            } catch {
                logger.error(
                    "Security-group reconciliation could not complete",
                    metadata: ["error": .string(error.localizedDescription)])
            }
        }
        await SecurityGroupReconciler.reconcileMembership(
            memberships: portMemberships, actuator: self, logger: logger)
    }

    /// Converge this chassis's metadata namespaces toward `desired` — the
    /// networks this host runs a metadata-enabled NIC on (STR-49).
    ///
    /// Level-triggered like everything else here: create what's missing, remove
    /// what's no longer wanted. Nil means the control plane predates the field
    /// and has no opinion; converging an empty set against it would tear down
    /// every live namespace on a rollback, so nil touches nothing — the
    /// `dhcpEnabled` contract.
    ///
    /// Observation keys off external-ids rather than the `mdp` name prefix, so
    /// an operator's own internal ports on `br-int` are never candidates for
    /// removal.
    private func reconcileResolvers(
        _ resolverNetworks: [ResolverNetworkConfig]?, dnsZones: [DesiredDNSZone]?
    ) async {
        #if os(Linux)
        guard let resolverNetworks else { return }
        guard let resolverSupervisor else {
            if !resolverNetworks.isEmpty {
                logger.debug(
                    "Networks want a resolver but this host has no usable CoreDNS; skipping",
                    metadata: ["networks": .stringConvertible(resolverNetworks.count)])
            }
            return
        }

        // The host-namespace foot for each network, converged before the
        // process: CoreDNS binds these addresses, and `bind` naming one that
        // does not exist makes it refuse to start — for every network at once,
        // now that one process serves them all.
        await reconcileResolverHostPorts(resolverNetworks)

        let zones = dnsZones ?? []
        let ipv6 = ResolverSupervisionPolicy.supportsIPv6()
        let networks = resolverNetworks.map { network in
            CoreDNSZoneRenderer.Network(
                networkId: network.networkId,
                bindAddresses: ResolverSupervisionPolicy.bindable(
                    network.addresses, ipv6Available: ipv6),
                zones: zones.filter { $0.networkIds.contains(network.networkId) },
                upstreams: network.upstreams,
                searchDomain: network.searchDomain)
        }
        await resolverSupervisor.reconcile(ResolverRenderRequest(networks: networks))
        #endif
    }

    /// Converge the host-namespace interface that terminates each network's
    /// resolver localport, plus its policy routing.
    private func reconcileResolverHostPorts(_ desired: [ResolverNetworkConfig]) async {
        #if os(Linux)
        guard let ovsManager, let ipBinaryPath else { return }
        let observed: [ObservedResolverHostPort]
        do {
            observed = try await observedResolverHostPorts(ovsManager)
        } catch {
            logger.error(
                "Could not read resolver host ports; skipping this pass",
                metadata: ["error": .string(error.localizedDescription)])
            return
        }
        let wanted = Dictionary(
            desired.map { ($0.networkId, $0) }, uniquingKeysWith: { first, _ in first })

        for action in ResolverHostPortReconciler.actions(
            desired: wanted.mapValues(\.addresses), observed: observed)
        {
            switch action {
            case .realize(let networkId, let addresses):
                await attemptResolverHostPortSetup(
                    networkId: networkId, addresses: addresses, ipBinaryPath: ipBinaryPath)
            case .remove(let networkId, let interfaceName, let addresses):
                await removeResolverHostPort(
                    networkId: networkId, interfaceName: interfaceName, addresses: addresses,
                    ipBinaryPath: ipBinaryPath)
            }
        }
        #endif
    }

    #if os(Linux)
    private func observedResolverHostPorts(_ ovsManager: OVSManager) async throws
        -> [ObservedResolverHostPort]
    {
        var found: [ObservedResolverHostPort] = []
        for interface in try await ovsManager.getInterfaces() {
            guard let ids = interface.external_ids,
                ids[ChassisServicePlan.managedKey] == ChassisServicePlan.managedValue,
                ids[ChassisServicePlan.roleKey] == ResolverHostPortPlan.roleValue,
                let raw = ids[ChassisServicePlan.networkIDKey],
                let networkId = UUID(uuidString: raw)
            else { continue }
            found.append(
                ObservedResolverHostPort(
                    networkId: networkId,
                    interfaceName: interface.name,
                    addresses: ResolverHostPortPlan.parseAddresses(
                        ids[ResolverHostPortPlan.addressesKey])))
        }
        return found
    }

    private func attemptResolverHostPortSetup(
        networkId: UUID, addresses: [String], ipBinaryPath: String
    ) async {
        // A missing `tc` costs the policer, not the resolver: an unlimited but
        // working resolver beats no resolver, and the host preflight already
        // reports the tool as absent.
        let plan = ResolverHostPortPlan.plan(
            networkId: networkId, addresses: addresses, ipBinaryPath: ipBinaryPath,
            tcBinaryPath: tcBinaryPath ?? "tc",
            bridge: Self.ovnIntegrationBridge, ovsTimeoutSeconds: Self.ovsCommandTimeoutSeconds,
            ratePPS: tcBinaryPath == nil ? 0 : linkLocalServiceRatePPS)
        do {
            try run("ovs-vsctl", plan.ovsAttach)
            _ = try await verifyOVSBinding(
                verify: plan.ovsVerify, device: plan.interfaceName, portName: plan.logicalPortName,
                stage: "attach")
            for command in plan.setup {
                try await runNetnsCommand(command)
            }
            logger.info(
                "Realized resolver host port",
                metadata: [
                    "networkId": .string(networkId.uuidString),
                    "interface": .string(plan.interfaceName),
                    "addresses": .string(addresses.joined(separator: ",")),
                ])
        } catch {
            logger.error(
                "Failed to realize resolver host port",
                metadata: [
                    "networkId": .string(networkId.uuidString),
                    "error": .string(error.localizedDescription),
                ])
            // Roll back so the next pass observes an honest "not built". A
            // half-built foot is worse here than elsewhere: CoreDNS binds these
            // addresses, so one that exists without its routing answers queries
            // whose replies go nowhere.
            await removeResolverHostPort(
                networkId: networkId, interfaceName: plan.interfaceName, addresses: addresses,
                ipBinaryPath: ipBinaryPath, quiet: true)
        }
    }

    private func removeResolverHostPort(
        networkId: UUID, interfaceName: String, addresses: [String], ipBinaryPath: String,
        quiet: Bool = false
    ) async {
        let removal = ResolverHostPortPlan.teardownPlan(
            networkId: networkId, interfaceName: interfaceName, addresses: addresses,
            ipBinaryPath: ipBinaryPath, bridge: Self.ovnIntegrationBridge,
            ovsTimeoutSeconds: Self.ovsCommandTimeoutSeconds)
        // Rules first: they outlive the interface, which the OVS detach
        // destroys. Removing the device first would strand every rule that named
        // its address, and those accumulate in the host's policy table.
        for command in removal.commands {
            try? await runNetnsCommand(command)
        }
        do {
            try run("ovs-vsctl", removal.ovsDetach)
        } catch {
            if !quiet {
                logger.warning(
                    "Failed to remove resolver host port",
                    metadata: [
                        "networkId": .string(networkId.uuidString),
                        "error": .string(error.localizedDescription),
                    ])
            }
            return
        }
        if !quiet {
            logger.info(
                "Removed resolver host port", metadata: ["networkId": .string(networkId.uuidString)])
        }
    }
    #endif

    private func reconcileChassisServicePorts(_ desired: [UUID]?) async {
        #if os(Linux)
        guard let desired else { return }
        guard let ovsManager else { return }

        let observed: [ObservedChassisServicePort]
        do {
            observed = try await observedChassisServicePorts(ovsManager)
        } catch {
            // Without a trustworthy snapshot, removals can't be computed safely.
            // Creates are idempotent, so skip the whole pass and let the next
            // periodic sync retry rather than guess.
            logger.error(
                "Could not read chassis service ports; skipping this pass",
                metadata: ["error": .string(error.localizedDescription)])
            return
        }

        for action in ChassisServiceReconciler.actions(desired: desired, observed: observed) {
            switch action {
            case .realize(let networkId):
                await attemptChassisServiceSetup(networkId: networkId)
            case .remove(let networkId, let interfaceName):
                await removeChassisServicePort(networkId: networkId, interfaceName: interfaceName)
            }
        }
        #endif
    }

    #if os(Linux)
    /// Every metadata interface this chassis currently owns, read from the
    /// interfaces' external-ids — never a name prefix, so an operator's own
    /// internal port on `br-int` is never a removal candidate.
    ///
    /// The namespace is probed alongside the row because the two have different
    /// lifetimes (see `ObservedChassisServicePort.namespacePresent`). A `stat` per
    /// network, no subprocess.
    private func observedChassisServicePorts(_ ovsManager: OVSManager) async throws
        -> [ObservedChassisServicePort]
    {
        var found: [ObservedChassisServicePort] = []
        for interface in try await ovsManager.getInterfaces() {
            guard let ids = interface.external_ids,
                ids[ChassisServicePlan.managedKey] == ChassisServicePlan.managedValue,
                ids[ChassisServicePlan.roleKey] == ChassisServicePlan.roleValue,
                let raw = ids[ChassisServicePlan.networkIDKey],
                let networkId = UUID(uuidString: raw)
            else { continue }
            found.append(
                ObservedChassisServicePort(
                    networkId: networkId,
                    interfaceName: interface.name,
                    namespacePresent: FileManager.default.fileExists(
                        atPath: ChassisServicePlan.netnsPath(networkId: networkId))))
        }
        return found
    }

    /// Realize one network's metadata namespace, logging and swallowing failure
    /// so one bad network can't stall the sync.
    ///
    /// The logical switch port this binds to may not exist yet: on a
    /// non-controller agent the site's network controller writes it, and the two
    /// syncs are independent. That needs no retry logic — `ovn-controller`
    /// simply leaves the port unbound until the row appears, and the next
    /// periodic sync re-verifies.
    private func attemptChassisServiceSetup(networkId: UUID) async {
        guard let ipBinaryPath else {
            let message =
                "Link-local services need the iproute2 `ip` tool, which was not found on this host; "
                + "guests on this network will not reach the metadata or resolver addresses"
            logger.warning(
                "\(message)",
                metadata: [
                    "networkId": .string(networkId.uuidString),
                    "searched": .string(SandboxJailerResolver.ipBinaryCandidates.joined(separator: ", ")),
                ])
            return
        }
        // A missing `tc` costs the policer, not the service: an unlimited but
        // working resolver beats no resolver, and the host preflight already
        // reports the tool as absent.
        let ratePPS = tcBinaryPath == nil ? 0 : linkLocalServiceRatePPS
        let plan = ChassisServicePlan.plan(
            networkId: networkId,
            ipBinaryPath: ipBinaryPath, tcBinaryPath: tcBinaryPath ?? "tc",
            bridge: Self.ovnIntegrationBridge, ovsTimeoutSeconds: Self.ovsCommandTimeoutSeconds,
            ratePPS: ratePPS)
        do {
            // Ordering is forced from both sides: the device cannot be moved
            // into a namespace that does not exist, and it cannot be moved
            // before the OVS attach creates it. Hence the attach between the two
            // halves of setup.
            for command in plan.namespaceSetup {
                try await runNetnsCommand(command)
            }
            try run("ovs-vsctl", plan.ovsAttach)
            _ = try await verifyOVSBinding(
                verify: plan.ovsVerify, device: plan.interfaceName, portName: plan.logicalPortName,
                stage: "attach")
            for command in plan.interfaceSetup {
                try await runNetnsCommand(command)
            }
            // Re-read after the move. Moving a TAP out from under OVS silently
            // kills its port while the rows survive (STR-99); an internal port
            // is a different animal and should be fine, but "should be fine" is
            // exactly what that bug looked like, so prove it.
            let binding = try await verifyOVSBinding(
                verify: plan.ovsVerify, device: plan.interfaceName, portName: plan.logicalPortName,
                stage: "namespace-setup")
            logger.info(
                "Realized chassis service namespace",
                metadata: [
                    "networkId": .string(networkId.uuidString),
                    "netns": .string(plan.netnsName),
                    "interface": .string(plan.interfaceName),
                    "port": .string(plan.logicalPortName),
                    "ofport": .string(binding.ofport.map(String.init) ?? "unset"),
                ])
        } catch {
            logger.error(
                "Failed to realize chassis service namespace",
                metadata: [
                    "networkId": .string(networkId.uuidString),
                    "error": .string(error.localizedDescription),
                ])
            // Roll the namespace back so the next pass observes an honest
            // "not built" and rebuilds from scratch. Without this a setup that
            // died between `netns add` and the addresses would leave a namespace
            // that looks realized to every future observation while carrying no
            // addresses — the same silent half-built state the reboot case
            // produces, just reached a different way.
            await removeChassisServicePort(
                networkId: networkId, interfaceName: plan.interfaceName, quiet: true)
        }
    }

    /// Remove one network's metadata namespace and its OVS port. Each step is
    /// independently tolerant so a partial teardown still removes what it can.
    ///
    /// `interfaceName` is the device observed on the bridge rather than one
    /// rederived here, so teardown removes what it actually found.
    ///
    /// `quiet` marks the rollback path, where a failure is the *expected* shape
    /// (there may be nothing to remove yet) and the real error has already been
    /// logged by the caller.
    private func removeChassisServicePort(
        networkId: UUID, interfaceName: String, quiet: Bool = false
    ) async {
        // Like sandbox teardown, cleanup falls back to the PATH-resolved name:
        // it must attempt something on a host whose iproute2 was never resolved,
        // rather than refuse and leak a namespace forever.
        let removal = ChassisServicePlan.teardownPlan(
            networkId: networkId, interfaceName: interfaceName, ipBinaryPath: ipBinaryPath ?? "ip",
            bridge: Self.ovnIntegrationBridge, ovsTimeoutSeconds: Self.ovsCommandTimeoutSeconds)
        var failures = 0
        do {
            try run("ovs-vsctl", removal.ovsDetach)
        } catch {
            failures += 1
            if !quiet {
                logger.warning(
                    "Failed to remove chassis service OVS port",
                    metadata: [
                        "networkId": .string(networkId.uuidString),
                        "interface": .string(interfaceName),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }
        for command in removal.commands {
            do {
                try await runNetnsCommand(command)
            } catch {
                failures += 1
                if !quiet {
                    logger.warning(
                        "Failed to remove metadata namespace",
                        metadata: [
                            "networkId": .string(networkId.uuidString),
                            "command": .string(command.arguments.joined(separator: " ")),
                            "error": .string(error.localizedDescription),
                        ])
                }
            }
        }
        // Only claim what actually happened: a partial teardown leaves state
        // behind, and logging success over it is how a leak stays invisible.
        guard failures == 0, !quiet else { return }
        logger.info(
            "Removed chassis service namespace",
            metadata: [
                "networkId": .string(networkId.uuidString), "interface": .string(interfaceName),
            ])
    }
    #endif

    /// Best-effort per-network DHCP row convergence; a failing network is
    /// logged and left for the next periodic sync, like reconcile steps.
    private func attemptDHCPConvergence(for network: DesiredNetworkState, dhcpEnabled: Bool) async {
        #if os(Linux)
        do {
            if !dhcpEnabled {
                try await removeDHCPOptions(networkId: network.networkId, networkName: network.name)
                return
            }
            if let gateway = network.gateway, let cidr = IPv4CIDR(network.subnet) {
                // Masked, so the row key matches what the NIC path derives
                // from ip+netmask (the stored subnet may carry host bits).
                _ = try await ensureDHCPOptions(
                    networkId: network.networkId,
                    networkName: network.name,
                    subnet: "\(cidr.networkAddress)/\(cidr.prefix)",
                    gateway: gateway,
                    dnsServers: network.dnsServers ?? [], domainName: network.domainName,
                    leaseTime: network.leaseTime,
                    // `== true`, matching how the topology plan reads these
                    // fields: a control plane with no opinion advertises no
                    // route rather than one to an address it never asked to
                    // have published — and, for the resolver, leaves the guest
                    // pointed at the configured servers rather than at an
                    // address that may terminate nothing.
                    metadataEnabled: network.metadataEnabled == true,
                    resolverAddresses: network.resolverEnabled == true
                        ? (network.resolverAddresses ?? []) : [])
            }
            if let subnet6 = network.subnet6 {
                _ = try await ensureDHCPOptions6(
                    networkId: network.networkId, networkName: network.name, subnet6: subnet6,
                    dnsServers: network.dnsServers ?? [], domainName: network.domainName,
                    resolverAddresses: network.resolverEnabled == true
                        ? (network.resolverAddresses ?? []) : [])
            }
        } catch {
            logger.error(
                "DHCP options convergence failed for network",
                metadata: [
                    "network": .string(network.name),
                    "networkId": .string(network.networkId.uuidString),
                    "error": .string(error.localizedDescription),
                ])
        }
        #endif
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
        var dnatRules = Set<DNATRuleKey>()
        for router in managedRouters {
            for uuid in router.nat ?? [] {
                guard let nat = natByUUID[uuid], Self.isManaged(nat.external_ids) else { continue }
                if nat.natType == "snat" {
                    snatRules.insert(SNATRuleKey(router: router.name, logicalIP: nat.logical_ip))
                } else if nat.natType == "dnat_and_snat" {
                    dnatRules.insert(DNATRuleKey(router: router.name, externalIP: nat.external_ip))
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
            snatRules: snatRules,
            dnatRules: dnatRules,
            // Metadata localports get their own set rather than joining
            // `switchRouterPortNames`, which is filtered to `type=router`. That
            // filter is also why an agent predating this field never swept a
            // localport it didn't understand — the ports were simply invisible
            // to its teardown diff.
            serviceLocalPortNames: Set(
                switchPorts.filter { $0.portType == Self.localPortType && Self.isManaged($0.external_ids) }
                    .map(\.name)))
        #else
        return ObservedNetworkTopology()
        #endif
    }

    /// Create or re-address a network's metadata `localport`.
    ///
    /// Deliberately without `port_security`, matching the localnet port: port
    /// security on a localport filters the agent's own replies to the guest.
    func ensureServiceLocalPort(_ port: DesiredServiceLocalPort) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let desired = OVNLogicalSwitchPort(
            name: port.name,
            portType: Self.localPortType,
            addresses: port.addresses,
            external_ids: [
                Self.managedKey: Self.managedValue,
                "description": "Strato instance metadata localport",
            ])
        if let existing = try await ovnManager.getLogicalSwitchPort(named: port.name) {
            // Re-write in place on drift: the port name is derived from the
            // network, so the row is stable across edits and a stale
            // type/address set would otherwise persist forever. Addresses
            // compared as a set — OVN's column is unordered.
            //
            // The switch the port sits on is deliberately not compared. Both the
            // port name and the switch name derive from the same network id, so
            // they can only disagree if an operator moved the port by hand —
            // and re-homing it would mean a delete and recreate, not an update,
            // which is a heavier repair than an unreachable case earns.
            let drifted =
                existing.portType != Self.localPortType
                || Set(existing.addresses ?? []) != Set(port.addresses)
            if drifted, let uuid = existing.uuid {
                try await ovnManager.updateLogicalSwitchPort(uuid: uuid, desired)
                logger.info(
                    "Updated metadata localport",
                    metadata: [
                        "port": .string(port.name),
                        "addresses": .string(port.addresses.joined(separator: ", ")),
                    ])
            }
            return
        }
        do {
            _ = try await ovnManager.createLogicalSwitchPort(desired, onSwitch: port.switchName)
        } catch {
            // Tolerate a concurrent creator that won the check→insert race.
            if try await ovnManager.getLogicalSwitchPort(named: port.name) == nil { throw error }
        }
        #endif
    }

    func removeServiceLocalPort(name: String) async throws {
        #if os(Linux)
        try? await ovnManager?.deleteLogicalSwitchPort(named: name)
        #endif
    }

    /// The managed `DNS` rows and the switches referencing each (STR-39).
    ///
    /// Ownership keys off the `strato-managed` + `dns-zone-id` external-ids
    /// this agent stamps, never the row's contents: the `DNS` table is a root
    /// table shared with whatever else runs against this northbound database,
    /// and an operator's own rows must be invisible to the teardown diff.
    func observeDNSZones() async throws -> [ObservedDNSZone] {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let rows = try await ovnManager.getDNS()
        // The attachment lives on the switch, so the reverse index is built
        // from the switch side. Unmanaged switches are included deliberately:
        // a managed row attached to a switch this agent doesn't author is
        // still an attachment it has to be able to see (and detach).
        var switchesByRow: [String: Set<String>] = [:]
        for logicalSwitch in try await ovnManager.getLogicalSwitches() {
            for uuid in logicalSwitch.dnsRecords ?? [] {
                switchesByRow[uuid, default: []].insert(logicalSwitch.name)
            }
        }
        return rows.compactMap { row in
            guard let uuid = row.uuid, let zoneId = DNSRowIdentity.ownedZoneID(row.external_ids) else {
                return nil
            }
            return ObservedDNSZone(
                uuid: uuid,
                zoneId: zoneId,
                recordsHash: row.external_ids?[DNSRowIdentity.recordsHashKey],
                zoneName: row.external_ids?[DNSRowIdentity.zoneNameKey],
                records: row.records,
                switchNames: switchesByRow[uuid] ?? [])
        }
        #else
        return []
        #endif
    }

    /// Apply one zone's decided convergence. The write says what changed, so a
    /// zone whose records are unchanged costs no OVSDB transaction at all —
    /// which is the whole point of the stamp, since a zone's record map is
    /// O(VMs on its networks) and ships on every sync.
    func ensureDNSZone(_ write: DNSZoneWrite) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let desired = OVNDNS(records: write.plan.records, external_ids: write.plan.externalIDs)
        let uuid: String
        if let existing = write.existingUUID {
            uuid = existing
            if write.rewriteRecords {
                try await ovnManager.updateDNS(uuid: existing, desired)
                logger.info(
                    "Updated DNS zone records",
                    metadata: [
                        "zone": .string(write.plan.zoneName),
                        "records": .stringConvertible(write.plan.records.count),
                    ])
            }
        } else {
            uuid = try await ovnManager.createDNS(desired)
            logger.info(
                "Realized DNS zone",
                metadata: [
                    "zone": .string(write.plan.zoneName),
                    "records": .stringConvertible(write.plan.records.count),
                ])
        }

        // Per-switch tolerance: the switch may not exist yet (its network's
        // reconcile step failed this pass), and one unattachable switch must
        // not cost the zone its other attachments. Retried by the next
        // level-triggered sync, which recomputes the diff from observation.
        for switchName in write.attach {
            do {
                try await ovnManager.attachDNS(uuid: uuid, toSwitch: switchName)
            } catch {
                logger.warning(
                    "Could not attach DNS zone to switch (retried next sync)",
                    metadata: [
                        "zone": .string(write.plan.zoneName),
                        "switch": .string(switchName),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }
        for switchName in write.detach {
            do {
                try await ovnManager.detachDNS(uuid: uuid, fromSwitch: switchName)
            } catch {
                logger.warning(
                    "Could not detach DNS zone from switch (retried next sync)",
                    metadata: [
                        "zone": .string(write.plan.zoneName),
                        "switch": .string(switchName),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }
        #endif
    }

    func removeDNSZone(uuid: String) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        try await ovnManager.deleteDNS(uuid: uuid)
        logger.info("Removed DNS zone row", metadata: ["row": .string(uuid)])
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
            name: port.name, mac: port.mac, cidrs: port.cidrs,
            ipv6RAConfigs: port.ipv6RAConfigs,
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
        // dedicated external address. Dual-stack when the operator supplied an
        // `external_cidr6`: the same port then also claims the v6 external
        // address that IPv6 SNAT translates to (issue #519). A malformed
        // `external_cidr6` degrades the uplink to v4 rather than failing it —
        // mirroring how a bad tenant v6 config degrades a tenant router port.
        var uplinkCIDRs = [uplink.externalCIDR]
        if let externalCIDR6 = uplink.externalCIDR6 {
            // Canonical form, so a non-canonical operator spelling doesn't read
            // as port drift on every reconcile. `base`, not `networkAddress`:
            // this is the port's own host address, not the prefix.
            if let cidr6 = IPv6CIDR(externalCIDR6) {
                uplinkCIDRs.append("\(cidr6.base)/\(cidr6.prefix)")
            } else {
                logger.error(
                    "OVN uplink external_cidr6 is not a valid ip/prefix; realizing a v4-only uplink",
                    metadata: ["externalCIDR6": .string(externalCIDR6)])
            }
        }
        try await ensureRouterPort(
            name: router.externalRouterPortName, mac: uplinkMAC, cidrs: uplinkCIDRs,
            switchName: router.externalSwitchName, switchPortName: router.externalSwitchRouterPortName,
            router: router.name)

        // Pin the gateway port to this chassis. OVN only programs centralized
        // SNAT on the chassis holding the router's distributed gateway port,
        // so without a Gateway_Chassis binding the NAT rule sits in the NB
        // unprogrammed and VM traffic egresses un-NAT'd (issue #372).
        try await ensureGatewayChassis(onPort: router.externalRouterPortName)

        // Default route out the uplink, so SNAT'd traffic to off-subnet
        // destinations actually has a route (the NAT rule alone is not enough).
        if let nextHop = uplink.gateway {
            try await ensureDefaultRoute(router: router.name, nextHop: nextHop, family: .v4)
        } else {
            let message =
                "OVN uplink has no gateway; skipping the router default route "
                + "(SNAT egress limited to the external subnet)"
            logger.warning("\(message)", metadata: ["router": .string(router.name)])
        }

        // The v6 sibling. Independent of the v4 route: each reconciles only its
        // own family's default prefix, so one family's absence never disturbs
        // the other. Only meaningful once the port carries a v6 address.
        var installedIPv6Default = false
        if uplinkCIDRs.count > 1 {
            if let nextHop6 = uplink.gateway6 {
                // Validate here rather than letting ensureDefaultRoute throw: a
                // throw escapes ensureUplink, reconcile records the uplink as
                // not ready, and it then skips *every* SNAT rule on the router —
                // so a typo in the optional v6 next hop would take IPv4 egress
                // down with it. Degrade to a v4 uplink instead.
                if IPv6Address(nextHop6) != nil {
                    try await ensureDefaultRoute(router: router.name, nextHop: nextHop6, family: .v6)
                    installedIPv6Default = true
                } else {
                    logger.error(
                        "OVN uplink gateway6 is not a valid IPv6 address; skipping the IPv6 default route",
                        metadata: ["router": .string(router.name), "gateway6": .string(nextHop6)])
                }
            } else {
                let message =
                    "OVN uplink has no gateway6; skipping the router IPv6 default route "
                    + "(IPv6 SNAT egress limited to the external subnet)"
                logger.warning("\(message)", metadata: ["router": .string(router.name)])
            }
        }
        // Every path that does NOT install a `::/0` must also drop one we
        // installed earlier — a removed `external_cidr6`, a removed or now
        // malformed `gateway6`. Topology teardown covers switches, ports,
        // routers, and SNAT, never static routes, so nothing else would: the
        // router would keep steering v6 traffic at a next hop the config no
        // longer names. Never let this throw — it would escape ensureUplink and
        // cost the router its IPv4 SNAT, the very coupling fixed above.
        if !installedIPv6Default {
            do {
                try await removeManagedDefaultRoute(router: router.name, family: .v6)
            } catch {
                logger.error(
                    "Failed to remove the stale IPv6 default route",
                    metadata: ["router": .string(router.name), "error": .string("\(error)")])
            }
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
        // SNAT to the configured dedicated external IP of the rule's own address
        // family (reconcile only calls this after ensureUplink returned true, so
        // the v4 uplink config is present/valid).
        let externalIP: String
        if IPv6CIDR(logicalIP) != nil {
            // An IPv6 uplink is optional and additive, so a dual-stack tenant
            // network on a v4-only uplink is a normal configuration, not an
            // error. Skip the rule rather than throw: reconcile catches per
            // subnet, so throwing wouldn't break v4 egress, but it would log an
            // error every pass for a site that simply has no IPv6 uplink.
            guard let externalIP6 = uplinkConfig?.externalIP6 else {
                logger.warning(
                    "IPv6 SNAT skipped: no external_cidr6 configured on the OVN uplink",
                    metadata: ["router": .string(routerName), "logicalIP": .string(logicalIP)])
                // Drop any rule an earlier, since-removed v6 uplink left behind.
                // Teardown can't: the plan still *wants* this rule (planning is
                // pure and can't see the uplink config), so the stale rule is
                // desired-and-observed and never classified as extra. It would
                // otherwise keep translating to an external address the port no
                // longer claims — worse than having no IPv6 egress at all.
                //
                // Managed-only, unlike the teardown path's `removeSNAT`: that
                // one is fed logical IPs `observeTopology` already filtered to
                // managed rules, whereas this runs on every pass against a
                // logical IP straight from the plan. A site that wires its own
                // IPv6 egress — plausible precisely because Strato lacked it —
                // would otherwise have its hand-authored rule deleted on every
                // reconcile.
                try await removeManagedSNAT(router: routerName, logicalIP: logicalIP)
                return
            }
            externalIP = externalIP6
        } else {
            guard let externalIP4 = uplinkConfig?.externalIP else {
                throw NetworkError.invalidConfiguration(
                    "SNAT for \(logicalIP) requested without a configured uplink external IP")
            }
            externalIP = externalIP4
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

    /// Remove only *this agent's* SNAT rule for `logicalIP`. The counterpart to
    /// `removeSNAT` for callers that haven't already filtered to managed rules:
    /// teardown acts on logical IPs `observeTopology` narrowed to the
    /// `strato-managed` set, but a withdrawn-config cleanup works from the plan
    /// and would otherwise delete an operator's own rule for the same subnet.
    func removeManagedSNAT(router routerName: String, logicalIP: String) async throws {
        #if os(Linux)
        guard let ovnManager else { return }
        for rule in try await snatRules(onRouter: routerName)
        where rule.natType == "snat" && rule.logical_ip == logicalIP && Self.isManaged(rule.external_ids) {
            if let uuid = rule.uuid { try await ovnManager.deleteNATRule(uuid: uuid) }
        }
        #endif
    }

    func ensureDNAT(router routerName: String, rule: DesiredDNATRule) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        // Idempotent by external IP (the rule's identity): reuse a matching
        // rule; re-point one whose attachment (logical IP/port) drifted —
        // that's a floating IP moving to another VM, which must update in
        // place rather than delete/recreate.
        for existing in try await snatRules(onRouter: routerName)
        where existing.natType == "dnat_and_snat" && existing.external_ip == rule.externalIP {
            if existing.logical_ip == rule.logicalIP
                && existing.logical_port == rule.logicalPort
                && existing.external_mac == rule.externalMAC
            {
                return
            }
            if let uuid = existing.uuid { try await ovnManager.deleteNATRule(uuid: uuid) }
        }
        let nat = OVNNAT(
            natType: "dnat_and_snat", external_ip: rule.externalIP, logical_ip: rule.logicalIP,
            external_mac: rule.externalMAC, logical_port: rule.logicalPort,
            external_ids: [Self.managedKey: Self.managedValue])
        _ = try await ovnManager.createNATRule(nat, onRouter: routerName)
        logger.info(
            "Ensured floating IP NAT",
            metadata: [
                "router": .string(routerName),
                "externalIP": .string(rule.externalIP),
                "logicalIP": .string(rule.logicalIP),
            ])
        #endif
    }

    func removeDNAT(router routerName: String, externalIP: String) async throws {
        #if os(Linux)
        guard let ovnManager else { return }
        for rule in try await snatRules(onRouter: routerName)
        where rule.natType == "dnat_and_snat" && rule.external_ip == externalIP {
            if let uuid = rule.uuid { try await ovnManager.deleteNATRule(uuid: uuid) }
        }
        #endif
    }

    func ensureDynamicRouting(for router: DesiredRouter, uplinkReady: Bool) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        guard let lr = try await ovnManager.getLogicalRouter(named: router.name), let lrUUID = lr.uuid
        else { return }

        // Enabling needs a realized uplink (the gateway port is what faces
        // the fabric); everything else — disabled, absent, or an uplink that
        // went away — converges to stripped options.
        if let config = dynamicRoutingConfig, config.enabled, uplinkReady {
            // Router: enable + what to redistribute. `withoutDynamicRouting()`
            // first, so an option removed from the config (e.g. vrf_name) is
            // dropped rather than lingering.
            let redistribute = Set(
                config.redistribute.compactMap { OVNDynamicRoutingRedistribute(rawValue: $0) })
            let desired = lr.withoutDynamicRouting().withDynamicRouting(
                enabled: true, redistribute: redistribute, vrfName: config.vrfName)
            if (lr.options ?? [:]) != (desired.options ?? [:]) {
                try await ovnManager.updateLogicalRouter(uuid: lrUUID, desired)
                logger.info(
                    "Enabled OVN dynamic routing on router",
                    metadata: [
                        "router": .string(router.name),
                        "redistribute": .string(config.redistribute.joined(separator: ",")),
                    ])
            }
            // Gateway port: VRF maintenance + which protocol traffic to punt
            // to the local FRR. Only meaningful on the uplink port — it is the
            // port facing the fabric.
            if let port = try await ovnManager.getLogicalRouterPort(named: router.externalRouterPortName),
                let portUUID = port.uuid
            {
                let protocols = Set(config.routingProtocols.compactMap { OVNRoutingProtocol(rawValue: $0) })
                let desiredPort = port.withoutDynamicRoutingOverrides().withDynamicRouting(
                    maintainVRF: config.maintainVRF, routingProtocols: protocols)
                if (port.options ?? [:]) != (desiredPort.options ?? [:]) {
                    try await ovnManager.updateLogicalRouterPort(uuid: portUUID, desiredPort)
                }
            }
        } else {
            // Converge off: strip any dynamic-routing options this agent set
            // earlier. The row encoder omits nil maps (which would leave the
            // stale options in place), so an empty result is written as an
            // explicit `[:]` via a minimal model.
            let strippedOptions = lr.withoutDynamicRouting().options
            if (lr.options ?? [:]) != (strippedOptions ?? [:]) {
                try await ovnManager.updateLogicalRouter(
                    uuid: lrUUID, OVNLogicalRouter(name: lr.name, options: strippedOptions ?? [:]))
                logger.info(
                    "Disabled OVN dynamic routing on router", metadata: ["router": .string(router.name)])
            }
            if let port = try await ovnManager.getLogicalRouterPort(named: router.externalRouterPortName),
                let portUUID = port.uuid
            {
                let strippedPortOptions = port.withoutDynamicRoutingOverrides().options
                if (port.options ?? [:]) != (strippedPortOptions ?? [:]) {
                    try await ovnManager.updateLogicalRouterPort(
                        uuid: portUUID,
                        OVNLogicalRouterPort(
                            name: port.name, mac: port.mac, networks: port.networks,
                            options: strippedPortOptions ?? [:]))
                }
            }
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
/// Which address family a router's default route belongs to. Each family owns
/// its own default prefix and reconciles only that prefix, so a v4 and a v6
/// default coexist on one router without disturbing each other.
fileprivate enum DefaultRouteFamily {
    case v4
    case v6

    var defaultPrefix: String {
        switch self {
        case .v4: "0.0.0.0/0"
        case .v6: "::/0"
        }
    }
}

extension NetworkServiceLinux {
    /// Create a router port and its peering `type=router` switch port in an
    /// idempotent pair (both, or neither, so the switch never has a dangling
    /// router peer). Shared by tenant ports and the external gateway port.
    /// `ipv6_ra_configs` is always written as a concrete map (empty when nil)
    /// so removing IPv6 from a network clears the port's RA config — the row
    /// encoder omits nil fields, which would otherwise leave it stale.
    fileprivate func ensureRouterPort(
        name: String, mac: String, cidrs: [String], ipv6RAConfigs: [String: String]? = nil,
        switchName: String, switchPortName: String, router: String
    ) async throws {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let raConfigs = ipv6RAConfigs ?? [:]
        let desiredPort = OVNLogicalRouterPort(
            name: name, mac: mac, networks: cidrs,
            ipv6_ra_configs: raConfigs,
            external_ids: ["strato-managed": "true"])
        if let existing = try await ovnManager.getLogicalRouterPort(named: name) {
            // Re-address in place when the network's gateway/subnet (either
            // family) or RA config changed: the port name is stable (derived
            // from the network), so without this an edit would leave a stale
            // CIDR/MAC/RA and break L3.
            let drifted =
                Set(existing.networks) != Set(cidrs)
                || existing.mac != mac
                || (existing.ipv6_ra_configs ?? [:]) != raConfigs
            if drifted, let uuid = existing.uuid {
                try await ovnManager.updateLogicalRouterPort(uuid: uuid, desiredPort)
                logger.info(
                    "Updated logical router port addressing",
                    metadata: ["port": .string(name), "cidrs": .string(cidrs.joined(separator: " "))])
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
        if try await ovsManager.getBridge(named: bridgeName) == nil {
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
        try await ensureBridgeLocalPort(bridgeName)
        await warnIfBridgeNetdevMissing(bridgeName)
    }

    /// Ensure the bridge-named internal `Port`/`Interface` pair exists.
    /// SwiftOVN's `createBridge` inserts only the `Bridge` row; without this
    /// pair `ovs-vswitchd` never instantiates the bridge's Linux netdev, so
    /// the bridge has no host presence and no localnet datapath (issue #371).
    /// `ovs-vsctl add-br` creates all three rows in one transaction — this
    /// repairs both freshly created bridges and ones from older agents.
    fileprivate func ensureBridgeLocalPort(_ bridgeName: String) async throws {
        guard let ovsManager else {
            throw NetworkError.notConnected("OVS manager not connected")
        }
        if try await ovsManager.getPort(named: bridgeName) != nil { return }
        do {
            _ = try await ovsManager.createPort(
                OVSPort(name: bridgeName, interfaces: []),
                withInterface: OVSInterface(name: bridgeName, interfaceType: "internal"),
                onBridge: bridgeName)
            logger.info("Created bridge internal port", metadata: ["bridge": .string(bridgeName)])
        } catch {
            // Tolerate a concurrent creator that won the check→insert race.
            if try await ovsManager.getPort(named: bridgeName) == nil { throw error }
        }
    }

    /// Log loudly when the bridge netdev hasn't materialized shortly after its
    /// OVSDB rows converged — the rows committing does not prove that
    /// `ovs-vswitchd` realized the datapath (issue #371's silent failure mode,
    /// where the operator cannot address the bridge or attach the physical
    /// NIC). Warning-only: OVSDB is the desired state and vswitchd may just be
    /// catching up; usually the first probe succeeds and this costs one exec.
    fileprivate func warnIfBridgeNetdevMissing(_ bridgeName: String) async {
        for _ in 0..<10 {
            if let probe = try? runProcess("ip", ["link", "show", "dev", bridgeName]), probe.status == 0 {
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let message =
            "Provider bridge exists in OVSDB but its netdev did not appear; "
            + "host-side uplink wiring (addressing the bridge, attaching the external NIC) will fail"
        logger.warning("\(message)", metadata: ["bridge": .string(bridgeName)])
    }

    /// Bind the router's external gateway port to the local chassis (the OVS
    /// `system-id` that `ovn-controller` registers southbound). Only the
    /// uplink-authoring agent — the site's network controller — reaches this,
    /// so the local chassis is the site's designated SNAT gateway; stale
    /// Strato-managed bindings to other chassis (host re-provisioned, role
    /// moved) are removed, operator-authored rows are left alone.
    fileprivate func ensureGatewayChassis(onPort portName: String) async throws {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let chassisName = try localChassisSystemID()
        guard let port = try await ovnManager.getLogicalRouterPort(named: portName) else {
            throw NetworkError.ovnError(
                "external router port \(portName) not found while binding its gateway chassis")
        }
        let refs = Set(port.gateway_chassis ?? [])
        let bindings: [GatewayChassisBinding] = try await ovnManager.getGatewayChassis().compactMap { row in
            guard let uuid = row.uuid, refs.contains(uuid) else { return nil }
            return GatewayChassisBinding(
                uuid: uuid, chassisName: row.chassis_name, managed: Self.isManaged(row.external_ids))
        }
        let actions = GatewayChassisPlan.plan(localChassis: chassisName, existing: bindings)
        for uuid in actions.deleteUUIDs {
            try await ovnManager.deleteGatewayChassis(uuid: uuid)
            logger.info("Removed stale gateway chassis binding", metadata: ["port": .string(portName)])
        }
        if actions.createForLocalChassis {
            let binding = OVNGatewayChassis(
                name: OVNNaming.gatewayChassisName(portName: portName, chassis: chassisName),
                chassis_name: chassisName, priority: 1,
                external_ids: [Self.managedKey: Self.managedValue])
            _ = try await ovnManager.createGatewayChassis(binding, onRouterPort: portName)
            logger.info(
                "Bound external router port to gateway chassis",
                metadata: ["port": .string(portName), "chassis": .string(chassisName)])
        }
    }

    /// The chassis `system-id` of the local OVS — the name `ovn-controller`
    /// registers in the southbound `Chassis` table (set or verified by
    /// `ensureChassisConfiguration` at connect time).
    fileprivate func localChassisSystemID() throws -> String {
        let result = try runProcess(
            "ovs-vsctl",
            ["--timeout=\(Self.ovsCommandTimeoutSeconds)", "get", "open_vswitch", ".", "external_ids"])
        guard result.status == 0 else {
            throw NetworkError.ovsError(
                "cannot read chassis external_ids (exit \(result.status)): "
                    + result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let systemID = OVNChassisBootstrap.parseExternalIDs(result.output)["system-id"],
            !systemID.isEmpty
        else {
            throw NetworkError.invalidConfiguration(
                "the local OVS has no external_ids:system-id, so the SNAT gateway cannot be "
                    + "bound to this chassis. Enable ovn_bootstrap_chassis in the agent "
                    + "configuration or set external_ids:system-id on the OVS.")
        }
        return systemID
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
    /// route out. Uses SwiftOVN's `Logical_Router_Static_Route` API directly
    /// against the NB DB — no `ovn-nbctl` dependency on the host.
    ///
    /// `family` is declared by the caller, never sniffed from `nextHop`:
    /// `[ovn_uplink] gateway` is the IPv4 next hop and `gateway6` the IPv6 one,
    /// so an address of the wrong family is an operator error to reject, not a
    /// family to infer. Inferring it would let a v6 address in `gateway` install
    /// a `::/0`, skip `0.0.0.0/0` entirely, and still report the uplink ready —
    /// leaving IPv4 SNAT running over a router with no IPv4 default route.
    fileprivate func ensureDefaultRoute(
        router routerName: String, nextHop: String, family: DefaultRouteFamily
    ) async throws {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        // The native OVSDB path writes nexthop verbatim, so validate the gateway
        // ourselves — the old `ovn-nbctl lr-route-add` rejected a malformed one.
        // Throwing keeps this a failed uplink instead of committing a broken route
        // and then proceeding to install SNAT over silently dead egress.
        let defaultPrefix = family.defaultPrefix
        let hop: String
        switch family {
        case .v4:
            guard IPv4Address(nextHop) != nil else {
                throw NetworkError.invalidConfiguration(
                    "OVN uplink gateway '\(nextHop)' is not a valid IPv4 address; cannot install default route")
            }
            hop = nextHop
        case .v6:
            // Canonicalized, so a non-canonical operator spelling
            // (`2001:0db8::1`) doesn't read as drift on every reconcile.
            guard let address6 = IPv6Address(nextHop) else {
                throw NetworkError.invalidConfiguration(
                    "OVN uplink gateway6 '\(nextHop)' is not a valid IPv6 address; cannot install default route"
                )
            }
            hop = address6.description
        }
        // The agent owns L3 on this router (deterministically named, created with
        // the managed external ID), so it owns the router's default route too.
        // Mirrors ensureSNAT's reconcile-in-place stance.
        let route = OVNLogicalRouterStaticRoute(
            ip_prefix: defaultPrefix, nexthop: hop,
            external_ids: [Self.managedKey: Self.managedValue])
        // Only the main-table dst-ip default is the one the agent owns and that the
        // old `ovn-nbctl lr-route-add` (no --policy/--route-table) reconciled. Leave
        // src-ip or named-route-table default routes (operator policy routing)
        // untouched. OVN defaults an unset policy to dst-ip and an unset route_table
        // to the main table, matching the route we create below.
        let defaults = try await staticRoutes(onRouter: routerName).filter {
            $0.ip_prefix == defaultPrefix
                && ($0.policy ?? "dst-ip") == "dst-ip"
                && ($0.route_table ?? "").isEmpty
        }
        // Keep at most one route that already matches the desired tagged route;
        // every other default is stale, drifted, legacy-untagged, or a duplicate
        // from an earlier/concurrent reconcile. Delete them all so exactly one
        // default per family remains and OVN can't fall back to a stale next hop.
        let keep = defaults.first(where: { $0.nexthop == hop && Self.isManaged($0.external_ids) })
        for existing in defaults where existing.uuid != keep?.uuid {
            if let uuid = existing.uuid { try await ovnManager.deleteStaticRoute(uuid: uuid) }
        }
        // Install the desired route only when nothing already matched.
        if keep == nil {
            _ = try await ovnManager.createStaticRoute(route, onRouter: routerName)
        }
        logger.info(
            "Installed default route on logical router",
            metadata: [
                "router": .string(routerName), "prefix": .string(defaultPrefix), "nextHop": .string(hop),
            ])
    }

    /// Delete this agent's own default route for `prefix` on `router`, if one is
    /// there. The counterpart to `ensureDefaultRoute` for the case where the
    /// operator withdrew the config that justified the route; topology teardown
    /// never touches static routes, so without this a withdrawn uplink leaves a
    /// live route behind.
    ///
    /// Only the managed main-table dst-ip route is removed. `ensureDefaultRoute`
    /// also clears untagged duplicates, but that is safe only because it is
    /// replacing them — here there is no replacement, so an operator's own
    /// default (untagged, or policy/named-table) is left alone.
    fileprivate func removeManagedDefaultRoute(router routerName: String, family: DefaultRouteFamily) async throws {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let prefix = family.defaultPrefix
        for route in try await staticRoutes(onRouter: routerName)
        where route.ip_prefix == prefix
            && (route.policy ?? "dst-ip") == "dst-ip"
            && (route.route_table ?? "").isEmpty
            && Self.isManaged(route.external_ids)
        {
            guard let uuid = route.uuid else { continue }
            try await ovnManager.deleteStaticRoute(uuid: uuid)
            logger.info(
                "Removed stale default route from logical router",
                metadata: ["router": .string(routerName), "prefix": .string(prefix)])
        }
    }

    /// The static routes attached to a router, resolved from its
    /// `static_routes` refs. Mirrors `snatRules(onRouter:)`.
    fileprivate func staticRoutes(onRouter routerName: String) async throws -> [OVNLogicalRouterStaticRoute] {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        guard let routeUUIDs = try await ovnManager.getLogicalRouter(named: routerName)?.static_routes,
            !routeUUIDs.isEmpty
        else { return [] }
        let byUUID = Dictionary(
            uniqueKeysWithValues: try await ovnManager.getStaticRoutes().compactMap { route in
                route.uuid.map { ($0, route) }
            })
        return routeUUIDs.compactMap { byUUID[$0] }
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

// MARK: - Security-group actuation (OVN port groups + ACLs)

extension NetworkServiceLinux: SecurityGroupActuator {
    /// External-id key carrying the generation a port group's ACL set was
    /// built from; absence forces a rewrite (see `needsACLRewrite`) and marks
    /// the group not-yet-enforcing for the membership paths — the row can
    /// exist committed transactions before its ACLs do.
    static let generationKey = "strato-generation"
    /// External-id key carrying the `aclSchemaRevision` that wrote the ACLs,
    /// so builder fixes roll out on agent upgrade without waiting for rule
    /// edits to bump each group's generation.
    static let builderRevisionKey = "strato-builder-rev"

    func observeSecurityGroups() async throws -> [ObservedPortGroup] {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        return try await ovnManager.getPortGroups()
            .filter { Self.isManaged($0.external_ids) }
            .map {
                ObservedPortGroup(
                    name: $0.name,
                    generation: $0.external_ids?[Self.generationKey].flatMap(Int64.init),
                    builderRevision: $0.external_ids?[Self.builderRevisionKey].flatMap(Int64.init))
            }
        #else
        return []
        #endif
    }

    func ensurePortGroup(_ plan: PortGroupPlan) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }

        let pgUUID: String
        var supersededACLs: [String] = []
        if let existing = try await ovnManager.getPortGroup(named: plan.name) {
            guard
                SecurityGroupReconciler.needsACLRewrite(
                    planned: plan.generation,
                    observed: existing.external_ids?[Self.generationKey].flatMap(Int64.init),
                    observedBuilderRevision: existing.external_ids?[Self.builderRevisionKey]
                        .flatMap(Int64.init))
            else { return }
            guard let uuid = existing.uuid else {
                throw NetworkError.ovnError("Port group \(plan.name) has no UUID")
            }
            pgUUID = uuid
            supersededACLs = existing.acls ?? []
        } else {
            // Created without the generation stamp: the membership paths read
            // a stamp-less group as not-yet-enforcing and refuse to join it,
            // so a port can never go live behind a group whose ACLs aren't
            // written yet. `ports` stays untouched here and always
            // (membership belongs to each VM's hosting agent).
            pgUUID = try await ovnManager.createPortGroup(
                OVNPortGroup(name: plan.name, external_ids: [Self.managedKey: Self.managedValue]))
        }

        // Full replace, NEW SET FIRST: OVN ACL rows have no natural key to
        // diff on, and each write is its own OVSDB transaction. Creating
        // before deleting means the group never has *fewer* ACLs than it
        // started with — with both sets present the drops still drop and the
        // allows still allow, so live members (the drop group holds every
        // managed port on the site) never lose their default-deny, and a rule
        // edit never blacks out the group's allows. Deleting first would open
        // exactly those windows. Duplicates during the overlap are harmless.
        for acl in plan.acls {
            _ = try await ovnManager.createACL(
                OVNACL(
                    priority: acl.priority,
                    direction: acl.direction,
                    match: acl.match,
                    action: acl.action,
                    // Per-rule logging (STR-34). `name` is what identifies the
                    // rule in the emitted line, so it rides with `log`.
                    log: acl.log,
                    severity: acl.severity,
                    name: acl.name,
                    external_ids: acl.externalIDs),
                onPortGroup: plan.name)
        }
        for aclUUID in supersededACLs {
            try await ovnManager.deleteACL(uuid: aclUUID)
        }

        // Stamps last: a crash anywhere above leaves them absent/stale and
        // the next sync redoes the whole rewrite.
        try await ovnManager.updatePortGroup(
            uuid: pgUUID,
            OVNPortGroup(
                name: plan.name,
                external_ids: [
                    Self.managedKey: Self.managedValue,
                    Self.generationKey: String(plan.generation),
                    Self.builderRevisionKey: String(SecurityGroupACLBuilder.aclSchemaRevision),
                ]))
        logger.info(
            "Security-group port group converged",
            metadata: [
                "portGroup": .string(plan.name),
                "generation": .stringConvertible(plan.generation),
                "acls": .stringConvertible(plan.acls.count),
            ])
        #endif
    }

    func removePortGroup(named name: String) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        // Only ever called for managed groups (observeSecurityGroups filters),
        // and deletion drops its ACL rows with it; member-port references are
        // weak, so no port cleanup is needed.
        try await ovnManager.deletePortGroup(named: name)
        logger.info(
            "Security-group port group removed", metadata: ["portGroup": .string(name)])
        #endif
    }

    func observeMembership(ofPorts portNames: [String]) async throws -> [String: Set<String>] {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let groups = try await ovnManager.getPortGroups().filter { Self.isManaged($0.external_ids) }
        var membership: [String: Set<String>] = [:]
        for portName in portNames {
            guard let portUUID = try await ovnManager.getLogicalSwitchPort(named: portName)?.uuid
            else { continue }
            for group in groups where (group.ports ?? []).contains(portUUID) {
                membership[portName, default: []].insert(group.name)
            }
        }
        return membership
        #else
        return [:]
        #endif
    }

    func addPort(named portName: String, toGroup group: String) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        guard let portGroup = try await ovnManager.getPortGroup(named: group) else {
            throw DependencyPendingError(
                "port group \(group) does not exist yet; waiting for the site's network controller to realize it"
            )
        }
        // Existence is not enforcement: the authority realizes a group as
        // separate transactions (row, then ACLs, then the generation stamp),
        // so a stamp-less row is a group whose ACLs are not written yet —
        // joining it would put the port behind a drop group with no drops.
        guard portGroup.external_ids?[Self.generationKey] != nil else {
            throw DependencyPendingError(
                "port group \(group) exists but its ACLs are not realized yet; waiting for the site's network controller"
            )
        }
        guard let portUUID = try await ovnManager.getLogicalSwitchPort(named: portName)?.uuid else {
            // The VM's own reconcile lane creates the port; membership catches
            // up on the next sync.
            throw DependencyPendingError("logical switch port \(portName) does not exist yet")
        }
        try await ovnManager.addPorts([portUUID], toPortGroup: group)
        #endif
    }

    func removePort(named portName: String, fromGroup group: String) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        guard let portUUID = try await ovnManager.getLogicalSwitchPort(named: portName)?.uuid else {
            return
        }
        try await ovnManager.removePorts([portUUID], fromPortGroup: group)
        #endif
    }
}
