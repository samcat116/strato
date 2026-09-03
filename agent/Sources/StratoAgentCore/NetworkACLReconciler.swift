import Foundation
import Logging
import StratoShared

// Network ACLs: ordered, subnet-level filtering realized as OVN ACLs attached
// directly to tenant logical switches. This file owns every policy decision;
// NetworkServiceLinux only translates the actuator operations to OVSDB calls.

/// External-id keys shared by the pure planner and the Linux OVN actuator.
public enum NetworkACLRowIdentity {
    public static let managedKey = "strato-managed"
    public static let managedValue = "true"
    public static let roleKey = "strato-acl-role"
    public static let roleValue = "network-acl"
    public static let networkIDKey = "strato-network-id"
    public static let policyIDKey = "strato-network-acl-id"
    public static let ruleIDKey = "strato-network-acl-rule-id"
    public static let ruleKindKey = "strato-network-acl-kind"
    public static let defaultDropKind = "default-drop"
    public static let replacementGuardKind = "replacement-guard"
    public static let ruleKind = "rule"
    public static let generationKey = "strato-nacl-generation"
    public static let builderRevisionKey = "strato-nacl-builder-rev"
    public static let policyStampKey = "strato-nacl-id"
}

/// A complete switch policy, split by application order so replacement can be
/// fail-closed even though SwiftOVN exposes one transaction per ACL row.
public struct NetworkACLPlan: Equatable, Sendable {
    public let networkID: UUID
    public let policyID: UUID
    public let switchName: String
    public let generation: Int64
    public let defaultDrops: [ACLSpec]
    public let ruleDrops: [ACLSpec]
    public let rulePasses: [ACLSpec]

    public init(
        networkID: UUID,
        policyID: UUID,
        switchName: String,
        generation: Int64,
        defaultDrops: [ACLSpec],
        ruleDrops: [ACLSpec],
        rulePasses: [ACLSpec]
    ) {
        self.networkID = networkID
        self.policyID = policyID
        self.switchName = switchName
        self.generation = generation
        self.defaultDrops = defaultDrops
        self.ruleDrops = ruleDrops
        self.rulePasses = rulePasses
    }

    public var acls: [ACLSpec] { defaultDrops + ruleDrops + rulePasses }
}

/// One Strato-owned NACL row attached to a logical switch.
public struct ObservedNetworkACLRule: Equatable, Sendable {
    public let uuid: String
    public let action: String
    public let direction: String
    public let priority: Int?
    public let tier: Int?
    public let match: String
    public let kind: String?
    public let externalIDs: [String: String]

    public init(
        uuid: String,
        action: String,
        direction: String = "",
        priority: Int? = nil,
        tier: Int? = nil,
        match: String = "",
        kind: String? = nil,
        externalIDs: [String: String] = [:]
    ) {
        self.uuid = uuid
        self.action = action
        self.direction = direction
        self.priority = priority
        self.tier = tier
        self.match = match
        self.kind = kind
        self.externalIDs = externalIDs
    }

    public init(uuid: String, spec: ACLSpec) {
        self.init(
            uuid: uuid,
            action: spec.action,
            direction: spec.direction,
            priority: spec.priority,
            tier: spec.tier,
            match: spec.match,
            kind: spec.externalIDs[NetworkACLRowIdentity.ruleKindKey],
            externalIDs: spec.externalIDs)
    }

    fileprivate func matches(_ spec: ACLSpec) -> Bool {
        action == spec.action
            && direction == spec.direction
            && priority == spec.priority
            && tier == spec.tier
            && match == spec.match
            && externalIDs == spec.externalIDs
    }
}

/// The NACL feature's state on one logical switch. Operator ACLs and ACLs from
/// other Strato roles are excluded by the actuator before this reaches core.
public struct ObservedNetworkACL: Equatable, Sendable {
    public let switchName: String
    public let policyID: UUID?
    public let generation: Int64?
    public let builderRevision: Int64?
    public let rules: [ObservedNetworkACLRule]

    public init(
        switchName: String,
        policyID: UUID?,
        generation: Int64?,
        builderRevision: Int64?,
        rules: [ObservedNetworkACLRule]
    ) {
        self.switchName = switchName
        self.policyID = policyID
        self.generation = generation
        self.builderRevision = builderRevision
        self.rules = rules
    }
}

public struct InvalidNetworkACLPlan: Equatable, Sendable {
    public let networkID: UUID
    public let policyIDs: [UUID]
    public let ruleIDs: [UUID]
    public let reason: String

    public init(networkID: UUID, policyIDs: [UUID], ruleIDs: [UUID], reason: String) {
        self.networkID = networkID
        self.policyIDs = policyIDs
        self.ruleIDs = ruleIDs
        self.reason = reason
    }
}

public struct NetworkACLPlanningResult: Equatable, Sendable {
    public let hasOpinion: Bool
    public let plans: [NetworkACLPlan]
    /// Switches whose current ACLs must be left untouched: nil is no opinion,
    /// while malformed authoritative input keeps last-known-good enforcement.
    public let protectedSwitchNames: Set<String>
    public let invalid: [InvalidNetworkACLPlan]

    public init(
        hasOpinion: Bool,
        plans: [NetworkACLPlan],
        protectedSwitchNames: Set<String>,
        invalid: [InvalidNetworkACLPlan]
    ) {
        self.hasOpinion = hasOpinion
        self.plans = plans
        self.protectedSwitchNames = protectedSwitchNames
        self.invalid = invalid
    }
}

/// Pure conversion from the wire's ordered rule vocabulary to OVN ACL rows.
public enum NetworkACLBuilder {
    public static let builderRevision: Int64 = 1
    public static let minimumRuleNumber = 1
    public static let maximumRuleNumber = 32_766
    public static let maximumRulesPerPolicy = 100
    public static let defaultDropPriority = 0
    /// Reserved above every user rule while a replacement is in progress.
    public static let replacementGuardPriority = 32_767

    public static func priority(forRuleNumber ruleNumber: Int) -> Int? {
        guard (minimumRuleNumber...maximumRuleNumber).contains(ruleNumber) else { return nil }
        return 32_767 - ruleNumber
    }

    /// Build one user rule. An allow becomes `pass`, not `allow` or
    /// `allow-stateless`: it advances to the stateful security-group tier, so a
    /// packet must satisfy both policies and the NACL rule creates no conntrack
    /// state itself. OVN nevertheless admits return traffic for a connection
    /// already accepted by a later `allow-related` ACL without re-evaluating an
    /// ACL verdict; that pinned backend boundary means this is not an exact AWS
    /// established-return-flow model.
    public static func acl(
        for rule: DesiredNetworkACLRule,
        networkID: UUID,
        policyID: UUID,
        generation: Int64
    ) -> ACLSpec? {
        guard let priority = priority(forRuleNumber: rule.ruleNumber) else { return nil }

        let family: String
        switch rule.ethertype {
        case "ipv4": family = "ip4"
        case "ipv6": family = "ip6"
        default: return nil
        }

        let direction: String
        let peerField: String
        switch rule.direction {
        case "ingress":
            direction = "to-lport"
            peerField = "\(family).src"
        case "egress":
            direction = "from-lport"
            peerField = "\(family).dst"
        default: return nil
        }

        let action: String
        switch rule.action {
        case "allow": action = "pass"
        case "deny": action = "drop"
        default: return nil
        }

        switch rule.ethertype {
        case "ipv4": guard IPv4CIDR(rule.remoteCIDR) != nil else { return nil }
        case "ipv6": guard IPv6CIDR(rule.remoteCIDR) != nil else { return nil }
        default: return nil
        }
        var clauses = [family, "\(peerField) == \(rule.remoteCIDR)"]

        switch rule.protocolName {
        case nil:
            guard rule.portRangeMin == nil, rule.portRangeMax == nil else { return nil }
        case "tcp", "udp":
            let proto = rule.protocolName!
            clauses.append(proto)
            switch (rule.portRangeMin, rule.portRangeMax) {
            case (nil, nil):
                break
            case let (minimum?, maximum?)
            where (0...65_535).contains(minimum)
                && (0...65_535).contains(maximum) && minimum <= maximum:
                if minimum == maximum {
                    clauses.append("\(proto).dst == \(minimum)")
                } else {
                    clauses.append("\(proto).dst >= \(minimum) && \(proto).dst <= \(maximum)")
                }
            default:
                return nil
            }
        case "icmp":
            let proto = rule.ethertype == "ipv6" ? "icmp6" : "icmp4"
            clauses.append(proto)
            switch (rule.portRangeMin, rule.portRangeMax) {
            case (nil, nil):
                break
            case let (type?, nil) where (0...255).contains(type):
                clauses.append("\(proto).type == \(type)")
            case let (type?, code?) where (0...255).contains(type) && (0...255).contains(code):
                clauses.append("\(proto).type == \(type)")
                clauses.append("\(proto).code == \(code)")
            default:
                return nil
            }
        default:
            return nil
        }

        var externalIDs = baseExternalIDs(
            networkID: networkID, policyID: policyID, generation: generation)
        externalIDs[NetworkACLRowIdentity.ruleIDKey] = rule.id.uuidString.lowercased()
        externalIDs[NetworkACLRowIdentity.ruleKindKey] = NetworkACLRowIdentity.ruleKind
        return ACLSpec(
            direction: direction,
            priority: priority,
            tier: StratoACLTier.network,
            match: clauses.joined(separator: " && "),
            action: action,
            externalIDs: externalIDs)
    }

    public static func defaultDrops(
        networkID: UUID, policyID: UUID, generation: Int64
    ) -> [ACLSpec] {
        var externalIDs = baseExternalIDs(
            networkID: networkID, policyID: policyID, generation: generation)
        externalIDs[NetworkACLRowIdentity.ruleKindKey] = NetworkACLRowIdentity.defaultDropKind
        return ["from-lport", "to-lport"].map { direction in
            ACLSpec(
                direction: direction,
                priority: defaultDropPriority,
                tier: StratoACLTier.network,
                match: "ip",
                action: "drop",
                externalIDs: externalIDs)
        }
    }

    /// Temporary terminal drops that make a multi-transaction replacement
    /// restrictive before any old positive verdict is removed. They are not
    /// part of the finished plan and are deleted before the switch is stamped.
    public static func replacementGuards(
        networkID: UUID, policyID: UUID, generation: Int64
    ) -> [ACLSpec] {
        var externalIDs = baseExternalIDs(
            networkID: networkID, policyID: policyID, generation: generation)
        externalIDs[NetworkACLRowIdentity.ruleKindKey] =
            NetworkACLRowIdentity.replacementGuardKind
        return ["from-lport", "to-lport"].map { direction in
            ACLSpec(
                direction: direction,
                priority: replacementGuardPriority,
                tier: StratoACLTier.network,
                match: "ip",
                action: "drop",
                externalIDs: externalIDs)
        }
    }

    private static func baseExternalIDs(
        networkID: UUID, policyID: UUID, generation: Int64
    ) -> [String: String] {
        [
            NetworkACLRowIdentity.managedKey: NetworkACLRowIdentity.managedValue,
            NetworkACLRowIdentity.roleKey: NetworkACLRowIdentity.roleValue,
            NetworkACLRowIdentity.networkIDKey: networkID.uuidString.lowercased(),
            NetworkACLRowIdentity.policyIDKey: policyID.uuidString.lowercased(),
            NetworkACLRowIdentity.generationKey: String(generation),
            NetworkACLRowIdentity.builderRevisionKey: String(builderRevision),
        ]
    }
}

/// Live side effects used by the pure reconciler. Creating attaches the row to
/// the named logical switch atomically; deleting detaches it from every parent.
public protocol NetworkACLActuator: Sendable {
    func observeNetworkACLs() async throws -> [ObservedNetworkACL]
    @discardableResult
    func createNetworkACL(_ acl: ACLSpec, onSwitchNamed switchName: String) async throws -> String
    func removeNetworkACL(uuid: String) async throws
    /// Stamps the parent last, after the complete desired ACL set exists.
    func stampNetworkACL(_ plan: NetworkACLPlan) async throws
    /// Clears only feature-specific parent stamps, preserving every other id.
    func clearNetworkACLStamp(onSwitchNamed switchName: String) async throws
}

public enum NetworkACLReconciler {
    public static func plan(networks: [DesiredNetworkState]) -> NetworkACLPlanningResult {
        var hasOpinion = false
        var plans: [NetworkACLPlan] = []
        var protected: Set<String> = []
        var invalid: [InvalidNetworkACLPlan] = []

        for network in networks.sorted(by: { $0.networkId.uuidString < $1.networkId.uuidString }) {
            let switchName = OVNNaming.switchName(networkId: network.networkId)
            guard let policies = network.networkACLs else {
                protected.insert(switchName)
                continue
            }
            hasOpinion = true

            guard policies.count <= 1 else {
                protected.insert(switchName)
                invalid.append(
                    InvalidNetworkACLPlan(
                        networkID: network.networkId,
                        policyIDs: policies.map(\.id),
                        ruleIDs: policies.flatMap(\.rules).map(\.id),
                        reason: "a logical network may have at most one network ACL"))
                continue
            }
            guard let policy = policies.first else { continue }

            guard policy.generation >= 1,
                policy.rules.count <= NetworkACLBuilder.maximumRulesPerPolicy
            else {
                protected.insert(switchName)
                invalid.append(
                    InvalidNetworkACLPlan(
                        networkID: network.networkId,
                        policyIDs: [policy.id],
                        ruleIDs: policy.rules.map(\.id),
                        reason: policy.generation < 1
                            ? "network ACL generation must be positive"
                            : "a network ACL may contain at most \(NetworkACLBuilder.maximumRulesPerPolicy) rules"))
                continue
            }

            let sortedRules = policy.rules.sorted {
                if $0.ruleNumber != $1.ruleNumber { return $0.ruleNumber < $1.ruleNumber }
                if $0.direction != $1.direction { return $0.direction < $1.direction }
                return $0.id.uuidString < $1.id.uuidString
            }
            var seenRuleNumbers: Set<String> = []
            var built: [ACLSpec] = []
            var badRuleIDs: [UUID] = []
            for rule in sortedRules {
                let orderingKey = "\(rule.direction):\(rule.ruleNumber)"
                guard seenRuleNumbers.insert(orderingKey).inserted,
                    let acl = NetworkACLBuilder.acl(
                        for: rule,
                        networkID: network.networkId,
                        policyID: policy.id,
                        generation: policy.generation)
                else {
                    badRuleIDs.append(rule.id)
                    continue
                }
                built.append(acl)
            }

            guard badRuleIDs.isEmpty else {
                protected.insert(switchName)
                invalid.append(
                    InvalidNetworkACLPlan(
                        networkID: network.networkId,
                        policyIDs: [policy.id],
                        ruleIDs: badRuleIDs,
                        reason: "one or more network ACL rules cannot be expressed safely"))
                continue
            }

            plans.append(
                NetworkACLPlan(
                    networkID: network.networkId,
                    policyID: policy.id,
                    switchName: switchName,
                    generation: policy.generation,
                    defaultDrops: NetworkACLBuilder.defaultDrops(
                        networkID: network.networkId,
                        policyID: policy.id,
                        generation: policy.generation),
                    ruleDrops: built.filter { $0.action == "drop" },
                    rulePasses: built.filter { $0.action == "pass" }))
        }

        return NetworkACLPlanningResult(
            hasOpinion: hasOpinion,
            plans: plans,
            protectedSwitchNames: protected,
            invalid: invalid)
    }

    /// Missing/stale stamps and builder changes rewrite; a newer observed
    /// generation is left untouched so a replay cannot resurrect older rules.
    public static func needsRewrite(
        planned: NetworkACLPlan, observed: ObservedNetworkACL?
    ) -> Bool {
        guard let observed, let generation = observed.generation else { return true }
        // Generations are scoped to one policy row. Deleting and recreating an
        // ACL gives it a new id and resets its generation, so compare identity
        // before ordering: the owning network's outer generation has already
        // rejected stale network payloads before this reconciler runs.
        if observed.policyID != planned.policyID { return true }
        if planned.generation < generation { return false }
        if observed.builderRevision != NetworkACLBuilder.builderRevision { return true }
        if observed.rules.contains(where: {
            $0.kind == NetworkACLRowIdentity.replacementGuardKind
        }) {
            return true
        }
        if observed.rules.count != planned.acls.count { return true }
        if planned.generation > generation { return true }

        // The parent stamp proves which desired generation completed, but it
        // cannot prove that the referenced rows stayed intact afterward. Match
        // the complete owned multiset so action/tier/match drift (including a
        // deny mutated into a pass) is healed at the same generation.
        var unmatched = observed.rules
        for acl in planned.acls {
            guard let index = unmatched.firstIndex(where: { $0.matches(acl) }) else {
                return true
            }
            unmatched.remove(at: index)
        }
        return !unmatched.isEmpty
    }

    /// Converge one switch. The order is deliberately stricter than the
    /// security-group replace: old and new ordered allow/deny rows can conflict.
    /// A temporary highest-priority drop in each direction masks the old set
    /// while it is replaced, then disappears before the generation stamp. A
    /// thrown operation leaves the stamp stale and the guards fail closed until
    /// the next level-triggered retry completes.
    public static func converge(
        plan: NetworkACLPlan,
        observed: ObservedNetworkACL?,
        actuator: any NetworkACLActuator
    ) async throws {
        guard needsRewrite(planned: plan, observed: observed) else { return }

        guard let observed else {
            // Initial realization cannot weaken a previous Strato policy, so it
            // needs no temporary replacement guard. Defaults still precede
            // positive rules, and the parent stamp remains last.
            for acl in plan.acls {
                _ = try await actuator.createNetworkACL(acl, onSwitchNamed: plan.switchName)
            }
            try await actuator.stampNetworkACL(plan)
            return
        }

        let validDirections: Set<String> = ["from-lport", "to-lport"]
        let existingGuards = observed.rules.filter {
            $0.kind == NetworkACLRowIdentity.replacementGuardKind
                && $0.action == "drop"
                && $0.priority == NetworkACLBuilder.replacementGuardPriority
                && $0.tier == StratoACLTier.network
                && $0.match == "ip"
                && validDirections.contains($0.direction)
        }
        var guardIDs = existingGuards.map(\.uuid)
        var guardedDirections = Set(existingGuards.map(\.direction))
        for acl in NetworkACLBuilder.replacementGuards(
            networkID: plan.networkID,
            policyID: plan.policyID,
            generation: plan.generation)
        where guardedDirections.insert(acl.direction).inserted {
            guardIDs.append(
                try await actuator.createNetworkACL(acl, onSwitchNamed: plan.switchName))
        }

        // Valid guards stay attached until the new set is complete. Any
        // malformed row that merely claims the guard kind is treated as an old
        // policy row and removed in verdict-safe order.
        let retainedGuards = Set(existingGuards.map(\.uuid))
        let oldRules = observed.rules.filter { !retainedGuards.contains($0.uuid) }
        for rule in oldRules.filter({ $0.action != "drop" }).sorted(by: { $0.uuid < $1.uuid }) {
            try await actuator.removeNetworkACL(uuid: rule.uuid)
        }
        for rule in oldRules.filter({ $0.action == "drop" }).sorted(by: { $0.uuid < $1.uuid }) {
            try await actuator.removeNetworkACL(uuid: rule.uuid)
        }

        for acl in plan.acls {
            _ = try await actuator.createNetworkACL(acl, onSwitchNamed: plan.switchName)
        }
        for uuid in guardIDs.sorted() {
            try await actuator.removeNetworkACL(uuid: uuid)
        }
        try await actuator.stampNetworkACL(plan)
    }

    public static func tearDown(
        observed: ObservedNetworkACL,
        actuator: any NetworkACLActuator
    ) async throws {
        // Removing a policy is intentionally permissive, but keep a partial
        // teardown restrictive: passes disappear before drops.
        for rule in observed.rules.filter({ $0.action != "drop" }).sorted(by: { $0.uuid < $1.uuid }) {
            try await actuator.removeNetworkACL(uuid: rule.uuid)
        }
        for rule in observed.rules.filter({ $0.action == "drop" }).sorted(by: { $0.uuid < $1.uuid }) {
            try await actuator.removeNetworkACL(uuid: rule.uuid)
        }
        try await actuator.clearNetworkACLStamp(onSwitchNamed: observed.switchName)
    }

    /// Authority-side convergence. Nil networkACLs are protected no-opinion;
    /// an explicit empty list participates in observed-minus-desired teardown.
    public static func reconcile(
        networks: [DesiredNetworkState],
        protectedSwitchNames extraProtection: Set<String> = [],
        actuator: any NetworkACLActuator,
        logger: Logger
    ) async throws {
        let result = plan(networks: networks)
        guard result.hasOpinion else { return }

        for item in result.invalid {
            logger.error(
                "Network ACL desired state is invalid; leaving the switch's existing ACLs untouched",
                metadata: [
                    "networkId": .string(item.networkID.uuidString),
                    "policyIds": .array(item.policyIDs.map { .string($0.uuidString) }),
                    "ruleIds": .array(item.ruleIDs.map { .string($0.uuidString) }),
                    "reason": .string(item.reason),
                ])
        }

        let observed = try await actuator.observeNetworkACLs()
        let observedBySwitch = Dictionary(uniqueKeysWithValues: observed.map { ($0.switchName, $0) })
        for plan in result.plans {
            await attempt(logger, "converge network ACL on \(plan.switchName)") {
                try await converge(
                    plan: plan,
                    observed: observedBySwitch[plan.switchName],
                    actuator: actuator)
            }
        }

        let desiredSwitches = Set(result.plans.map(\.switchName))
        let protected = result.protectedSwitchNames.union(extraProtection)
        for row in observed.sorted(by: { $0.switchName < $1.switchName })
        where !desiredSwitches.contains(row.switchName) && !protected.contains(row.switchName) {
            await attempt(logger, "tear down network ACL on \(row.switchName)") {
                try await tearDown(observed: row, actuator: actuator)
            }
        }
    }
}
