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
        generation: Int64 = 1,
        id: UUID = UUID()
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
            generation: generation)
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
        // The switch is named by UUID; the user name is carried as the legacy
        // name so the agent can migrate an old name-based switch in place.
        #expect(plan.switches[0].name == OVNNaming.switchName(networkId: net.networkId))
        #expect(plan.switches[0].legacyName == "isolated")
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
}

/// Records the calls the reconciler drives, for asserting orchestration order
/// and content without a live OVSDB.
private actor RecordingNetworkActuator: NetworkActuator {
    private(set) var calls: [String] = []
    private let observed: ObservedNetworkTopology
    private let uplinkAvailable: Bool

    init(observed: ObservedNetworkTopology, uplinkAvailable: Bool = true) {
        self.observed = observed
        self.uplinkAvailable = uplinkAvailable
    }

    func observeTopology() async throws -> ObservedNetworkTopology { observed }
    func ensureSwitch(_ desired: DesiredSwitch) async throws { calls.append("ensureSwitch(\(desired.name))") }
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
    }
    func removeSwitchRouterPort(name: String) async throws { calls.append("removeSwitchRouterPort(\(name))") }
    func removeRouterPort(name: String) async throws { calls.append("removeRouterPort(\(name))") }
    func removeExternalSwitch(name: String) async throws { calls.append("removeExternalSwitch(\(name))") }
    func removeRouter(name: String) async throws { calls.append("removeRouter(\(name))") }
}
