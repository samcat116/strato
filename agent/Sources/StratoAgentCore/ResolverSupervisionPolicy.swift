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
    public let networkId: UUID

    public init(root: String, networkId: UUID) {
        self.root = root
        self.networkId = networkId
    }

    /// Everything for one network. Named by id, never by the network's name:
    /// names are unique only within a project, and two projects' networks would
    /// otherwise share a directory.
    public var directory: String { "\(root)/\(networkId.uuidString.lowercased())" }
    public var corefilePath: String { "\(directory)/Corefile" }
    public var zonesDirectory: String { "\(directory)/zones" }
    /// Where the supervisor records the pid it started, so a restarted agent
    /// adopts a running CoreDNS instead of starting a second one beside it.
    public var pidFilePath: String { "\(directory)/coredns.pid" }
}

/// The desired resolver for one network, as the supervisor needs it.
public struct DesiredResolver: Equatable, Sendable {
    public let networkId: UUID
    /// The rendered Corefile and zone files, relative to the network's
    /// directory.
    public let files: [CoreDNSZoneRenderer.RenderedFile]
    /// Notes about records that could not be rendered, logged once per change
    /// rather than once per sync.
    public let diagnostics: [String]

    public init(
        networkId: UUID, files: [CoreDNSZoneRenderer.RenderedFile], diagnostics: [String] = []
    ) {
        self.networkId = networkId
        self.files = files
        self.diagnostics = diagnostics
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

/// What the supervisor knows about one network's resolver right now.
public struct ObservedResolver: Equatable, Sendable {
    public let networkId: UUID
    /// The process the supervisor believes is serving this network, if any.
    public let pid: Int32?
    /// Whether that process is actually alive.
    public let running: Bool
    /// The digest of the configuration last written for this network.
    public let configurationDigest: String?
    /// Consecutive unexpected exits since the last successful run.
    public let consecutiveFailures: Int

    public init(
        networkId: UUID, pid: Int32? = nil, running: Bool = false,
        configurationDigest: String? = nil, consecutiveFailures: Int = 0
    ) {
        self.networkId = networkId
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
    case writeConfiguration(networkId: UUID)
    /// Start CoreDNS for this network.
    case start(networkId: UUID)
    /// Stop this network's CoreDNS and remove its directory.
    case stop(networkId: UUID)
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
        desired: [DesiredResolver]?, observed: [ObservedResolver]
    ) -> [ResolverAction] {
        guard let desired else { return [] }
        let byNetwork = Dictionary(
            observed.map { ($0.networkId, $0) }, uniquingKeysWith: { first, _ in first })
        var actions: [ResolverAction] = []

        for resolver in desired.sorted(by: { $0.networkId.uuidString < $1.networkId.uuidString }) {
            let current = byNetwork[resolver.networkId]
            if current?.configurationDigest != resolver.configurationDigest {
                actions.append(.writeConfiguration(networkId: resolver.networkId))
            }
            if current?.running != true {
                actions.append(.start(networkId: resolver.networkId))
            }
        }

        let wanted = Set(desired.map(\.networkId))
        for resolver in observed.sorted(by: { $0.networkId.uuidString < $1.networkId.uuidString })
        where !wanted.contains(resolver.networkId) {
            actions.append(.stop(networkId: resolver.networkId))
        }
        return actions
    }

    /// The addresses CoreDNS should `bind` in a namespace on this host.
    ///
    /// The v6 ULA is included only when the kernel has IPv6 at all, because
    /// `bind` naming a non-existent address makes CoreDNS refuse to start — and
    /// `ChassisServicePlan` establishes both families independently precisely so
    /// an IPv6-less host keeps a working v4 service. `/proc/net/if_inet6` is the
    /// kernel-wide switch, and its absence is exactly the condition under which
    /// the namespace's `addr add` for the ULA failed.
    public static func bindAddresses(
        ipv6Available: Bool = FileManager.default.fileExists(atPath: "/proc/net/if_inet6")
    ) -> [String] {
        ipv6Available
            ? NetworkResolverEndpoint.addresses
            : [NetworkResolverEndpoint.address]
    }

    /// The zone files that should exist for one network, so the supervisor can
    /// delete the ones left over from a zone that was renamed or detached.
    ///
    /// Stale zone files are not inert: the Corefile stops referencing a removed
    /// zone, but a file left on disk is a name an operator debugging the host
    /// will read as still served.
    public static func expectedRelativePaths(_ resolver: DesiredResolver) -> Set<String> {
        Set(resolver.files.map(\.relativePath))
    }
}
