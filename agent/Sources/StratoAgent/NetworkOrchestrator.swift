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
    /// `placement` says where the NICs are realized: VMs run in the host network
    /// namespace, a jailed sandbox's VMM does not (issue STR-100). The same
    /// funnel serves both so a new workload kind never grows its own copy of
    /// this rollback logic.
    ///
    /// Without a network service, every NIC degrades to `.userMode` with the
    /// spec's addressing passed through — matching the drivers' historical
    /// "no network service → user-mode fallback" behavior.
    ///
    /// `metadataDenied` is the workload's per-instance metadata kill switch
    /// (STR-185), a property of the VM rather than of any one NIC, so it is
    /// passed alongside the spec list rather than read out of it. Sandboxes pass
    /// false: they have no metadata document, so there is nothing to switch off.
    func prepareAttachments(
        vmId: String, networks: [NetworkSpec], metadataDenied: Bool = false,
        placement: NICPlacement = .hostNamespace
    ) async throws -> [ResolvedNetworkAttachment] {
        var resolved: [ResolvedNetworkAttachment] = []
        for (index, spec) in networks.enumerated() {
            do {
                resolved.append(
                    try await prepareAttachment(
                        vmId: vmId,
                        spec: spec,
                        fallbackIndex: index,
                        metadataDenied: metadataDenied,
                        placement: placement))
            } catch {
                let slot = nicSlot(for: spec, fallbackIndex: index)
                logger.error(
                    "Failed to realize NIC; rolling back already-realized NICs",
                    metadata: [
                        "vmId": .string(vmId),
                        "nicIndex": .stringConvertible(slot),
                        "network": .string(spec.network),
                        "error": .string(error.localizedDescription),
                    ])
                // Include the NIC that just failed: createVMNetwork may have
                // created some of its resources (e.g. the OVN port exists but
                // the TAP/OVS step threw). Teardown is idempotent, so covering
                // a NIC that never got started is harmless.
                await teardownAttachments(
                    vmId: vmId,
                    networks: Array(networks.prefix(index + 1)),
                    placement: placement)
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

    /// Realize a single interface at its durable slot. `fallbackIndex` exists
    /// only for pre-v40 manifests that do not yet carry `orderIndex`.
    func prepareAttachment(
        vmId: String,
        spec: NetworkSpec,
        fallbackIndex: Int,
        metadataDenied: Bool = false,
        placement: NICPlacement = .hostNamespace
    ) async throws -> ResolvedNetworkAttachment {
        guard let networkService else {
            logger.warning(
                "Network service not available; falling back to user-mode networking",
                metadata: ["vmId": .string(vmId)])
            return userModeAttachment(for: spec)
        }

        let slot = nicSlot(for: spec, fallbackIndex: fallbackIndex)
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
            leaseTime: spec.leaseTime,
            securityGroupIds: spec.securityGroupIds,
            metadataDenied: metadataDenied,
            mtu: spec.mtu,
            metadataEnabled: spec.metadataEnabled == true,
            resolverAddresses: spec.resolverEnabled == true ? (spec.resolverAddresses ?? []) : []
        )
        let info = try await networkService.createVMNetwork(
            vmId: vmId, nicIndex: slot, config: config, placement: placement)
        let dhcpRealized = spec.dhcpEnabled && info.attachment.isTap
        let metadataRealized = spec.metadataEnabled == true && info.attachment.isTap
        if spec.metadataEnabled == true && !metadataRealized {
            logger.debug(
                "NIC degraded to user-mode; withholding the guest's route to the metadata service",
                metadata: [
                    "vmId": .string(vmId),
                    "nicIndex": .stringConvertible(slot),
                    "network": .string(spec.network),
                ])
        }
        let wantsResolver = spec.resolverEnabled == true && !(spec.resolverAddresses ?? []).isEmpty
        let resolverRealized = wantsResolver && info.attachment.isTap
        if wantsResolver && !resolverRealized {
            logger.debug(
                "NIC degraded to user-mode; the guest resolves through the network's upstream servers",
                metadata: [
                    "vmId": .string(vmId),
                    "nicIndex": .stringConvertible(slot),
                    "network": .string(spec.network),
                ])
        }
        return ResolvedNetworkAttachment(
            network: info.networkName,
            attachment: info.attachment,
            macAddress: info.macAddress,
            ipAddress: info.ipAddress ?? spec.ipAddress,
            netmask: spec.netmask,
            gateway: spec.gateway,
            ip6Address: info.ip6Address ?? spec.ipv6Address,
            prefixLength6: spec.ipv6PrefixLength,
            gateway6: spec.gateway6,
            mtu: spec.mtu,
            dhcpEnabled: dhcpRealized,
            dnsServers: spec.dnsServers,
            domainName: spec.domainName,
            metadataEnabled: metadataRealized,
            resolverAddresses: resolverRealized ? (spec.resolverAddresses ?? []) : []
        )
    }

    /// Best-effort teardown of the requested NICs of a workload. Failures are
    /// logged, never thrown — network cleanup must not block VM deletion.
    /// `placement` must match what the NICs were created with.
    func teardownAttachments(
        vmId: String,
        networks: [NetworkSpec],
        placement: NICPlacement = .hostNamespace
    ) async {
        guard networkService != nil else { return }

        for (index, spec) in networks.enumerated() {
            do {
                try await removeAttachment(
                    vmId: vmId, spec: spec, fallbackIndex: index, placement: placement)
            } catch {
                let slot = nicSlot(for: spec, fallbackIndex: index)
                logger.error(
                    "Failed to tear down VM NIC",
                    metadata: [
                        "vmId": .string(vmId),
                        "nicIndex": .stringConvertible(slot),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }
    }

    /// Remove one prepared TAP/OVN attachment. Unlike bulk teardown this
    /// throws, because hot-unplug may only be committed to the manifest after
    /// both libvirt and the host network have converged.
    func removeAttachment(
        vmId: String,
        spec: NetworkSpec,
        fallbackIndex: Int,
        placement: NICPlacement = .hostNamespace
    ) async throws {
        guard let networkService else { return }
        try await networkService.detachVMFromNetwork(
            vmId: vmId,
            nicIndex: nicSlot(for: spec, fallbackIndex: fallbackIndex),
            placement: placement)
    }

    private func nicSlot(for spec: NetworkSpec, fallbackIndex: Int) -> Int {
        spec.orderIndex ?? fallbackIndex
    }

    private func userModeAttachment(for spec: NetworkSpec) -> ResolvedNetworkAttachment {
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
            dhcpEnabled: false,
            dnsServers: spec.dnsServers,
            domainName: spec.domainName,
            metadataEnabled: false,
            resolverAddresses: []
        )
    }

}
