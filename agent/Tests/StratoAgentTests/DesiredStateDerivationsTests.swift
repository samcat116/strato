import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("Desired-state network derivations")
struct DesiredStateDerivationsTests {
    private let networkA = UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!
    private let networkB = UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!
    private let group = UUID(uuidString: "00000000-0000-0000-0000-00000000000c")!

    @Test("Sandbox memberships and metadata networks are projected once")
    func membershipsAndMetadata() {
        let message = DesiredStateMessage(
            vms: [],
            sandboxes: [
                sandbox(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    network: NetworkSpec(
                        network: "b", networkId: networkB,
                        securityGroupIds: [group], metadataEnabled: true)),
                sandbox(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                    network: NetworkSpec(
                        network: "a", networkId: networkA, metadataEnabled: true)),
                sandbox(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                    network: NetworkSpec(
                        network: "b-copy", networkId: networkB, metadataEnabled: true)),
            ])

        let result = DesiredStateDerivations(message: message)

        #expect(result.metadataNetworkIDs == [networkA, networkB])
        #expect(result.portMemberships.count == 3)
        #expect(result.portMemberships[0].securityGroupIds == [group])
        #expect(
            result.portMemberships[0].portName
                == OVNNaming.sandboxPortName(
                    sandboxId: "00000000-0000-0000-0000-000000000001", nicIndex: 0))
    }

    @Test("An absent resolver opinion stays absent")
    func absentResolverOpinion() {
        let message = DesiredStateMessage(
            vms: [],
            sandboxes: [
                sandbox(
                    id: UUID(),
                    network: NetworkSpec(network: "a", networkId: networkA))
            ])

        #expect(DesiredStateDerivations(message: message).resolverNetworks == nil)
        #expect(DesiredStateDerivations(message: DesiredStateMessage(vms: [])).resolverNetworks == [])
    }

    @Test("Enabled resolvers are grouped by network and sorted")
    func enabledResolvers() {
        let message = DesiredStateMessage(
            vms: [],
            sandboxes: [
                sandbox(
                    id: UUID(),
                    network: NetworkSpec(
                        network: "b", networkId: networkB,
                        dnsServers: ["1.1.1.1"], domainName: "example.test",
                        resolverEnabled: true, resolverAddresses: ["169.254.1.2"])),
                sandbox(
                    id: UUID(),
                    network: NetworkSpec(
                        network: "a", networkId: networkA,
                        resolverEnabled: true, resolverAddresses: ["169.254.1.1"])),
            ])

        let resolvers = DesiredStateDerivations(message: message).resolverNetworks

        #expect(resolvers?.map(\.networkId) == [networkA, networkB])
        #expect(resolvers?[1].upstreams == ["1.1.1.1"])
        #expect(resolvers?[1].searchDomain == "example.test")
    }

    private func sandbox(id: UUID, network: NetworkSpec) -> DesiredSandboxState {
        DesiredSandboxState(
            sandboxId: id,
            spec: SandboxSpec(
                image: "example.invalid/test:latest", cpus: 1,
                memoryBytes: 128 * 1024 * 1024, network: network),
            desiredStatus: .running,
            generation: 1)
    }
}
