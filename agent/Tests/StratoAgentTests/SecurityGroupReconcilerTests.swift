import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("Security Group Reconciler")
struct SecurityGroupReconcilerTests {

    private let groupId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0001")!
    private let peerId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0002")!

    private var pg: String { OVNNaming.portGroupName(securityGroupId: groupId) }
    private var peerPG: String { OVNNaming.portGroupName(securityGroupId: peerId) }

    private func rule(
        direction: String = "ingress",
        ethertype: String = "ipv4",
        protocolName: String? = nil,
        portRangeMin: Int? = nil,
        portRangeMax: Int? = nil,
        remoteCIDR: String? = nil,
        remoteGroupId: UUID? = nil,
        log: Bool? = nil,
        id: UUID = UUID()
    ) -> DesiredSecurityGroupRule {
        DesiredSecurityGroupRule(
            id: id,
            direction: direction,
            ethertype: ethertype,
            protocolName: protocolName,
            portRangeMin: portRangeMin,
            portRangeMax: portRangeMax,
            remoteCIDR: remoteCIDR,
            remoteGroupId: remoteGroupId,
            log: log)
    }

    // MARK: - Naming

    @Test("Port group names are valid OVN identifiers derived from the group id")
    func portGroupNaming() {
        #expect(pg == "pg_aaaaaaaabbbbccccddddeeeeffff0001")
        // Identifier-safe: alphanumerics and underscores only, no leading digit.
        #expect(pg.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" })
        #expect(OVNNaming.addressSetReference(portGroup: pg, ethertype: "ipv4") == "$\(pg)_ip4")
        #expect(OVNNaming.addressSetReference(portGroup: pg, ethertype: "ipv6") == "$\(pg)_ip6")
    }

    // MARK: - ACL match construction

    @Test("Ingress TCP range with a CIDR peer")
    func ingressTCPRangeCIDR() {
        let acl = SecurityGroupACLBuilder.acl(
            for: rule(
                protocolName: "tcp", portRangeMin: 8000, portRangeMax: 8080,
                remoteCIDR: "203.0.113.0/24"),
            portGroup: pg)!
        #expect(acl.direction == "to-lport")
        #expect(acl.action == "allow-related")
        #expect(acl.priority == SecurityGroupACLBuilder.allowPriority)
        #expect(
            acl.match
                == "outport == @\(pg) && ip4 && ip4.src == 203.0.113.0/24 && tcp && tcp.dst >= 8000 && tcp.dst <= 8080"
        )
    }

    @Test("Single-port rule collapses the range to an equality")
    func singlePortEquality() {
        let acl = SecurityGroupACLBuilder.acl(
            for: rule(protocolName: "tcp", portRangeMin: 443, portRangeMax: 443),
            portGroup: pg)!
        #expect(acl.match == "outport == @\(pg) && ip4 && tcp && tcp.dst == 443")
    }

    @Test("Egress UDP v6 with a group peer references the auto-generated address set")
    func egressGroupPeer() {
        let acl = SecurityGroupACLBuilder.acl(
            for: rule(
                direction: "egress", ethertype: "ipv6", protocolName: "udp",
                portRangeMin: 53, portRangeMax: 53, remoteGroupId: peerId),
            portGroup: pg)!
        #expect(acl.direction == "from-lport")
        #expect(
            acl.match
                == "inport == @\(pg) && ip6 && ip6.dst == $\(peerPG)_ip6 && udp && udp.dst == 53")
    }

    @Test("ICMP maps to icmp4/icmp6 with type and code clauses")
    func icmpTypeCode() {
        let v4 = SecurityGroupACLBuilder.acl(
            for: rule(protocolName: "icmp", portRangeMin: 8, portRangeMax: 0),
            portGroup: pg)!
        #expect(v4.match == "outport == @\(pg) && ip4 && icmp4 && icmp4.type == 8 && icmp4.code == 0")

        let v6TypeOnly = SecurityGroupACLBuilder.acl(
            for: rule(ethertype: "ipv6", protocolName: "icmp", portRangeMin: 128),
            portGroup: pg)!
        #expect(v6TypeOnly.match == "outport == @\(pg) && ip6 && icmp6 && icmp6.type == 128")

        let anyICMP = SecurityGroupACLBuilder.acl(
            for: rule(protocolName: "icmp"),
            portGroup: pg)!
        #expect(anyICMP.match == "outport == @\(pg) && ip4 && icmp4")
    }

    @Test("Any-protocol any-peer rules match the bare family")
    func anyProtocolAnyPeer() {
        let ingress = SecurityGroupACLBuilder.acl(for: rule(), portGroup: pg)!
        #expect(ingress.match == "outport == @\(pg) && ip4")
        let egress = SecurityGroupACLBuilder.acl(for: rule(direction: "egress"), portGroup: pg)!
        #expect(egress.match == "inport == @\(pg) && ip4")
    }

    @Test("Unknown direction, ethertype, or protocol yields nil, never a permissive ACL")
    func unknownEnumsRefused() {
        #expect(SecurityGroupACLBuilder.acl(for: rule(direction: "sideways"), portGroup: pg) == nil)
        #expect(SecurityGroupACLBuilder.acl(for: rule(ethertype: "ipx"), portGroup: pg) == nil)
        #expect(SecurityGroupACLBuilder.acl(for: rule(protocolName: "sctp"), portGroup: pg) == nil)
    }

    @Test("Rule ACLs carry the managed marker and rule id")
    func aclExternalIDs() {
        let acl = SecurityGroupACLBuilder.acl(for: rule(), portGroup: pg)!
        #expect(acl.externalIDs["strato-managed"] == "true")
        #expect(acl.externalIDs["strato-rule-id"] != nil)
    }

    // MARK: - Logging

    @Test("A logged rule sets log, severity, and a name identifying the rule")
    func loggedRule() {
        let acl = SecurityGroupACLBuilder.acl(for: rule(log: true, id: groupId), portGroup: pg)!
        #expect(acl.log)
        #expect(acl.severity == "info")
        #expect(acl.name == "sgr_aaaaaaaabbbbccccddddeeeeffff0001")
        // OVN caps ACL names at 63 characters.
        #expect(acl.name!.count <= 63)
    }

    @Test("An unlogged rule — explicit false or a pre-v24 nil — sets no log columns")
    func unloggedRule() {
        for value: Bool? in [nil, false] {
            let acl = SecurityGroupACLBuilder.acl(for: rule(log: value), portGroup: pg)!
            #expect(!acl.log)
            #expect(acl.severity == nil)
            #expect(acl.name == nil)
        }
    }

    @Test("Plan preserves a rule's log columns while stamping the group id")
    func planPreservesLogging() {
        let group = DesiredSecurityGroup(
            id: groupId, generation: 1, rules: [rule(log: true, id: groupId)])
        let (plans, _) = SecurityGroupReconciler.plan(securityGroups: [group])
        let acl = plans[1].acls[0]
        #expect(acl.log)
        #expect(acl.severity == "info")
        #expect(acl.name == "sgr_aaaaaaaabbbbccccddddeeeeffff0001")
        #expect(acl.externalIDs["strato-sg-id"] == groupId.uuidString.lowercased())
    }

    // MARK: - Drop group

    @Test("Drop group denies IP both ways below the allows, with DHCP, ND, and MLD carve-outs")
    func dropGroupShape() {
        let acls = SecurityGroupACLBuilder.dropGroupACLs()
        let pgDrop = OVNNaming.dropPortGroupName

        let drops = acls.filter { $0.action == "drop" }
        #expect(drops.count == 2)
        #expect(drops.allSatisfy { $0.priority == SecurityGroupACLBuilder.dropPriority })
        #expect(
            Set(drops.map(\.match)) == [
                "inport == @\(pgDrop) && ip",
                "outport == @\(pgDrop) && ip",
            ])

        let allows = acls.filter { $0.action != "drop" }
        // Every carve-out except metadata egress (asserted on its own below,
        // and deliberately a priority above the rest).
        #expect(
            allows.filter { $0.priority != SecurityGroupACLBuilder.metadataAllowPriority }
                .allSatisfy { $0.priority == SecurityGroupACLBuilder.allowPriority })
        // DHCPv4+v6 both directions, ND/RA both directions.
        #expect(allows.contains { $0.match.contains("udp.dst == 67") })
        #expect(allows.contains { $0.match.contains("udp.dst == 547") })
        #expect(allows.contains { $0.match.contains("udp.src == 67") })
        #expect(allows.contains { $0.match.contains("udp.src == 547") })
        #expect(
            allows.contains { $0.match == "inport == @\(pgDrop) && (nd || nd_rs || nd_ra)" })
        #expect(
            allows.contains { $0.match == "outport == @\(pgDrop) && (nd || nd_rs || nd_ra)" })
        // MLD (STR-34), deliberately asymmetric: a guest may send listener
        // reports and dones but never a Query (type 130), which only the
        // querier originates — otherwise any member of the site-wide drop
        // group could win querier election and then stop querying, timing out
        // every other guest's multicast state. Written as explicit icmp6
        // types, not OVN's mldv1/mldv2 predicates.
        let listener = "icmp6.type == 131 || icmp6.type == 132 || icmp6.type == 143"
        #expect(allows.contains { $0.match == "inport == @\(pgDrop) && icmp6 && (\(listener))" })
        #expect(
            allows.contains {
                $0.match == "outport == @\(pgDrop) && icmp6 && (icmp6.type == 130 || \(listener))"
            })
        // The egress carve-out must not admit type 130 under any spelling.
        let egressMLD = allows.first { $0.direction == "from-lport" && $0.match.contains("icmp6.type == 131") }
        #expect(egressMLD != nil)
        #expect(egressMLD?.match.contains("icmp6.type == 130") == false)
        #expect(acls.allSatisfy { $0.externalIDs["strato-managed"] == "true" })
        // Infra carve-outs are never logged: they would drown the log in
        // per-guest DHCP and multicast chatter nobody asked to see.
        #expect(acls.allSatisfy { !$0.log })
    }

    @Test("Bumping the drop-group revision forces existing deployments to rewrite it")
    func dropGroupRevisionForcesRewrite() {
        // A deployment still carrying revision 1 (pre-MLD) must be rewritten.
        #expect(
            SecurityGroupReconciler.needsACLRewrite(
                planned: SecurityGroupACLBuilder.dropGroupRevision, observed: 1,
                observedBuilderRevision: SecurityGroupACLBuilder.aclSchemaRevision))
        #expect(SecurityGroupACLBuilder.dropGroupRevision > 1)
        // A deployment carrying revision 3 predates the metadata carve-out
        // (STR-54), so it must be rewritten too — otherwise every port group
        // already on 3 keeps silently dropping IMDS until some unrelated edit
        // happens to bump it.
        #expect(
            SecurityGroupReconciler.needsACLRewrite(
                planned: SecurityGroupACLBuilder.dropGroupRevision, observed: 3,
                observedBuilderRevision: SecurityGroupACLBuilder.aclSchemaRevision))
    }

    // MARK: - Instance metadata carve-out (STR-54)

    @Test("Metadata egress is allowed on every managed port, one ACL per family")
    func metadataEgressCarveOut() {
        let pgDrop = OVNNaming.dropPortGroupName
        let acls = SecurityGroupACLBuilder.metadataEgressACLs()

        #expect(acls.count == 2)
        #expect(
            acls.map(\.match) == [
                "inport == @\(pgDrop) && ip4 && ip4.dst == 169.254.169.254 && tcp && tcp.dst == 80",
                "inport == @\(pgDrop) && ip6 && ip6.dst == fd00:ec2::254 && tcp && tcp.dst == 80",
            ])
        // Stateful, so the service's replies return on conntrack state rather
        // than through a standing inbound allow.
        #expect(acls.allSatisfy { $0.action == "allow-related" })
        #expect(acls.allSatisfy { $0.direction == "from-lport" })
        // Never logged: an every-boot cloud-init probe on every guest in the
        // site is exactly the chatter the drop group's carve-outs stay quiet
        // about.
        #expect(acls.allSatisfy { !$0.log })
        #expect(acls.allSatisfy { $0.externalIDs["strato-managed"] == "true" })
    }

    @Test("Metadata egress outranks rule allows and the default deny")
    func metadataEgressIsNonOverridable() {
        // The point of the separate priority: a rule-derived ACL — including a
        // deny-capable shape the model doesn't have yet — cannot tie with this
        // one and win the coin flip.
        #expect(SecurityGroupACLBuilder.metadataAllowPriority > SecurityGroupACLBuilder.allowPriority)
        #expect(SecurityGroupACLBuilder.allowPriority > SecurityGroupACLBuilder.dropPriority)
    }

    @Test("A NIC in a group with no egress rule still reaches metadata")
    func metadataSurvivesARestrictiveGroup() {
        // The scenario STR-54 exists for: a group that permits nothing
        // outbound. Its port group carries no egress allow at all, and the
        // carve-out reaches the port anyway because membership always includes
        // the drop group.
        let restrictive = DesiredSecurityGroup(
            id: groupId, generation: 1,
            rules: [rule(direction: "ingress", protocolName: "tcp", portRangeMin: 22, portRangeMax: 22)])
        let (plans, unexpressed) = SecurityGroupReconciler.plan(securityGroups: [restrictive])

        // Pinned to the exact ACL, not `allSatisfy { $0.direction != ... }`:
        // that predicate is vacuously true on an empty array, so a builder that
        // stopped expressing this rule would drop it into `unexpressed` and the
        // test would keep passing while no longer testing its own premise —
        // that the group is restrictive *and* real.
        #expect(unexpressed.isEmpty)
        #expect(plans[1].acls.count == 1)
        #expect(plans[1].acls[0].direction == "to-lport")
        #expect(plans[0].name == OVNNaming.dropPortGroupName)
        for metadata in SecurityGroupACLBuilder.metadataEgressACLs() {
            #expect(plans[0].acls.contains(metadata))
        }

        let membership = DesiredPortMembership(portName: "lsp-vm", securityGroupIds: [groupId])
        #expect(membership.desiredGroups?.contains(OVNNaming.dropPortGroupName) == true)
    }

    // MARK: - Plan and teardown

    @Test("Plan emits the drop group plus one port group per security group")
    func planShape() {
        let group = DesiredSecurityGroup(
            id: groupId, generation: 4,
            rules: [rule(protocolName: "tcp", portRangeMin: 22, portRangeMax: 22)])
        let (plans, unexpressed) = SecurityGroupReconciler.plan(securityGroups: [group])

        #expect(unexpressed.isEmpty)
        #expect(plans.count == 2)
        #expect(plans[0].name == OVNNaming.dropPortGroupName)
        #expect(plans[0].generation == SecurityGroupACLBuilder.dropGroupRevision)
        #expect(plans[1].name == pg)
        #expect(plans[1].generation == 4)
        #expect(plans[1].acls.count == 1)
        #expect(plans[1].acls[0].externalIDs["strato-sg-id"] == groupId.uuidString.lowercased())
    }

    @Test("Inexpressible rules are reported, the rest of the group still plans")
    func unexpressedRules() {
        let bad = rule(protocolName: "sctp")
        let good = rule()
        let group = DesiredSecurityGroup(id: groupId, generation: 1, rules: [bad, good])
        let (plans, unexpressed) = SecurityGroupReconciler.plan(securityGroups: [group])
        #expect(unexpressed == [bad.id])
        #expect(plans[1].acls.count == 1)
    }

    @Test("Teardown removes managed groups the plan no longer wants, never the drop group")
    func teardown() {
        let (plans, _) = SecurityGroupReconciler.plan(securityGroups: [])
        let observed = [
            ObservedPortGroup(name: OVNNaming.dropPortGroupName, generation: 1),
            ObservedPortGroup(name: pg, generation: 3),
            ObservedPortGroup(name: peerPG, generation: nil),
        ]
        let names = SecurityGroupReconciler.teardownNames(desired: plans, observed: observed)
        #expect(names == [pg, peerPG].sorted())
    }

    @Test("ACL rewrite triggers on missing or older stamps, not on newer ones")
    func generationGuard() {
        let rev = SecurityGroupACLBuilder.aclSchemaRevision
        #expect(SecurityGroupReconciler.needsACLRewrite(planned: 3, observed: nil))
        #expect(
            SecurityGroupReconciler.needsACLRewrite(planned: 3, observed: 2, observedBuilderRevision: rev))
        #expect(
            !SecurityGroupReconciler.needsACLRewrite(planned: 3, observed: 3, observedBuilderRevision: rev))
        // A newer stored generation means this sync is stale: don't downgrade.
        #expect(
            !SecurityGroupReconciler.needsACLRewrite(planned: 3, observed: 4, observedBuilderRevision: rev))
    }

    @Test("A builder-revision change rewrites current groups but never stale syncs")
    func builderRevisionGuard() {
        let stale = SecurityGroupACLBuilder.aclSchemaRevision - 1
        // Same generation, older builder: the upgrade's fixed ACLs roll out.
        #expect(
            SecurityGroupReconciler.needsACLRewrite(planned: 3, observed: 3, observedBuilderRevision: stale))
        // Missing revision stamp (pre-revision rows): rewrite.
        #expect(
            SecurityGroupReconciler.needsACLRewrite(planned: 3, observed: 3, observedBuilderRevision: nil))
        // A stale sync must not rewrite with outdated rules, even to apply
        // the new builder — the current-generation sync does that.
        #expect(
            !SecurityGroupReconciler.needsACLRewrite(planned: 2, observed: 3, observedBuilderRevision: stale))
    }

    // MARK: - Membership

    @Test("Desired membership is the attached groups plus the drop group; nil stays nil")
    func desiredMembership() {
        let managed = DesiredPortMembership(portName: "vm-X", securityGroupIds: [groupId, peerId])
        #expect(managed.desiredGroups == [pg, peerPG, OVNNaming.dropPortGroupName])
        let unmanaged = DesiredPortMembership(portName: "vm-Y", securityGroupIds: nil)
        #expect(unmanaged.desiredGroups == nil)
    }

    @Test("Membership convergence adds missing and removes extra groups, skipping unmanaged ports")
    func membershipConvergence() async {
        let actuator = RecordingSecurityGroupActuator(
            membership: [
                // vm-A: already in drop, missing pg, wrongly in peerPG.
                "vm-A": [OVNNaming.dropPortGroupName, peerPG]
            ])
        let memberships = [
            DesiredPortMembership(portName: "vm-A", securityGroupIds: [groupId]),
            DesiredPortMembership(portName: "vm-B", securityGroupIds: nil),
        ]
        await SecurityGroupReconciler.reconcileMembership(
            memberships: memberships, actuator: actuator, logger: Logger(label: "test"))

        let added = await actuator.added
        let removed = await actuator.removed
        let observedPorts = await actuator.observedPorts
        #expect(added == [Membership(port: "vm-A", group: pg)])
        #expect(removed == [Membership(port: "vm-A", group: peerPG)])
        // The unmanaged port was never even observed.
        #expect(observedPorts == ["vm-A"])
    }

    /// A sandbox port is nothing special to the reconciler (STR-102): only the
    /// name differs, and the `sbx-`/`vm-` split is deliberate. Pinned here
    /// because getting the name wrong upstream is a *silent* failure — a port
    /// `observeMembership` never returns is skipped without a log line.
    @Test("Sandbox ports converge exactly as VM ports do, under their own name")
    func sandboxPortMembership() async {
        let sandboxPort = OVNNaming.sandboxPortName(sandboxId: "S", nicIndex: 0)
        #expect(sandboxPort != OVNNaming.vmPortName(vmId: "S", nicIndex: 0))
        // The membership derivation in `Agent.handleMessage` calls
        // `sandboxPortName` directly — it has no `NICPlacement` in hand — while
        // the orchestrator that *creates* the port routes through
        // `portName(workloadId:nicIndex:placement:)`. Two decision sites for one
        // name, so pin that they agree: if `portName` ever grew a case that
        // named a sandbox port differently, membership would converge against a
        // port OVN does not have, and nothing would say so.
        #expect(
            OVNNaming.portName(
                workloadId: "S", nicIndex: 0,
                placement: .sandboxNetns(netnsName: "strato-sbx-S", owner: nil)) == sandboxPort)

        let actuator = RecordingSecurityGroupActuator(
            membership: [sandboxPort: [OVNNaming.dropPortGroupName, peerPG]])
        await SecurityGroupReconciler.reconcileMembership(
            memberships: [
                DesiredPortMembership(portName: sandboxPort, securityGroupIds: [groupId])
            ],
            actuator: actuator, logger: Logger(label: "test"))

        #expect(await actuator.added == [Membership(port: sandboxPort, group: pg)])
        #expect(await actuator.removed == [Membership(port: sandboxPort, group: peerPG)])
    }

    @Test("A port joins the drop group before any allow group")
    func membershipDropGroupFirst() async {
        let actuator = RecordingSecurityGroupActuator()
        let memberships = [
            DesiredPortMembership(portName: "vm-A", securityGroupIds: [groupId, peerId])
        ]
        await SecurityGroupReconciler.reconcileMembership(
            memberships: memberships, actuator: actuator, logger: Logger(label: "test"))

        let added = await actuator.added
        #expect(added.first?.group == OVNNaming.dropPortGroupName)
        #expect(Set(added.map(\.group)) == [OVNNaming.dropPortGroupName, pg, peerPG])
    }

    @Test("A failed drop-group join skips the port's allow groups entirely (fail closed)")
    func membershipDropGroupFailureSkipsAllows() async {
        let actuator = RecordingSecurityGroupActuator(
            failingGroups: [OVNNaming.dropPortGroupName])
        let memberships = [
            DesiredPortMembership(portName: "vm-A", securityGroupIds: [groupId]),
            // A port already in the drop group converges its allows normally.
            DesiredPortMembership(portName: "vm-B", securityGroupIds: [groupId]),
        ]
        let actuatorWithB = actuator
        await actuatorWithB.seedMembership(port: "vm-B", groups: [OVNNaming.dropPortGroupName])
        await SecurityGroupReconciler.reconcileMembership(
            memberships: memberships, actuator: actuator, logger: Logger(label: "test"))

        let added = await actuator.added
        // vm-A: the drop add failed, so no allow group was joined — a port in
        // allow groups without the drop group would be default-allow.
        #expect(!added.contains(Membership(port: "vm-A", group: pg)))
        // vm-B: already default-denied, its allow group converged.
        #expect(added.contains(Membership(port: "vm-B", group: pg)))
    }

    @Test("Authority reconcile ensures plans then tears down leftovers")
    func authorityReconcile() async throws {
        let group = DesiredSecurityGroup(id: groupId, generation: 2, rules: [rule()])
        let actuator = RecordingSecurityGroupActuator(
            observed: [
                ObservedPortGroup(name: OVNNaming.dropPortGroupName, generation: 1),
                ObservedPortGroup(name: peerPG, generation: 5),
            ])
        try await SecurityGroupReconciler.reconcile(
            securityGroups: [group], actuator: actuator, logger: Logger(label: "test"))

        let ensured = await actuator.ensured
        let removedGroups = await actuator.removedGroups
        #expect(ensured.map(\.name) == [OVNNaming.dropPortGroupName, pg])
        #expect(removedGroups == [peerPG])
    }
}

// MARK: - Recording actuator

private struct Membership: Equatable {
    let port: String
    let group: String
}

private actor RecordingSecurityGroupActuator: SecurityGroupActuator {
    struct AddFailed: Error {}

    private(set) var ensured: [PortGroupPlan] = []
    private(set) var removedGroups: [String] = []
    private(set) var added: [Membership] = []
    private(set) var removed: [Membership] = []
    private(set) var observedPorts: [String] = []

    private let observed: [ObservedPortGroup]
    private var membership: [String: Set<String>]
    private let failingGroups: Set<String>

    init(
        observed: [ObservedPortGroup] = [], membership: [String: Set<String>] = [:],
        failingGroups: Set<String> = []
    ) {
        self.observed = observed
        self.membership = membership
        self.failingGroups = failingGroups
    }

    func seedMembership(port: String, groups: Set<String>) {
        membership[port] = groups
    }

    func observeSecurityGroups() async throws -> [ObservedPortGroup] { observed }

    func ensurePortGroup(_ plan: PortGroupPlan) async throws {
        ensured.append(plan)
    }

    func removePortGroup(named name: String) async throws {
        removedGroups.append(name)
    }

    func observeMembership(ofPorts portNames: [String]) async throws -> [String: Set<String>] {
        observedPorts.append(contentsOf: portNames)
        return membership.filter { portNames.contains($0.key) }
    }

    func addPort(named portName: String, toGroup group: String) async throws {
        if failingGroups.contains(group) { throw AddFailed() }
        added.append(Membership(port: portName, group: group))
    }

    func removePort(named portName: String, fromGroup group: String) async throws {
        removed.append(Membership(port: portName, group: group))
    }
}
