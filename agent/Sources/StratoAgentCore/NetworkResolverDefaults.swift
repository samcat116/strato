import Foundation

/// Host-side defaults for the per-network DNS resolver (STR-40).
///
/// Separate from `AgentConfig` so the pure planning types can reach them
/// without importing the config parser, the way `SandboxJailerResolver` keeps
/// its binary candidates beside the plan that consumes them.
public enum NetworkResolverDefaults {
    /// Aggregate ingress packet-rate cap on a network's chassis service
    /// interface, in packets per second. 0 disables the policer.
    ///
    /// 1024 is AWS's published ceiling for its link-local services, taken here
    /// for the same reason the addresses were: it is a number operators have
    /// already sized workloads against. It is an *aggregate* over everything the
    /// interface terminates — DNS and instance metadata together — because what
    /// it protects is the hypervisor, not either service.
    public static let rateLimitPPS = 1024

    /// Where the agent renders each network's Corefile and zone files.
    ///
    /// Under `/var/lib` rather than `/run`: not because the content is precious
    /// (it is rederived from desired state on every sync) but because a resolver
    /// that survives a reboot without waiting for the first sync is one fewer
    /// window in which guests cannot resolve anything.
    public static let configDirectory = "/var/lib/strato/resolver"

    /// Where a CoreDNS binary is usually installed, in probe order. Mirrors
    /// `SandboxJailerResolver.ipBinaryCandidates`.
    public static let corednsBinaryCandidates = [
        "/usr/local/bin/coredns",
        "/usr/bin/coredns",
        "/opt/coredns/coredns",
    ]

    /// Where the procps `sysctl` binary is usually installed, in probe order.
    /// Resolver host-port setup writes per-interface isolation knobs through
    /// this executable; iproute2's `ip` has no `sysctl` subcommand.
    public static let sysctlBinaryCandidates = [
        "/usr/sbin/sysctl",
        "/sbin/sysctl",
        "/usr/bin/sysctl",
        "/bin/sysctl",
    ]

    /// Resolves the `sysctl` binary the resolver host-port plan invokes.
    public static func resolveSysctlBinaryPath(
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        sysctlBinaryCandidates.first(where: isExecutable)
    }

    /// Resolves the CoreDNS binary, preferring an explicit configuration.
    ///
    /// Returns nil when nothing usable is present, which is not an error: the
    /// agent registers with `resolverCapable: false` and the control plane
    /// withholds the resolver from every network in the site rather than
    /// pointing guests at an address nothing answers on.
    public static func resolveBinaryPath(
        configured: String?,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let configured, !configured.isEmpty {
            return isExecutable(configured) ? configured : nil
        }
        return corednsBinaryCandidates.first(where: isExecutable)
    }
}

/// One network's resolver configuration, as the agent's own workload specs
/// describe it (STR-40).
///
/// Carried per network rather than read from `DesiredNetworkState`, for
/// `ChassisServicePlan`'s reason: a sited agent that is not its site's network
/// controller receives an empty `networks` list and still has guests whose
/// resolver it must run, so the NIC specs are the only input it has.
public struct ResolverNetworkConfig: Equatable, Sendable {
    public let networkId: UUID
    /// This network's own resolver addresses, v4 first — what its guests are
    /// pointed at, what the host binds, and what its routing rule keys on.
    public let addresses: [String]
    /// What the resolver forwards misses to — the network's `dnsServers` under
    /// their post-STR-40 reading.
    public let upstreams: [String]
    /// The network's search domain, recorded in the rendered Corefile for an
    /// operator's benefit. Not a resolution mechanism: the guest's own `search`
    /// list is what qualifies a bare name.
    public let searchDomain: String?

    public init(networkId: UUID, addresses: [String], upstreams: [String], searchDomain: String?) {
        self.networkId = networkId
        self.addresses = addresses
        self.upstreams = upstreams
        self.searchDomain = searchDomain
    }
}

/// The `[resolver]` section of the agent's TOML config (STR-40).
///
/// Every field is optional so a host that says nothing gets
/// `NetworkResolverDefaults` — which is the right default because the feature is
/// an opt-out on the *network*: an operator who never touched this file still
/// expects their networks' resolvers to work.
public struct NetworkResolverConfig: Codable, Sendable, Equatable {
    /// The host-side escape hatch. False makes this agent report
    /// `resolverCapable: false`, which withholds the resolver from every network
    /// in its site — not just from this host, because a network's guests must
    /// not get an address that answers on only some hypervisors.
    public let enabled: Bool
    /// An explicit CoreDNS path. When set and not executable, discovery does
    /// *not* fall back to the usual locations: an operator who named a binary
    /// meant that one, and silently running a different build is how a host
    /// serves DNS from something nobody deployed.
    public let corednsBinaryPath: String?
    public let configDirectory: String?
    /// Aggregate ingress packet-rate cap per network interface; 0 disables it.
    public let rateLimitPPS: Int?

    public init(
        enabled: Bool = true, corednsBinaryPath: String? = nil, configDirectory: String? = nil,
        rateLimitPPS: Int? = nil
    ) {
        self.enabled = enabled
        self.corednsBinaryPath = corednsBinaryPath
        self.configDirectory = configDirectory
        self.rateLimitPPS = rateLimitPPS
    }

    public var effectiveConfigDirectory: String {
        configDirectory ?? NetworkResolverDefaults.configDirectory
    }
    public var effectiveRateLimitPPS: Int {
        rateLimitPPS ?? NetworkResolverDefaults.rateLimitPPS
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case corednsBinaryPath = "coredns_binary_path"
        case configDirectory = "config_dir"
        case rateLimitPPS = "rate_limit_pps"
    }
}
