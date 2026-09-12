import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("Network ACL Reconciler")
struct NetworkACLReconcilerTests {
    private let networkID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0100")!
    private let policyID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0200")!

    private var switchName: String { OVNNaming.switchName(networkId: networkID) }

    private func rule(
        id: UUID = UUID(),
        number: Int = 100,
        direction: String = "ingress",
        ethertype: String = "ipv4",
        action: String = "allow",
        protocolName: String? = nil,
        minimum: Int? = nil,
        maximum: Int? = nil,
        cidr: String = "0.0.0.0/0"
    ) -> DesiredNetworkACLRule {
        DesiredNetworkACLRule(
            id: id,
            ruleNumber: number,
            direction: direction,
            ethertype: ethertype,
            action: action,
            protocolName: protocolName,
            portRangeMin: minimum,
            portRangeMax: maximum,
            remoteCIDR: cidr)
    }

    private func policy(
        id: UUID? = nil,
        generation: Int64 = 4,
        rules: [DesiredNetworkACLRule]
    ) -> DesiredNetworkACL {
        DesiredNetworkACL(id: id ?? policyID, generation: generation, rules: rules)
    }

    private func network(
        id: UUID? = nil,
        generation: Int64 = 7,
        policies: [DesiredNetworkACL]?
    ) -> DesiredNetworkState {
        DesiredNetworkState(
            networkId: id ?? networkID,
            name: "private",
            subnet: "10.0.0.0/24",
            gateway: nil,
            routerKey: "project",
            externalAccess: false,
            generation: generation,
            networkACLs: policies)
    }

    private func plan(rules: [DesiredNetworkACLRule], generation: Int64 = 4) -> NetworkACLPlan {
        NetworkACLReconciler.plan(
            networks: [network(policies: [policy(generation: generation, rules: rules)])]
        ).plans[0]
    }

    // MARK: - Rule construction

    @Test("Lower rule numbers map to higher OVN priorities")
    func orderedPriorityMapping() {
        #expect(NetworkACLBuilder.priority(forRuleNumber: 1) == 32_766)
        #expect(NetworkACLBuilder.priority(forRuleNumber: 100) == 32_667)
        #expect(NetworkACLBuilder.priority(forRuleNumber: 32_766) == 1)
        #expect(NetworkACLBuilder.priority(forRuleNumber: 0) == nil)
        #expect(NetworkACLBuilder.priority(forRuleNumber: 32_767) == nil)
    }

    @Test("Ingress allow is a stateless tier-1 pass and still gates through security groups")
    func ingressAllowTCPRange() {
        let ruleID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0300")!
        let acl = NetworkACLBuilder.acl(
            for: rule(
                id: ruleID,
                protocolName: "tcp",
                minimum: 8000,
                maximum: 8080,
                cidr: "203.0.113.0/24"),
            networkID: networkID,
            policyID: policyID,
            generation: 4)!

        #expect(acl.direction == "to-lport")
        #expect(acl.priority == 32_667)
        #expect(acl.tier == StratoACLTier.network)
        // `allow` would be terminal and bypass SG default-deny;
        // `allow-stateless` takes precedence over stateful ACLs in OVN. `pass`
        // is the only action that preserves NACL AND security-group policy.
        #expect(acl.action == "pass")
        #expect(
            acl.match
                == "ip4 && ip4.src == 203.0.113.0/24 && tcp && tcp.dst >= 8000 && tcp.dst <= 8080")
        #expect(acl.externalIDs[NetworkACLRowIdentity.roleKey] == NetworkACLRowIdentity.roleValue)
        #expect(
            acl.externalIDs[NetworkACLRowIdentity.ruleIDKey]
                == ruleID.uuidString.lowercased())
    }

    @Test("Egress deny and ICMPv6 type/code compile without a port-group binding")
    func egressDenyICMPv6() {
        let acl = NetworkACLBuilder.acl(
            for: rule(
                direction: "egress",
                ethertype: "ipv6",
                action: "deny",
                protocolName: "icmp",
                minimum: 128,
                maximum: 0,
                cidr: "2001:db8::/32"),
            networkID: networkID,
            policyID: policyID,
            generation: 4)!
        #expect(acl.direction == "from-lport")
        #expect(acl.action == "drop")
        #expect(
            acl.match
                == "ip6 && ip6.dst == 2001:db8::/32 && icmp6 && icmp6.type == 128 && icmp6.code == 0")
        #expect(!acl.match.contains("@pg_"))
    }

    @Test("Both directions get an implicit tier-1 priority-zero default drop")
    func defaultDeny() {
        let drops = NetworkACLBuilder.defaultDrops(
            networkID: networkID, policyID: policyID, generation: 4)
        #expect(drops.count == 2)
        #expect(Set(drops.map(\.direction)) == ["from-lport", "to-lport"])
        #expect(drops.allSatisfy { $0.priority == 0 })
        #expect(drops.allSatisfy { $0.tier == StratoACLTier.network })
        #expect(drops.allSatisfy { $0.match == "ip" && $0.action == "drop" })
        #expect(
            drops.allSatisfy {
                $0.externalIDs[NetworkACLRowIdentity.ruleKindKey]
                    == NetworkACLRowIdentity.defaultDropKind
            })
    }

    @Test("Unknown vocabulary and malformed ranges fail closed instead of producing a rule")
    func invalidRulesRefused() {
        let invalid = [
            rule(direction: "sideways"),
            rule(ethertype: "ipx"),
            rule(action: "reject"),
            rule(protocolName: "sctp"),
            rule(protocolName: "tcp", minimum: 443, maximum: nil),
            rule(protocolName: nil, minimum: 1, maximum: 2),
            rule(protocolName: "icmp", minimum: nil, maximum: 0),
            rule(cidr: ""),
            rule(cidr: "not-a-cidr"),
            rule(ethertype: "ipv4", cidr: "2001:db8::/32"),
            rule(ethertype: "ipv6", cidr: "203.0.113.0/24"),
        ]
        for item in invalid {
            #expect(
                NetworkACLBuilder.acl(
                    for: item,
                    networkID: networkID,
                    policyID: policyID,
                    generation: 1) == nil)
        }
    }

    // MARK: - Planning and generations

    @Test("Nil is no opinion, empty is teardown, and one ACL plans the switch")
    func opinionSemantics() {
        let noOpinion = NetworkACLReconciler.plan(networks: [network(policies: nil)])
        #expect(!noOpinion.hasOpinion)
        #expect(noOpinion.plans.isEmpty)
        #expect(noOpinion.protectedSwitchNames == [switchName])

        let teardown = NetworkACLReconciler.plan(networks: [network(policies: [])])
        #expect(teardown.hasOpinion)
        #expect(teardown.plans.isEmpty)
        #expect(teardown.protectedSwitchNames.isEmpty)

        let desired = NetworkACLReconciler.plan(
            networks: [network(policies: [policy(rules: [rule()])])])
        #expect(desired.hasOpinion)
        #expect(desired.plans.map(\.switchName) == [switchName])
    }

    @Test("Multiple ACLs and duplicate directional rule numbers protect last-known-good state")
    func invalidPolicyIsProtected() {
        let second = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0201")!
        let multiple = NetworkACLReconciler.plan(
            networks: [
                network(policies: [policy(rules: []), policy(id: second, rules: [])])
            ])
        #expect(multiple.invalid.count == 1)
        #expect(multiple.plans.isEmpty)
        #expect(multiple.protectedSwitchNames == [switchName])

        let duplicate = NetworkACLReconciler.plan(
            networks: [
                network(policies: [policy(rules: [rule(number: 100), rule(number: 100)])])
            ])
        #expect(duplicate.invalid.count == 1)
        #expect(duplicate.plans.isEmpty)
        #expect(duplicate.protectedSwitchNames == [switchName])

        // Ingress and egress have independent ordered lists, so the same rule
        // number in opposite directions is valid.
        let oppositeDirections = NetworkACLReconciler.plan(
            networks: [
                network(policies: [
                    policy(rules: [rule(number: 100), rule(number: 100, direction: "egress")])
                ])
            ])
        #expect(oppositeDirections.invalid.isEmpty)
        #expect(oppositeDirections.plans.count == 1)
    }

    @Test("Nonpositive generations and oversized policies preserve last-known-good state")
    func generationAndRuleLimitValidation() {
        let badGeneration = NetworkACLReconciler.plan(
            networks: [network(policies: [policy(generation: 0, rules: [])])])
        #expect(badGeneration.invalid.count == 1)
        #expect(badGeneration.protectedSwitchNames == [switchName])

        let tooMany = NetworkACLReconciler.plan(
            networks: [
                network(policies: [
                    policy(
                        rules: (0...NetworkACLBuilder.maximumRulesPerPolicy).map {
                            rule(id: UUID(), number: $0 + 1)
                        })
                ])
            ])
        #expect(tooMany.invalid.count == 1)
        #expect(tooMany.protectedSwitchNames == [switchName])
        #expect(tooMany.plans.isEmpty)
    }

    @Test("A newer observed generation is never replaced by a stale sync")
    func generationGuard() {
        let desired = plan(rules: [rule()], generation: 4)
        #expect(
            !NetworkACLReconciler.needsRewrite(
                planned: desired,
                observed: observed(generation: 5, builderRevision: 0)))
        #expect(
            NetworkACLReconciler.needsRewrite(
                planned: desired,
                observed: observed(generation: 4, builderRevision: 0)))
        #expect(
            !NetworkACLReconciler.needsRewrite(
                planned: desired,
                observed: observed(
                    generation: 4,
                    builderRevision: NetworkACLBuilder.builderRevision,
                    rules: desired.acls.enumerated().map {
                        ObservedNetworkACLRule(uuid: "rule-\($0.offset)", spec: $0.element)
                    })))
        #expect(
            NetworkACLReconciler.needsRewrite(
                planned: desired,
                observed: observed(
                    generation: 4,
                    builderRevision: NetworkACLBuilder.builderRevision,
                    rules: [])))
    }

    @Test("Same-stamp rule drift forces a full replacement")
    func sameStampRuleDrift() {
        let desired = plan(rules: [rule(number: 100, action: "deny")], generation: 4)
        var rows = desired.acls.enumerated().map {
            ObservedNetworkACLRule(uuid: "rule-\($0.offset)", spec: $0.element)
        }
        let denied = desired.ruleDrops[0]
        rows[2] = ObservedNetworkACLRule(
            uuid: "rule-2",
            action: "pass",
            direction: denied.direction,
            priority: denied.priority,
            tier: denied.tier,
            match: denied.match,
            kind: denied.externalIDs[NetworkACLRowIdentity.ruleKindKey],
            externalIDs: denied.externalIDs)

        #expect(
            NetworkACLReconciler.needsRewrite(
                planned: desired,
                observed: observed(
                    generation: 4,
                    builderRevision: NetworkACLBuilder.builderRevision,
                    rules: rows)))
    }

    @Test("A recreated policy replaces the old policy even when its generation reset")
    func recreatedPolicyIdentityWinsBeforeGeneration() {
        let recreatedID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0201")!
        let recreated = NetworkACLReconciler.plan(
            networks: [
                network(policies: [policy(id: recreatedID, generation: 1, rules: [rule()])])
            ]
        ).plans[0]

        #expect(
            NetworkACLReconciler.needsRewrite(
                planned: recreated,
                observed: observed(
                    policyID: policyID,
                    generation: 42,
                    builderRevision: NetworkACLBuilder.builderRevision)))
    }

    // MARK: - Fail-closed operation ordering

    @Test("Initial creation attaches defaults, then user drops, then passes, and stamps last")
    func initialCreationOrder() async throws {
        let desired = plan(
            rules: [
                rule(number: 200, action: "allow"),
                rule(number: 100, action: "deny"),
            ])
        let actuator = RecordingNetworkACLActuator()
        try await NetworkACLReconciler.converge(
            plan: desired, observed: nil, actuator: actuator)

        #expect(
            await actuator.events == [
                .create(kind: "default-drop", action: "drop", priority: 0),
                .create(kind: "default-drop", action: "drop", priority: 0),
                .create(kind: "rule", action: "drop", priority: 32_667),
                .create(kind: "rule", action: "pass", priority: 32_567),
                .stamp(generation: 4),
            ])
    }

    @Test("Replacement guards both directions before swapping the full policy")
    func replacementOrder() async throws {
        let desired = plan(
            rules: [
                rule(number: 200, action: "allow"),
                rule(number: 100, action: "deny"),
            ])
        let old = observed(
            generation: 3,
            rules: [
                ObservedNetworkACLRule(uuid: "drop-b", action: "drop"),
                ObservedNetworkACLRule(uuid: "pass-b", action: "pass"),
                ObservedNetworkACLRule(uuid: "allow-a", action: "allow"),
                ObservedNetworkACLRule(uuid: "drop-a", action: "drop"),
            ])
        let actuator = RecordingNetworkACLActuator()
        try await NetworkACLReconciler.converge(
            plan: desired, observed: old, actuator: actuator)

        #expect(
            await actuator.events == [
                .create(kind: "replacement-guard", action: "drop", priority: 32_767),
                .create(kind: "replacement-guard", action: "drop", priority: 32_767),
                .remove(uuid: "allow-a"),
                .remove(uuid: "pass-b"),
                .remove(uuid: "drop-a"),
                .remove(uuid: "drop-b"),
                .create(kind: "default-drop", action: "drop", priority: 0),
                .create(kind: "default-drop", action: "drop", priority: 0),
                .create(kind: "rule", action: "drop", priority: 32_667),
                .create(kind: "rule", action: "pass", priority: 32_567),
                .remove(uuid: "created-1"),
                .remove(uuid: "created-2"),
                .stamp(generation: 4),
            ])
    }

    @Test("Guard drops outrank an old pass when its removal fails")
    func replacementFailureAborts() async {
        let desired = plan(rules: [rule(number: 100, action: "allow")])
        let failure = ActuatorEvent.remove(uuid: "old-pass")
        let actuator = RecordingNetworkACLActuator(failOn: failure)

        await #expect(throws: RecordingNetworkACLActuator.InjectedFailure.self) {
            try await NetworkACLReconciler.converge(
                plan: desired,
                observed: observed(
                    generation: 3,
                    rules: [ObservedNetworkACLRule(uuid: "old-pass", action: "pass")]),
                actuator: actuator)
        }
        #expect(
            await actuator.events == [
                .create(kind: "replacement-guard", action: "drop", priority: 32_767),
                .create(kind: "replacement-guard", action: "drop", priority: 32_767),
                .remove(uuid: "old-pass"),
            ])
    }

    @Test("A retry reuses valid guard drops and cannot hide them behind an equal row count")
    func replacementRetryReusesGuards() async throws {
        let desired = plan(rules: [rule(number: 100, action: "allow")])
        let guarded = observed(
            generation: 3,
            rules: [
                ObservedNetworkACLRule(
                    uuid: "guard-egress", action: "drop", direction: "from-lport",
                    priority: NetworkACLBuilder.replacementGuardPriority,
                    tier: StratoACLTier.network,
                    match: "ip",
                    kind: NetworkACLRowIdentity.replacementGuardKind),
                ObservedNetworkACLRule(
                    uuid: "guard-ingress", action: "drop", direction: "to-lport",
                    priority: NetworkACLBuilder.replacementGuardPriority,
                    tier: StratoACLTier.network,
                    match: "ip",
                    kind: NetworkACLRowIdentity.replacementGuardKind),
                ObservedNetworkACLRule(uuid: "old-pass", action: "pass"),
            ])
        // Three observed rows equals the desired two defaults plus one rule;
        // the temporary marker must still force completion.
        #expect(NetworkACLReconciler.needsRewrite(planned: desired, observed: guarded))

        let actuator = RecordingNetworkACLActuator()
        try await NetworkACLReconciler.converge(
            plan: desired, observed: guarded, actuator: actuator)

        #expect(
            await actuator.events == [
                .remove(uuid: "old-pass"),
                .create(kind: "default-drop", action: "drop", priority: 0),
                .create(kind: "default-drop", action: "drop", priority: 0),
                .create(kind: "rule", action: "pass", priority: 32_667),
                .remove(uuid: "guard-egress"),
                .remove(uuid: "guard-ingress"),
                .stamp(generation: 4),
            ])
    }

    @Test("A malformed claimed guard is replaced before old positive verdicts are removed")
    func replacementRetryRejectsMalformedGuard() async throws {
        let desired = plan(rules: [rule(number: 100, action: "allow")])
        let actuator = RecordingNetworkACLActuator()

        try await NetworkACLReconciler.converge(
            plan: desired,
            observed: observed(
                generation: 3,
                rules: [
                    ObservedNetworkACLRule(
                        uuid: "wrong-tier", action: "drop", direction: "from-lport",
                        priority: NetworkACLBuilder.replacementGuardPriority,
                        tier: StratoACLTier.system,
                        match: "ip",
                        kind: NetworkACLRowIdentity.replacementGuardKind),
                    ObservedNetworkACLRule(uuid: "old-pass", action: "pass"),
                ]),
            actuator: actuator)

        #expect(
            await actuator.events == [
                .create(kind: "replacement-guard", action: "drop", priority: 32_767),
                .create(kind: "replacement-guard", action: "drop", priority: 32_767),
                .remove(uuid: "old-pass"),
                .remove(uuid: "wrong-tier"),
                .create(kind: "default-drop", action: "drop", priority: 0),
                .create(kind: "default-drop", action: "drop", priority: 0),
                .create(kind: "rule", action: "pass", priority: 32_667),
                .remove(uuid: "created-1"),
                .remove(uuid: "created-2"),
                .stamp(generation: 4),
            ])
    }

    @Test("Teardown removes passes before drops and clears the feature stamp last")
    func teardownOrder() async throws {
        let actuator = RecordingNetworkACLActuator()
        try await NetworkACLReconciler.tearDown(
            observed: observed(
                rules: [
                    ObservedNetworkACLRule(uuid: "drop", action: "drop"),
                    ObservedNetworkACLRule(uuid: "pass", action: "pass"),
                ]),
            actuator: actuator)
        #expect(
            await actuator.events == [
                .remove(uuid: "pass"),
                .remove(uuid: "drop"),
                .clear(switchName: switchName),
            ])
    }

    @Test("Invalid multi-ACL input leaves observed enforcement untouched")
    func invalidReconcileDoesNotTearDown() async throws {
        let second = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0201")!
        let actuator = RecordingNetworkACLActuator(
            observed: [observed(rules: [ObservedNetworkACLRule(uuid: "old", action: "drop")])])
        let failures = try await NetworkACLReconciler.reconcile(
            networks: [network(policies: [policy(rules: []), policy(id: second, rules: [])])],
            actuator: actuator,
            logger: Logger(label: "test"))
        #expect(await actuator.events == [.observe])
        #expect(failures.count == 1)
        #expect(failures[0].classification == .permanent)
        #expect(failures[0].affectedNetworkIds == [networkID])
    }

    @Test("Per-policy actuator failures identify the affected network")
    func reconcileReturnsPerNetworkFailures() async throws {
        let createFailure = ActuatorEvent.create(
            kind: NetworkACLRowIdentity.defaultDropKind, action: "drop", priority: 0)
        let convergeActuator = RecordingNetworkACLActuator(failOn: createFailure)
        let convergeFailures = try await NetworkACLReconciler.reconcile(
            networks: [network(policies: [policy(rules: [])])],
            actuator: convergeActuator,
            logger: Logger(label: "test"))
        #expect(convergeFailures.count == 1)
        #expect(convergeFailures[0].affectedNetworkIds == [networkID])

        let teardownActuator = RecordingNetworkACLActuator(
            observed: [observed(rules: [ObservedNetworkACLRule(uuid: "old", action: "pass")])],
            failOn: .remove(uuid: "old"))
        let teardownFailures = try await NetworkACLReconciler.reconcile(
            networks: [network(policies: [])],
            actuator: teardownActuator,
            logger: Logger(label: "test"))
        #expect(teardownFailures.count == 1)
        #expect(teardownFailures[0].affectedNetworkIds == [networkID])
    }

    @Test("Explicit empty policy tears down, while all-nil desired state performs no observation")
    func reconcileOpinionSemantics() async throws {
        let nilActuator = RecordingNetworkACLActuator(
            observed: [observed(rules: [ObservedNetworkACLRule(uuid: "old", action: "drop")])])
        try await NetworkACLReconciler.reconcile(
            networks: [network(policies: nil)],
            actuator: nilActuator,
            logger: Logger(label: "test"))
        #expect(await nilActuator.events.isEmpty)

        let emptyActuator = RecordingNetworkACLActuator(
            observed: [observed(rules: [ObservedNetworkACLRule(uuid: "old", action: "drop")])])
        try await NetworkACLReconciler.reconcile(
            networks: [network(policies: [])],
            actuator: emptyActuator,
            logger: Logger(label: "test"))
        #expect(
            await emptyActuator.events == [
                .observe,
                .remove(uuid: "old"),
                .clear(switchName: switchName),
            ])
    }

    private func observed(
        policyID: UUID? = nil,
        generation: Int64? = 4,
        builderRevision: Int64? = NetworkACLBuilder.builderRevision,
        rules: [ObservedNetworkACLRule] = []
    ) -> ObservedNetworkACL {
        ObservedNetworkACL(
            switchName: switchName,
            policyID: policyID ?? self.policyID,
            generation: generation,
            builderRevision: builderRevision,
            rules: rules)
    }
}

private enum ActuatorEvent: Equatable, Sendable {
    case observe
    case create(kind: String, action: String, priority: Int)
    case remove(uuid: String)
    case stamp(generation: Int64)
    case clear(switchName: String)
}

private actor RecordingNetworkACLActuator: NetworkACLActuator {
    struct InjectedFailure: Error {}

    private(set) var events: [ActuatorEvent] = []
    private let observed: [ObservedNetworkACL]
    private let failOn: ActuatorEvent?
    private var nextCreatedID = 1

    init(observed: [ObservedNetworkACL] = [], failOn: ActuatorEvent? = nil) {
        self.observed = observed
        self.failOn = failOn
    }

    private func record(_ event: ActuatorEvent) throws {
        events.append(event)
        if event == failOn { throw InjectedFailure() }
    }

    func observeNetworkACLs() async throws -> [ObservedNetworkACL] {
        try record(.observe)
        return observed
    }

    func createNetworkACL(_ acl: ACLSpec, onSwitchNamed switchName: String) async throws -> String {
        let uuid = "created-\(nextCreatedID)"
        try record(
            .create(
                kind: acl.externalIDs[NetworkACLRowIdentity.ruleKindKey] ?? "",
                action: acl.action,
                priority: acl.priority))
        nextCreatedID += 1
        return uuid
    }

    func removeNetworkACL(uuid: String) async throws {
        try record(.remove(uuid: uuid))
    }

    func stampNetworkACL(_ plan: NetworkACLPlan) async throws {
        try record(.stamp(generation: plan.generation))
    }

    func clearNetworkACLStamp(onSwitchNamed switchName: String) async throws {
        try record(.clear(switchName: switchName))
    }
}
