import Foundation
import Logging
import StratoShared
import StratoAgentCore

#if os(Linux)
import SwiftOVN
#endif

actor NetworkServiceLinux: NetworkServiceProtocol {
    let logger: Logger
    /// OVN NB connection string in OVN syntax (`unix:<path>`, `tcp:<host>:<port>`,
    /// `ssl:<host>:<port>`). Defaults to the legacy per-node local socket; a
    /// site's agents all point it at the site's shared ovn-central (issue #343).
    let ovnNBConnection: String
    /// TLS material for an `ssl:` NB endpoint (CA, client cert/key). Nil for
    /// `unix:`/`tcp:` connections, or for `ssl:` with system trust roots.
    let ovnNBTLS: OVNNorthboundTLSConfig?
    let ovsSocketPath: String
    let chassisConfig: OVNChassisConfig
    /// Site uplink for SNAT egress; nil disables SNAT (issue #342). SNAT needs a
    /// dedicated external IP the host doesn't own, so it is explicit config.
    let uplinkConfig: OVNUplinkConfig?
    /// OVN native dynamic routing (issue #344): BGP advertisement of floating
    /// IPs / tenant routes via FRR. Nil or disabled strips any previously
    /// applied `dynamic-routing*` options during reconcile.
    let dynamicRoutingConfig: OVNDynamicRoutingConfig?
    /// Absolute paths to iproute2's `ip` and `tc`, plus procps's `sysctl`,
    /// resolved once at agent start. The sandbox netns path invokes them directly
    /// rather than through `/usr/bin/env` like the host-namespace path does: a
    /// service manager's stripped `PATH` must not break namespace attachment on
    /// a host the start-time probe already declared usable. Nil means the host
    /// has no such binary, and networked sandboxes are refused with that reason
    /// instead of failing halfway through wiring one up.
    let ipBinaryPath: String?
    let tcBinaryPath: String?
    let sysctlBinaryPath: String?
    /// Aggregate ingress packet-rate cap on each of a network's link-local
    /// service interfaces (STR-40); 0 disables the policer. Applied to *both*
    /// feet — the metadata one in the network's chassis namespace and the
    /// resolver one in the host's — because since ADR 0008 they are separate
    /// devices and each carries its own traffic. Operator-configurable
    /// (`[resolver] rate_limit_pps`) because the right ceiling depends on how
    /// many guests share a hypervisor.
    let linkLocalServiceRatePPS: Int
    /// Runs the host's CoreDNS, which serves every resolver-enabled network this
    /// host has a NIC on (STR-40). Nil when the host has no usable CoreDNS
    /// binary, in which case the agent also registers `resolverCapable: false`
    /// and the control plane withholds the resolver from every network in the
    /// site — so this being nil while networks still want a resolver is a
    /// mixed-version window, not a steady state.
    let resolverSupervisor: ResolverSupervisor?

    /// Whether this agent may author NB topology (switches, routers, NAT,
    /// teardown), per the control plane's last sync. False on agents sharing a
    /// site NB that another agent (the site's network controller) writes; such
    /// agents only bind their own VMs' ports. Defaults true: an agent that has
    /// never received a sync owns its local NB (the legacy model).
    var topologyAuthority = true

    /// Highest network `generation` this agent has applied, per network id. A
    /// full-list sync whose entry for a network is older than what's recorded is
    /// stale (actor-reentrancy reordering of two fetched payloads)
    /// and is skipped, so it can't roll the network's L3 realization backward —
    /// the same guard the VM reconciler applies per VM.
    var networkGenerations: [UUID: Int64] = [:]
    var lastObservedLoadBalancers: [ObservedLoadBalancerState]?

    #if os(Linux)
    var ovnManager: OVNManager?
    /// Read-only Southbound connection used for Service_Monitor health. The
    /// NB manager cannot read this table even when both databases share one
    /// ovn-central process.
    var ovnSouthboundManager: OVNManager?
    var ovsManager: OVSManager?
    var isConnected = false
    #endif

    init(
        nbConnection: String? = nil,
        nbTLS: OVNNorthboundTLSConfig? = nil,
        ovsSocketPath: String = "/var/run/openvswitch/db.sock",
        chassisConfig: OVNChassisConfig = OVNChassisConfig(),
        uplink: OVNUplinkConfig? = nil,
        dynamicRouting: OVNDynamicRoutingConfig? = nil,
        ipBinaryPath: String? = nil,
        tcBinaryPath: String? = nil,
        sysctlBinaryPath: String? = nil,
        linkLocalServiceRatePPS: Int = NetworkResolverDefaults.rateLimitPPS,
        resolverSupervisor: ResolverSupervisor? = nil,
        logger: Logger
    ) {
        self.ovnNBConnection = nbConnection ?? "unix:/var/run/ovn/ovnnb_db.sock"
        self.ovnNBTLS = nbTLS
        self.ovsSocketPath = ovsSocketPath
        self.chassisConfig = chassisConfig
        self.uplinkConfig = uplink
        self.dynamicRoutingConfig = dynamicRouting
        self.ipBinaryPath = ipBinaryPath
        self.tcBinaryPath = tcBinaryPath
        self.sysctlBinaryPath = sysctlBinaryPath
        self.linkLocalServiceRatePPS = linkLocalServiceRatePPS
        self.resolverSupervisor = resolverSupervisor
        self.logger = logger

        #if os(Linux)
        logger.info("Network service initialized with SwiftOVN support")
        #else
        logger.warning("Network service running in development mode - operations will be mocked")
        #endif
    }

    /// Bridge that OVN's `ovn-controller` binds VM ports onto.
    static let ovnIntegrationBridge = "br-int"

    /// External-id ownership marker stamped on every OVN object the reconciler
    /// creates, so teardown can identify its own objects without relying on name
    /// prefixes (which an operator or another feature might also use).
    static let managedKey = "strato-managed"
    static let managedValue = "true"
    /// Distinguishes the external/provider logical switch from tenant switches
    /// (both are `Logical_Switch`es), so only external switches are teardown
    /// candidates.
    static let externalRoleKey = "strato-role"
    static let externalRoleValue = "external"
    /// OVN port type for the metadata port (STR-49). `localport` is instantiated
    /// on every chassis by `ovn-controller` and never forwarded across geneve
    /// tunnels, which is what lets one address be published on every switch in a
    /// site and still reach the guest's own host.
    static let localPortType = "localport"

    /// Whether an OVN object's external-ids mark it as created by this reconciler.
    static func isManaged(_ externalIDs: [String: String]?) -> Bool {
        externalIDs?[managedKey] == managedValue
    }

    /// OVN logical switch port name for one NIC of a VM. Delegates to
    /// `OVNNaming` so the control-plane-driven floating IP path derives the
    /// same name for a NIC's port (issue #344).
    static func portName(vmId: String, nicIndex: Int) -> String {
        OVNNaming.vmPortName(vmId: vmId, nicIndex: nicIndex)
    }

    /// OVN logical switch port name for one NIC of any workload. Sandbox NICs
    /// take the disjoint `sbx-` namespace so the two kinds of port are
    /// distinguishable in OVN and OVS (issue STR-100).
    static func portName(workloadId: String, nicIndex: Int, placement: NICPlacement) -> String {
        OVNNaming.portName(workloadId: workloadId, nicIndex: nicIndex, placement: placement)
    }

    /// Bound on `ovs-vsctl` so a config change can't hang the network actor
    /// forever when `ovs-vswitchd` is down/overloaded (the default waits forever).
    static let ovsCommandTimeoutSeconds = 10

    /// How many times to re-read a freshly attached port's `ofport` before
    /// giving up, and the pause between attempts. Small: `ovs-vsctl` already
    /// waits for `ovs-vswitchd`, so this only covers a narrow assignment window.
    static let ovsBindingReadbackAttempts = 3
    static let ovsBindingReadbackDelay: Duration = .milliseconds(50)

    /// Bound on each `ip`/`tc` invocation in the sandbox namespace path, so a
    /// wedged child cannot park the attach forever. Generous: these are local
    /// netlink operations that answer in milliseconds.
    static let netnsCommandTimeout: Duration = .seconds(15)
}
