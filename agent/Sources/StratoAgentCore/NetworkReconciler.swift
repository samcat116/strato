import Foundation
import Logging
import StratoShared

// First-class L3 network reconciliation (issue #342, epic #341).
//
// The control plane sends the authoritative set of logical networks an agent
// should realize (`DesiredStateMessage.networks`). This file is the pure,
// unit-testable core that turns that desired set into an OVN topology plan
// (routers, router ports, external uplinks, SNAT rules) and diffs it against
// what OVN currently has to compute teardown actions. It has no SwiftOVN
// dependency — the live OVSDB side effects live in `NetworkServiceLinux`
// behind `NetworkActuator`, mirroring how `OVNChassisBootstrap` keeps the
// chassis decisions testable off the wire.
//
// Router scope is per-project: every network sharing a `routerKey` shares one
// logical router, so VMs on different switches route to each other (east-west);
// a project-less network keys its router on its own id and still gets SNAT.

// MARK: - Naming and derivation

/// Deterministic OVN object names derived from desired-network identity, so a
/// replayed sync always targets the same rows (idempotency) and teardown can
/// find them again without persisted state.
public enum OVNNaming {
    /// The tenant logical switch name for a network. Derived from the network's
    /// UUID, never its user-chosen name, so a user cannot pick a name that
    /// collides with a Strato-managed switch (e.g. a provider `ls-ext-*` switch)
    /// in OVN's shared `Logical_Switch` namespace (issue #342).
    public static func switchName(networkId: UUID) -> String {
        "net-\(networkId.uuidString.lowercased())"
    }
    public static func routerName(routerKey: String) -> String { "lr-\(routerKey)" }
    /// A network attaches to exactly one router, so its id uniquely names the
    /// router port.
    public static func routerPortName(networkId: UUID) -> String {
        "lrp-\(networkId.uuidString.lowercased())"
    }
    /// The `type=router` switch port peering the tenant switch to its router port.
    public static func switchRouterPortName(networkId: UUID) -> String {
        "lsp-\(networkId.uuidString.lowercased())-router"
    }
    public static func externalSwitchName(routerKey: String) -> String { "ls-ext-\(routerKey)" }
    public static func externalRouterPortName(routerKey: String) -> String { "lrp-ext-\(routerKey)" }
    /// The `type=router` switch port peering the external switch to the router's
    /// gateway port (the external-side counterpart of a tenant switch port).
    public static func externalSwitchRouterPortName(routerKey: String) -> String {
        "lsp-ext-\(routerKey)-router"
    }
    public static func localnetPortName(routerKey: String) -> String { "ln-ext-\(routerKey)" }
    /// The `Gateway_Chassis` row pinning a router's external port to a chassis,
    /// named `<port>-<chassis>` to match `ovn-nbctl lrp-set-gateway-chassis`.
    public static func gatewayChassisName(portName: String, chassis: String) -> String {
        "\(portName)-\(chassis)"
    }

    /// A stable, locally-administered unicast MAC for a router port, derived
    /// from its gateway IP (gateways are unique per network, so the MAC is too).
    /// `02:` sets the locally-administered bit and clears the multicast bit;
    /// the low four octets are the gateway address. Deterministic, so a replayed
    /// sync never churns the port's MAC. Nil when the gateway isn't IPv4.
    public static func routerPortMAC(gateway: String) -> String? {
        guard let ip = IPv4Address(gateway) else { return nil }
        return String(
            format: "02:00:%02x:%02x:%02x:%02x",
            (ip.raw >> 24) & 0xff, (ip.raw >> 16) & 0xff, (ip.raw >> 8) & 0xff, ip.raw & 0xff)
    }
}

// MARK: - Desired topology plan

/// A tenant logical switch the plan wants to exist.
public struct DesiredSwitch: Equatable, Sendable {
    /// The UUID-derived OVN switch name (`OVNNaming.switchName`).
    public let name: String
    public let subnet: String
    /// The network's user-facing name, i.e. the switch name older agents used
    /// before UUID naming. The actuator renames such a legacy switch in place to
    /// `name` on upgrade, so existing VM ports migrate without re-creation.
    public let legacyName: String

    public init(name: String, subnet: String, legacyName: String) {
        self.name = name
        self.subnet = subnet
        self.legacyName = legacyName
    }
}

/// A router port giving one tenant network its L3 gateway, plus the peering
/// `type=router` switch port on that network's switch.
public struct DesiredRouterPort: Equatable, Sendable {
    public let name: String
    public let switchName: String
    public let switchPortName: String
    public let mac: String
    /// The router port's address, `gateway/prefix` (e.g. `192.168.1.1/24`).
    public let cidr: String

    public init(name: String, switchName: String, switchPortName: String, mac: String, cidr: String) {
        self.name = name
        self.switchName = switchName
        self.switchPortName = switchPortName
        self.mac = mac
        self.cidr = cidr
    }
}

/// One per-project (or per-global-network) logical router the plan wants.
public struct DesiredRouter: Equatable, Sendable {
    public let name: String
    public let routerKey: String
    public let ports: [DesiredRouterPort]
    /// Tenant subnets (CIDR) that should egress via SNAT to the site uplink.
    public let snatSubnets: [String]

    public init(name: String, routerKey: String, ports: [DesiredRouterPort], snatSubnets: [String]) {
        self.name = name
        self.routerKey = routerKey
        self.ports = ports
        self.snatSubnets = snatSubnets
    }

    /// Whether this router needs an external uplink attachment (any SNAT).
    public var needsUplink: Bool { !snatSubnets.isEmpty }
    public var externalSwitchName: String { OVNNaming.externalSwitchName(routerKey: routerKey) }
    public var externalRouterPortName: String { OVNNaming.externalRouterPortName(routerKey: routerKey) }
    public var externalSwitchRouterPortName: String {
        OVNNaming.externalSwitchRouterPortName(routerKey: routerKey)
    }
    public var localnetPortName: String { OVNNaming.localnetPortName(routerKey: routerKey) }
}

/// The complete desired OVN L3 topology for one agent, derived purely from the
/// control plane's desired networks. Concrete uplink addressing (the host's
/// outbound IP) is resolved later by the actuator, not here.
public struct NetworkTopologyPlan: Equatable, Sendable {
    public let switches: [DesiredSwitch]
    public let routers: [DesiredRouter]

    public init(switches: [DesiredSwitch], routers: [DesiredRouter]) {
        self.switches = switches
        self.routers = routers
    }

    /// The observed topology this plan implies once fully realized — the set of
    /// object identities the diff should converge to. Used to compute teardown
    /// (observed − desired) and as the fixture for idempotency tests.
    public var expectedTopology: ObservedNetworkTopology {
        var routerNames = Set<String>()
        var routerPortNames = Set<String>()
        var switchRouterPortNames = Set<String>()
        var externalSwitchNames = Set<String>()
        var snatRules = Set<SNATRuleKey>()

        for router in routers {
            routerNames.insert(router.name)
            for port in router.ports {
                routerPortNames.insert(port.name)
                switchRouterPortNames.insert(port.switchPortName)
            }
            if router.needsUplink {
                externalSwitchNames.insert(router.externalSwitchName)
                routerPortNames.insert(router.externalRouterPortName)
                switchRouterPortNames.insert(router.externalSwitchRouterPortName)
                for subnet in router.snatSubnets {
                    snatRules.insert(SNATRuleKey(router: router.name, logicalIP: subnet))
                }
            }
        }

        return ObservedNetworkTopology(
            routerNames: routerNames,
            routerPortNames: routerPortNames,
            switchRouterPortNames: switchRouterPortNames,
            externalSwitchNames: externalSwitchNames,
            snatRules: snatRules)
    }
}

// MARK: - Observed topology and teardown

/// Identity of one SNAT rule, keyed by the router it lives on and the tenant
/// subnet it translates. The external IP is deliberately excluded: it can be
/// re-set in place (the uplink IP may change) without a delete/recreate.
public struct SNATRuleKey: Hashable, Sendable {
    public let router: String
    public let logicalIP: String
    public init(router: String, logicalIP: String) {
        self.router = router
        self.logicalIP = logicalIP
    }
}

/// A snapshot of the OVN L3 objects this reconciler owns, as observed on the
/// host. Gathered by the actuator from OVSDB; diffed against a plan to find
/// what to tear down. Tenant logical switches are intentionally absent — their
/// lifecycle stays with the VM-attach path, not this reconciler.
public struct ObservedNetworkTopology: Equatable, Sendable {
    public var routerNames: Set<String>
    public var routerPortNames: Set<String>
    public var switchRouterPortNames: Set<String>
    public var externalSwitchNames: Set<String>
    public var snatRules: Set<SNATRuleKey>

    public init(
        routerNames: Set<String> = [],
        routerPortNames: Set<String> = [],
        switchRouterPortNames: Set<String> = [],
        externalSwitchNames: Set<String> = [],
        snatRules: Set<SNATRuleKey> = []
    ) {
        self.routerNames = routerNames
        self.routerPortNames = routerPortNames
        self.switchRouterPortNames = switchRouterPortNames
        self.externalSwitchNames = externalSwitchNames
        self.snatRules = snatRules
    }
}

/// One teardown side effect: an owned OVN object present on the host that the
/// desired plan no longer wants. Ordered by the reconciler so dependents go
/// before the objects they reference.
public enum NetworkTeardownAction: Equatable, Sendable {
    case snat(router: String, logicalIP: String)
    case switchRouterPort(name: String)
    case routerPort(name: String)
    case externalSwitch(name: String)
    case router(name: String)
}

/// OVN object identities that teardown must never touch, regardless of the plan.
/// Built only from the networks a sync *skipped as stale* (present in the sync
/// but at a generation older than one already applied), so those networks —
/// absent from the applied plan yet still live — are left exactly as-is. It is
/// deliberately NOT built from current networks: a current network's dropped
/// objects (e.g. SNAT after `externalAccess` is turned off) must still be torn
/// down. SNAT is protected precisely by (router, subnet), not by router, so a
/// stale network can't shield a current sibling's SNAT on a shared router.
public struct ProtectedTopology: Equatable, Sendable {
    public var routerNames: Set<String>
    public var routerPortNames: Set<String>
    public var switchRouterPortNames: Set<String>
    public var externalSwitchNames: Set<String>
    public var snatRules: Set<SNATRuleKey>

    public init(
        routerNames: Set<String> = [],
        routerPortNames: Set<String> = [],
        switchRouterPortNames: Set<String> = [],
        externalSwitchNames: Set<String> = [],
        snatRules: Set<SNATRuleKey> = []
    ) {
        self.routerNames = routerNames
        self.routerPortNames = routerPortNames
        self.switchRouterPortNames = switchRouterPortNames
        self.externalSwitchNames = externalSwitchNames
        self.snatRules = snatRules
    }

    public var isEmpty: Bool {
        routerNames.isEmpty && routerPortNames.isEmpty && switchRouterPortNames.isEmpty
            && externalSwitchNames.isEmpty && snatRules.isEmpty
    }
}

// MARK: - Reconciler

/// Pure planning for L3 network reconciliation. No side effects, fully testable.
public enum NetworkReconciler {

    /// Build the desired OVN topology from the control plane's desired networks.
    ///
    /// * One tenant switch per network.
    /// * Networks grouped by `routerKey` share one logical router; each network
    ///   with a gateway contributes a router port (its L3 gateway) — this is
    ///   what gives cross-switch east-west within a project.
    /// * A network with a gateway and `externalAccess` contributes a SNAT subnet
    ///   on its router — outbound internet.
    /// * A router-key group with no gatewayed network yields no router (nothing
    ///   to route). Output is fully sorted, so the plan is deterministic.
    public static func plan(networks: [DesiredNetworkState]) -> NetworkTopologyPlan {
        let sorted = networks.sorted { $0.name < $1.name }

        let switches = sorted.map {
            DesiredSwitch(
                name: OVNNaming.switchName(networkId: $0.networkId), subnet: $0.subnet, legacyName: $0.name)
        }

        // Group by router key, preserving deterministic order.
        var groups: [String: [DesiredNetworkState]] = [:]
        for network in sorted { groups[network.routerKey, default: []].append(network) }

        var routers: [DesiredRouter] = []
        for routerKey in groups.keys.sorted() {
            let members = groups[routerKey] ?? []
            var ports: [DesiredRouterPort] = []
            var snatSubnets: [String] = []

            for network in members {
                // L3 needs a gateway (the router-port IP) and a prefix from the
                // subnet CIDR; a network missing either is switch-only.
                guard let gateway = network.gateway,
                    let prefix = prefixLength(ofCIDR: network.subnet),
                    let mac = OVNNaming.routerPortMAC(gateway: gateway)
                else { continue }

                ports.append(
                    DesiredRouterPort(
                        name: OVNNaming.routerPortName(networkId: network.networkId),
                        switchName: OVNNaming.switchName(networkId: network.networkId),
                        switchPortName: OVNNaming.switchRouterPortName(networkId: network.networkId),
                        mac: mac,
                        cidr: "\(gateway)/\(prefix)"))

                if network.externalAccess {
                    snatSubnets.append(network.subnet)
                }
            }

            // No gatewayed network in this group → no router to create.
            guard !ports.isEmpty else { continue }

            routers.append(
                DesiredRouter(
                    name: OVNNaming.routerName(routerKey: routerKey),
                    routerKey: routerKey,
                    ports: ports,
                    snatSubnets: snatSubnets))
        }

        return NetworkTopologyPlan(switches: switches, routers: routers)
    }

    /// The OVN objects protected from teardown for the networks a sync skipped
    /// as stale — every object each (and its shared router/uplink) could own, so
    /// a stale network keeps its live objects. Pass ONLY the stale-skipped
    /// networks: current networks are governed by the plan so their dropped
    /// objects are still torn down. SNAT is protected precisely by (router,
    /// subnet) so a stale network shields only its own SNAT on a shared router.
    public static func protectedTopology(forStale stale: [DesiredNetworkState]) -> ProtectedTopology {
        var protected = ProtectedTopology()
        for network in stale {
            let routerName = OVNNaming.routerName(routerKey: network.routerKey)
            protected.routerPortNames.insert(OVNNaming.routerPortName(networkId: network.networkId))
            protected.switchRouterPortNames.insert(
                OVNNaming.switchRouterPortName(networkId: network.networkId))
            protected.routerNames.insert(routerName)
            protected.externalSwitchNames.insert(OVNNaming.externalSwitchName(routerKey: network.routerKey))
            protected.routerPortNames.insert(OVNNaming.externalRouterPortName(routerKey: network.routerKey))
            protected.switchRouterPortNames.insert(
                OVNNaming.externalSwitchRouterPortName(routerKey: network.routerKey))
            protected.snatRules.insert(SNATRuleKey(router: routerName, logicalIP: network.subnet))
        }
        return protected
    }

    /// Owned OVN objects present on the host that the plan no longer wants,
    /// ordered so dependents are removed before the objects they reference
    /// (SNAT rules and peered ports before their routers/switches). Objects in
    /// `protected` are never torn down — they belong to a network still present
    /// in the sync whose (stale) generation kept it out of the applied plan.
    public static func teardownActions(
        desired: NetworkTopologyPlan,
        observed: ObservedNetworkTopology,
        protected: ProtectedTopology = ProtectedTopology()
    ) -> [NetworkTeardownAction] {
        let want = desired.expectedTopology
        var actions: [NetworkTeardownAction] = []

        for rule in observed.snatRules.subtracting(want.snatRules).sorted(by: snatOrder)
        where !protected.snatRules.contains(rule) {
            actions.append(.snat(router: rule.router, logicalIP: rule.logicalIP))
        }
        for name in observed.switchRouterPortNames.subtracting(want.switchRouterPortNames).sorted()
        where !protected.switchRouterPortNames.contains(name) {
            actions.append(.switchRouterPort(name: name))
        }
        for name in observed.routerPortNames.subtracting(want.routerPortNames).sorted()
        where !protected.routerPortNames.contains(name) {
            actions.append(.routerPort(name: name))
        }
        for name in observed.externalSwitchNames.subtracting(want.externalSwitchNames).sorted()
        where !protected.externalSwitchNames.contains(name) {
            actions.append(.externalSwitch(name: name))
        }
        for name in observed.routerNames.subtracting(want.routerNames).sorted()
        where !protected.routerNames.contains(name) {
            actions.append(.router(name: name))
        }
        return actions
    }

    // MARK: - Helpers

    /// The prefix length of a CIDR string such as `192.168.1.0/24` → 24.
    static func prefixLength(ofCIDR cidr: String) -> Int? {
        guard let slash = cidr.firstIndex(of: "/") else { return nil }
        let value = cidr[cidr.index(after: slash)...]
        guard let prefix = Int(value), (0...32).contains(prefix) else { return nil }
        return prefix
    }

    private static func snatOrder(_ a: SNATRuleKey, _ b: SNATRuleKey) -> Bool {
        (a.router, a.logicalIP) < (b.router, b.logicalIP)
    }
}

// MARK: - Actuator and apply orchestration

/// The live OVN side effects the reconciler drives, implemented by
/// `NetworkServiceLinux`. Every method must be idempotent at the "already
/// satisfied" level — level-triggered syncs re-drive them — so ensuring a
/// router that exists or removing one that is already gone is a no-op.
public protocol NetworkActuator: Sendable {
    /// Snapshot of the L3 objects this reconciler owns, from OVSDB.
    func observeTopology() async throws -> ObservedNetworkTopology
    func ensureSwitch(_ desired: DesiredSwitch) async throws
    func ensureRouter(_ router: DesiredRouter) async throws
    /// Create the tenant router port and its peering `type=router` switch port.
    func ensureRouterPort(_ port: DesiredRouterPort, onRouter routerName: String) async throws
    /// Ensure the external uplink attachment (external switch + localnet + a
    /// gateway router port) for a router that needs SNAT. Returns false when the
    /// host has no detectable uplink, in which case SNAT is skipped this pass.
    func ensureUplink(for router: DesiredRouter) async throws -> Bool
    func ensureSNAT(router routerName: String, logicalIP: String) async throws
    func removeSNAT(router routerName: String, logicalIP: String) async throws
    func removeSwitchRouterPort(name: String) async throws
    func removeRouterPort(name: String) async throws
    func removeExternalSwitch(name: String) async throws
    func removeRouter(name: String) async throws
}

extension NetworkReconciler {
    /// Converge the host's OVN L3 topology toward the desired networks. Ensures
    /// desired objects first (idempotent), then tears down owned objects the
    /// plan no longer wants. Best-effort per object: a single failing network is
    /// logged and skipped so it can't stall the rest of the sync — the periodic
    /// level-triggered sync retries it. Throws only when the topology snapshot
    /// itself can't be read (teardown can't be computed safely without it).
    public static func reconcile(
        networks: [DesiredNetworkState],
        actuator: any NetworkActuator,
        logger: Logger,
        protected: ProtectedTopology = ProtectedTopology()
    ) async throws {
        let topology = plan(networks: networks)

        for desired in topology.switches {
            await attempt(logger, "ensure switch \(desired.name)") {
                try await actuator.ensureSwitch(desired)
            }
        }

        for router in topology.routers {
            let ensured = await attempt(logger, "ensure router \(router.name)") {
                try await actuator.ensureRouter(router)
            }
            guard ensured else { continue }

            for port in router.ports {
                await attempt(logger, "ensure router port \(port.name)") {
                    try await actuator.ensureRouterPort(port, onRouter: router.name)
                }
            }

            guard router.needsUplink else { continue }
            var uplinkReady = false
            _ = await attempt(logger, "ensure uplink for \(router.name)") {
                uplinkReady = try await actuator.ensureUplink(for: router)
            }
            guard uplinkReady else {
                logger.warning(
                    "No detectable host uplink; skipping SNAT this pass",
                    metadata: ["router": .string(router.name)])
                continue
            }
            for subnet in router.snatSubnets {
                await attempt(logger, "ensure SNAT \(subnet) on \(router.name)") {
                    try await actuator.ensureSNAT(router: router.name, logicalIP: subnet)
                }
            }
        }

        let observed = try await actuator.observeTopology()
        for action in teardownActions(desired: topology, observed: observed, protected: protected) {
            await attempt(logger, "teardown \(action)") {
                switch action {
                case .snat(let router, let logicalIP):
                    try await actuator.removeSNAT(router: router, logicalIP: logicalIP)
                case .switchRouterPort(let name):
                    try await actuator.removeSwitchRouterPort(name: name)
                case .routerPort(let name):
                    try await actuator.removeRouterPort(name: name)
                case .externalSwitch(let name):
                    try await actuator.removeExternalSwitch(name: name)
                case .router(let name):
                    try await actuator.removeRouter(name: name)
                }
            }
        }
    }

    /// Run one side effect, logging and swallowing its error. Returns whether it
    /// succeeded, so callers can skip dependent steps for a failed object.
    @discardableResult
    private static func attempt(
        _ logger: Logger, _ what: String, _ body: () async throws -> Void
    ) async -> Bool {
        do {
            try await body()
            return true
        } catch {
            logger.error(
                "Network reconcile step failed",
                metadata: ["step": .string(what), "error": .string(error.localizedDescription)])
            return false
        }
    }
}
