import Foundation
import Testing

@testable import StratoShared

@Suite("Security Group Protocol Tests")
struct SecurityGroupProtocolTests {

    @Test("DesiredStateMessage carries security groups through the envelope")
    func securityGroupsRoundTrip() throws {
        let groupId = UUID()
        let peerId = UUID()
        let ruleId = UUID()
        let message = DesiredStateMessage(
            syncId: "sync-sg",
            vms: [],
            securityGroups: [
                DesiredSecurityGroup(
                    id: groupId,
                    generation: 3,
                    rules: [
                        DesiredSecurityGroupRule(
                            id: ruleId,
                            direction: "ingress",
                            ethertype: "ipv4",
                            protocolName: "tcp",
                            portRangeMin: 443,
                            portRangeMax: 443,
                            remoteCIDR: "0.0.0.0/0"
                        ),
                        DesiredSecurityGroupRule(
                            id: UUID(),
                            direction: "egress",
                            ethertype: "ipv6",
                            remoteGroupId: peerId
                        ),
                    ]
                )
            ]
        )
        let decoded = try MessageEnvelope(message: message).decode(as: DesiredStateMessage.self)

        let groups = try #require(decoded._jsonSecurityGroups)
        #expect(groups.count == 1)
        #expect(groups[0]._jsonId == groupId)
        #expect(groups[0]._jsonGeneration == 3)
        #expect(groups[0]._jsonRules.count == 2)
        #expect(groups[0]._jsonRules[0]._jsonId == ruleId)
        #expect(groups[0]._jsonRules[0]._jsonDirection == "ingress")
        #expect(groups[0]._jsonRules[0]._jsonProtocolName == "tcp")
        #expect(groups[0]._jsonRules[0]._jsonPortRangeMin == 443)
        #expect(groups[0]._jsonRules[0]._jsonRemoteCIDR == "0.0.0.0/0")
        #expect(groups[0]._jsonRules[0]._jsonRemoteGroupId == nil)
        #expect(groups[0]._jsonRules[1]._jsonEthertype == "ipv6")
        #expect(groups[0]._jsonRules[1]._jsonRemoteGroupId == peerId)
        #expect(groups[0]._jsonRules[1]._jsonProtocolName == nil)
    }

    @Test("A non-authoritative desired message keeps securityGroups nil")
    func securityGroupsSemanticAbsence() throws {
        // Nil (not []): absence means this sender has no opinion on security
        // groups, which the agent must not read as "tear down all port groups".
        let nonAuthoritative = """
            {"requestId":"r","timestamp":0,"syncId":"s","vms":[],"sandboxes":[],
             "networks":[],"networksAuthoritative":false,"tombstones":[],"volumes":[],"snapshots":[],
             "cephCredentialRevocations":[]}
            """
        let decoded = try WireProtocol.makeDecoder().decode(
            DesiredStateMessage.self, from: Data(nonAuthoritative.utf8))
        #expect(decoded._jsonSecurityGroups == nil)
    }

    @Test("NetworkSpec carries securityGroupIds and tolerates their absence")
    func networkSpecSecurityGroupIds() throws {
        let ids = [UUID(), UUID()]
        let spec = NetworkSpec(network: "default", networkId: UUID(), securityGroupIds: ids)
        let data = try WireProtocol.makeEncoder().encode(spec)
        let decoded = try WireProtocol.makeDecoder().decode(NetworkSpec.self, from: data)
        #expect(decoded._jsonSecurityGroupIds == ids)

        // Nil marks the NIC unmanaged: it joins no port groups, including the
        // drop group.
        let unmanaged = """
            {"network":"default","networkId":"\(UUID().uuidString)",
             "dhcpEnabled":false,"dnsServers":[],"metadataEnabled":false}
            """
        let unmanagedDecoded = try WireProtocol.makeDecoder().decode(
            NetworkSpec.self, from: Data(unmanaged.utf8))
        #expect(unmanagedDecoded._jsonSecurityGroupIds == nil)
    }

    @Test("A rule's log flag round-trips and is required")
    func ruleLogFlag() throws {
        let logged = DesiredSecurityGroupRule(
            id: UUID(), direction: "ingress", ethertype: "ipv4", log: true)
        let data = try WireProtocol.makeEncoder().encode(logged)
        #expect(try WireProtocol.makeDecoder().decode(DesiredSecurityGroupRule.self, from: data)._jsonLog == true)

        let missingLog = """
            {"id":"\(UUID().uuidString)","direction":"ingress","ethertype":"ipv4"}
            """
        #expect(throws: DecodingError.self) {
            try WireProtocol.makeDecoder().decode(
                DesiredSecurityGroupRule.self, from: Data(missingLog.utf8))
        }
    }
}
