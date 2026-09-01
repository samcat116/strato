import Foundation
import Logging
import StratoShared
import StratoAgentCore

#if os(Linux)
import SwiftOVN
#endif

/// Owns VM and sandbox logical-port lifecycle.
extension NetworkServiceLinux {
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
            metadata: ["strato.vm.id": .string(vmId), "nicIndex": .stringConvertible(nicIndex)])

        // Create logical switch port for the workload's NIC. Everything down to
        // the TAP/veth step below is identical for VMs and sandboxes — only the
        // port's namespace and how the device is realized differ.
        let portName = Self.portName(workloadId: vmId, nicIndex: nicIndex, placement: placement)
        var macAddress: String
        if let configuredMAC = config.macAddress {
            guard let parsedMAC = MACAddress(configuredMAC) else {
                throw NetworkError.invalidConfiguration(
                    "MAC address '\(configuredMAC)' is not a six-octet unicast address")
            }
            macAddress = parsedMAC.description
        } else {
            macAddress = generateMACAddress()
        }
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
            try await joinSecurityGroups(
                portName: portName, portUUID: portUUID, groupIds: groupIds,
                metadataDenied: config.metadataDenied)
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
                "strato.vm.id": .string(vmId),
                "portName": .string(portName),
                "tapInterface": .string(tapInterface),
            ])

        return networkInfo
        #else
        // Development mode
        logger.info("Creating mock VM network (development mode)", metadata: ["strato.vm.id": .string(vmId)])

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
            metadata: ["strato.vm.id": .string(vmId), "nicIndex": .stringConvertible(nicIndex)])

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
                try await run(
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

        logger.info("VM detached from network successfully", metadata: ["strato.vm.id": .string(vmId)])
        #else
        // Development mode
        logger.info("Detaching mock VM from network (development mode)", metadata: ["strato.vm.id": .string(vmId)])
        #endif
    }
}
