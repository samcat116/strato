import Foundation
import Testing

@testable import StratoShared

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

        let data = try WireProtocol.makeEncoder().encode(network)
        let decoded = try WireProtocol.makeDecoder().decode(DesiredNetworkState.self, from: data)
        let acl = try #require(decoded._jsonNetworkACLs?.first)
        let rule = try #require(acl._jsonRules.first)

        #expect(acl._jsonId == aclID)
        #expect(acl._jsonGeneration == 4)
        #expect(rule._jsonId == ruleID)
        #expect(rule._jsonRuleNumber == 100)
        #expect(rule._jsonAction == "allow")
        #expect(rule._jsonRemoteCIDR == "198.51.100.0/24")
        #expect(rule._jsonPortRangeMin == 443)
    }

    @Test("Network ACL absence and authoritative emptiness remain distinct")
    func semanticAbsence() throws {
        let legacy = """
            {"networkId":"\(UUID().uuidString)","name":"private","subnet":"10.0.0.0/24",
             "gateway":"10.0.0.1","routerKey":"project-test","externalAccess":false,
             "dhcpEnabled":false,"dnsServers":[],"metadataEnabled":false,
             "floatingIPs":[],"loadBalancers":[],"generation":1}
            """
        let absent = try WireProtocol.makeDecoder().decode(
            DesiredNetworkState.self, from: Data(legacy.utf8))
        #expect(absent._jsonNetworkACLs == nil)

        let authoritative = DesiredNetworkState(
            networkId: UUID(),
            name: "private",
            subnet: "10.0.0.0/24",
            gateway: "10.0.0.1",
            routerKey: "project-test",
            externalAccess: false,
            generation: 1,
            networkACLs: [])
        let data = try WireProtocol.makeEncoder().encode(authoritative)
        let decoded = try WireProtocol.makeDecoder().decode(DesiredNetworkState.self, from: data)
        #expect(decoded._jsonNetworkACLs == [])
    }
}
