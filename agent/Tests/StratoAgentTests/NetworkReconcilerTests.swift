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
        routerKey: String,
        externalAccess: Bool = true,
        generation: Int64 = 1
    ) -> DesiredNetworkState {
        DesiredNetworkState(
            networkId: UUID(),
            name: name,
            subnet: subnet,
            gateway: gateway,
            routerKey: routerKey,
            externalAccess: externalAccess,
            generation: generation)
    }

    // MARK: - Plan

    @Test("Networks sharing a project share one router with a port each")
    func perProjectRouterGrouping() {
        let project = "project-A"
        let plan = NetworkReconciler.plan(networks: [
            network(name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: project),
            network(name: "db", subnet: "10.0.5.0/24", gateway: "10.0.5.1", routerKey: project),
        ])

        #expect(plan.switches.count == 2)
        #expect(plan.routers.count == 1)

        let router = plan.routers[0]
        #expect(router.name == "lr-project-A")
        #expect(router.ports.count == 2)
        // Cross-switch east-west: both switches peer to the same router.
        #expect(Set(router.ports.map(\.switchName)) == ["web", "db"])
        // Both networks want external access → both subnets get SNAT.
        #expect(Set(router.snatSubnets) == ["192.168.1.0/24", "10.0.5.0/24"])
        #expect(router.needsUplink)
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
        let plan = NetworkReconciler.plan(networks: [
            network(name: "isolated", subnet: "10.9.0.0/24", gateway: nil, routerKey: "project-Z")
        ])
        #expect(plan.switches.count == 1)
        #expect(plan.routers.isEmpty)
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

        #expect(actions.contains(.routerPort(name: "lrp-db")))
        #expect(actions.contains(.switchRouterPort(name: "lsp-db-router")))
        #expect(actions.contains(.snat(router: "lr-p", logicalIP: "10.0.5.0/24")))
        // The shared router and web's objects survive.
        #expect(!actions.contains(.router(name: "lr-p")))
        #expect(!actions.contains(.routerPort(name: "lrp-web")))
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
        #expect(unprotected.contains(.routerPort(name: "lrp-db")))
        #expect(unprotected.contains(.snat(router: "lr-p", logicalIP: "10.0.5.0/24")))
    }

    @Test("Turning off externalAccess on a current network tears down its SNAT")
    func currentNetworkLosesSNATWhenExternalAccessOff() {
        let on = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
            externalAccess: true)
        let off = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
            externalAccess: false)
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
        let webOff = network(
            name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p",
            externalAccess: false)
        let db = network(name: "db", subnet: "10.0.5.0/24", gateway: "10.0.5.1", routerKey: "p")
        // Both networks previously had SNAT on the shared router lr-p.
        let observed = NetworkReconciler.plan(networks: [
            network(name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p"), db,
        ]).expectedTopology

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
        #expect(protected.routerPortNames.contains("lrp-web"))
        #expect(protected.routerPortNames.contains("lrp-ext-p"))
        #expect(protected.switchRouterPortNames.contains("lsp-web-router"))
        #expect(protected.externalSwitchNames.contains("ls-ext-p"))
        #expect(protected.snatRules.contains(SNATRuleKey(router: "lr-p", logicalIP: "192.168.1.0/24")))
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
        #expect(calls.contains("ensureSwitch(web)"))
        #expect(calls.contains("ensureRouter(lr-p)"))
        #expect(calls.contains("ensureRouterPort(lrp-web@lr-p)"))
        #expect(calls.contains("ensureSNAT(lr-p,192.168.1.0/24)"))
        // db's objects are torn down.
        #expect(calls.contains("removeRouterPort(lrp-db)"))
        #expect(calls.contains("removeSNAT(lr-p,10.0.5.0/24)"))
    }

    @Test("reconcile skips SNAT when no uplink is available")
    func reconcileSkipsSNATWithoutUplink() async throws {
        let web = network(name: "web", subnet: "192.168.1.0/24", gateway: "192.168.1.1", routerKey: "p")
        let actuator = RecordingNetworkActuator(observed: ObservedNetworkTopology(), uplinkAvailable: false)

        try await NetworkReconciler.reconcile(
            networks: [web], actuator: actuator, logger: Logger(label: "test"))

        let calls = await actuator.calls
        #expect(calls.contains("ensureRouterPort(lrp-web@lr-p)"))
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
