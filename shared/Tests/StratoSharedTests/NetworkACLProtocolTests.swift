import Foundation
import Testing

import StratoShared

@Suite("Network ACL Protocol Tests")
struct NetworkACLProtocolTests {
    @Test("A network carries its ordered ACL through the wire")
    func roundTrip() throws {
        let aclID = UUID()
        let ruleID = UUID()
        let network = DesiredNetworkState(
            networkId: UUID(),
            name: "private",
            subnet: "10.0.0.0/24",
            gateway: "10.0.0.1",
            routerKey: "project-test",
            externalAccess: false,
            generation: 7,
            networkACLs: [
                DesiredNetworkACL(
                    id: aclID,
                    generation: 4,
                    rules: [
                        DesiredNetworkACLRule(
                            id: ruleID,
                            ruleNumber: 100,
                            direction: "ingress",
                            ethertype: "ipv4",
                            action: "allow",
                            protocolName: "tcp",
                            portRangeMin: 443,
                            portRangeMax: 443,
                            remoteCIDR: "198.51.100.0/24")
                    ])
            ])

        let decoded = try throughEnvelope(DesiredStateMessage(syncId: "acl", vms: [], networks: [network]))
        let decodedNetwork = try #require(decoded.networks.values.first)
        #expect(decodedNetwork.hasNetworkAcLs)
        let acl = try #require(decodedNetwork.networkAcLs.values.first)
        let rule = try #require(acl.rules.values.first)

        #expect(acl.id == aclID.uuidString)
        #expect(acl.generation == 4)
        #expect(rule.id == ruleID.uuidString)
        #expect(rule.ruleNumber == 100)
        #expect(rule.action == "allow")
        #expect(rule.remoteCidr == "198.51.100.0/24")
        #expect(rule.portRangeMin == 443)
    }

    @Test("Network ACL absence and authoritative emptiness remain distinct")
    func semanticAbsence() throws {
        let authoritative = DesiredNetworkState(
            networkId: UUID(),
            name: "private",
            subnet: "10.0.0.0/24",
            gateway: "10.0.0.1",
            routerKey: "project-test",
            externalAccess: false,
            generation: 1,
            networkACLs: [])
        var absent = authoritative
        absent.clearNetworkAcLs()
        let decoded = try throughEnvelope(
            DesiredStateMessage(syncId: "presence", vms: [], networks: [absent, authoritative]))
        try #require(decoded.networks.values.count == 2)
        #expect(!decoded.networks.values[0].hasNetworkAcLs)
        #expect(decoded.networks.values[1].hasNetworkAcLs)
        #expect(decoded.networks.values[1].networkAcLs.values.isEmpty)
    }
}
