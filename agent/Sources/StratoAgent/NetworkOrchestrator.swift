import Foundation
import Logging
import StratoAgentCore
import StratoShared

/// Resolves a VM's `NetworkSpec` list into host-side attachments before the
/// hypervisor driver runs, and tears them down after the VM is gone.
///
/// This used to live copy-pasted inside each hypervisor driver (QEMU,
/// Firecracker), each with its own hardcoded subnet and first-NIC-only
/// limitation. Centralizing it means drivers only translate typed
/// `NetworkAttachment`s into their native config, and a new backend gets
/// networking for free.
struct NetworkOrchestrator: Sendable {
    let networkService: (any NetworkServiceProtocol)?
    let logger: Logger

    /// Realizes every NIC in `networks` (in spec order). On failure, host-side
    /// resources of already-realized NICs are rolled back before rethrowing.
    ///
    /// Without a network service, every NIC degrades to `.userMode` with the
    /// spec's addressing passed through — matching the drivers' historical
    /// "no network service → user-mode fallback" behavior.
    func prepareAttachments(vmId: String, networks: [NetworkSpec]) async throws -> [ResolvedNetworkAttachment] {
        guard let networkService else {
            if !networks.isEmpty {
                logger.warning(
                    "Network service not available; falling back to user-mode networking",
                    metadata: ["vmId": .string(vmId)])
            }
            return networks.map { spec in
                ResolvedNetworkAttachment(
                    network: spec.network,
                    attachment: .userMode,
                    macAddress: spec.macAddress,
                    ipAddress: spec.ipAddress,
                    netmask: spec.netmask,
                    gateway: spec.gateway,
                    ip6Address: spec.ipv6Address,
                    prefixLength6: spec.ipv6PrefixLength,
                    gateway6: spec.gateway6,
                    mtu: spec.mtu,
                    // No OVN here (user-mode SLIRP), so its DHCP responder can't
                    // run; fall back to static guest config.
                    dhcpEnabled: false,
                    dnsServers: spec.dnsServers
                )
            }
        }

        var resolved: [ResolvedNetworkAttachment] = []
        for (index, spec) in networks.enumerated() {
            let config = VMNetworkConfig(
                networkName: spec.network,
                networkId: spec.networkId,
                macAddress: spec.macAddress,
                ipAddress: spec.ipAddress,
                subnet: subnetCIDR(ipAddress: spec.ipAddress, netmask: spec.netmask),
                gateway: spec.gateway,
                ip6Address: spec.ipv6Address,
                prefixLength6: spec.ipv6PrefixLength,
                gateway6: spec.gateway6,
                subnet6: subnet6CIDR(ip6Address: spec.ipv6Address, prefixLength: spec.ipv6PrefixLength),
                dhcpEnabled: spec.dhcpEnabled,
                dnsServers: spec.dnsServers,
                domainName: spec.domainName,
                leaseTime: spec.leaseTime
            )

            do {
                let info = try await networkService.createVMNetwork(vmId: vmId, nicIndex: index, config: config)
                // OVN can only serve DHCP for a real TAP-backed port; a service
                // that degraded this NIC to user-mode did not program DHCP, so
                // don't tell the guest to expect it.
                let dhcpRealized = spec.dhcpEnabled && info.attachment.isTap
                resolved.append(
                    ResolvedNetworkAttachment(
                        network: info.networkName,
                        attachment: info.attachment,
                        macAddress: info.macAddress,
                        // The network service may have recovered the addresses of an
                        // existing port (agent restart, retry); its answer wins over
                        // the spec so the guest boots with what OVN enforces.
                        ipAddress: info.ipAddress ?? spec.ipAddress,
                        netmask: spec.netmask,
                        gateway: spec.gateway,
                        ip6Address: info.ip6Address ?? spec.ipv6Address,
                        prefixLength6: spec.ipv6PrefixLength,
                        gateway6: spec.gateway6,
                        mtu: spec.mtu,
                        dhcpEnabled: dhcpRealized,
                        dnsServers: spec.dnsServers
                    ))
            } catch {
                logger.error(
                    "Failed to realize NIC; rolling back already-realized NICs",
                    metadata: [
                        "vmId": .string(vmId),
                        "nicIndex": .stringConvertible(index),
                        "network": .string(spec.network),
                        "error": .string(error.localizedDescription),
                    ])
                // Include the NIC that just failed: createVMNetwork may have
                // created some of its resources (e.g. the OVN port exists but
                // the TAP/OVS step threw). Teardown is idempotent, so covering
                // a NIC that never got started is harmless.
                await teardownAttachments(vmId: vmId, count: index + 1)
                throw error
            }
        }

        logger.info(
            "VM networking prepared",
            metadata: [
                "vmId": .string(vmId),
                "nics": .stringConvertible(resolved.count),
            ])
        return resolved
    }

    /// Best-effort teardown of the first `count` NICs of a VM. Failures are
    /// logged, never thrown — network cleanup must not block VM deletion.
    func teardownAttachments(vmId: String, count: Int) async {
        guard let networkService, count > 0 else { return }

        for index in 0..<count {
            do {
                try await networkService.detachVMFromNetwork(vmId: vmId, nicIndex: index)
            } catch {
                logger.error(
                    "Failed to tear down VM NIC",
                    metadata: [
                        "vmId": .string(vmId),
                        "nicIndex": .stringConvertible(index),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }
    }

}
