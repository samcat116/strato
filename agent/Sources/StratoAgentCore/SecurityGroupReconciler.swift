import Foundation
import Logging
import StratoShared

// Security groups: stateful NIC-level filtering realized as OVN ACLs on port
// groups (the OpenStack/ovn-kubernetes pattern).
//
// This file is the pure, unit-testable core: it turns the control plane's
// `DesiredStateMessage.securityGroups` into port-group plans (one OVN
// Port_Group per group, one ACL per rule, plus the global drop group that
// gives member ports their default-deny), and computes teardown as
// observed − desired. Live OVSDB side effects live in `NetworkServiceLinux`
// behind `SecurityGroupActuator`, exactly like `NetworkReconciler` /
// `NetworkActuator`.
//
// Ownership follows the site topology-authority split (issue #343): port
// groups and their ACLs are site-wide NB records authored only by the
// authority; port *membership* is per-VM and converged by every agent for its
// own VMs' ports (the LSP pattern), so attach/detach on a running VM takes
// effect without a restart.

// MARK: - Naming

extension OVNNaming {
    /// The OVN Port_Group name for a security group. Port-group names double
    /// as identifiers inside ACL match expressions (`@<name>`, and the
    /// auto-generated `$<name>_ip4` address sets), which admit only
    /// alphanumerics and underscores — so the UUID is flattened to hex and the
    /// `pg_` prefix keeps it from starting with a digit.
    public static func portGroupName(securityGroupId: UUID) -> String {
        "pg_" + securityGroupId.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    /// The site-singleton drop port group: every managed VM port is a member,
    /// and its low-priority drop ACLs are what make security groups
    /// default-deny (allows win at higher priority). Mirrors Neutron's
    /// `neutron_pg_drop`.
    public static let dropPortGroupName = "pg_strato_drop"

    /// The OVN-generated address set carrying a port group's member addresses
    /// for one family, as referenced from ACL matches (`$<name>`).
    public static func addressSetReference(portGroup: String, ethertype: String) -> String {
        "$\(portGroup)_\(ethertype == "ipv6" ? "ip6" : "ip4")"
    }
}

// MARK: - ACL construction

/// One OVN ACL row the plan wants on a port group. Pure data; the actuator
/// maps it onto `OVNACL`.
public struct ACLSpec: Equatable, Sendable {
    /// "to-lport" (traffic delivered to a port — ingress from the VM's view)
    /// or "from-lport" (traffic sent by a port — egress).
    public let direction: String
    public let priority: Int
    public let match: String
    /// "allow-related" for stateful rule allows, "allow" for infra carve-outs,
    /// "drop" for the default deny.
    public let action: String
    public let externalIDs: [String: String]

    public init(direction: String, priority: Int, match: String, action: String, externalIDs: [String: String]) {
        self.direction = direction
        self.priority = priority
        self.match = match
        self.action = action
        self.externalIDs = externalIDs
    }
}

/// Builds OVN ACL rows from security-group rules. Pure string assembly —
/// exhaustively unit-tested, because a malformed match either fails the NB
/// transaction or (worse) silently matches nothing.
public enum SecurityGroupACLBuilder {
    /// Rule allows sit above the drop-group denies; both are far below the
    /// reserved OVN internal priorities. Neutron's proven values.
    public static let allowPriority = 1002
    public static let dropPriority = 1001

    /// Bumped when the drop-group ACL set below changes shape, so existing
    /// deployments replace it on upgrade (the generation mechanism reused).
    public static let dropGroupRevision: Int64 = 1

    /// Bumped whenever this builder's ACL *construction* changes — a fixed
    /// match syntax, a newly expressible rule shape — so upgraded agents
    /// rewrite every group's ACLs even though the control-plane generations
    /// didn't move. Without it, a builder fix would sit unapplied until some
    /// unrelated rule edit happened to bump each group.
    public static let aclSchemaRevision: Int64 = 1

    static let managedKey = "strato-managed"
    static let managedValue = "true"

    /// The ACL for one security-group rule, or nil for a rule the builder
    /// cannot express (unknown direction/ethertype/protocol from a newer
    /// control plane) — dropped rules must fail loud at the call site, never
    /// silently allow.
    public static func acl(for rule: DesiredSecurityGroupRule, portGroup: String) -> ACLSpec? {
        let ipMatch: String
        switch rule.ethertype {
        case "ipv4": ipMatch = "ip4"
        case "ipv6": ipMatch = "ip6"
        default: return nil
        }

        let portBinding: String
        let peerField: String
        switch rule.direction {
        case "ingress":
            portBinding = "outport == @\(portGroup)"
            peerField = "\(ipMatch).src"
        case "egress":
            portBinding = "inport == @\(portGroup)"
            peerField = "\(ipMatch).dst"
        default:
            return nil
        }

        var clauses = [portBinding, ipMatch]

        if let peer = rule.remoteCIDR {
            clauses.append("\(peerField) == \(peer)")
        } else if let peerGroup = rule.remoteGroupId {
            let reference = OVNNaming.addressSetReference(
                portGroup: OVNNaming.portGroupName(securityGroupId: peerGroup),
                ethertype: rule.ethertype)
            clauses.append("\(peerField) == \(reference)")
        }

        switch rule.protocolName {
        case nil:
            break
        case "tcp", "udp":
            let proto = rule.protocolName!
            clauses.append(proto)
            if let min = rule.portRangeMin, let max = rule.portRangeMax {
                if min == max {
                    clauses.append("\(proto).dst == \(min)")
                } else {
                    clauses.append("\(proto).dst >= \(min) && \(proto).dst <= \(max)")
                }
            }
        case "icmp":
            let proto = rule.ethertype == "ipv6" ? "icmp6" : "icmp4"
            clauses.append(proto)
            if let type = rule.portRangeMin {
                clauses.append("\(proto).type == \(type)")
                if let code = rule.portRangeMax {
                    clauses.append("\(proto).code == \(code)")
                }
            }
        default:
            return nil
        }

        return ACLSpec(
            direction: rule.direction == "ingress" ? "to-lport" : "from-lport",
            priority: allowPriority,
            match: clauses.joined(separator: " && "),
            action: "allow-related",
            externalIDs: [
                managedKey: managedValue,
                "strato-rule-id": rule.id.uuidString.lowercased(),
            ])
    }

    /// The drop group's ACL set: default-deny both directions for all IP
    /// traffic (ARP is not `ip`, so address resolution keeps working), with
    /// carve-outs for DHCP and IPv6 neighbor discovery / router
    /// advertisements — without which a default-denied guest could never even
    /// acquire its address or default route.
    public static func dropGroupACLs() -> [ACLSpec] {
        let pg = OVNNaming.dropPortGroupName
        let ids = [managedKey: managedValue]
        return [
            // DHCPv4/v6: the guest's requests out, the server's replies in.
            ACLSpec(
                direction: "from-lport", priority: allowPriority,
                match: "inport == @\(pg) && udp && udp.dst == 67", action: "allow-related",
                externalIDs: ids),
            ACLSpec(
                direction: "from-lport", priority: allowPriority,
                match: "inport == @\(pg) && udp && udp.dst == 547", action: "allow-related",
                externalIDs: ids),
            ACLSpec(
                direction: "to-lport", priority: allowPriority,
                match: "outport == @\(pg) && udp && udp.src == 67", action: "allow",
                externalIDs: ids),
            ACLSpec(
                direction: "to-lport", priority: allowPriority,
                match: "outport == @\(pg) && udp && udp.src == 547", action: "allow",
                externalIDs: ids),
            // IPv6 ND (NS/NA), router solicitations and advertisements: ICMPv6
            // is `ip`, so the default drop would otherwise break IPv6 entirely.
            ACLSpec(
                direction: "from-lport", priority: allowPriority,
                match: "inport == @\(pg) && (nd || nd_rs || nd_ra)", action: "allow",
                externalIDs: ids),
            ACLSpec(
                direction: "to-lport", priority: allowPriority,
                match: "outport == @\(pg) && (nd || nd_rs || nd_ra)", action: "allow",
                externalIDs: ids),
            // The default deny that makes membership meaningful.
            ACLSpec(
                direction: "from-lport", priority: dropPriority,
                match: "inport == @\(pg) && ip", action: "drop",
                externalIDs: ids),
            ACLSpec(
                direction: "to-lport", priority: dropPriority,
                match: "outport == @\(pg) && ip", action: "drop",
                externalIDs: ids),
        ]
    }
}

// MARK: - Plans, observation, membership

/// One OVN Port_Group the plan wants: its name, the generation its ACL set
/// was built from, and the ACL rows. Membership (`ports`) is deliberately
/// absent — it belongs to the per-agent membership pass, never the authority.
public struct PortGroupPlan: Equatable, Sendable {
    public let name: String
    public let generation: Int64
    public let acls: [ACLSpec]

    public init(name: String, generation: Int64, acls: [ACLSpec]) {
        self.name = name
        self.generation = generation
        self.acls = acls
    }
}

/// A managed Port_Group as observed in the NB: its name, the generation its
/// ACLs were last written from, and the builder revision that wrote them
/// (nil stamps — rows predating them, or a crash mid-rewrite — force a
/// rewrite).
public struct ObservedPortGroup: Equatable, Sendable {
    public let name: String
    public let generation: Int64?
    public let builderRevision: Int64?

    public init(name: String, generation: Int64?, builderRevision: Int64? = nil) {
        self.name = name
        self.generation = generation
        self.builderRevision = builderRevision
    }
}

/// The desired group membership of one VM port on this host. `groupIds` nil
/// means the NIC is unmanaged (spec from a pre-security-group control plane,
/// or a sandbox NIC): its membership is left exactly as-is — absence of the
/// field is "no opinion", never "remove from all groups".
public struct DesiredPortMembership: Equatable, Sendable {
    public let portName: String
    public let securityGroupIds: [UUID]?

    public init(portName: String, securityGroupIds: [UUID]?) {
        self.portName = portName
        self.securityGroupIds = securityGroupIds
    }

    /// The port-group names this port should be a member of: every attached
    /// group plus the drop group (default-deny). Nil for an unmanaged port.
    public var desiredGroups: Set<String>? {
        guard let securityGroupIds else { return nil }
        var groups = Set(securityGroupIds.map { OVNNaming.portGroupName(securityGroupId: $0) })
        groups.insert(OVNNaming.dropPortGroupName)
        return groups
    }
}

// MARK: - Reconciler

/// Pure planning for security-group reconciliation. No side effects.
public enum SecurityGroupReconciler {

    /// The port groups the authority should realize: one per security group
    /// (ACLs from its rules) plus the drop group. Deterministically sorted.
    /// Rules the builder cannot express (from a newer control plane) are
    /// skipped and reported in `unexpressed` so the caller can log loudly —
    /// the group still converges to the rules this build understands.
    public static func plan(
        securityGroups: [DesiredSecurityGroup]
    ) -> (plans: [PortGroupPlan], unexpressed: [UUID]) {
        var plans: [PortGroupPlan] = [
            PortGroupPlan(
                name: OVNNaming.dropPortGroupName,
                generation: SecurityGroupACLBuilder.dropGroupRevision,
                acls: SecurityGroupACLBuilder.dropGroupACLs())
        ]
        var unexpressed: [UUID] = []

        for group in securityGroups.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let name = OVNNaming.portGroupName(securityGroupId: group.id)
            var acls: [ACLSpec] = []
            for rule in group.rules {
                if let acl = SecurityGroupACLBuilder.acl(for: rule, portGroup: name) {
                    var ids = acl.externalIDs
                    ids["strato-sg-id"] = group.id.uuidString.lowercased()
                    acls.append(
                        ACLSpec(
                            direction: acl.direction, priority: acl.priority, match: acl.match,
                            action: acl.action, externalIDs: ids))
                } else {
                    unexpressed.append(rule.id)
                }
            }
            plans.append(PortGroupPlan(name: name, generation: group.generation, acls: acls))
        }
        return (plans, unexpressed)
    }

    /// Managed port groups present in the NB that the plan no longer wants.
    /// The drop group is part of every plan, so it is never torn down while
    /// security groups are in use.
    public static func teardownNames(
        desired: [PortGroupPlan], observed: [ObservedPortGroup]
    ) -> [String] {
        let want = Set(desired.map(\.name))
        return observed.map(\.name).filter { !want.contains($0) }.sorted()
    }

    /// Whether a port group's ACLs need (re)writing: yes for a missing
    /// generation stamp (pre-stamp row, fresh creation, or a crash between
    /// ACL writes and stamping), an older generation, or ACLs written by a
    /// different builder revision (an agent upgrade that changed match
    /// construction must roll its fixes out without waiting for rule edits).
    /// A *newer* stored generation means this sync is stale — leave the ACLs
    /// alone rather than downgrade them, builder revision included: the
    /// current-generation sync that follows performs the schema rewrite.
    public static func needsACLRewrite(
        planned: Int64, observed: Int64?, observedBuilderRevision: Int64? = nil
    ) -> Bool {
        guard let observed else { return true }
        if planned < observed { return false }
        if observedBuilderRevision != SecurityGroupACLBuilder.aclSchemaRevision { return true }
        return planned > observed
    }
}

// MARK: - Actuator

/// The live OVN side effects security-group reconciliation drives,
/// implemented by `NetworkServiceLinux`. All methods idempotent —
/// level-triggered syncs re-drive them.
public protocol SecurityGroupActuator: Sendable {
    /// The managed port groups currently in the NB (drop group included).
    func observeSecurityGroups() async throws -> [ObservedPortGroup]
    /// Create the port group if missing and converge its ACL set to the plan
    /// when `needsACLRewrite` says so. Must never write the `ports` column.
    func ensurePortGroup(_ plan: PortGroupPlan) async throws
    /// Delete a managed port group (its ACLs die with it; member port
    /// references are weak).
    func removePortGroup(named name: String) async throws
    /// The managed port groups each of `portNames` is currently a member of.
    func observeMembership(ofPorts portNames: [String]) async throws -> [String: Set<String>]
    func addPort(named portName: String, toGroup group: String) async throws
    func removePort(named portName: String, fromGroup group: String) async throws
}

extension SecurityGroupReconciler {
    /// Authority-side convergence: ensure every planned port group + ACL set,
    /// then tear down managed groups the plan no longer wants. Best-effort
    /// per object (a failing group is retried by the next level-triggered
    /// sync); throws only when the NB snapshot itself can't be read.
    public static func reconcile(
        securityGroups: [DesiredSecurityGroup],
        actuator: any SecurityGroupActuator,
        logger: Logger
    ) async throws {
        let (plans, unexpressed) = plan(securityGroups: securityGroups)
        if !unexpressed.isEmpty {
            logger.error(
                "Security-group rules from a newer control plane could not be expressed as ACLs; they are NOT enforced",
                metadata: ["ruleIds": .array(unexpressed.map { .string($0.uuidString) })])
        }

        for plan in plans {
            do {
                try await actuator.ensurePortGroup(plan)
            } catch {
                logger.error(
                    "Failed to converge security-group port group",
                    metadata: [
                        "portGroup": .string(plan.name),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }

        let observed = try await actuator.observeSecurityGroups()
        for name in teardownNames(desired: plans, observed: observed) {
            do {
                try await actuator.removePortGroup(named: name)
            } catch {
                logger.error(
                    "Failed to tear down security-group port group",
                    metadata: ["portGroup": .string(name), "error": .string(error.localizedDescription)])
            }
        }
    }

    /// Every-agent membership convergence for this host's own VM ports:
    /// each managed port joins its groups + the drop group and leaves managed
    /// groups it no longer belongs to. Ports whose NIC is unmanaged
    /// (`securityGroupIds == nil`) are left exactly as-is. A port group that
    /// doesn't exist yet (the authority's sync hasn't realized it) is logged
    /// and left for the next sync — same wait-for-the-authority semantics as
    /// a missing switch.
    public static func reconcileMembership(
        memberships: [DesiredPortMembership],
        actuator: any SecurityGroupActuator,
        logger: Logger
    ) async {
        let managed = memberships.filter { $0.securityGroupIds != nil }
        guard !managed.isEmpty else { return }

        let observed: [String: Set<String>]
        do {
            observed = try await actuator.observeMembership(ofPorts: managed.map(\.portName))
        } catch {
            logger.error(
                "Could not read port-group membership; skipping membership convergence this pass",
                metadata: ["error": .string(error.localizedDescription)])
            return
        }

        for membership in managed {
            guard let desired = membership.desiredGroups else { continue }
            let current = observed[membership.portName] ?? []
            // The drop group joins FIRST: additions are one OVSDB round trip
            // each, and a port that lands in an allow group before the drop
            // group would spend the gap default-allow on live traffic. If the
            // drop-group add fails, the port's allow-group adds are skipped
            // entirely this pass (fail closed, retried next sync) — removals
            // below still run, since they only ever narrow access.
            let additions = desired.subtracting(current).sorted {
                ($0 == OVNNaming.dropPortGroupName ? 0 : 1, $0) < ($1 == OVNNaming.dropPortGroupName ? 0 : 1, $1)
            }
            var portPending = false
            for group in additions {
                if portPending { break }
                do {
                    try await actuator.addPort(named: membership.portName, toGroup: group)
                } catch {
                    if group == OVNNaming.dropPortGroupName { portPending = true }
                    logger.warning(
                        "Could not add port to security-group port group (retried next sync)",
                        metadata: [
                            "port": .string(membership.portName),
                            "portGroup": .string(group),
                            "error": .string(error.localizedDescription),
                        ])
                }
            }
            for group in current.subtracting(desired).sorted() {
                do {
                    try await actuator.removePort(named: membership.portName, fromGroup: group)
                } catch {
                    logger.warning(
                        "Could not remove port from security-group port group (retried next sync)",
                        metadata: [
                            "port": .string(membership.portName),
                            "portGroup": .string(group),
                            "error": .string(error.localizedDescription),
                        ])
                }
            }
        }
    }
}
