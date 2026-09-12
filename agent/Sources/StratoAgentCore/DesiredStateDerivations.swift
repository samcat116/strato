import Foundation
import StratoShared

/// Pure, host-local network projections of one desired-state message.
public struct DesiredStateDerivations: Sendable {
    public let portMemberships: [DesiredPortMembership]
    public let metadataNetworkIDs: [UUID]
    public let resolverNetworks: [ResolverNetworkConfig]?

    public init(message: DesiredStateMessage) {
        var memberships = VMPortMembershipPlanner.memberships(for: message.vms)
        memberships += message.sandboxes.compactMap { sandbox in
            sandbox.spec.network.map { spec in
                DesiredPortMembership(
                    interfaceId: spec.interfaceId,
                    portName: OVNNaming.sandboxPortName(
                        sandboxId: sandbox.sandboxId.uuidString, nicIndex: 0),
                    securityGroupIds: spec.securityGroupIds)
            }
        }
        portMemberships = memberships

        let specs =
            message.vms.flatMap { $0.spec.networks }
            + message.sandboxes.compactMap { $0.spec.network }
        metadataNetworkIDs = Set(specs.filter(\.metadataEnabled).map(\.networkId))
            .sorted { $0.uuidString < $1.uuidString }

        if !specs.isEmpty, specs.allSatisfy({ $0.resolverEnabled == nil }) {
            resolverNetworks = nil
        } else {
            var byNetwork: [UUID: ResolverNetworkConfig] = [:]
            for spec in specs
            where spec.resolverEnabled == true && !(spec.resolverAddresses ?? []).isEmpty {
                guard byNetwork[spec.networkId] == nil else { continue }
                byNetwork[spec.networkId] = ResolverNetworkConfig(
                    networkId: spec.networkId,
                    addresses: spec.resolverAddresses ?? [],
                    upstreams: spec.dnsServers,
                    searchDomain: spec.domainName)
            }
            resolverNetworks = byNetwork.values.sorted {
                $0.networkId.uuidString < $1.networkId.uuidString
            }
        }
    }
}
