import Fluent
import Foundation
import Metrics
import SQLKit
import StratoShared
import Vapor

extension DesiredStateAssembler {
    /// The DNS zones this sync's topology authority should realize (STR-39):
    /// every zone attached to a network whose topology the receiving agent
    /// authors, with the zone's full effective contents.
    ///
    /// **The records are assembled fleet-wide, not from the receiving agent's
    /// own VMs.** That is the load-bearing difference between this and every
    /// other list in the sync. A zone's names span every VM on every network
    /// that registers into it — a VM created on agent A changes a zone realized
    /// by agent B — and `DNSZoneAssembler` reads those rows directly rather
    /// than from anything scoped to `agentId`. What the scope decides here is
    /// only *which zones* this agent is responsible for, never whose records
    /// they contain.
    ///
    /// A consequence worth naming: a zone attached to networks in two sites is
    /// realized identically in both, so site A answers for site B's VMs. That
    /// is DNS behaving as DNS — a name resolving is not a claim that the
    /// address is reachable — and the alternative (per-site subsets of one
    /// zone) would make a zone's contents depend on where you asked, which is
    /// what split-horizon views exist to express deliberately.
    func desiredDNSZones(networkIDs: Set<UUID>, on db: any Database) async throws
        -> [DesiredDNSZone]
    {
        guard !networkIDs.isEmpty else { return [] }
        let attachments = try await DNSZoneNetwork.query(on: db)
            .filter(\.$logicalNetwork.$id ~~ Array(networkIDs))
            .all()
        guard !attachments.isEmpty else { return [] }

        var networksByZone: [UUID: [UUID]] = [:]
        for attachment in attachments {
            networksByZone[attachment.$zone.id, default: []].append(attachment.$logicalNetwork.id)
        }
        var names: [UUID: String] = [:]
        for zone in try await DNSZone.query(on: db).filter(\.$id ~~ Array(networksByZone.keys)).all() {
            guard let zoneID = zone.id else { continue }
            names[zoneID] = zone.name
        }

        // Batched, not one assembly per zone: this runs on *every* poll of the
        // authority agent, and each zone's derivation reads every NIC and VM on
        // its networks. `assemble(zones:)` is a fixed number of queries however
        // many zones a site's networks attach.
        return try await DNSZoneAssembler.assemble(zones: names, on: db)
            .map { DNSZoneAssembler.desiredZone($0, networkIDs: networksByZone[$0.zoneId] ?? []) }
            .sorted { $0.zoneId.uuidString < $1.zoneId.uuidString }
    }

    /// Whether every agent that could host a guest on this agent's networks can
    /// answer on the resolver address (STR-40).
    ///
    /// Deliberately a property of the **site**, not of the receiving agent. A
    /// network's resolver is advertised through one DHCP row — authored by the
    /// site's topology authority — but answered by a CoreDNS on each chassis.
    /// Ask the agent alone and a site with one un-upgraded host hands every
    /// guest on that network an address that resolves until the guest's VM is
    /// migrated, which presents as an intermittent network fault rather than as
    /// the missing dependency it is.
    ///
    /// Offline agents count. A host that is down is one that will come back,
    /// and treating "not currently connected" as "not in the site" would flip
    /// the resolver on during a rolling restart and off again afterwards.
    ///
    /// An agent this assembly could not load at all is not asked — the caller
    /// sends nil rather than an opinion, because `false` here is a teardown
    /// instruction rather than silence.
    func resolverCapableSiteWide(site: Site, on db: any Database) async throws -> Bool {
        let siteID = try site.requireID()
        // One query returning the offending names rather than a count plus a
        // second lookup on failure: the common answer materializes zero rows, so
        // this costs the hot path nothing, and the names are what makes the
        // withholding actionable. The predicate itself lives on
        // `ResolverCapability`, shared with the API surface that has to report
        // the same verdict (STR-201).
        let names = try await ResolverCapability.incapableAgentNames(inSite: siteID, on: db)
        guard names.isEmpty else {
            app.logger.notice(
                "Withholding the per-network DNS resolver: not every agent in the site can run it",
                metadata: [
                    "siteId": .string(siteID.uuidString),
                    "incapableAgents": .string(names.joined(separator: ",")),
                    "remedy": .string(
                        "install CoreDNS on these hosts and restart their agents, "
                            + "or delete the rows of any that are decommissioned"),
                ])
            return false
        }
        // No empty-site guard: this is only ever called for an agent, and that
        // agent is in the site, so the set is never empty.
        return true
    }

    /// Load an id-indexed logical-network slice without ever issuing an
    /// unbounded table scan. Empty scopes intentionally produce no query.
    func logicalNetworks(
        ids: Set<UUID>, on db: any Database
    ) async throws -> [UUID: LogicalNetwork] {
        guard !ids.isEmpty else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: try await LogicalNetwork.query(on: db)
                .filter(\.$id ~~ Array(ids))
                .all()
                .compactMap { network in network.id.map { ($0, network) } })
    }

    /// The optional ACL attached to each authoritative logical network. One
    /// bounded eager load avoids a rule query per switch, and both the outer
    /// index and each rule list are made deterministic before they reach the
    /// desired-state digest.
    func desiredNetworkACLs(
        networkIDs: Set<UUID>, on db: any Database
    ) async throws -> [UUID: DesiredNetworkACL] {
        guard !networkIDs.isEmpty else { return [:] }
        let rows = try await NetworkACL.query(on: db)
            .filter(\.$logicalNetwork.$id ~~ Array(networkIDs))
            .with(\.$rules)
            .all()

        var byNetwork: [UUID: DesiredNetworkACL] = [:]
        for acl in rows {
            guard let aclID = acl.id else { continue }
            let rules = acl.rules
                .compactMap { rule -> DesiredNetworkACLRule? in
                    guard let ruleID = rule.id else { return nil }
                    return DesiredNetworkACLRule(
                        id: ruleID,
                        ruleNumber: rule.ruleNumber,
                        direction: rule.direction.rawValue,
                        ethertype: rule.ethertype.rawValue,
                        action: rule.action.rawValue,
                        protocolName: rule.protocolName,
                        portRangeMin: rule.portRangeMin,
                        portRangeMax: rule.portRangeMax,
                        remoteCIDR: rule.remoteCIDR)
                }
                .sorted { lhs, rhs in
                    let lhsDirection = lhs.direction == "ingress" ? 0 : 1
                    let rhsDirection = rhs.direction == "ingress" ? 0 : 1
                    if lhsDirection != rhsDirection { return lhsDirection < rhsDirection }
                    if lhs.ruleNumber != rhs.ruleNumber { return lhs.ruleNumber < rhs.ruleNumber }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            byNetwork[acl.$logicalNetwork.id] = DesiredNetworkACL(
                id: aclID, generation: acl.generation, rules: rules)
        }
        return byNetwork
    }

    /// Which networks an agent's sync should carry, and whether the agent is
    /// the topology authority for the NB it writes to (issue #343).
    ///
    /// - The agent designated as the site's network controller: the whole
    ///   site shares one NB and this agent is its single topology writer, so
    ///   it gets every network referenced by any VM in the site plus every
    ///   network pinned to the site (pinned-but-unused networks are realized
    ///   ahead of their first VM).
    /// - Any other agent: non-authoritative and empty. It still binds
    ///   its own VMs' ports to the shared NB, but topology belongs to the
    ///   controller — two level-triggered writers would fight over teardown.
    func networkAssemblyScope(
        agentId: String,
        agent: Agent,
        site: Site,
        ownVMs: [VM],
        ownSandboxes: [Sandbox],
        on db: any Database
    ) async throws -> NetworkAssemblyScope {
        // A network referenced by either a VM or a sandbox on this host must be
        // realized here (issue #416).
        var ownReferences = Set(ownVMs.flatMap { $0.networkInterfaces.map(\.logicalNetworkID) })
        ownReferences.formUnion(ownSandboxes.flatMap { $0.networkInterfaces.map(\.logicalNetworkID) })

        guard let agentUUID = agent.id, site.id == agent.$site.id else {
            throw Abort(.internalServerError, reason: "Cannot assemble topology without an agent site")
        }
        let siteID = agent.$site.id

        guard let controllerID = site.$networkControllerAgent.id else {
            // No designated controller: nobody may author topology, so the
            // site's networks are realized nowhere until one is set. Loud —
            // this is a misconfiguration, not a transient.
            app.logger.warning(
                "Site has no network controller; its networks will not be reconciled",
                metadata: ["site": .string(site.name), "strato.agent.name": .string(agent.name)])
            return NetworkAssemblyScope(
                networkIDs: [],
                authoritative: false,
                floatingIPAgentIDs: [],
                coveredVMs: [],
                coveredSandboxes: [])
        }
        guard controllerID == agentUUID else {
            return NetworkAssemblyScope(
                networkIDs: [],
                authoritative: false,
                floatingIPAgentIDs: [],
                coveredVMs: [],
                coveredSandboxes: [])
        }

        let siteAgentIDs = try await Agent.query(on: db)
            .filter(\.$site.$id == siteID)
            .all()
            .compactMap { $0.id?.uuidString }
        let siteVMs = try await VM.query(on: db)
            .filter(\.$hypervisorId ~~ siteAgentIDs)
            .with(\.$networkInterfaces)
            .all()
        var ids = Set(siteVMs.flatMap { $0.networkInterfaces.map(\.logicalNetworkID) })
        // Sandboxes placed anywhere in the site reference networks the
        // controller must realize too (issue #416) — and, since STR-102, the
        // security groups whose port groups it must author. Both come off this
        // one query: it already loads the NICs, so `coveredSandboxes` below is
        // a reuse of these rows, not a second read of them.
        let siteSandboxes = try await Sandbox.query(on: db)
            .filter(\.$hypervisorId ~~ siteAgentIDs)
            .with(\.$networkInterfaces)
            .all()
        ids.formUnion(siteSandboxes.flatMap { $0.networkInterfaces.map(\.logicalNetworkID) })
        let pinned = try await LogicalNetwork.query(on: db)
            .filter(\.$site.$id == siteID)
            .all()
        ids.formUnion(pinned.compactMap(\.id))
        return NetworkAssemblyScope(
            networkIDs: ids,
            authoritative: true,
            floatingIPAgentIDs: Set(siteAgentIDs),
            coveredVMs: siteVMs,
            coveredSandboxes: siteSandboxes)
    }

    /// VM NIC id → attached security-group ids (sorted for stable wire output)
    /// for the given interfaces.
    func nicSecurityGroupMemberships(
        interfaceIDs: [UUID], on db: any Database
    ) async throws -> [UUID: [UUID]] {
        guard !interfaceIDs.isEmpty else { return [:] }
        let memberships = try await VMInterfaceSecurityGroup.query(on: db)
            .filter(\.$interface.$id ~~ interfaceIDs)
            .all()
        var byInterface: [UUID: [UUID]] = [:]
        for membership in memberships {
            byInterface[membership.$interface.id, default: []].append(membership.$securityGroup.id)
        }
        return byInterface.mapValues { $0.sorted { $0.uuidString < $1.uuidString } }
    }

    /// The sandbox twin (STR-102), reading the sandbox NICs' own join table.
    ///
    /// Its result is discarded for an agent that does not advertise sandbox
    /// networking, since the whole `NetworkSpec` is withheld from one
    /// (STR-103). That is one `IN` query per sync per agent that hosts sandbox
    /// NICs — the `isEmpty` guard means agents without them pay nothing — and
    /// it is not worth a second condition to skip: the memberships are what
    /// make a sandbox port come up filtered rather than unmanaged, so they must
    /// be in hand the moment the capability does light up.
    ///
    /// Kept as a separate query and a separate dictionary rather than merged
    /// with the VM map: the two ids could only share a keyspace because they
    /// come from different tables and so cannot collide, which is true but
    /// unstated — and the cost of not relying on it is one local. Generalizing
    /// the two queries behind a protocol is worse still: the join models'
    /// `@Parent` fields are differently typed, so it would buy two call sites a
    /// layer of Fluent generics.
    func sandboxNICSecurityGroupMemberships(
        interfaceIDs: [UUID], on db: any Database
    ) async throws -> [UUID: [UUID]] {
        guard !interfaceIDs.isEmpty else { return [:] }
        let memberships = try await SandboxInterfaceSecurityGroup.query(on: db)
            .filter(\.$interface.$id ~~ interfaceIDs)
            .all()
        var byInterface: [UUID: [UUID]] = [:]
        for membership in memberships {
            byInterface[membership.$interface.id, default: []].append(membership.$securityGroup.id)
        }
        return byInterface.mapValues { $0.sorted { $0.uuidString < $1.uuidString } }
    }

    /// The security groups the desired-state sync should carry for a topology
    /// authority: every group attached to a NIC of a VM *or sandbox* placed on
    /// the hosts whose topology the receiving agent authors, expanded to the
    /// transitive closure over rule references so every `$pg_…` address-set
    /// match resolves against an existing port group.
    ///
    /// The sandbox arm (STR-102) runs regardless of whether the *receiving*
    /// agent will be sent any sandbox `NetworkSpec` (STR-103). That is the
    /// point: the authority realizes a sandbox's port groups and ACLs before
    /// any sandbox port exists, so the moment a host gains the sandbox-networking
    /// capability is not also the moment those groups are first created, which
    /// would park every first sandbox create on `DependencyPendingError`. A
    /// port group with no members matches nothing, so realizing it early costs
    /// an OVN row and changes no traffic.
    func desiredSecurityGroups(
        forVMs vms: [VM], sandboxes: [Sandbox], on db: any Database
    ) async throws -> [DesiredSecurityGroup] {
        let vmInterfaceIDs = vms.flatMap { $0.networkInterfaces.compactMap(\.id) }
        let sandboxInterfaceIDs = sandboxes.flatMap { $0.networkInterfaces.compactMap(\.id) }
        // Both seeds, not just the VM one: an agent (or a whole site) hosting
        // sandboxes and no VM NICs would otherwise silently receive no groups
        // at all, and nothing downstream would report the omission.
        guard !vmInterfaceIDs.isEmpty || !sandboxInterfaceIDs.isEmpty else { return [] }

        var groupIDs: Set<UUID> = []
        if !vmInterfaceIDs.isEmpty {
            groupIDs.formUnion(
                try await VMInterfaceSecurityGroup.query(on: db)
                    .filter(\.$interface.$id ~~ vmInterfaceIDs)
                    .all()
                    .map { $0.$securityGroup.id })
        }
        if !sandboxInterfaceIDs.isEmpty {
            groupIDs.formUnion(
                try await SandboxInterfaceSecurityGroup.query(on: db)
                    .filter(\.$interface.$id ~~ sandboxInterfaceIDs)
                    .all()
                    .map { $0.$securityGroup.id })
        }

        // Reference closure: rules pointing at groups outside the attached
        // set pull those groups in (definitions only — their ACLs matter for
        // the address set, and membership comes from whatever NICs attach
        // them). Bounded by the per-project group cap.
        var frontier = groupIDs
        while !frontier.isEmpty {
            let referenced = Set(
                try await SecurityGroupRule.query(on: db)
                    .filter(\.$securityGroup.$id ~~ Array(frontier))
                    .all()
                    .compactMap { $0.$remoteGroup.id })
            frontier = referenced.subtracting(groupIDs)
            groupIDs.formUnion(frontier)
        }
        guard !groupIDs.isEmpty else { return [] }

        let groups = try await SecurityGroup.query(on: db)
            .filter(\.$id ~~ Array(groupIDs))
            .with(\.$rules)
            .all()

        // This is the first point that proves an authority will receive each
        // group. Start the silence deadline here rather than at create or rule
        // mutation time: an unattached, unreferenced group belongs in no
        // agent's desired closure and therefore cannot report an observation.
        let outstandingIDs = groups.compactMap { group -> UUID? in
            guard group.observedGeneration < group.generation,
                group.convergenceDeadline == nil
            else { return nil }
            return group.id
        }
        if !outstandingIDs.isEmpty {
            guard let sql = db as? any SQLDatabase else {
                throw DesiredStateGenerationWriter.Error.unsupportedDatabase
            }
            let convergenceDeadline = Date().addingTimeInterval(180)
            try await sql.raw(
                """
                UPDATE security_groups
                SET convergence_deadline = \(bind: convergenceDeadline)
                WHERE id IN (\(binds: outstandingIDs))
                  AND observed_generation < generation
                  AND convergence_deadline IS NULL
                """
            ).run()
        }
        return
            groups
            .compactMap { group -> DesiredSecurityGroup? in
                guard let groupId = group.id else { return nil }
                let rules = group.rules.compactMap { rule -> DesiredSecurityGroupRule? in
                    guard let ruleId = rule.id else { return nil }
                    return DesiredSecurityGroupRule(
                        id: ruleId,
                        direction: rule.direction.rawValue,
                        ethertype: rule.ethertype.rawValue,
                        protocolName: rule.protocolName,
                        portRangeMin: rule.portRangeMin,
                        portRangeMax: rule.portRangeMax,
                        remoteCIDR: rule.remoteCIDR,
                        remoteGroupId: rule.$remoteGroup.id,
                        log: rule.log
                    )
                }
                .sorted { $0.id.uuidString < $1.id.uuidString }
                return DesiredSecurityGroup(id: groupId, generation: group.generation, rules: rules)
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Floating IPs (issue #344) the desired-state sync should carry, keyed by
    /// the attached NIC's network name: each becomes a `dnat_and_snat` rule on
    /// that network's router. Only attachments to VMs placed on `agentIDs` —
    /// the hosts whose topology the receiving agent authors.
    func desiredLoadBalancers(
        networkIDs: Set<UUID>, on db: any Database
    ) async throws -> [UUID: [DesiredLoadBalancer]] {
        guard !networkIDs.isEmpty else { return [:] }
        let rows = try await LoadBalancer.query(on: db)
            .filter(\.$logicalNetwork.$id ~~ networkIDs)
            .sort(\.$id)
            .all()
        var byNetwork: [UUID: [DesiredLoadBalancer]] = [:]
        var gatewaysByNetwork: [UUID: String?] = [:]
        for row in rows {
            guard let loadBalancerID = row.id else { continue }
            let listeners = try await LoadBalancerListener.query(on: db)
                .filter(\.$loadBalancer.$id == loadBalancerID)
                .sort(\.$port)
                .sort(\.$id)
                .all()
            let backendRows = try await LoadBalancerBackend.query(on: db)
                .filter(\.$loadBalancer.$id == loadBalancerID)
                .sort(\.$id)
                .all()
            var backends: [DesiredLoadBalancerBackend] = []
            for backend in backendRows {
                guard let backendID = backend.id else { continue }
                if let address = backend.address {
                    backends.append(DesiredLoadBalancerBackend(id: backendID, ipAddress: address))
                    continue
                }
                guard let interfaceID = backend.$interface.id,
                    let interface = try await VMNetworkInterface.query(on: db)
                        .filter(\.$id == interfaceID)
                        .with(\.$addresses)
                        .first(),
                    interface.detachGeneration == nil,
                    let address = interface.ipv4Address?.address
                else {
                    // SET NULL on NIC deletion deliberately leaves the backend
                    // record as history, but it no longer participates in the
                    // desired OVN set.
                    continue
                }
                let backendNetworkID = interface.logicalNetworkID
                let healthCheckSourceIP: String?
                if let cached = gatewaysByNetwork[backendNetworkID] {
                    healthCheckSourceIP = cached
                } else {
                    let gateway = try await LogicalNetwork.find(backendNetworkID, on: db)?.gateway
                    gatewaysByNetwork[backendNetworkID] = gateway
                    healthCheckSourceIP = gateway
                }
                backends.append(
                    DesiredLoadBalancerBackend(
                        id: backendID,
                        ipAddress: address,
                        vmId: interface.$vm.id,
                        nicIndex: interface.orderIndex,
                        networkId: backendNetworkID,
                        healthCheckSourceIP: healthCheckSourceIP))
            }
            let desired = DesiredLoadBalancer(
                id: loadBalancerID,
                name: row.name,
                vip: row.vip,
                protocolName: row.protocolName.rawValue,
                generation: row.generation,
                healthCheck: DesiredLoadBalancerHealthCheck(
                    enabled: row.healthCheckEnabled,
                    intervalSeconds: row.healthCheckIntervalSeconds,
                    timeoutSeconds: row.healthCheckTimeoutSeconds,
                    successThreshold: row.healthCheckSuccessThreshold,
                    failureThreshold: row.healthCheckFailureThreshold),
                listeners: listeners.compactMap { listener in
                    listener.id.map {
                        DesiredLoadBalancerListener(
                            id: $0, port: listener.port, backendPort: listener.backendPort)
                    }
                },
                backends: backends)
            byNetwork[row.$logicalNetwork.id, default: []].append(desired)
        }
        return byNetwork
    }

    func desiredFloatingIPs(
        forAgentIDs agentIDs: Set<String>, networkIDs: Set<UUID>, on db: any Database
    ) async throws -> [UUID: [DesiredFloatingIP]] {
        guard !agentIDs.isEmpty, !networkIDs.isEmpty else { return [:] }
        let attached = try await FloatingIP.query(on: db)
            .filter(\.$interface.$id != nil)
            .with(\.$interface)
            .all()

        // Load the owning VMs (scoped to the covered agents) with their NIC
        // address rows. The NAT target uses each row's stable `orderIndex`,
        // which is also the slot encoded in its OVN logical-port name.
        let vmIDs = Set(attached.compactMap { $0.interface?.$vm.id })
        let vmsByID = try await Dictionary(
            VM.query(on: db)
                .filter(\.$id ~~ vmIDs)
                .filter(\.$hypervisorId ~~ agentIDs)
                .with(\.$networkInterfaces) { $0.with(\.$addresses) }
                .all()
                .compactMap { vm in vm.id.map { ($0, vm) } },
            uniquingKeysWith: { first, _ in first }
        )

        var byNetwork: [UUID: [DesiredFloatingIP]] = [:]
        for floatingIP in attached {
            guard let interface = floatingIP.interface,
                let vm = vmsByID[interface.$vm.id],
                let vmId = vm.id
            else { continue }
            guard let desiredInterface = vm.networkInterfaces.first(where: { $0.id == interface.id }),
                desiredInterface.detachGeneration == nil,
                let logicalIP = desiredInterface.ipv4Address?.address
            else {
                app.logger.warning(
                    "Floating IP attached to a NIC without an IPv4 address; skipping its NAT rule",
                    metadata: ["address": .string(floatingIP.address)])
                continue
            }
            byNetwork[desiredInterface.logicalNetworkID, default: []].append(
                DesiredFloatingIP(
                    externalIP: floatingIP.address,
                    logicalIP: logicalIP,
                    vmId: vmId,
                    nicIndex: desiredInterface.orderIndex))
        }
        let loadBalancerFloatingIPs = try await FloatingIP.query(on: db)
            .filter(\.$loadBalancer.$id != nil)
            .with(\.$loadBalancer)
            .all()
        for floatingIP in loadBalancerFloatingIPs {
            guard let loadBalancer = floatingIP.loadBalancer,
                networkIDs.contains(loadBalancer.$logicalNetwork.id)
            else { continue }
            byNetwork[loadBalancer.$logicalNetwork.id, default: []].append(
                DesiredFloatingIP(
                    externalIP: floatingIP.address,
                    logicalIP: loadBalancer.vip))
        }
        return byNetwork.mapValues { $0.sorted { $0.externalIP < $1.externalIP } }
    }
}
