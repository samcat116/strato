import Foundation
import StratoShared

/// The layout of one network's resolver state on disk.
///
/// Every path is derived from the network id under one configured root, the
/// `VMDirectoryLayout` convention: an agent that restarts rederives all of them
/// with no retained state, which is also what lets it find and reap the
/// directories of networks it no longer serves.
public struct ResolverDirectoryLayout: Equatable, Sendable {
    public let root: String

    public init(root: String) {
        self.root = root
    }

    /// One directory for the host, since one process serves every network. Zone
    /// files are namespaced *inside* it by network id — see
    /// `CoreDNSZoneRenderer.zoneFilePath` — because two networks may attach
    /// zones with the same name and different contents.
    public var directory: String { root }
    public var corefilePath: String { "\(root)/Corefile" }
    public var zonesDirectory: String { "\(root)/zones" }
    /// Where the supervisor records the pid it started, so a restarted agent
    /// adopts a running CoreDNS instead of starting a second one beside it.
    public var pidFilePath: String { "\(root)/coredns.pid" }
}

/// The host's rendered resolver configuration.
public struct DesiredResolver: Equatable, Sendable {
    /// The rendered Corefile and zone files, relative to the resolver root.
    public let files: [CoreDNSZoneRenderer.RenderedFile]
    /// Notes about records that could not be rendered, logged once per change
    /// rather than once per sync.
    public let diagnostics: [String]

    /// Whether any network wants a resolver at all. Distinct from "no files":
    /// a host serving nothing still renders a Corefile, and the difference
    /// between that and a real one is what decides whether the process runs.
    public let servesNothing: Bool

    public init(
        files: [CoreDNSZoneRenderer.RenderedFile], diagnostics: [String] = [],
        servesNothing: Bool = false
    ) {
        self.files = files
        self.diagnostics = diagnostics
        self.servesNothing = servesNothing
    }

    /// A digest of the rendered configuration, used to decide whether anything
    /// on disk has to change. Content-addressed rather than compared file by
    /// file so "did this network's resolver config change" is one string
    /// comparison per sync — the same argument `DesiredDNSZone.recordsHash`
    /// makes, applied one layer down.
    public var configurationDigest: String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        func update(_ text: String) {
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 1_099_511_628_211
            }
        }
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            update(file.relativePath)
            update("\u{0}")
            update(file.contents)
            update("\u{0}")
        }
        return String(format: "%016llx", hash)
    }
}

/// A cheap digest of everything one network's rendering depends on, so an
/// unchanged network can skip the render entirely.
///
/// The render is O(records) string building, and a zone's records span every VM
/// on every attached network *fleet-wide* — so its cost grows with the cluster
/// rather than with this host, while the overwhelmingly common outcome is a
/// digest that matches and a result thrown away. This is the same hash-skip the
/// OVN driver already does one layer up with `external_ids`, and it reuses the
/// control plane's own `recordsHash` rather than computing a new one.
public struct ResolverRenderKey: Equatable, Sendable {
    private let value: String

    public init(
        zoneHashes: [String], upstreams: [String], searchDomain: String?, bindAddresses: [String]
    ) {
        // Length-prefixed for `DNSZoneAssembler.recordsHash`'s reason: every
        // component is operator-supplied text, so any separator is one an
        // operator can author, and two different inputs colliding is the single
        // failure a change detector must not have.
        func field(_ text: String) -> String { "\(text.utf8.count):\(text)" }
        self.value =
            (zoneHashes.sorted() + ["|"] + upstreams + ["|"] + [searchDomain ?? ""] + ["|"]
            + bindAddresses)
            .map(field).joined()
    }
}

/// Everything this host's single resolver serves, as inputs rather than as
/// rendered files.
///
/// One request for the whole host rather than one per network, because there is
/// one CoreDNS: it binds every network's addresses and keys each server block on
/// the address the query arrived at. Rendering is skipped wholesale when
/// `renderKey` has not moved.
public struct ResolverRenderRequest: Sendable {
    public let networks: [CoreDNSZoneRenderer.Network]

    public init(networks: [CoreDNSZoneRenderer.Network]) {
        self.networks = networks
    }

    public var isEmpty: Bool { networks.isEmpty }

    public var renderKey: ResolverRenderKey {
        ResolverRenderKey(
            zoneHashes: networks.flatMap { network in
                // The network id is folded in beside each hash so two networks
                // swapping zones is not the same key as neither changing.
                network.zones.map { "\(network.networkId.uuidString):\($0.recordsHash)" }
            },
            upstreams: networks.flatMap { ["\($0.networkId.uuidString)"] + $0.upstreams },
            searchDomain: networks.map { $0.searchDomain ?? "" }.joined(separator: ","),
            bindAddresses: networks.flatMap(\.bindAddresses))
    }

    /// The rendered configuration for the whole host.
    public func render() -> DesiredResolver {
        let rendering = CoreDNSZoneRenderer.render(networks: networks)
        return DesiredResolver(
            files: rendering.files, diagnostics: rendering.diagnostics,
            servesNothing: networks.isEmpty)
    }
}

/// What the supervisor knows about the host's resolver right now.
public struct ObservedResolver: Equatable, Sendable {
    public let pid: Int32?
    /// Whether that process is actually alive.
    public let running: Bool
    /// The digest of the configuration last written.
    public let configurationDigest: String?
    /// Consecutive unexpected exits since the last successful run.
    public let consecutiveFailures: Int

    public init(
        pid: Int32? = nil, running: Bool = false, configurationDigest: String? = nil,
        consecutiveFailures: Int = 0
    ) {
        self.pid = pid
        self.running = running
        self.configurationDigest = configurationDigest
        self.consecutiveFailures = consecutiveFailures
    }
}

/// One side effect the supervisor should perform.
public enum ResolverAction: Equatable, Sendable {
    /// Write the rendered files. Always precedes a start, and stands alone when
    /// a running CoreDNS can pick the change up itself.
    case writeConfiguration
    /// Start the host's CoreDNS.
    case start
    /// Stop it and remove its directory.
    case stop
}

/// The pure half of resolver supervision: what to do, given what is wanted and
/// what is running.
///
/// Separated from the actor for `ChassisServicePlan`'s reason — the actor lives
/// in the executable target and no test can reach it — and because the decisions
/// here are the ones with teeth. Restarting when a reload would do costs the
/// network a resolution gap; not restarting when a restart was needed leaves it
/// serving stale names indefinitely.
public enum ResolverSupervisionPolicy {
    /// How long to wait before restarting a CoreDNS that exited, indexed by how
    /// many times it has now failed in a row.
    ///
    /// Backoff rather than immediate restart because the failures this protects
    /// against are not transient: a Corefile CoreDNS refuses to parse, or a port
    /// something else holds, fails identically every time, and a hot loop of
    /// `exec` would be a busier neighbour on the hypervisor than the query flood
    /// the policer exists to stop.
    ///
    /// Capped rather than unbounded: the resolver is a service a network needs,
    /// so a host that has been broken for an hour should still be retrying at a
    /// rate that recovers promptly once an operator fixes it.
    public static func restartDelay(consecutiveFailures: Int) -> Duration {
        // The *exponent* is clamped, not just the result. Swift's `<<` on `Int`
        // is a non-trapping smart shift, so `1 << 63` is `Int.min` and anything
        // beyond over-shifts to 0 — a resolver that had been failing for an hour
        // would back off politely and then enter a hot `exec` loop, which is
        // exactly what this exists to prevent.
        let exponent = min(max(consecutiveFailures - 1, 0), 6)
        return .seconds(min(1 << exponent, 60))
    }

    /// The shortest run that counts as the resolver having actually worked.
    ///
    /// The counter `restartDelay` and `isCrashLooping` read has to be cleared by
    /// a *run*, not by a successful `fork`. Every failure the backoff exists for
    /// — a Corefile CoreDNS refuses to parse, `:53` already held by an orphan —
    /// spawns cleanly and exits a moment later, so clearing on spawn would pin
    /// the delay at its first step forever and `crashLoopThreshold` would never
    /// be reached. The operator would see "will restart" indefinitely and never
    /// the error saying it is not coming back.
    ///
    /// 30s is comfortably longer than any of those failures take to surface
    /// (CoreDNS parses its Corefile and binds before it serves anything) and
    /// comfortably shorter than any legitimate lifetime, so it separates the two
    /// without needing to know which failure occurred.
    public static let healthyRuntimeSeconds: TimeInterval = 30

    /// Whether a child that ran for `ranForSeconds` before exiting should clear
    /// the consecutive-failure count.
    public static func runProvedHealthy(ranForSeconds: TimeInterval) -> Bool {
        ranForSeconds >= healthyRuntimeSeconds
    }

    /// The number of consecutive failures past which the supervisor should log
    /// at error rather than warning, and report the resolver as unhealthy.
    ///
    /// Three, not one: a single exit is what a restart during a config change
    /// looks like, and paging on it would make every zone edit noisy.
    public static let crashLoopThreshold = 3

    /// Whether `failures` consecutive exits constitute a crash loop worth
    /// surfacing.
    public static func isCrashLooping(consecutiveFailures: Int) -> Bool {
        consecutiveFailures >= crashLoopThreshold
    }

    /// The actions that converge this host toward `desired`.
    ///
    /// `desired` nil ≙ a sync with no opinion about resolvers at all: no
    /// actions, so silence never stops a running one. An empty (non-nil) list is
    /// an opinion and stops everything, which is what makes turning the feature
    /// off on every network actually work.
    ///
    /// **A configuration change alone does not restart CoreDNS.** The rendered
    /// Corefile carries `reload`, and the `file` plugin watches its zone files,
    /// so a running process picks up a record edit within seconds — and every
    /// second of a restart is a second in which this network resolves nothing
    /// but what OVN can answer. A start is emitted only when nothing is running.
    public static func actions(
        desired: DesiredResolver?, observed: ObservedResolver
    ) -> [ResolverAction] {
        guard let desired else { return [] }
        // Nothing to serve: stop the process rather than leave it bound to
        // addresses no network publishes any more.
        guard !desired.servesNothing else {
            return observed.running ? [.stop] : []
        }
        var actions: [ResolverAction] = []
        if observed.configurationDigest != desired.configurationDigest {
            actions.append(.writeConfiguration)
        }
        if !observed.running { actions.append(.start) }
        return actions
    }

    /// Whether this host can bind the IPv6 half of a network's resolver pair.
    ///
    /// `bind` naming a non-existent address makes CoreDNS refuse to start — and
    /// refuse for *every* network, now that one process serves them all, which
    /// is the sharpest edge the single process introduces. `/proc/net/if_inet6`
    /// is the kernel-wide switch, and its absence is exactly the condition under
    /// which the interface's `addr add` for the ULA failed.
    public static func supportsIPv6(
        probe: Bool = FileManager.default.fileExists(atPath: "/proc/net/if_inet6")
    ) -> Bool { probe }

    /// The subset of a network's addresses this host can actually bind.
    public static func bindable(_ addresses: [String], ipv6Available: Bool) -> [String] {
        ipv6Available ? addresses : addresses.filter { IPv4Address($0) != nil }
    }

    /// The files that should exist, so the supervisor can delete the ones left
    /// over from a zone that was renamed, detached, or whose network is gone.
    ///
    /// Stale zone files are not inert: the Corefile stops referencing a removed
    /// zone, but a file left on disk is a name an operator debugging the host
    /// will read as still served.
    public static func expectedRelativePaths(_ resolver: DesiredResolver) -> Set<String> {
        Set(resolver.files.map(\.relativePath))
    }
}
