import Foundation
import StratoShared

/// Pure, host-local network projections of one desired-state message.
public struct DesiredStateDerivations: Sendable {
    public let portMemberships: [DesiredPortMembership]
    public let metadataNetworkIDs: [UUID]
    public let resolverNetworks: [ResolverNetworkConfig]?

    public init(message: DesiredStateMessage) throws {
        var memberships = try VMPortMembershipPlanner.memberships(for: message.vms.values)
        memberships += try message.sandboxes.values.compactMap { sandbox in
            guard sandbox.spec.hasNetwork else { return nil }
            let spec = sandbox.spec.network
            return DesiredPortMembership(
                interfaceId: spec.hasInterfaceID ? try UUID(protocolString: spec.interfaceID) : nil,
                portName: OVNNaming.sandboxPortName(sandboxId: sandbox.sandboxID, nicIndex: 0),
                securityGroupIds: spec.hasSecurityGroupIds
                    ? try spec.securityGroupIds.values.map { try UUID(protocolString: $0) } : nil)
        }
        portMemberships = memberships

        let specs =
            message.vms.values.flatMap { $0.spec.networks.values }
            + message.sandboxes.values.compactMap { $0.spec.optionalNetwork }
        metadataNetworkIDs = Set(try specs.filter(\.metadataEnabled).map { try UUID(protocolString: $0.networkID) })
            .sorted { $0.uuidString < $1.uuidString }

        if !specs.isEmpty, specs.allSatisfy({ !$0.hasResolverEnabled }) {
            resolverNetworks = nil
        } else {
            var byNetwork: [UUID: ResolverNetworkConfig] = [:]
            for spec in specs
            where spec.hasResolverEnabled && spec.resolverEnabled && !spec.resolverAddresses.values.isEmpty {
                let networkID = try UUID(protocolString: spec.networkID)
                guard byNetwork[networkID] == nil else { continue }
                byNetwork[networkID] = ResolverNetworkConfig(
                    networkId: networkID,
                    addresses: spec.resolverAddresses.values,
                    upstreams: spec.dnsServers.values,
                    searchDomain: spec.optionalDomainName)
            }
            resolverNetworks = byNetwork.values.sorted {
                $0.networkId.uuidString < $1.networkId.uuidString
            }
        }
    }
}
