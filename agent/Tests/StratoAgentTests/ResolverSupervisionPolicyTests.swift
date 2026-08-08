import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

/// The supervision decisions, kept pure for `ChassisServicePlan`'s reason:
/// `ResolverSupervisor` lives in the executable target and no test can reach it.
/// The two that matter are "when to restart" and "when *not* to" — restarting
/// when a reload would do costs the network a resolution gap, and not restarting
/// when a restart was needed leaves it serving stale names indefinitely.
@Suite("Resolver Supervision Policy")
struct ResolverSupervisionPolicyTests {

    private let a = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    private func desired(
        _ networkId: UUID, corefile: String = "corefile-v1"
    ) -> DesiredResolver {
        DesiredResolver(
            networkId: networkId,
            files: [CoreDNSZoneRenderer.RenderedFile(relativePath: "Corefile", contents: corefile)])
    }

    // MARK: - Layout

    @Test("Every path is derived from the network id under one root")
    func layoutIsDerived() {
        // The `VMDirectoryLayout` convention: a restarted agent rederives all of
        // them with no retained state, which is also what lets it reap the
        // directories of networks it no longer serves.
        let layout = ResolverDirectoryLayout(root: "/var/lib/strato/resolver", networkId: a)
        let id = a.uuidString.lowercased()
        #expect(layout.directory == "/var/lib/strato/resolver/\(id)")
        #expect(layout.corefilePath == "/var/lib/strato/resolver/\(id)/Corefile")
        #expect(layout.zonesDirectory == "/var/lib/strato/resolver/\(id)/zones")
        #expect(layout.pidFilePath == "/var/lib/strato/resolver/\(id)/coredns.pid")
    }

    @Test("Directories are named by id, not by the network's name")
    func layoutUsesIDs() {
        // Names are unique only within a project, so two projects' networks
        // would otherwise share a directory.
        let one = ResolverDirectoryLayout(root: "/r", networkId: a)
        let two = ResolverDirectoryLayout(root: "/r", networkId: b)
        #expect(one.directory != two.directory)
    }

    // MARK: - Digest

    @Test("The configuration digest tracks contents and paths, and nothing else")
    func digestIsContentAddressed() {
        #expect(desired(a).configurationDigest == desired(b).configurationDigest)
        #expect(desired(a).configurationDigest != desired(a, corefile: "corefile-v2").configurationDigest)
    }

    @Test("The digest is order-insensitive, so a reordered render is not a rewrite")
    func digestIgnoresFileOrder() {
        let one = DesiredResolver(
            networkId: a,
            files: [
                .init(relativePath: "Corefile", contents: "c"),
                .init(relativePath: "zones/x.zone", contents: "z"),
            ])
        let two = DesiredResolver(
            networkId: a,
            files: [
                .init(relativePath: "zones/x.zone", contents: "z"),
                .init(relativePath: "Corefile", contents: "c"),
            ])
        #expect(one.configurationDigest == two.configurationDigest)
    }

    @Test("Two files cannot swap their contents unnoticed")
    func digestSeparatesFields() {
        // Path and contents are separated so `("a", "bc")` and `("ab", "c")`
        // cannot hash equal — the one failure mode a change detector must not
        // have.
        let one = DesiredResolver(networkId: a, files: [.init(relativePath: "a", contents: "bc")])
        let two = DesiredResolver(networkId: a, files: [.init(relativePath: "ab", contents: "c")])
        #expect(one.configurationDigest != two.configurationDigest)
    }

    // MARK: - Actions

    @Test("A network with nothing running is written and started")
    func startsFromNothing() {
        #expect(
            ResolverSupervisionPolicy.actions(desired: [desired(a)], observed: [])
                == [.writeConfiguration(networkId: a), .start(networkId: a)])
    }

    @Test("A running resolver with matching configuration needs nothing")
    func convergedNeedsNothing() {
        let observed = ObservedResolver(
            networkId: a, pid: 42, running: true, configurationDigest: desired(a).configurationDigest)
        #expect(ResolverSupervisionPolicy.actions(desired: [desired(a)], observed: [observed]).isEmpty)
    }

    @Test("A configuration change writes but does NOT restart")
    func configChangeDoesNotRestart() {
        // The rendered Corefile carries `reload` and the `file` plugin watches
        // its zone files, so a running process picks up a record edit within
        // seconds. Every second of a restart is a second in which this network
        // resolves only what OVN can answer.
        let observed = ObservedResolver(
            networkId: a, pid: 42, running: true,
            configurationDigest: desired(a, corefile: "stale").configurationDigest)
        #expect(
            ResolverSupervisionPolicy.actions(desired: [desired(a)], observed: [observed])
                == [.writeConfiguration(networkId: a)])
    }

    @Test("A dead resolver is restarted without rewriting matching configuration")
    func deadProcessIsRestarted() {
        let observed = ObservedResolver(
            networkId: a, pid: nil, running: false, configurationDigest: desired(a).configurationDigest)
        #expect(
            ResolverSupervisionPolicy.actions(desired: [desired(a)], observed: [observed])
                == [.start(networkId: a)])
    }

    @Test("A resolver whose network is gone is stopped")
    func unwantedIsStopped() {
        let observed = ObservedResolver(networkId: b, pid: 7, running: true, configurationDigest: "x")
        #expect(
            ResolverSupervisionPolicy.actions(desired: [], observed: [observed])
                == [.stop(networkId: b)])
    }

    @Test("A nil desired list is silence, not an instruction to stop everything")
    func nilDesiredStopsNothing() {
        // The contract every level-triggered list in the agent carries, and the
        // one that matters most here: a control plane rolled back below v37 must
        // not take DNS away from every network on the host on its way past.
        let observed = ObservedResolver(networkId: a, pid: 1, running: true, configurationDigest: "x")
        #expect(ResolverSupervisionPolicy.actions(desired: nil, observed: [observed]).isEmpty)
        #expect(!ResolverSupervisionPolicy.actions(desired: [], observed: [observed]).isEmpty)
    }

    @Test("Actions are deterministic across a replayed sync")
    func actionsAreOrdered() {
        let actions = ResolverSupervisionPolicy.actions(
            desired: [desired(b), desired(a)], observed: [])
        #expect(
            actions == [
                .writeConfiguration(networkId: a), .start(networkId: a),
                .writeConfiguration(networkId: b), .start(networkId: b),
            ])
    }

    // MARK: - Backoff

    @Test("Restart backoff grows and is capped")
    func backoffGrowsAndCaps() {
        // A Corefile CoreDNS refuses to parse fails identically every time, so a
        // hot `exec` loop would be a busier neighbour on the hypervisor than the
        // query flood the policer exists to stop. Capped because the resolver is
        // a service a network needs: a host broken for an hour should still
        // recover promptly once an operator fixes it.
        #expect(ResolverSupervisionPolicy.restartDelay(consecutiveFailures: 1) == .seconds(1))
        #expect(ResolverSupervisionPolicy.restartDelay(consecutiveFailures: 2) == .seconds(2))
        #expect(ResolverSupervisionPolicy.restartDelay(consecutiveFailures: 4) == .seconds(8))
        #expect(ResolverSupervisionPolicy.restartDelay(consecutiveFailures: 20) == .seconds(60))
    }

    @Test("Backoff stays capped past the point a shift would overflow")
    func backoffDoesNotOverflow() {
        // Swift's `<<` on Int is a non-trapping smart shift: `1 << 63` is
        // Int.min and beyond that it over-shifts to 0. Clamping only the result
        // would let an hour-old failure turn into a hot exec loop — the exact
        // thing the backoff exists to prevent.
        for failures in [63, 64, 65, 1_000, Int.max] {
            #expect(ResolverSupervisionPolicy.restartDelay(consecutiveFailures: failures) == .seconds(60))
        }
    }

    @Test("A zeroth failure does not produce a negative shift")
    func backoffHandlesZero() {
        #expect(ResolverSupervisionPolicy.restartDelay(consecutiveFailures: 0) == .seconds(1))
    }

    @Test("A crash loop needs more than one exit")
    func crashLoopNeedsRepetition() {
        // One exit is what a restart during a config change looks like; paging
        // on it would make every zone edit noisy.
        #expect(!ResolverSupervisionPolicy.isCrashLooping(consecutiveFailures: 1))
        #expect(!ResolverSupervisionPolicy.isCrashLooping(consecutiveFailures: 2))
        #expect(ResolverSupervisionPolicy.isCrashLooping(consecutiveFailures: 3))
    }

    // MARK: - Bind addresses

    @Test("The v6 bind is withheld on a kernel without IPv6")
    func bindSkipsIPv6WhenUnavailable() {
        // `bind` naming a non-existent address makes CoreDNS refuse to start,
        // and `ChassisServicePlan` establishes both families independently
        // precisely so an IPv6-less host keeps a working v4 service.
        #expect(
            ResolverSupervisionPolicy.bindAddresses(ipv6Available: true)
                == [NetworkResolverEndpoint.address, NetworkResolverEndpoint.addressV6])
        #expect(
            ResolverSupervisionPolicy.bindAddresses(ipv6Available: false)
                == [NetworkResolverEndpoint.address])
    }

    // MARK: - Sweeping

    @Test("The expected path set is what a stale zone file is swept against")
    func expectedPathsCoverEveryFile() {
        // A zone renamed or detached leaves a file the Corefile no longer
        // references. Inert to CoreDNS, but an operator reading the directory
        // will believe the name is still served.
        let resolver = DesiredResolver(
            networkId: a,
            files: [
                .init(relativePath: "Corefile", contents: "c"),
                .init(relativePath: "zones/one.zone", contents: "z"),
            ])
        #expect(
            ResolverSupervisionPolicy.expectedRelativePaths(resolver)
                == ["Corefile", "zones/one.zone"])
    }
}

/// Binary discovery, which decides whether this host reports itself capable at
/// all — and therefore whether the control plane enables the resolver for the
/// whole site.
@Suite("Network Resolver Defaults")
struct NetworkResolverDefaultsTests {

    @Test("An explicit path is used when executable")
    func explicitPathWins() {
        #expect(
            NetworkResolverDefaults.resolveBinaryPath(
                configured: "/opt/dns/coredns", isExecutable: { $0 == "/opt/dns/coredns" })
                == "/opt/dns/coredns")
    }

    @Test("An explicit path that is not executable does not fall back")
    func explicitPathDoesNotFallBack() {
        // An operator who named a binary meant that one; silently running a
        // different build is how a host serves DNS from something nobody
        // deployed.
        #expect(
            NetworkResolverDefaults.resolveBinaryPath(
                configured: "/opt/dns/coredns", isExecutable: { $0 == "/usr/bin/coredns" }) == nil)
    }

    @Test("Discovery walks the candidate list in order")
    func discoveryIsOrdered() {
        #expect(
            NetworkResolverDefaults.resolveBinaryPath(configured: nil, isExecutable: { _ in true })
                == NetworkResolverDefaults.corednsBinaryCandidates.first)
        #expect(
            NetworkResolverDefaults.resolveBinaryPath(
                configured: nil, isExecutable: { $0 == "/usr/bin/coredns" }) == "/usr/bin/coredns")
    }

    @Test("A host with no CoreDNS resolves to nil rather than throwing")
    func absentBinaryIsNotAnError() {
        // Not an error: the agent registers `resolverCapable: false` and the
        // control plane withholds the resolver from every network in the site,
        // rather than pointing guests at an address nothing answers on.
        #expect(NetworkResolverDefaults.resolveBinaryPath(configured: nil, isExecutable: { _ in false }) == nil)
    }

    @Test("An empty configured path is treated as unset")
    func emptyConfiguredPathIsUnset() {
        #expect(
            NetworkResolverDefaults.resolveBinaryPath(
                configured: "", isExecutable: { $0 == "/usr/bin/coredns" }) == "/usr/bin/coredns")
    }

    @Test("The config's effective values fall back to the defaults")
    func configFallsBack() {
        let empty = NetworkResolverConfig()
        #expect(empty.effectiveConfigDirectory == NetworkResolverDefaults.configDirectory)
        #expect(empty.effectiveRateLimitPPS == NetworkResolverDefaults.rateLimitPPS)

        // Zero is a real value, not an absent one: it disables the policer.
        let uncapped = NetworkResolverConfig(rateLimitPPS: 0)
        #expect(uncapped.effectiveRateLimitPPS == 0)
    }
}
