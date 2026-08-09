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

    /// The site-singleton drop port group: every managed workload port is a member,
    /// and its low-priority drop ACLs are what make security groups
    /// default-deny (allows win at higher priority). Mirrors Neutron's
    /// `neutron_pg_drop`.
    public static let dropPortGroupName = "pg_strato_drop"

    /// The site-singleton *metadata deny* port group (STR-185): the ports of
    /// VMs whose per-instance metadata switch is off, carrying one drop ACL per
    /// family above the drop group's metadata allow.
    ///
    /// A second site-wide group rather than a per-network or per-VM one, for
    /// the reason `metadataEgressACLs` gives for putting the allow on
    /// `pg_strato_drop`: an object whose lifetime is the site's costs nothing
    /// to keep, while one per network or per workload is a lifetime to create,
    /// converge and reap. Membership is per-VM and already has a mechanism —
    /// the same `reconcileMembership` pass that joins a port to its security
    /// groups — so the per-VM part needs no new machinery at all.
    ///
    /// Empty on almost every site, and that is fine: a port group with no
    /// members matches nothing, and its two ACLs cost one NB row each.
    public static let metadataDenyPortGroupName = "pg_strato_no_metadata"

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
    /// Whether OVN should log every packet this ACL matches (STR-34). Off for
    /// everything except rules whose control-plane row asked for it.
    public let log: Bool
    /// Log severity, meaningful only alongside `log`. OVN defaults an unset
    /// severity to "info"; we set it explicitly so the emitted line is
    /// deterministic rather than dependent on the OVN version's default.
    public let severity: String?
    /// The ACL's OVN `name`, which is what identifies the rule in the log
    /// line. Only set for logged ACLs — an unlogged one has nothing to name.
    public let name: String?
    public let externalIDs: [String: String]

    public init(
        direction: String,
        priority: Int,
        match: String,
        action: String,
        log: Bool = false,
        severity: String? = nil,
        name: String? = nil,
        externalIDs: [String: String]
    ) {
        self.direction = direction
        self.priority = priority
        self.match = match
        self.action = action
        self.log = log
        self.severity = severity
        self.name = name
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

    /// The instance metadata carve-out sits one step above rule allows
    /// (STR-54). Today that step buys nothing — a security-group rule can only
    /// *allow*, so nothing at `allowPriority` could contradict it — but the
    /// rule vocabulary is control-plane data, and the switch-attached stateless
    /// NACLs on the roadmap are the deny-capable shape. Two ACLs that both
    /// match at equal priority resolve arbitrarily in OVN, so equal priority
    /// would make "non-overridable" a property of today's rule model rather
    /// than of this ACL. One number makes it a property of the ACL.
    public static let metadataAllowPriority = 1003

    /// The per-instance metadata kill switch's deny, one step above the allow
    /// it cancels (STR-185) — the reserved space `metadataAllowPriority`'s note
    /// set aside, now occupied.
    ///
    /// The deny has to be strictly higher rather than equal for exactly the
    /// reason the allow sits above rule allows: two ACLs matching at equal
    /// priority resolve arbitrarily in OVN, so a same-priority deny would
    /// silence IMDS *usually*. It also means the kill switch is as
    /// non-overridable as the carve-out — nothing a tenant can write reaches
    /// 1004, so a security group with an allow-all egress rule does not undo it.
    public static let metadataDenyPriority = 1004

    /// Bumped when the drop-group ACL set below changes shape, so existing
    /// deployments replace it on upgrade (the generation mechanism reused).
    /// 2: MLD carve-outs (STR-34). 3: MLD split by direction so guests cannot
    /// originate Queries. 4: instance metadata egress (STR-54). 5: per-network
    /// resolver egress (STR-40). 6: the resolver carve-out widened from one
    /// address to the link-local space, once each network got its own.
    ///
    /// "On upgrade" means the *authority's* upgrade: this group's ACLs are
    /// authored only by the site's network-controller agent, so a mixed-version
    /// site behind an older authority keeps the older ACL set no matter how
    /// current its other agents are. That skew is worth naming for revision 5
    /// in particular: guests on freshly upgraded agents in a site whose
    /// authority is still on 4 keep getting DNS to the resolver *dropped*, so
    /// on a network with a restrictive security group the resolver looks broken
    /// until the controller upgrades. The reverse direction is safe —
    /// `needsACLRewrite` returns false when the planned generation is older
    /// than the observed one, so a lagging authority leaves a revision-5 group
    /// alone instead of stripping the carve-out back off.
    public static let dropGroupRevision: Int64 = 6

    /// Bumped whenever this builder's ACL *construction* changes — a fixed
    /// match syntax, a newly expressible rule shape — so upgraded agents
    /// rewrite every group's ACLs even though the control-plane generations
    /// didn't move. Without it, a builder fix would sit unapplied until some
    /// unrelated rule edit happened to bump each group.
    /// 2: per-rule `log`/`severity`/`name` columns (STR-34).
    public static let aclSchemaRevision: Int64 = 2

    /// Severity for logged ACLs. Not an API surface: the control plane's rule
    /// carries a boolean, and every logged rule lands at the same level.
    static let logSeverity = "info"

    static let managedKey = "strato-managed"
    static let managedValue = "true"

    /// The OVN `name` of the ACL built from a rule, which is the identifier
    /// that appears in its log line. Hyphen-free hex keeps it short (36 of
    /// OVN's 63 allowed characters) and matches the port-group convention.
    public static func aclName(ruleId: UUID) -> String {
        "sgr_" + ruleId.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

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

        // Logging is opt-in per rule (STR-34). Nil from a control plane that
        // predates the field reads as off, same as an explicit false.
        let logged = rule.log ?? false
        return ACLSpec(
            direction: rule.direction == "ingress" ? "to-lport" : "from-lport",
            priority: allowPriority,
            match: clauses.joined(separator: " && "),
            action: "allow-related",
            log: logged,
            severity: logged ? logSeverity : nil,
            name: logged ? aclName(ruleId: rule.id) : nil,
            externalIDs: [
                managedKey: managedValue,
                "strato-rule-id": rule.id.uuidString.lowercased(),
            ])
    }

    /// Multicast Listener Discovery, spelled as explicit ICMPv6 types rather
    /// than OVN's `mldv1`/`mldv2` predicates: the type form parses on every
    /// OVN version we support, and the set is small enough to be obvious.
    ///
    /// **Deliberately asymmetric.** Type 130 is the Multicast Listener Query,
    /// which only a router or the elected querier originates; 131/132/143 are
    /// the listener-originated v1 Report, Done, and v2 Report. Letting a guest
    /// *send* 130 would let any member of the site-wide drop group win querier
    /// election (lowest source link-local address wins) and then simply stop
    /// querying, timing out every other guest's multicast state — the IPv6
    /// twin of IGMP querier spoofing, and `pg_strato_drop` spans every project
    /// in the site, so it would cross tenancy boundaries. Guests therefore
    /// send reports and receive queries, which is all listener discovery
    /// actually requires of them.
    static let mldListenerTypes = "icmp6.type == 131 || icmp6.type == 132 || icmp6.type == 143"
    static let mldQueryType = "icmp6.type == 130"

    /// What a member port may originate: reports and dones, never queries.
    static let mldEgressMatch = "icmp6 && (\(mldListenerTypes))"
    /// What a member port may receive: the querier's queries, plus other
    /// members' reports (harmless, and snooping switches forward them).
    static let mldIngressMatch = "icmp6 && (\(mldQueryType) || \(mldListenerTypes))"

    /// Egress to the instance metadata service, one ACL per family, allowed on
    /// every managed port no matter which security groups it belongs to
    /// (STR-54).
    ///
    /// **This is deliberate, and it is not overridable.** It exists so that
    /// tightening a project's `default` group — or attaching a group that
    /// simply has no permissive egress rule — cannot take IMDS away. That
    /// failure would be silent and would not look like a policy outcome: the
    /// guest's cloud-init datasource hangs retrying `169.254.169.254`, and the
    /// operator sees a broken instance rather than a rule they wrote. AWS
    /// draws the same line — IMDS reachability is not subject to
    /// security-group rules there either. Anyone narrowing the default group
    /// later should find this rule and understand that it, not the group's
    /// permissiveness, is what keeps metadata reachable.
    ///
    /// **Not overridable by a rule; overridable by the operator.** STR-185
    /// filled in the half of the AWS parallel this once lacked: a VM whose
    /// `metadataEnabled` is off has its ports in `metadataDenyPortGroupName`,
    /// whose drop at `metadataDenyPriority` outranks these two. So "the tenant's
    /// rules cannot reach IMDS" and "the operator can take IMDS away from one
    /// workload" are both true, which is the pair AWS ships and the pair an
    /// operator hardening a single VM against SSRF needs.
    ///
    /// Egress only, and stateful (`allow-related`), so the service's replies
    /// come back on the connection's conntrack state rather than through a
    /// standing `to-lport` allow — which, unlike the DHCP carve-outs below,
    /// would admit *unsolicited* inbound traffic claiming to be from the
    /// metadata address to every managed port in the site.
    ///
    /// Scoped to the metadata port (`InstanceMetadataEndpoint.port`) rather
    /// than the whole address: the localport terminates nothing else, so a
    /// wider hole would only widen what a guest may probe on its own chassis.
    ///
    /// Applied on the site-singleton drop group, so it lands on every managed
    /// port including those on networks with `metadataEnabled` off. Harmless:
    /// such a switch publishes no localport, so a guest treating the address as
    /// on-link gets no answer to its ARP/ND, and one without that route hands
    /// the packet to its default gateway for the logical router to drop. Same
    /// outcome by either path — and the alternative (per-network port groups)
    /// would be a whole new object lifetime for the ability to deny traffic
    /// that already goes nowhere.
    public static func metadataEgressACLs() -> [ACLSpec] {
        let pg = OVNNaming.dropPortGroupName
        let ids = [managedKey: managedValue]
        let port = InstanceMetadataEndpoint.port
        // Clause order mirrors `acl(for:portGroup:)` — port binding, family,
        // peer, protocol, port — so a reader can diff a carve-out against a
        // rule-derived ACL without re-parsing either.
        return [
            ACLSpec(
                direction: "from-lport", priority: metadataAllowPriority,
                match:
                    "inport == @\(pg) && ip4 && ip4.dst == \(InstanceMetadataEndpoint.address) "
                    + "&& tcp && tcp.dst == \(port)",
                action: "allow-related", externalIDs: ids),
            ACLSpec(
                direction: "from-lport", priority: metadataAllowPriority,
                match:
                    "inport == @\(pg) && ip6 && ip6.dst == \(InstanceMetadataEndpoint.addressV6) "
                    + "&& tcp && tcp.dst == \(port)",
                action: "allow-related", externalIDs: ids),
        ]
    }

    /// Bumped when the metadata deny group's ACL set below changes shape, the
    /// `dropGroupRevision` mechanism applied to the second site-singleton group.
    /// 1: the kill switch itself (STR-185).
    public static let metadataDenyGroupRevision: Int64 = 1

    /// The per-instance kill switch, realized (STR-185): egress to the metadata
    /// service dropped for every port in `metadataDenyPortGroupName`.
    ///
    /// `metadataEgressACLs`' negation, and it differs from it in exactly two
    /// ways worth stating.
    ///
    /// **Not scoped to the port.** The allow is deliberately narrowed to TCP/80
    /// because a wider allow would only widen what a guest may probe; the deny
    /// wants the opposite and matches the whole address, so a switched-off guest
    /// cannot ping it, scan it, or find out from a refused connection that the
    /// chassis has anything there at all. Nothing else Strato runs lives at
    /// these addresses — `NetworkResolverEndpoint.reservedIndexes` keeps a
    /// resolver from ever being allocated `169.254.169.254`, and the resolvers'
    /// `fd00:ec2:1::/48` is disjoint from this address by construction — so the
    /// wider match cannot shadow the resolver carve-out that shares the
    /// enclosing `169.254.0.0/16` and `fd00:ec2::/32`.
    ///
    /// **`drop`, not `reject`.** OVN can send an RST; a blackhole is what AWS's
    /// disabled endpoint looks like, and it is what a guest's IMDS client
    /// already knows how to time out of. A refused connection would also tell a
    /// probe that something is deliberately in the way.
    ///
    /// Egress only, mirroring the allow, and no `to-lport` twin is needed:
    /// nothing returns from a connection that was never established.
    public static func metadataDenyACLs() -> [ACLSpec] {
        let pg = OVNNaming.metadataDenyPortGroupName
        let ids = [managedKey: managedValue]
        return [
            ACLSpec(
                direction: "from-lport", priority: metadataDenyPriority,
                match: "inport == @\(pg) && ip4 && ip4.dst == \(InstanceMetadataEndpoint.address)",
                action: "drop", externalIDs: ids),
            ACLSpec(
                direction: "from-lport", priority: metadataDenyPriority,
                match: "inport == @\(pg) && ip6 && ip6.dst == \(InstanceMetadataEndpoint.addressV6)",
                action: "drop", externalIDs: ids),
        ]
    }

    /// The implicit egress allow to the network's DNS resolver (STR-40).
    ///
    /// `metadataEgressACLs`' twin, and everything that doc comment argues holds
    /// here — non-overridable at `metadataAllowPriority`, egress only and
    /// stateful, scoped to the service's port, applied on the site-singleton
    /// drop group so it also lands harmlessly on ports whose network publishes
    /// no such address.
    ///
    /// Two differences are worth naming.
    ///
    /// **Four ACLs, not two.** An OVN match is per family *and* per protocol,
    /// and DNS is both: a resolver that answers only UDP silently breaks every
    /// response large enough to set TC, which a guest then retries over TCP and
    /// never gets. The four are v4/v6 × udp/tcp.
    ///
    /// **The consequence of getting this wrong is larger.** Without the
    /// metadata carve-out a default-denied guest loses IMDS; without this one
    /// it loses name resolution outright — including for the SNAT'd egress its
    /// security groups do allow — and the symptom reads as a broken network
    /// rather than as the policy outcome it is.
    public static func resolverEgressACLs() -> [ACLSpec] {
        let pg = OVNNaming.dropPortGroupName
        let ids = [managedKey: managedValue]
        let port = NetworkResolverEndpoint.port
        var acls: [ACLSpec] = []
        // Matched on the whole link-local *space* rather than one address,
        // because each network's resolver now has its own. A per-network match
        // would mean a per-network port group — "a whole new object lifetime",
        // as the metadata carve-out's doc comment puts it — for a rule that has
        // to land on every managed port anyway. Both ranges are unroutable and
        // hold nothing but Strato's own link-local services.
        for (family, space) in [
            ("ip4", NetworkResolverEndpoint.v4Space), ("ip6", NetworkResolverEndpoint.v6Space),
        ] {
            for proto in ["udp", "tcp"] {
                acls.append(
                    ACLSpec(
                        direction: "from-lport", priority: metadataAllowPriority,
                        match:
                            "inport == @\(pg) && \(family) && \(family).dst == \(space) "
                            + "&& \(proto) && \(proto).dst == \(port)",
                        action: "allow-related", externalIDs: ids))
            }
        }
        return acls
    }

    /// The drop group's ACL set: default-deny both directions for all IP
    /// traffic (ARP is not `ip`, so address resolution keeps working), with
    /// carve-outs for DHCP, IPv6 neighbor discovery / router advertisements,
    /// and MLD — without which a default-denied guest could never even
    /// acquire its address or default route, and IPv6 multicast (which
    /// depends on listener reports reaching the querier) would silently stop
    /// working the moment a NIC joined a security group. Instance metadata
    /// egress rides here too, for the same reason and with the same
    /// unconditional reach — see `metadataEgressACLs`. So does DNS to the
    /// network's own resolver, which needs it more than any of them: a guest
    /// that cannot resolve has no working network at all, however permissive
    /// the rest of its policy — see `resolverEgressACLs`.
    public static func dropGroupACLs() -> [ACLSpec] {
        let pg = OVNNaming.dropPortGroupName
        let ids = [managedKey: managedValue]
        return metadataEgressACLs() + resolverEgressACLs() + [
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
            // MLD both ways, but not the same types each way: a guest sends
            // reports and Done messages and receives queries. Dropping either
            // half makes the querier time the guest's groups out; allowing
            // guests to *send* queries would let one hijack the election (see
            // `mldEgressMatch`).
            ACLSpec(
                direction: "from-lport", priority: allowPriority,
                match: "inport == @\(pg) && \(mldEgressMatch)", action: "allow",
                externalIDs: ids),
            ACLSpec(
                direction: "to-lport", priority: allowPriority,
                match: "outport == @\(pg) && \(mldIngressMatch)", action: "allow",
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

/// The desired group membership of one workload port on this host — a VM's or
/// a sandbox's, indistinguishably (STR-102); only the port name differs.
/// `groupIds` nil means the NIC is unmanaged (a spec from a pre-security-group
/// control plane, or one omitting the field for this agent's version): its
/// membership is left exactly as-is — absence of the field is "no opinion",
/// never "remove from all groups".
public struct DesiredPortMembership: Equatable, Sendable {
    public let portName: String
    public let securityGroupIds: [UUID]?
    /// Whether this port's workload has its per-instance metadata switch off
    /// (STR-185), which puts it in `OVNNaming.metadataDenyPortGroupName`.
    ///
    /// Read off the workload rather than the NIC because the switch is a
    /// property of the instance: every port a switched-off VM owns is denied,
    /// not just the one whose network happens to publish the endpoint.
    ///
    /// **Only reaches a managed port.** An unmanaged NIC (`securityGroupIds`
    /// nil) is in no port group at all, so there is nothing for this to join
    /// and `desiredGroups` still answers nil — converging membership for a port
    /// this pass is meant to leave alone would strip it out of whatever an
    /// operator put it in. The switch is not weaker for it: the listener refuses
    /// the caller regardless of any ACL, and this ACL is the layer that keeps
    /// the packet off the chassis, not the layer that decides.
    public let metadataDenied: Bool

    public init(portName: String, securityGroupIds: [UUID]?, metadataDenied: Bool = false) {
        self.portName = portName
        self.securityGroupIds = securityGroupIds
        self.metadataDenied = metadataDenied
    }

    /// The port-group names this port should be a member of: every attached
    /// group, the drop group (default-deny), and the metadata deny group when
    /// the workload's kill switch is thrown. Nil for an unmanaged port.
    public var desiredGroups: Set<String>? {
        guard let securityGroupIds else { return nil }
        var groups = Set(securityGroupIds.map { OVNNaming.portGroupName(securityGroupId: $0) })
        groups.insert(OVNNaming.dropPortGroupName)
        if metadataDenied { groups.insert(OVNNaming.metadataDenyPortGroupName) }
        return groups
    }
}

/// Builds the per-VM port policy targets carried by desired state. New VM
/// manifests key host resources by the control plane's stable NIC slot;
/// compact array position remains only as the legacy fallback.
public enum VMPortMembershipPlanner {
    public static func memberships(for vms: [DesiredVMState]) -> [DesiredPortMembership] {
        vms.flatMap { vm in
            let metadataDenied = vm.metadata.map { !$0.isServiceEnabled } ?? false
            return vm.spec.networks.enumerated().map { fallbackIndex, spec in
                DesiredPortMembership(
                    portName: OVNNaming.vmPortName(
                        vmId: vm.vmId.uuidString,
                        nicIndex: spec.orderIndex ?? fallbackIndex),
                    securityGroupIds: spec.securityGroupIds,
                    metadataDenied: metadataDenied)
            }
        }
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
                acls: SecurityGroupACLBuilder.dropGroupACLs()),
            // Unconditional, like the drop group and for the same two reasons:
            // `teardownNames` reaps every managed group a plan omits, so a
            // conditional one would be created and destroyed as the last
            // switched-off VM on the site came and went; and a port cannot join
            // a group that does not exist yet, so realizing it only once
            // something needs it guarantees that the first thing to need it
            // waits a sync (STR-185).
            PortGroupPlan(
                name: OVNNaming.metadataDenyPortGroupName,
                generation: SecurityGroupACLBuilder.metadataDenyGroupRevision,
                acls: SecurityGroupACLBuilder.metadataDenyACLs()),
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
                            action: acl.action, log: acl.log, severity: acl.severity, name: acl.name,
                            externalIDs: ids))
                } else {
                    unexpressed.append(rule.id)
                }
            }
            plans.append(PortGroupPlan(name: name, generation: group.generation, acls: acls))
        }
        return (plans, unexpressed)
    }

    /// Managed port groups present in the NB that the plan no longer wants.
    /// The drop group and the metadata deny group are part of every plan, so
    /// neither is ever torn down while security groups are in use.
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

    /// How early a port group is joined: the two site-singleton groups whose
    /// ACLs only ever *narrow* what a port may do go before the rest, so a
    /// partially converged port is never more permissive than a converged one.
    /// Ties break on the name, keeping the order deterministic for tests.
    static func additionRank(of group: String) -> Int {
        switch group {
        case OVNNaming.dropPortGroupName, OVNNaming.metadataDenyPortGroupName: return 0
        default: return 1
        }
    }

    /// Every-agent membership convergence for this host's own VM ports:
    /// each managed port joins its groups + the drop group (+ the metadata deny
    /// group when its workload's kill switch is thrown) and leaves managed
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
            // The deny groups join FIRST: additions are one OVSDB round trip
            // each, and a port that lands in an allow group before the drop
            // group would spend the gap default-allow on live traffic. The
            // metadata deny group rides in the same rank for the same reason —
            // a port switched off IMDS should not be reachable to it for the
            // width of a round trip either. If the drop-group add fails, the
            // port's allow-group adds are skipped entirely this pass (fail
            // closed, retried next sync) — removals below still run, since they
            // only ever narrow access.
            let additions = desired.subtracting(current).sorted {
                (Self.additionRank(of: $0), $0) < (Self.additionRank(of: $1), $1)
            }
            var portPending = false
            for group in additions {
                if portPending { break }
                do {
                    try await actuator.addPort(named: membership.portName, toGroup: group)
                } catch {
                    // Only the drop group's failure abandons the port. A failed
                    // metadata-deny add leaves IMDS reachable at the network
                    // layer for a sync, which the listener's own refusal already
                    // covers; abandoning the port would instead leave a working
                    // workload with no allow groups at all, which is a real
                    // outage traded for a redundant layer.
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
