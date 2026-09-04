import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("Network Reconciler")
struct NetworkReconcilerTests {

    private func network(
        name: String,
        subnet: String,
        gateway: String?,
        subnet6: String? = nil,
        gateway6: String? = nil,
        routerKey: String,
        externalAccess: Bool = true,
        metadataEnabled: Bool = false,
        resolverEnabled: Bool? = nil,
        resolverAddresses: [String]? = nil,
        generation: Int64 = 1,
        id: UUID = UUID(),
        floatingIPs: [DesiredFloatingIP] = []
    ) -> DesiredNetworkState {
        DesiredNetworkState(
            networkId: id,
            name: name,
            subnet: subnet,
            gateway: gateway,
            subnet6: subnet6,
            gateway6: gateway6,
            routerKey: routerKey,
            externalAccess: externalAccess,
            metadataEnabled: metadataEnabled,
            resolverEnabled: resolverEnabled,
            resolverAddresses: resolverAddresses,
            generation: generation,
            floatingIPs: floatingIPs)
    }

    // MARK: - Plan

    @Test("Networks sharing a project share one router with a port each")
    func perProjectRouterGrouping() {
        let project = "project-A"
        let web = network(name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: project)
        let db = network(name: "db", subnet: "10.0.5.0/24", gateway: "10.0.5.1", routerKey: project)
        let plan = NetworkReconciler.plan(networks: [web, db])

        #expect(plan.switches.count == 2)
        #expect(plan.routers.count == 1)

        let router = plan.routers[0]
        #expect(router.name == "lr-project-A")
        #expect(router.ports.count == 2)
        // Cross-switch east-west: both switches peer to the same router. Switch
        // names are derived from network ids, not the user-chosen names.
        #expect(
            Set(router.ports.map(\.switchName)) == [
                OVNNaming.switchName(networkId: web.networkId),
                OVNNaming.switchName(networkId: db.networkId),
            ])
        // Both networks want external access → both subnets get SNAT.
        #expect(Set(router.snatSubnets) == ["192.168.1.0/24", "10.0.5.0/24"])
        #expect(router.needsUplink)
    }

    @Test("Egress and no-egress networks split onto separate routers")
    func egressSplitRouters() {
        // The control plane keys no-egress networks on a separate `-internal`
        // routerKey; the planner then groups them onto a router with no uplink,
        // so they provably can't egress.
        let web = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "project-P",
            externalAccess: true)
        let db = network(
            name: "db", subnet: "10.0.5.0/24", gateway: "10.0.5.1", routerKey: "project-P-internal",
            externalAccess: false)
        let plan = NetworkReconciler.plan(networks: [web, db])

        #expect(plan.routers.count == 2)
        let egress = plan.routers.first { $0.name == "lr-project-P" }
        let internalRouter = plan.routers.first { $0.name == "lr-project-P-internal" }
        #expect(egress?.needsUplink == true)
        #expect(internalRouter?.needsUplink == false)
    }

    @Test("A global (project-less) network keys its router on its own id")
    func globalNetworkFallback() {
        let plan = NetworkReconciler.plan(networks: [
            network(name: "shared", subnet: "172.16.0.0/24", gateway: "172.16.0.1", routerKey: "network-G")
        ])
        #expect(plan.routers.count == 1)
        #expect(plan.routers[0].name == "lr-network-G")
        #expect(plan.routers[0].ports.count == 1)
    }

    @Test("A network with no gateway is switch-only (no router port, no router)")
    func switchOnlyNetwork() {
        let net = network(name: "isolated", subnet: "10.9.0.0/24", gateway: nil, routerKey: "project-Z")
        let plan = NetworkReconciler.plan(networks: [net])
        #expect(plan.switches.count == 1)
        #expect(plan.routers.isEmpty)
        #expect(plan.switches[0].name == OVNNaming.switchName(networkId: net.networkId))
    }

    @Test("externalAccess=false gets an L3 gateway but no SNAT")
    func gatewayWithoutExternalAccess() {
        let plan = NetworkReconciler.plan(networks: [
            network(
                name: "internal", subnet: "10.1.0.0/24", gateway: "10.1.0.1",
                routerKey: "project-Y", externalAccess: false)
        ])
        #expect(plan.routers.count == 1)
        #expect(plan.routers[0].ports.count == 1)
        #expect(plan.routers[0].snatSubnets.isEmpty)
        #expect(!plan.routers[0].needsUplink)
    }

    @Test("A dual-stack network's router port carries both CIDRs and stateful RA config")
    func dualStackRouterPort() {
        let plan = NetworkReconciler.plan(networks: [
            network(
                name: "dual", subnet: "10.2.0.0/24", gateway: "10.2.0.1",
                subnet6: "fd12:3456:789a::/64", gateway6: "fd12:3456:789a::1",
                routerKey: "project-D")
        ])
        #expect(plan.routers.count == 1)
        let port = plan.routers[0].ports[0]
        #expect(port.cidrs == ["10.2.0.1/24", "fd12:3456:789a::1/64"])
        // MAC stays derived from the v4 gateway: rederiving on upgrade would
        // rewrite every existing router port's MAC.
        #expect(port.mac == OVNNaming.routerPortMAC(gateway: "10.2.0.1"))
        #expect(port.ipv6RAConfigs?["address_mode"] == "dhcpv6_stateful")
        #expect(port.ipv6RAConfigs?["send_periodic"] == "true")
        // Both families get SNAT, so the default route the RAs advertise leads
        // somewhere (issue #519).
        #expect(plan.routers[0].snatSubnets == ["10.2.0.0/24", "fd12:3456:789a::/64"])
    }

    @Test("The planned v6 SNAT subnet is the canonical masked prefix, not the raw string")
    func v6SNATSubnetIsCanonical() {
        // A non-canonical, non-masked spelling of fd12:3456:789a::/64. Planning
        // it verbatim would never match what OVN reports back, so every
        // reconcile would tear the rule down and recreate it.
        let plan = NetworkReconciler.plan(networks: [
            network(
                name: "dual", subnet: "10.2.0.0/24", gateway: "10.2.0.1",
                subnet6: "fd12:3456:789A::5/64", gateway6: "fd12:3456:789a::1",
                routerKey: "project-D")
        ])
        #expect(plan.routers[0].snatSubnets == ["10.2.0.0/24", "fd12:3456:789a::/64"])
    }

    @Test("A dual-stack network without external access gets no SNAT in either family")
    func dualStackNoExternalAccessHasNoSNAT() {
        let plan = NetworkReconciler.plan(networks: [
            network(
                name: "internal", subnet: "10.9.0.0/24", gateway: "10.9.0.1",
                subnet6: "fd99::/64", gateway6: "fd99::1",
                routerKey: "project-I", externalAccess: false)
        ])
        #expect(plan.routers[0].ports[0].cidrs.count == 2)
        #expect(plan.routers[0].snatSubnets.isEmpty)
    }

    @Test("An unparsable v6 config contributes no v6 SNAT subnet")
    func invalidIPv6ContributesNoSNAT() {
        let plan = NetworkReconciler.plan(networks: [
            network(
                name: "broken6", subnet: "10.3.0.0/24", gateway: "10.3.0.1",
                subnet6: "junk", gateway6: "fd00::1", routerKey: "project-B")
        ])
        #expect(plan.routers[0].snatSubnets == ["10.3.0.0/24"])
    }

    @Test("Unparsable IPv6 config degrades the port to v4-only, never drops it")
    func invalidIPv6DegradesToV4() {
        for (subnet6, gateway6) in [
            ("junk", "fd00::1"),
            ("fd00::/64", "not-an-ip"),
            ("fd00::/64", "fd99::1"),  // gateway outside the prefix
        ] {
            let plan = NetworkReconciler.plan(networks: [
                network(
                    name: "broken6", subnet: "10.3.0.0/24", gateway: "10.3.0.1",
                    subnet6: subnet6, gateway6: gateway6, routerKey: "project-B")
            ])
            #expect(plan.routers.count == 1)
            let port = plan.routers[0].ports[0]
            #expect(port.cidrs == ["10.3.0.1/24"], "\(subnet6)/\(gateway6) should degrade to v4-only")
            #expect(port.ipv6RAConfigs == nil)
        }
    }

    @Test("A v4-only network's router port has no RA config")
    func v4OnlyPortHasNoRAConfig() {
        let plan = NetworkReconciler.plan(networks: [
            network(name: "v4", subnet: "10.4.0.0/24", gateway: "10.4.0.1", routerKey: "project-V")
        ])
        #expect(plan.routers[0].ports[0].ipv6RAConfigs == nil)
        #expect(plan.routers[0].ports[0].cidrs == ["10.4.0.1/24"])
    }

    @Test("plan is deterministic regardless of input order")
    func planIsDeterministic() {
        let a = network(name: "a", subnet: "10.0.1.0/24", gateway: "10.0.1.1", routerKey: "p")
        let b = network(name: "b", subnet: "10.0.2.0/24", gateway: "10.0.2.1", routerKey: "p")
        #expect(NetworkReconciler.plan(networks: [a, b]) == NetworkReconciler.plan(networks: [b, a]))

        // Names alone are not a total order since issue #765, and Swift's sort
        // is not stable — two same-named networks would otherwise plan in
        // arbitrary order.
        let twinA = network(name: "default", subnet: "10.0.3.0/24", gateway: "10.0.3.1", routerKey: "p1")
        let twinB = network(name: "default", subnet: "10.0.4.0/24", gateway: "10.0.4.1", routerKey: "p2")
        #expect(
            NetworkReconciler.plan(networks: [twinA, twinB])
                == NetworkReconciler.plan(networks: [twinB, twinA]))
    }

    @Test("Two projects' same-named networks plan as fully separate topology")
    func sameNamedNetworksAreIndependent() {
        // The acceptance criterion of issue #765, at the OVN layer: same name,
        // same subnet, different projects.
        let cidr = "192.168.1.0/24"
        let gateway = "192.168.1.1"
        let a = network(name: "default", subnet: cidr, gateway: gateway, routerKey: "project-A")
        let b = network(name: "default", subnet: cidr, gateway: gateway, routerKey: "project-B")

        let plan = NetworkReconciler.plan(networks: [a, b])

        // Distinct switches, named by id rather than by the shared name.
        #expect(plan.switches.count == 2)
        #expect(Set(plan.switches.map(\.name)).count == 2)
        #expect(plan.switches.contains { $0.name == OVNNaming.switchName(networkId: a.networkId) })
        #expect(plan.switches.contains { $0.name == OVNNaming.switchName(networkId: b.networkId) })

        // One router each, so their identical subnets never meet — and each
        // SNATs that subnet on its own router.
        #expect(plan.routers.count == 2)
        #expect(Set(plan.routers.map(\.name)).count == 2)
        #expect(plan.routers.allSatisfy { $0.snatSubnets == [cidr] })
        let snatKeys = Set(plan.expectedTopology.snatRules)
        #expect(snatKeys.count == 2)
    }

    // MARK: - Teardown / idempotency

    @Test("A converged host needs no teardown (idempotent)")
    func idempotentWhenConverged() {
        let plan = NetworkReconciler.plan(networks: [
            network(name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p"),
            network(name: "db", subnet: "10.0.5.0/24", gateway: "10.0.5.1", routerKey: "p"),
        ])
        let actions = NetworkReconciler.teardownActions(
            desired: plan, observed: plan.expectedTopology)
        #expect(actions.isEmpty)
    }

    @Test("Removing a network tears down only its owned objects")
    func teardownRemovedNetwork() {
        let web = network(name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p")
        let db = network(name: "db", subnet: "10.0.5.0/24", gateway: "10.0.5.1", routerKey: "p")
        let observed = NetworkReconciler.plan(networks: [web, db]).expectedTopology

        // `db` is gone from the desired set; `web` (and the shared router) remain.
        let desired = NetworkReconciler.plan(networks: [web])
        let actions = NetworkReconciler.teardownActions(desired: desired, observed: observed)

        #expect(actions.contains(.routerPort(name: OVNNaming.routerPortName(networkId: db.networkId))))
        #expect(
            actions.contains(.switchRouterPort(name: OVNNaming.switchRouterPortName(networkId: db.networkId))))
        #expect(actions.contains(.snat(router: "lr-p", logicalIP: "10.0.5.0/24")))
        // The shared router and web's objects survive.
        #expect(!actions.contains(.router(name: "lr-p")))
        #expect(!actions.contains(.routerPort(name: OVNNaming.routerPortName(networkId: web.networkId))))
    }

    @Test("A stale-skipped network is protected from teardown")
    func staleNetworkSurvivesTeardown() {
        let web = network(name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p")
        let db = network(name: "db", subnet: "10.0.5.0/24", gateway: "10.0.5.1", routerKey: "p")
        let observed = NetworkReconciler.plan(networks: [web, db]).expectedTopology

        // `db` was skipped as stale, so the applied plan is [web] — but db is
        // still present, so its objects are protected. Nothing is torn down.
        let protected = NetworkReconciler.protectedTopology(forStale: [db])
        let actions = NetworkReconciler.teardownActions(
            desired: NetworkReconciler.plan(networks: [web]), observed: observed, protected: protected)
        #expect(actions.isEmpty)

        // With no stale protection (db truly absent from the sync), db is torn down.
        let unprotected = NetworkReconciler.teardownActions(
            desired: NetworkReconciler.plan(networks: [web]), observed: observed)
        #expect(unprotected.contains(.routerPort(name: OVNNaming.routerPortName(networkId: db.networkId))))
        #expect(unprotected.contains(.snat(router: "lr-p", logicalIP: "10.0.5.0/24")))
    }

    @Test("Turning off externalAccess on a current network tears down its SNAT")
    func currentNetworkLosesSNATWhenExternalAccessOff() {
        let webId = UUID()
        let on = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
            externalAccess: true, id: webId)
        let off = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
            externalAccess: false, id: webId)
        let observed = NetworkReconciler.plan(networks: [on]).expectedTopology

        // `web` is current (not stale), so protection is empty and its now-unwanted
        // SNAT + uplink must be removed rather than leaked.
        let actions = NetworkReconciler.teardownActions(
            desired: NetworkReconciler.plan(networks: [off]), observed: observed,
            protected: NetworkReconciler.protectedTopology(forStale: []))
        #expect(actions.contains(.snat(router: "lr-p", logicalIP: "192.168.1.0/24")))
        #expect(actions.contains(.externalSwitch(name: "ls-ext-p")))
    }

    @Test("A stale network protects only its own SNAT on a shared router")
    func staleSNATProtectionIsPerSubnet() {
        let webId = UUID()
        let webOff = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
            externalAccess: false, id: webId)
        let db = network(name: "db", subnet: "10.0.5.0/24", gateway: "10.0.5.1", routerKey: "p")
        // Both networks previously had SNAT on the shared router lr-p.
        let webOn = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p", id: webId)
        let observed = NetworkReconciler.plan(networks: [webOn, db]).expectedTopology

        // web is current with externalAccess off; db is stale (protected).
        let actions = NetworkReconciler.teardownActions(
            desired: NetworkReconciler.plan(networks: [webOff]), observed: observed,
            protected: NetworkReconciler.protectedTopology(forStale: [db]))
        // web's SNAT is removed; db's SNAT on the same router is protected.
        #expect(actions.contains(.snat(router: "lr-p", logicalIP: "192.168.1.0/24")))
        #expect(!actions.contains(.snat(router: "lr-p", logicalIP: "10.0.5.0/24")))
    }

    @Test("protectedTopology covers a stale network's tenant, external, and SNAT objects")
    func protectedTopologyCoverage() {
        let net = network(name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p")
        let protected = NetworkReconciler.protectedTopology(forStale: [net])
        #expect(protected.routerNames.contains("lr-p"))
        #expect(protected.routerPortNames.contains(OVNNaming.routerPortName(networkId: net.networkId)))
        #expect(protected.routerPortNames.contains("lrp-ext-p"))
        #expect(
            protected.switchRouterPortNames.contains(OVNNaming.switchRouterPortName(networkId: net.networkId)))
        #expect(protected.externalSwitchNames.contains("ls-ext-p"))
        #expect(protected.snatRules.contains(SNATRuleKey(router: "lr-p", logicalIP: "192.168.1.0/24")))
    }

    @Test("A stale dual-stack network protects its v6 SNAT rule too")
    func protectedTopologyCoversV6SNAT() {
        let net = network(
            name: "dual", subnet: "192.168.1.0/24", gateway: "192.168.1.1",
            subnet6: "fd12:3456:789a::/64", gateway6: "fd12:3456:789a::1", routerKey: "p")
        let protected = NetworkReconciler.protectedTopology(forStale: [net])
        #expect(protected.snatRules.contains(SNATRuleKey(router: "lr-p", logicalIP: "192.168.1.0/24")))
        #expect(protected.snatRules.contains(SNATRuleKey(router: "lr-p", logicalIP: "fd12:3456:789a::/64")))
    }

    @Test("A stale dual-stack network's v6 SNAT survives teardown")
    func staleV6SNATIsNotTornDown() {
        // The v6 rule exists on the host but the network was skipped as stale,
        // so the plan is empty. Without protection the reconciler would drop
        // live IPv6 egress for a network that is still present in the sync.
        let net = network(
            name: "dual", subnet: "192.168.1.0/24", gateway: "192.168.1.1",
            subnet6: "fd12:3456:789a::/64", gateway6: "fd12:3456:789a::1", routerKey: "p")
        var observed = ObservedNetworkTopology()
        observed.snatRules = [
            SNATRuleKey(router: "lr-p", logicalIP: "192.168.1.0/24"),
            SNATRuleKey(router: "lr-p", logicalIP: "fd12:3456:789a::/64"),
        ]
        let actions = NetworkReconciler.teardownActions(
            desired: NetworkReconciler.plan(networks: []),
            observed: observed,
            protected: NetworkReconciler.protectedTopology(forStale: [net]))
        #expect(actions.isEmpty)
    }

    @Test("Removing the last network in a project tears the router and uplink down")
    func teardownEmptyRouter() {
        let web = network(name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p")
        let observed = NetworkReconciler.plan(networks: [web]).expectedTopology

        let actions = NetworkReconciler.teardownActions(
            desired: NetworkTopologyPlan(switches: [], routers: []), observed: observed)

        #expect(actions.contains(.router(name: "lr-p")))
        #expect(actions.contains(.externalSwitch(name: "ls-ext-p")))
        #expect(actions.contains(.routerPort(name: "lrp-ext-p")))
        #expect(actions.contains(.snat(router: "lr-p", logicalIP: "192.168.1.0/24")))
        // Dependents (SNAT/ports) are ordered before the router they hang off.
        let routerIndex = actions.firstIndex(of: .router(name: "lr-p"))!
        let snatIndex = actions.firstIndex(of: .snat(router: "lr-p", logicalIP: "192.168.1.0/24"))!
        #expect(snatIndex < routerIndex)
    }

    // MARK: - Derivations

    @Test("Router-port MAC is stable, locally-administered, and gateway-derived")
    func routerPortMAC() {
        #expect(OVNNaming.routerPortMAC(gateway: "192.168.1.1") == "02:00:c0:a8:01:01")
        #expect(OVNNaming.routerPortMAC(gateway: "10.0.5.1") == "02:00:0a:00:05:01")
        #expect(OVNNaming.routerPortMAC(gateway: "not-an-ip") == nil)
    }

    @Test("Prefix length is parsed out of a CIDR")
    func cidrPrefix() {
        #expect(NetworkReconciler.prefixLength(ofCIDR: "192.168.1.0/24") == 24)
        #expect(NetworkReconciler.prefixLength(ofCIDR: "10.0.0.0/8") == 8)
        #expect(NetworkReconciler.prefixLength(ofCIDR: "192.168.1.0") == nil)
        #expect(NetworkReconciler.prefixLength(ofCIDR: "192.168.1.0/33") == nil)
    }

    // MARK: - Apply orchestration

    @Test("reconcile ensures desired objects then tears down extras")
    func reconcileDrivesActuator() async throws {
        let web = network(name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p")
        let db = network(name: "db", subnet: "10.0.5.0/24", gateway: "10.0.5.1", routerKey: "p")

        // The host already realized both networks; this sync drops `db`.
        let actuator = RecordingNetworkActuator(
            observed: NetworkReconciler.plan(networks: [web, db]).expectedTopology)

        try await NetworkReconciler.reconcile(
            networks: [web], actuator: actuator, logger: Logger(label: "test"))

        let calls = await actuator.calls
        #expect(calls.contains("ensureSwitch(\(OVNNaming.switchName(networkId: web.networkId)))"))
        #expect(calls.contains("ensureRouter(lr-p)"))
        #expect(calls.contains("ensureRouterPort(\(OVNNaming.routerPortName(networkId: web.networkId))@lr-p)"))
        #expect(calls.contains("ensureSNAT(lr-p,192.168.1.0/24)"))
        // db's objects are torn down.
        #expect(calls.contains("removeRouterPort(\(OVNNaming.routerPortName(networkId: db.networkId)))"))
        #expect(calls.contains("removeSNAT(lr-p,10.0.5.0/24)"))
    }

    @Test("reconcile skips SNAT when no uplink is available")
    func reconcileSkipsSNATWithoutUplink() async throws {
        let web = network(name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p")
        let actuator = RecordingNetworkActuator(observed: ObservedNetworkTopology(), uplinkAvailable: false)

        try await NetworkReconciler.reconcile(
            networks: [web], actuator: actuator, logger: Logger(label: "test"))

        let calls = await actuator.calls
        #expect(calls.contains("ensureRouterPort(\(OVNNaming.routerPortName(networkId: web.networkId))@lr-p)"))
        #expect(!calls.contains(where: { $0.hasPrefix("ensureSNAT") }))
    }

    @Test("A per-network reconcile failure identifies only its network")
    func reconcileAttributesPerNetworkFailure() async throws {
        let failed = network(
            name: "failed", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p")
        let healthy = network(
            name: "healthy", subnet: "10.0.5.0/24", gateway: "10.0.5.1", routerKey: "p")
        let failedSwitch = OVNNaming.switchName(networkId: failed.networkId)
        let actuator = RecordingNetworkActuator(
            observed: ObservedNetworkTopology(), failingSwitchNames: [failedSwitch])

        let failures = try await NetworkReconciler.reconcile(
            networks: [failed, healthy], actuator: actuator, logger: Logger(label: "test"))

        let failure = try #require(failures.first { $0.message.contains(failedSwitch) })
        #expect(failure.affectedNetworkIds == [failed.networkId])
        #expect(failure.affectedNetworkIds?.contains(healthy.networkId) == false)
    }

    // MARK: - Metadata localport (STR-49)

    @Test("An enabled network plans a dual-stack metadata localport on its switch")
    func metadataPortPlanned() throws {
        let id = UUID()
        let plan = NetworkReconciler.plan(networks: [
            network(
                name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
                metadataEnabled: true, id: id)
        ])

        // `try #require`, not `try?` + optional chaining: a missing port should
        // fail once, here, rather than cascade into five confusing comparisons.
        let port = try #require(plan.switches[0].serviceLocalPort)
        #expect(port.name == OVNNaming.serviceLocalPortName(networkId: id))
        #expect(port.switchName == OVNNaming.switchName(networkId: id))
        #expect(port.mac == OVNNaming.serviceLocalPortMAC(networkId: id))
        #expect(port.ips == ["169.254.169.254", "fd00:ec2::254"])
        // One whitespace-separated entry, not one per address: that is the
        // shape OVN's `addresses` column expects, and getting it wrong yields a
        // port that never answers.
        #expect(port.addresses == ["\(OVNNaming.serviceLocalPortMAC(networkId: id)) 169.254.169.254 fd00:ec2::254"])
        #expect(plan.expectedTopology.serviceLocalPortNames == [OVNNaming.serviceLocalPortName(networkId: id)])
    }

    @Test("A gateway-less network still gets a metadata port")
    func metadataPortOnSwitchOnlyNetwork() {
        // The port hangs off the switch precisely so this case works: no
        // gateway means no router at all, and those guests need metadata too.
        let id = UUID()
        let plan = NetworkReconciler.plan(networks: [
            network(
                name: "isolated", subnet: "10.9.0.0/24", gateway: nil, routerKey: "p", metadataEnabled: true, id: id)
        ])

        #expect(plan.routers.isEmpty)
        #expect(plan.switches[0].serviceLocalPort?.name == OVNNaming.serviceLocalPortName(networkId: id))
    }

    @Test("Disabling metadata plans no port and tears the existing one down")
    func metadataPortTornDownWhenDisabled() {
        let id = UUID()
        let portName = OVNNaming.serviceLocalPortName(networkId: id)
        let disabled = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
            metadataEnabled: false, id: id)
        let plan = NetworkReconciler.plan(networks: [disabled])

        #expect(plan.switches[0].serviceLocalPort == nil)

        let actions = NetworkReconciler.teardownActions(
            desired: plan,
            observed: ObservedNetworkTopology(serviceLocalPortNames: [portName]),
            protected: NetworkReconciler.serviceLocalPortProtection(for: [disabled]))
        #expect(actions == [.serviceLocalPort(name: portName)])
    }

    @Test("A stale network's metadata port survives teardown")
    func metadataPortProtectedWhenStale() {
        let stale = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
            metadataEnabled: true)
        let portName = OVNNaming.serviceLocalPortName(networkId: stale.networkId)
        let protected = NetworkReconciler.protectedTopology(forStale: [stale])

        #expect(protected.serviceLocalPortNames.contains(portName))
        #expect(!protected.isEmpty)

        let actions = NetworkReconciler.teardownActions(
            desired: NetworkTopologyPlan(switches: [], routers: []),
            observed: ObservedNetworkTopology(serviceLocalPortNames: [portName]),
            protected: protected)
        #expect(actions.isEmpty)
    }

    @Test("A stale network's resolver port survives teardown alongside its metadata port")
    func resolverPortProtectedWhenStale() {
        // The regression this guards: the resolver became a second localport
        // with its own name, and the stale-protection set only knew the
        // metadata one — so a network skipped for a stale generation kept its
        // metadata port and lost its resolver port. Dropping that port stops
        // OVN answering ARP for the resolver address, which costs the guests
        // external name resolution as well as internal.
        let stale = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
            metadataEnabled: true, resolverEnabled: true,
            resolverAddresses: ["169.254.1.0", "fd00:ec2:1::100"])
        let metadataPort = OVNNaming.serviceLocalPortName(networkId: stale.networkId)
        let resolverPort = OVNNaming.resolverPortName(networkId: stale.networkId)
        let protected = NetworkReconciler.protectedTopology(forStale: [stale])

        #expect(protected.serviceLocalPortNames.contains(resolverPort))

        let actions = NetworkReconciler.teardownActions(
            desired: NetworkTopologyPlan(switches: [], routers: []),
            observed: ObservedNetworkTopology(serviceLocalPortNames: [metadataPort, resolverPort]),
            protected: protected)
        #expect(actions.isEmpty)
    }

    @Test("A stale network with the resolver off still keeps the port it may still have")
    func resolverPortProtectedWhenStaleEvenIfDisabled() {
        // Over-protection is deliberate on the stale path: the sync was skipped,
        // so its opinion is not one to act on. Under-protection drops a live
        // service; over-protection defers a teardown by one sync.
        let stale = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
            metadataEnabled: false, resolverEnabled: false)
        let protected = NetworkReconciler.protectedTopology(forStale: [stale])

        #expect(protected.serviceLocalPortNames.contains(OVNNaming.resolverPortName(networkId: stale.networkId)))
    }

    @Test("Networks sharing a subnet get distinct metadata port names and MACs")
    func metadataPortsDistinctAcrossOverlappingSubnets() {
        // Two projects may use the same subnet, which is exactly why the port
        // name and MAC derive from the network id rather than an address.
        let a = network(
            name: "web", subnet: "10.0.0.0/24", gateway: "10.0.0.1", routerKey: "a", metadataEnabled: true)
        let b = network(
            name: "web", subnet: "10.0.0.0/24", gateway: "10.0.0.1", routerKey: "b", metadataEnabled: true)
        let plan = NetworkReconciler.plan(networks: [a, b])

        let ports = plan.switches.compactMap(\.serviceLocalPort)
        #expect(ports.count == 2)
        #expect(ports[0].name != ports[1].name)
        #expect(ports[0].mac != ports[1].mac)
    }

    @Test("A metadata MAC is stable per network and disjoint from router/FIP MACs")
    func metadataPortMACIsStable() {
        let id = UUID()
        // Stability across calls is what a process-seeded hash would break, and
        // a churning MAC rewrites the port on every agent restart.
        #expect(OVNNaming.serviceLocalPortMAC(networkId: id) == OVNNaming.serviceLocalPortMAC(networkId: id))
        #expect(OVNNaming.serviceLocalPortMAC(networkId: id) != OVNNaming.serviceLocalPortMAC(networkId: UUID()))
        #expect(OVNNaming.serviceLocalPortMAC(networkId: id).hasPrefix("02:02:"))
    }

    @Test("A realized metadata plan is a fixed point")
    func metadataPortIdempotent() {
        let plan = NetworkReconciler.plan(networks: [
            network(
                name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
                metadataEnabled: true)
        ])
        #expect(
            NetworkReconciler.teardownActions(desired: plan, observed: plan.expectedTopology).isEmpty)
    }

    @Test("reconcile ensures the metadata port after its switch")
    func reconcileEnsuresMetadataPort() async throws {
        let id = UUID()
        let web = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
            metadataEnabled: true, id: id)
        let actuator = RecordingNetworkActuator(observed: ObservedNetworkTopology())

        try await NetworkReconciler.reconcile(
            networks: [web], actuator: actuator, logger: Logger(label: "test"))

        let calls = await actuator.calls
        let switchName = OVNNaming.switchName(networkId: id)
        let ensureSwitch = try #require(calls.firstIndex(of: "ensureSwitch(\(switchName))"))
        let ensurePort = try #require(
            calls.firstIndex(
                of: "ensureServiceLocalPort(\(OVNNaming.serviceLocalPortName(networkId: id))@\(switchName))"))
        #expect(ensureSwitch < ensurePort)
    }

    @Test("reconcile removes a metadata port the plan no longer wants")
    func reconcileRemovesMetadataPort() async throws {
        let id = UUID()
        let portName = OVNNaming.serviceLocalPortName(networkId: id)
        let disabled = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
            metadataEnabled: false, id: id)
        let actuator = RecordingNetworkActuator(
            observed: ObservedNetworkTopology(serviceLocalPortNames: [portName]))

        try await NetworkReconciler.reconcile(
            networks: [disabled], actuator: actuator, logger: Logger(label: "test"),
            protected: NetworkReconciler.serviceLocalPortProtection(for: [disabled]))

        let calls = await actuator.calls
        #expect(calls.contains("removeServiceLocalPort(\(portName))"))
        #expect(!calls.contains(where: { $0.hasPrefix("ensureServiceLocalPort") }))
    }

    // MARK: - Floating IPs (issue #344)

    @Test("A floating IP plans a distributed dnat_and_snat rule on the network's router")
    func floatingIPPlansDNAT() {
        let vmId = UUID()
        let plan = NetworkReconciler.plan(networks: [
            network(
                name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
                floatingIPs: [
                    DesiredFloatingIP(
                        externalIP: "203.0.113.10", logicalIP: "192.168.1.5", vmId: vmId, nicIndex: 0)
                ])
        ])

        #expect(plan.routers.count == 1)
        let rules = plan.routers[0].dnatRules
        #expect(rules.count == 1)
        #expect(rules[0].externalIP == "203.0.113.10")
        #expect(rules[0].logicalIP == "192.168.1.5")
        // Distributed NAT: the rule names the VM's LSP and a MAC derived from
        // the floating address in the 02:01: namespace.
        #expect(rules[0].logicalPort == "vm-\(vmId.uuidString)")
        #expect(rules[0].externalMAC == "02:01:cb:00:71:0a")
        #expect(
            plan.expectedTopology.dnatRules == [DNATRuleKey(router: "lr-p", externalIP: "203.0.113.10")])
    }

    @Test("A secondary NIC's floating IP names the index-suffixed port")
    func floatingIPSecondaryNICPort() {
        let vmId = UUID()
        let plan = NetworkReconciler.plan(networks: [
            network(
                name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
                floatingIPs: [
                    DesiredFloatingIP(
                        externalIP: "203.0.113.11", logicalIP: "192.168.1.6", vmId: vmId, nicIndex: 1)
                ])
        ])
        #expect(plan.routers[0].dnatRules[0].logicalPort == "vm-\(vmId.uuidString)-1")
    }

    @Test("Floating IPs on a no-egress network are not planned (no uplink to NAT through)")
    func floatingIPIgnoredWithoutExternalAccess() {
        let plan = NetworkReconciler.plan(networks: [
            network(
                name: "internal", subnet: "10.1.0.0/24", gateway: "10.1.0.1",
                routerKey: "p-internal", externalAccess: false,
                floatingIPs: [
                    DesiredFloatingIP(
                        externalIP: "203.0.113.12", logicalIP: "10.1.0.5", vmId: UUID(), nicIndex: 0)
                ])
        ])
        #expect(plan.routers.count == 1)
        #expect(plan.routers[0].dnatRules.isEmpty)
        #expect(!plan.routers[0].needsUplink)
    }

    @Test("A floating IP alone gives the router an uplink (DNAT needs it like SNAT does)")
    func floatingIPAloneNeedsUplink() {
        let net = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
            floatingIPs: [
                DesiredFloatingIP(
                    externalIP: "203.0.113.13", logicalIP: "192.168.1.7", vmId: UUID(), nicIndex: 0)
            ])
        // No SNAT contribution — simulate by keying off the plan directly: the
        // network has externalAccess so it also plans SNAT; the property under
        // test is DesiredRouter's own uplink derivation.
        let router = DesiredRouter(
            name: "lr-p", routerKey: "p", ports: [], snatSubnets: [],
            dnatRules: NetworkReconciler.plan(networks: [net]).routers[0].dnatRules)
        #expect(router.needsUplink)
    }

    @Test("A stale dnat rule is torn down; a stale network's floating IPs are protected")
    func floatingIPTeardownAndProtection() {
        let current = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
            floatingIPs: [
                DesiredFloatingIP(
                    externalIP: "203.0.113.20", logicalIP: "192.168.1.5", vmId: UUID(), nicIndex: 0)
            ])
        let plan = NetworkReconciler.plan(networks: [current])

        let observed = ObservedNetworkTopology(
            routerNames: ["lr-p"],
            dnatRules: [
                DNATRuleKey(router: "lr-p", externalIP: "203.0.113.20"),  // still wanted
                DNATRuleKey(router: "lr-p", externalIP: "203.0.113.21"),  // detached → teardown
                DNATRuleKey(router: "lr-p", externalIP: "203.0.113.22"),  // stale network's → protected
            ])
        let stale = network(
            name: "old", subnet: "10.5.0.0/24", gateway: "10.5.0.1", routerKey: "p",
            floatingIPs: [
                DesiredFloatingIP(
                    externalIP: "203.0.113.22", logicalIP: "10.5.0.9", vmId: UUID(), nicIndex: 0)
            ])
        let actions = NetworkReconciler.teardownActions(
            desired: plan, observed: observed,
            protected: NetworkReconciler.protectedTopology(forStale: [stale]))

        #expect(actions.contains(.dnat(router: "lr-p", externalIP: "203.0.113.21")))
        #expect(!actions.contains(.dnat(router: "lr-p", externalIP: "203.0.113.20")))
        #expect(!actions.contains(.dnat(router: "lr-p", externalIP: "203.0.113.22")))
    }

    @Test("reconcile drives ensureDNAT after the uplink and removeDNAT for stale rules")
    func reconcileDrivesDNAT() async throws {
        let web = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
            floatingIPs: [
                DesiredFloatingIP(
                    externalIP: "203.0.113.30", logicalIP: "192.168.1.5", vmId: UUID(), nicIndex: 0)
            ])
        let observed = ObservedNetworkTopology(
            routerNames: ["lr-p"],
            dnatRules: [DNATRuleKey(router: "lr-p", externalIP: "203.0.113.31")])
        let actuator = RecordingNetworkActuator(observed: observed)

        try await NetworkReconciler.reconcile(
            networks: [web], actuator: actuator, logger: Logger(label: "test"))

        let calls = await actuator.calls
        #expect(calls.contains("ensureDNAT(lr-p,203.0.113.30->192.168.1.5)"))
        #expect(calls.contains("removeDNAT(lr-p,203.0.113.31)"))
        #expect(calls.contains("ensureDynamicRouting(lr-p,ready)"))
        // NAT waits for the uplink.
        let uplinkIndex = calls.firstIndex(of: "ensureUplink(lr-p)")
        let dnatIndex = calls.firstIndex(of: "ensureDNAT(lr-p,203.0.113.30->192.168.1.5)")
        #expect(uplinkIndex != nil && dnatIndex != nil && uplinkIndex! < dnatIndex!)
    }

    @Test("Retired NAT teardown failures retain router ownership")
    func reconcileAttributesRetiredNATFailures() async throws {
        let network = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p")
        let observed = ObservedNetworkTopology(
            routerNames: ["lr-p"],
            snatRules: [SNATRuleKey(router: "lr-p", logicalIP: "10.0.5.0/24")],
            dnatRules: [DNATRuleKey(router: "lr-p", externalIP: "203.0.113.31")])
        let actuator = RecordingNetworkActuator(
            observed: observed,
            failingSNATRemovals: ["10.0.5.0/24"],
            failingDNATRemovals: ["203.0.113.31"])

        let failures = try await NetworkReconciler.reconcile(
            networks: [network], actuator: actuator, logger: Logger(label: "test"))

        let natFailures = failures.filter {
            $0.message.contains("203.0.113.31") || $0.message.contains("10.0.5.0/24")
        }
        #expect(natFailures.count == 2)
        #expect(natFailures.allSatisfy { $0.affectedNetworkIds == [network.networkId] })
    }

    @Test("reconcile skips DNAT (like SNAT) when no uplink is available")
    func reconcileSkipsDNATWithoutUplink() async throws {
        let web = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
            floatingIPs: [
                DesiredFloatingIP(
                    externalIP: "203.0.113.32", logicalIP: "192.168.1.5", vmId: UUID(), nicIndex: 0)
            ])
        let actuator = RecordingNetworkActuator(observed: ObservedNetworkTopology(), uplinkAvailable: false)

        try await NetworkReconciler.reconcile(
            networks: [web], actuator: actuator, logger: Logger(label: "test"))

        let calls = await actuator.calls
        #expect(!calls.contains(where: { $0.hasPrefix("ensureDNAT") }))
        // Dynamic routing still converges — with the uplink flagged
        // unavailable, so a previously enabled config is stripped rather
        // than left stale (the actuator's strip path).
        #expect(calls.contains("ensureDynamicRouting(lr-p,noUplink)"))
    }

    @Test("Routers without an uplink still converge (strip) dynamic routing")
    func dynamicRoutingStripsOnUplinklessRouters() async throws {
        let internal_ = network(
            name: "internal", subnet: "10.1.0.0/24", gateway: "10.1.0.1",
            routerKey: "p-internal", externalAccess: false)
        let actuator = RecordingNetworkActuator(observed: ObservedNetworkTopology())

        try await NetworkReconciler.reconcile(
            networks: [internal_], actuator: actuator, logger: Logger(label: "test"))

        let calls = await actuator.calls
        #expect(!calls.contains(where: { $0.hasPrefix("ensureUplink") }))
        #expect(calls.contains("ensureDynamicRouting(lr-p-internal,noUplink)"))
    }

    @Test("Floating IP MACs live in their own namespace and are deterministic")
    func floatingIPMACNamespace() {
        let mac = OVNNaming.floatingIPMAC(externalIP: "203.0.113.10")
        #expect(mac == "02:01:cb:00:71:0a")
        // Same address through the router-port derivation differs only in the
        // second octet, so the two namespaces can never mint the same MAC.
        #expect(OVNNaming.routerPortMAC(gateway: "203.0.113.10") == "02:00:cb:00:71:0a")
        #expect(OVNNaming.floatingIPMAC(externalIP: "not-an-ip") == nil)
    }

    @Test("VM port naming matches the historical NIC-0 scheme")
    func vmPortNaming() {
        #expect(OVNNaming.vmPortName(vmId: "ABC", nicIndex: 0) == "vm-ABC")
        #expect(OVNNaming.vmPortName(vmId: "ABC", nicIndex: 2) == "vm-ABC-2")
    }

    @Test("Sandbox ports take a namespace disjoint from VM ports (issue STR-100)")
    func sandboxPortNaming() {
        #expect(OVNNaming.sandboxPortName(sandboxId: "ABC", nicIndex: 0) == "sbx-ABC")
        #expect(OVNNaming.sandboxPortName(sandboxId: "ABC", nicIndex: 2) == "sbx-ABC-2")
        // The two kinds of port are realized differently — a host TAP versus a
        // veth into a jail's namespace — so the same id must never yield the
        // same port name for both.
        for index in 0..<4 {
            #expect(
                OVNNaming.sandboxPortName(sandboxId: "ABC", nicIndex: index)
                    != OVNNaming.vmPortName(vmId: "ABC", nicIndex: index))
        }
    }

    @Test("Placement selects which port namespace a workload's NIC lands in")
    func portNamingFollowsPlacement() {
        #expect(
            OVNNaming.portName(workloadId: "ABC", nicIndex: 1, placement: .hostNamespace) == "vm-ABC-1")
        #expect(
            OVNNaming.portName(
                workloadId: "ABC", nicIndex: 1,
                placement: .sandboxNetns(
                    netnsName: "strato-sbx-ABC", owner: JailOwner(uid: 100_000, gid: 100_000)))
                == "sbx-ABC-1")
    }
}

/// Records the calls the reconciler drives, for asserting orchestration order
/// and content without a live OVSDB.
private actor RecordingNetworkActuator: NetworkActuator {
    private(set) var calls: [String] = []
    private let observed: ObservedNetworkTopology
    private let uplinkAvailable: Bool
    private let failingSwitchNames: Set<String>
    private let failingSNATRemovals: Set<String>
    private let failingDNATRemovals: Set<String>

    init(
        observed: ObservedNetworkTopology,
        uplinkAvailable: Bool = true,
        failingSwitchNames: Set<String> = [],
        failingSNATRemovals: Set<String> = [],
        failingDNATRemovals: Set<String> = []
    ) {
        self.observed = observed
        self.uplinkAvailable = uplinkAvailable
        self.failingSwitchNames = failingSwitchNames
        self.failingSNATRemovals = failingSNATRemovals
        self.failingDNATRemovals = failingDNATRemovals
    }

    func observeTopology() async throws -> ObservedNetworkTopology { observed }
    func ensureSwitch(_ desired: DesiredSwitch) async throws {
        calls.append("ensureSwitch(\(desired.name))")
        if failingSwitchNames.contains(desired.name) { throw RecordingNetworkActuatorError.expectedFailure }
    }
    func ensureServiceLocalPort(_ port: DesiredServiceLocalPort) async throws {
        calls.append("ensureServiceLocalPort(\(port.name)@\(port.switchName))")
    }
    func removeServiceLocalPort(name: String) async throws { calls.append("removeServiceLocalPort(\(name))") }
    func ensureRouter(_ router: DesiredRouter) async throws { calls.append("ensureRouter(\(router.name))") }
    func ensureRouterPort(_ port: DesiredRouterPort, onRouter routerName: String) async throws {
        calls.append("ensureRouterPort(\(port.name)@\(routerName))")
    }
    func ensureUplink(for router: DesiredRouter) async throws -> Bool {
        calls.append("ensureUplink(\(router.name))")
        return uplinkAvailable
    }
    func ensureSNAT(router routerName: String, logicalIP: String) async throws {
        calls.append("ensureSNAT(\(routerName),\(logicalIP))")
    }
    func removeSNAT(router routerName: String, logicalIP: String) async throws {
        calls.append("removeSNAT(\(routerName),\(logicalIP))")
        if failingSNATRemovals.contains(logicalIP) {
            throw RecordingNetworkActuatorError.expectedFailure
        }
    }
    func ensureDNAT(router routerName: String, rule: DesiredDNATRule) async throws {
        calls.append("ensureDNAT(\(routerName),\(rule.externalIP)->\(rule.logicalIP))")
    }
    func removeDNAT(router routerName: String, externalIP: String) async throws {
        calls.append("removeDNAT(\(routerName),\(externalIP))")
        if failingDNATRemovals.contains(externalIP) {
            throw RecordingNetworkActuatorError.expectedFailure
        }
    }
    func ensureDynamicRouting(for router: DesiredRouter, uplinkReady: Bool) async throws {
        calls.append("ensureDynamicRouting(\(router.name),\(uplinkReady ? "ready" : "noUplink"))")
    }
    func removeSwitchRouterPort(name: String) async throws { calls.append("removeSwitchRouterPort(\(name))") }
    func removeRouterPort(name: String) async throws { calls.append("removeRouterPort(\(name))") }
    func removeExternalSwitch(name: String) async throws { calls.append("removeExternalSwitch(\(name))") }
    func removeRouter(name: String) async throws { calls.append("removeRouter(\(name))") }
    func observeDNSZones() async throws -> [ObservedDNSZone] { [] }
    func ensureDNSZone(_ write: DNSZoneWrite) async throws {
        calls.append("ensureDNSZone(\(write.plan.zoneName))")
    }
    func removeDNSZone(uuid: String) async throws { calls.append("removeDNSZone(\(uuid))") }
}

private enum RecordingNetworkActuatorError: Error {
    case expectedFailure
}
