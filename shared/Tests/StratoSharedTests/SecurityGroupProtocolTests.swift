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

        let groups = try #require(decoded.securityGroups)
        #expect(groups.count == 1)
        #expect(groups[0].id == groupId)
        #expect(groups[0].generation == 3)
        #expect(groups[0].rules.count == 2)
        #expect(groups[0].rules[0].id == ruleId)
        #expect(groups[0].rules[0].direction == "ingress")
        #expect(groups[0].rules[0].protocolName == "tcp")
        #expect(groups[0].rules[0].portRangeMin == 443)
        #expect(groups[0].rules[0].remoteCIDR == "0.0.0.0/0")
        #expect(groups[0].rules[0].remoteGroupId == nil)
        #expect(groups[0].rules[1].ethertype == "ipv6")
        #expect(groups[0].rules[1].remoteGroupId == peerId)
        #expect(groups[0].rules[1].protocolName == nil)
    }

    @Test("DesiredStateMessage from an older control plane decodes securityGroups to nil")
    func securityGroupsBackwardCompatible() throws {
        // Nil (not []): absence means "this control plane has no opinion on
        // security groups", which the agent must not read as "tear down all
        // port groups".
        let legacy = """
            {"requestId":"r","timestamp":0,"syncId":"s","vms":[]}
            """
        let decoded = try WireProtocol.makeDecoder().decode(
            DesiredStateMessage.self, from: Data(legacy.utf8))
        #expect(decoded.securityGroups == nil)
    }

    @Test("NetworkSpec carries securityGroupIds and tolerates their absence")
    func networkSpecSecurityGroupIds() throws {
        let ids = [UUID(), UUID()]
        let spec = NetworkSpec(network: "default", securityGroupIds: ids)
        let data = try WireProtocol.makeEncoder().encode(spec)
        let decoded = try WireProtocol.makeDecoder().decode(NetworkSpec.self, from: data)
        #expect(decoded.securityGroupIds == ids)

        // A spec from a pre-security-group control plane has no key at all:
        // nil marks the NIC unmanaged (it joins no port groups, including the
        // drop group), preserving legacy traffic.
        let legacy = """
            {"network":"default"}
            """
        let legacyDecoded = try WireProtocol.makeDecoder().decode(
            NetworkSpec.self, from: Data(legacy.utf8))
        #expect(legacyDecoded.securityGroupIds == nil)
    }

    @Test("supportsSecurityGroups gates on v20")
    func versionGate() {
        #expect(!WireProtocol.supportsSecurityGroups(19))
        #expect(WireProtocol.supportsSecurityGroups(20))
        #expect(WireProtocol.supportsSecurityGroups(WireProtocol.securityGroupsMinimumVersion))
    }
}
