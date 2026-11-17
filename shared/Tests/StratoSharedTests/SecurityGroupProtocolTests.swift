import Foundation
import SwiftProtobuf
import Testing

import StratoShared

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
        let decoded = try throughEnvelope(message)

        try #require(decoded.hasSecurityGroups)
        let groups = decoded.securityGroups.values
        #expect(groups.count == 1)
        #expect(groups[0].id == groupId.uuidString)
        #expect(groups[0].generation == 3)
        #expect(groups[0].rules.values.count == 2)
        #expect(groups[0].rules.values[0].id == ruleId.uuidString)
        #expect(groups[0].rules.values[0].direction == "ingress")
        #expect(groups[0].rules.values[0].protocolName == "tcp")
        #expect(groups[0].rules.values[0].portRangeMin == 443)
        #expect(groups[0].rules.values[0].remoteCidr == "0.0.0.0/0")
        #expect(!groups[0].rules.values[0].hasRemoteGroupID)
        #expect(groups[0].rules.values[1].ethertype == "ipv6")
        #expect(groups[0].rules.values[1].remoteGroupID == peerId.uuidString)
        #expect(!groups[0].rules.values[1].hasProtocolName)
    }

    @Test("A non-authoritative desired message keeps securityGroups nil")
    func securityGroupsSemanticAbsence() throws {
        let absent = try throughEnvelope(DesiredStateMessage(syncId: "absent", vms: []))
        let empty = try throughEnvelope(DesiredStateMessage(syncId: "empty", vms: [], securityGroups: []))
        #expect(!absent.hasSecurityGroups)
        #expect(empty.hasSecurityGroups)
        #expect(empty.securityGroups.values.isEmpty)
    }

    @Test("NetworkSpec carries securityGroupIds and tolerates their absence")
    func networkSpecSecurityGroupIds() throws {
        let ids = [UUID(), UUID()]
        let spec = NetworkSpec(network: "default", networkId: UUID(), securityGroupIds: ids)
        let unmanaged = NetworkSpec(network: "default", networkId: UUID())
        let empty = NetworkSpec(network: "default", networkId: UUID(), securityGroupIds: [])
        let message = DesiredStateMessage(
            syncId: "nics",
            vms: [
                DesiredVMState(
                    vmId: UUID(), hypervisorType: .qemu,
                    spec: VMSpec(
                        cpus: 1, memoryBytes: 1 << 30, boot: .disk(firmware: nil), networks: [spec, unmanaged, empty]),
                    desiredStatus: .running, generation: 1)
            ])
        let decoded = try throughEnvelope(message)
        let vm = try #require(decoded.vms.values.first)
        let nics = vm.spec.networks.values
        try #require(nics.count == 3)
        #expect(nics[0].hasSecurityGroupIds)
        #expect(nics[0].securityGroupIds.values == ids.map(\.uuidString))
        #expect(!nics[1].hasSecurityGroupIds)
        #expect(nics[2].hasSecurityGroupIds)
        #expect(nics[2].securityGroupIds.values.isEmpty)
    }

    @Test("A rule's log flag round-trips and is required")
    func ruleLogFlag() throws {
        let logged = DesiredSecurityGroupRule(
            id: UUID(), direction: "ingress", ethertype: "ipv4", log: true)
        var message = DesiredStateMessage(
            syncId: "log", vms: [], securityGroups: [DesiredSecurityGroup(id: UUID(), generation: 1, rules: [logged])])
        let decoded = try throughEnvelope(message)
        let group = try #require(decoded.securityGroups.values.first)
        let rule = try #require(group.rules.values.first)
        #expect(rule.hasLog)
        #expect(rule.log)
        message.securityGroups.values[0].rules.values[0].clearLog()
        #expect(throws: (any Error).self) { try WireProtocol.encodeEnvelope(message) }
        let malformed = try MessageEnvelope(message: message).serializedData()
        #expect(throws: AgentProtocolDecodeError.self) { try WireProtocol.decodeEnvelope(malformed) }
    }
}
