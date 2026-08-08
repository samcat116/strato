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

    private func desired(corefile: String = "corefile-v1") -> DesiredResolver {
        DesiredResolver(
            files: [CoreDNSZoneRenderer.RenderedFile(relativePath: "Corefile", contents: corefile)])
    }

    // MARK: - Layout

    @Test("Every path is derived from the network id under one root")
    func layoutIsDerived() {
        // The `VMDirectoryLayout` convention: a restarted agent rederives all of
        // them with no retained state, which is also what lets it reap the
        // directories of networks it no longer serves.
        let layout = ResolverDirectoryLayout(root: "/var/lib/strato/resolver")
        #expect(layout.directory == "/var/lib/strato/resolver")
        #expect(layout.corefilePath == "/var/lib/strato/resolver/Corefile")
        #expect(layout.zonesDirectory == "/var/lib/strato/resolver/zones")
        #expect(layout.pidFilePath == "/var/lib/strato/resolver/coredns.pid")
    }

    @Test("Zone files are namespaced per network inside the one directory")
    func zoneFilesAreNamespaced() {
        // One process, one directory — but two networks may attach zones with
        // the same name and different contents, so a flat path would have one
        // silently overwrite the other.
        #expect(
            CoreDNSZoneRenderer.zoneFilePath(networkId: a, origin: "corp.example.com")
                != CoreDNSZoneRenderer.zoneFilePath(networkId: b, origin: "corp.example.com"))
    }

    // MARK: - Digest

    @Test("The configuration digest tracks contents and paths, and nothing else")
    func digestIsContentAddressed() {
        #expect(desired().configurationDigest == desired().configurationDigest)
        #expect(desired().configurationDigest != desired(corefile: "corefile-v2").configurationDigest)
    }

    @Test("The digest is order-insensitive, so a reordered render is not a rewrite")
    func digestIgnoresFileOrder() {
        let one = DesiredResolver(
            files: [
                .init(relativePath: "Corefile", contents: "c"),
                .init(relativePath: "zones/x.zone", contents: "z"),
            ])
        let two = DesiredResolver(
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
        let one = DesiredResolver(files: [.init(relativePath: "a", contents: "bc")])
        let two = DesiredResolver(files: [.init(relativePath: "ab", contents: "c")])
        #expect(one.configurationDigest != two.configurationDigest)
    }

    // MARK: - Actions

    @Test("Nothing running is written and started")
    func startsFromNothing() {
        #expect(
            ResolverSupervisionPolicy.actions(desired: desired(), observed: ObservedResolver())
                == [.writeConfiguration, .start])
    }

    @Test("A running resolver with matching configuration needs nothing")
    func convergedNeedsNothing() {
        let observed = ObservedResolver(
            pid: 42, running: true, configurationDigest: desired().configurationDigest)
        #expect(ResolverSupervisionPolicy.actions(desired: desired(), observed: observed).isEmpty)
    }

    @Test("A configuration change writes but does NOT restart")
    func configChangeDoesNotRestart() {
        // The Corefile carries `reload` and the `file` plugin watches its zone
        // files, so a running process picks up an edit within seconds — and a
        // restart here is a gap for *every* network on the host, not one.
        let observed = ObservedResolver(
            pid: 42, running: true,
            configurationDigest: desired(corefile: "stale").configurationDigest)
        #expect(
            ResolverSupervisionPolicy.actions(desired: desired(), observed: observed)
                == [.writeConfiguration])
    }

    @Test("A dead resolver is restarted without rewriting matching configuration")
    func deadProcessIsRestarted() {
        let observed = ObservedResolver(
            running: false, configurationDigest: desired().configurationDigest)
        #expect(
            ResolverSupervisionPolicy.actions(desired: desired(), observed: observed) == [.start])
    }

    @Test("A host serving no networks stops the process")
    func servingNothingStops() {
        // Distinct from "no files": a host serving nothing still renders a
        // Corefile, and the difference is what decides whether it runs.
        let nothing = DesiredResolver(
            files: [.init(relativePath: "Corefile", contents: "")], servesNothing: true)
        let observed = ObservedResolver(pid: 7, running: true, configurationDigest: "x")
        #expect(ResolverSupervisionPolicy.actions(desired: nothing, observed: observed) == [.stop])
        // And nothing to stop is nothing to do.
        #expect(
            ResolverSupervisionPolicy.actions(desired: nothing, observed: ObservedResolver()).isEmpty)
    }

    @Test("A nil desired is silence, not an instruction to stop")
    func nilDesiredStopsNothing() {
        // The contract that matters most here: a control plane that cannot
        // describe this host must not take DNS away from every network on it.
        let observed = ObservedResolver(pid: 1, running: true, configurationDigest: "x")
        #expect(ResolverSupervisionPolicy.actions(desired: nil, observed: observed).isEmpty)
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

    @Test("The v6 half is withheld on a kernel without IPv6")
    func bindSkipsIPv6WhenUnavailable() {
        // `bind` naming a non-existent address makes CoreDNS refuse to start —
        // and now for every network at once, since one process serves them all.
        let pair = ["169.254.1.0", "fd00:ec2:1::100"]
        #expect(ResolverSupervisionPolicy.bindable(pair, ipv6Available: true) == pair)
        #expect(ResolverSupervisionPolicy.bindable(pair, ipv6Available: false) == ["169.254.1.0"])
    }

    // MARK: - Sweeping

    @Test("The expected path set is what a stale zone file is swept against")
    func expectedPathsCoverEveryFile() {
        // A zone renamed or detached leaves a file the Corefile no longer
        // references. Inert to CoreDNS, but an operator reading the directory
        // will believe the name is still served.
        let resolver = DesiredResolver(
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
