import Foundation
import Testing

@testable import StratoAgentCore

/// Unit tests for the sandbox NIC namespace attachment recipe (issue STR-100).
///
/// This suite carries most of the issue's real coverage: `NetworkServiceLinux`
/// lives in the executable target and cannot be imported from tests, so the
/// planner is deliberately where the decisions live and the actor is only its
/// executor. The failure this guards against is not a crash — a
/// wrong-but-plausible sequence produces a NIC that binds on `br-int`, reports
/// healthy, and silently carries no packets.
@Suite("Sandbox netns attachment plan")
struct SandboxNetnsAttachmentPlanTests {

    private static let sandboxId = "0d9f8c6a-3f21-4b0e-9a44-8a1c2f9b7e10"
    private static let netns = "strato-sbx-\(sandboxId)"
    private static let ipPath = "/usr/sbin/ip"
    private static let tcPath = "/usr/sbin/tc"

    private func makePlan(mtu: Int? = 1400, nicIndex: Int = 0) -> SandboxNetnsAttachmentPlan {
        SandboxNetnsAttachmentPlan.plan(
            sandboxId: Self.sandboxId,
            nicIndex: nicIndex,
            netnsName: Self.netns,
            ownerUID: 100_042,
            ownerGID: 100_042,
            logicalPortName: "sbx-\(Self.sandboxId)",
            mtu: mtu,
            ipBinaryPath: Self.ipPath,
            tcBinaryPath: Self.tcPath,
            bridge: "br-int",
            ovsTimeoutSeconds: 10
        )
    }

    /// Flattens a command list to `"<argv joined>"` strings for order assertions.
    private func argv(_ commands: [NetnsCommand]) -> [String] {
        commands.map { $0.arguments.joined(separator: " ") }
    }

    // MARK: - The verified sequence

    @Test("Host setup creates the namespace and the veth pair, then brings the host end up")
    func hostSetupSequence() {
        let plan = makePlan()
        #expect(
            argv(plan.hostSetup) == [
                "netns add \(Self.netns)",
                "link add \(plan.vethHostName) type veth peer name \(plan.vethPeerName)",
                "link set \(plan.vethHostName) mtu 1400",
                "link set \(plan.vethHostName) up",
            ])
        #expect(plan.hostSetup.allSatisfy { $0.executable == Self.ipPath })
    }

    @Test("The OVS attach binds the veth host end — never the TAP — to the logical port")
    func ovsAttachBindsTheVethHostEnd() {
        let plan = makePlan()
        #expect(
            plan.ovsAttach == [
                "--timeout=10", "--may-exist", "add-port", "br-int", plan.vethHostName,
                "--", "set", "Interface", plan.vethHostName,
                "external_ids:iface-id=sbx-\(Self.sandboxId)",
            ])
        // The whole point of the recipe: the device OVS owns never moves
        // namespaces, so the TAP must not appear in the bridge transaction.
        #expect(!plan.ovsAttach.contains(plan.tapName))
    }

    @Test("The namespace setup moves the peer in, then creates the TAP owned by the jail uid")
    func namespaceSetupSequence() {
        let plan = makePlan()
        let peer = plan.vethPeerName
        let tap = plan.tapName
        #expect(
            argv(plan.namespaceSetup) == [
                "link set \(peer) netns \(Self.netns)",
                "-n \(Self.netns) link set \(peer) mtu 1400",
                "-n \(Self.netns) link set \(peer) up",
                "-n \(Self.netns) tuntap del dev \(tap) mode tap",
                "-n \(Self.netns) tuntap add dev \(tap) mode tap user 100042 group 100042",
                "-n \(Self.netns) link set \(tap) mtu 1400",
                "-n \(Self.netns) link set \(tap) up",
                "netns exec \(Self.netns) \(Self.tcPath) qdisc replace dev \(peer) clsact",
                "netns exec \(Self.netns) \(Self.tcPath) qdisc replace dev \(tap) clsact",
                "netns exec \(Self.netns) \(Self.tcPath) filter add dev \(tap) ingress protocol all prio 1 "
                    + "matchall action mirred egress redirect dev \(peer)",
                "netns exec \(Self.netns) \(Self.tcPath) filter add dev \(peer) ingress protocol all prio 1 "
                    + "matchall action mirred egress redirect dev \(tap)",
            ])
    }

    @Test("The TAP is created with the jail's uid and gid as owner")
    func tapCarriesOwnership() {
        let plan = SandboxNetnsAttachmentPlan.plan(
            sandboxId: Self.sandboxId, nicIndex: 0, netnsName: Self.netns,
            ownerUID: 123_456, ownerGID: 654_321, logicalPortName: "sbx-x", mtu: nil,
            ipBinaryPath: Self.ipPath, tcBinaryPath: Self.tcPath, bridge: "br-int", ovsTimeoutSeconds: 10)

        let create = plan.namespaceSetup.first { $0.arguments.contains("add") && $0.arguments.contains("tuntap") }
        #expect(create != nil)
        // A jailed Firecracker has dropped CAP_NET_ADMIN by the time it opens
        // the device, so TUNSETIFF only succeeds when the caller owns it.
        #expect(create?.arguments.contains("user") == true)
        #expect(create?.arguments.contains("123456") == true)
        #expect(create?.arguments.contains("group") == true)
        #expect(create?.arguments.contains("654321") == true)
    }

    @Test("The TAP is recreated rather than reused, so a device with the wrong owner cannot survive")
    func tapIsRecreated() {
        let plan = makePlan()
        let tuntap = plan.namespaceSetup.filter { $0.arguments.contains("tuntap") }
        #expect(tuntap.count == 2)
        #expect(tuntap.first?.arguments.contains("del") == true)
        #expect(tuntap.last?.arguments.contains("add") == true)
        // The delete is expected to fail on a first create.
        #expect(tuntap.first?.tolerates("Cannot find device \"\(plan.tapName)\"") == true)
    }

    // MARK: - The directional trap

    @Test("Both redirect filters sit on the ingress hook, cross-wired to each other")
    func filtersUseIngressHooksAndRedirectToEachOther() {
        let plan = makePlan()
        let filters = plan.namespaceSetup.filter { $0.arguments.contains("filter") }
        #expect(filters.count == 2)

        // A TAP's ingress is where frames the VMM *writes* appear, and its
        // egress is what the VMM reads. Installing either filter on the egress
        // hook yields a port that binds and carries nothing. The hook is the
        // token immediately after the device, so check that position rather than
        // membership — "egress" legitimately appears later, in the mirred action.
        for filter in filters {
            guard let verb = filter.arguments.firstIndex(of: "filter") else {
                Issue.record("no `filter` subcommand in \(filter.arguments)")
                return
            }
            #expect(filter.arguments[verb + 1] == "add")
            #expect(filter.arguments[verb + 2] == "dev")
            #expect(filter.arguments[verb + 4] == "ingress")
            #expect(filter.arguments.contains("matchall"))
            #expect(filter.arguments.contains("mirred"))
        }

        let fromTap = filters[0].arguments
        let fromPeer = filters[1].arguments
        // guest -> world: read off the TAP's ingress, redirected out the peer.
        #expect(fromTap.firstIndex(of: plan.tapName)! < fromTap.firstIndex(of: plan.vethPeerName)!)
        #expect(fromTap.last == plan.vethPeerName)
        // world -> guest: read off the peer's ingress, redirected into the TAP.
        #expect(fromPeer.firstIndex(of: plan.vethPeerName)! < fromPeer.firstIndex(of: plan.tapName)!)
        #expect(fromPeer.last == plan.tapName)
    }

    @Test("Both clsact qdiscs are established before either filter is installed")
    func qdiscsPrecedeFilters() {
        // `qdisc replace` clears the qdisc's filters, so interleaving the two
        // would silently drop the first filter installed.
        let plan = makePlan()
        let lastQdisc = plan.namespaceSetup.lastIndex { $0.arguments.contains("qdisc") }
        let firstFilter = plan.namespaceSetup.firstIndex { $0.arguments.contains("filter") }
        #expect(lastQdisc != nil && firstFilter != nil)
        #expect(lastQdisc! < firstFilter!)
    }

    // MARK: - MTU

    @Test("MTU is applied to every device the plan creates")
    func mtuReachesAllThreeDevices() {
        let plan = makePlan(mtu: 1400)
        let mtuCommands = (plan.hostSetup + plan.namespaceSetup).filter { $0.arguments.contains("mtu") }
        #expect(mtuCommands.count == 3)
        let devices = Set(
            mtuCommands.compactMap { command -> String? in
                guard let mtuIndex = command.arguments.firstIndex(of: "mtu"), mtuIndex > 0 else { return nil }
                return command.arguments[mtuIndex - 1]
            })
        #expect(devices == [plan.vethHostName, plan.vethPeerName, plan.tapName])
        #expect(mtuCommands.allSatisfy { $0.arguments.contains("1400") })
    }

    @Test("No MTU commands when the network does not set one")
    func mtuAbsentWhenUnset() {
        let plan = makePlan(mtu: nil)
        #expect((plan.hostSetup + plan.namespaceSetup).allSatisfy { !$0.arguments.contains("mtu") })
    }

    @Test("A non-positive MTU is treated as absent, not as a device configuration")
    func nonPositiveMTUIsIgnored() {
        for value in [0, -1] {
            let plan = makePlan(mtu: value)
            #expect((plan.hostSetup + plan.namespaceSetup).allSatisfy { !$0.arguments.contains("mtu") })
        }
    }

    // MARK: - Teardown

    @Test("Teardown is host-side only: it never enters the namespace")
    func teardownNeverEntersTheNamespace() {
        let plan = makePlan()
        // Deleting one end of a veth pair destroys its peer, which takes the
        // in-namespace devices and their filters with it — so teardown must work
        // on a host whose namespace is already gone.
        #expect(plan.teardown.allSatisfy { !$0.arguments.contains("exec") })
        #expect(plan.teardown.allSatisfy { !$0.arguments.contains("-n") })
        #expect(plan.teardown.allSatisfy { !$0.arguments.contains(plan.tapName) })
    }

    @Test("Teardown removes the OVS port, the host veth, and the namespace, in that order")
    func teardownOrder() {
        let plan = makePlan()
        #expect(plan.ovsDetach == ["--timeout=10", "--if-exists", "del-port", "br-int", plan.vethHostName])
        #expect(
            argv(plan.teardown) == [
                "link del \(plan.vethHostName)",
                "netns del \(Self.netns)",
            ])
    }

    @Test("Teardown tolerates devices and namespaces that are already gone")
    func teardownIsIdempotent() {
        let plan = makePlan()
        #expect(plan.teardown[0].tolerates("Cannot find device \"\(plan.vethHostName)\""))
        #expect(
            plan.teardown[1].tolerates("Cannot remove namespace file \"/var/run/netns/x\": No such file or directory"))
    }

    @Test("Create tolerates exactly the re-run failures, and nothing else")
    func createIdempotencyTolerances() {
        let plan = makePlan()
        let namespaceAdd = plan.hostSetup[0]
        let vethAdd = plan.hostSetup[1]
        #expect(namespaceAdd.tolerates("Cannot create namespace file \"/var/run/netns/x\": File exists"))
        #expect(vethAdd.tolerates("RTNETLINK answers: File exists"))
        // Moving an already-moved peer is benign; the in-namespace commands
        // that follow prove the device really is there.
        #expect(plan.namespaceSetup[0].tolerates("Cannot find device \"\(plan.vethPeerName)\""))
        // A genuine privilege failure must never be swallowed.
        #expect(!namespaceAdd.tolerates("Operation not permitted"))
        #expect(!vethAdd.tolerates("Operation not permitted"))
        #expect(!plan.namespaceSetup[0].tolerates("Operation not permitted"))
    }

    // MARK: - Names

    @Test("Every device name fits IFNAMSIZ, is distinct, and is stable")
    func deviceNamesAreValidAndStable() {
        for nicIndex in 0..<4 {
            let plan = makePlan(nicIndex: nicIndex)
            let names = [plan.tapName, plan.vethHostName, plan.vethPeerName]
            for name in names {
                #expect(name.count == 15, "'\(name)' is not exactly IFNAMSIZ-1 characters")
            }
            #expect(Set(names).count == 3, "device names collided at nicIndex \(nicIndex)")
            #expect(argv(makePlan(nicIndex: nicIndex).hostSetup) == argv(plan.hostSetup))
        }
    }

    @Test("The TAP name matches what the VM helper derives, so one digest serves both")
    func tapNameMatchesTheSharedDigest() {
        for nicIndex in 0..<4 {
            let plan = makePlan(nicIndex: nicIndex)
            #expect(plan.tapName == tapInterfaceName(for: Self.sandboxId, nicIndex: nicIndex))
        }
    }

    @Test("Distinct sandboxes get distinct devices across all three roles")
    func namesDoNotCollideAcrossSandboxes() {
        var seen: Set<String> = []
        for index in 0..<500 {
            let names = sandboxNICDeviceNames(sandboxId: "sandbox-\(index)", nicIndex: 0)
            for name in [names.tap, names.vethHost, names.vethPeer] {
                #expect(!seen.contains(name), "'\(name)' collided")
                seen.insert(name)
            }
        }
    }
}

/// `ovs-vsctl show` keeps a `Port`/`Interface` row alive after its device has
/// become unusable, so the row proves nothing. These parse the two columns that
/// do (issue STR-100, measurement from STR-99).
@Suite("OVS interface binding readback")
struct OVSInterfaceBindingTests {

    @Test("A bound port reports a positive ofport and an empty error column")
    func boundPort() {
        let binding = OVSInterfaceBinding.parse("5\n[]\n")
        #expect(binding.ofport == 5)
        #expect(binding.error == nil)
        #expect(binding.isBound)
    }

    @Test("The silent failure after a namespace move is recognized as unbound")
    func devicePresentInOVSDBButGone() {
        let binding = OVSInterfaceBinding.parse(
            "-1\n\"could not open network device tapabc (No such device)\"\n")
        #expect(binding.ofport == -1)
        #expect(binding.error == "could not open network device tapabc (No such device)")
        #expect(!binding.isBound)
    }

    @Test("An error alongside a plausible ofport still counts as unbound")
    func errorDominatesOfport() {
        #expect(!OVSInterfaceBinding.parse("3\n\"boom\"").isBound)
    }

    @Test("Missing or unparseable output is unbound, never optimistically bound")
    func missingOutput() {
        #expect(!OVSInterfaceBinding.parse("").isBound)
        #expect(!OVSInterfaceBinding.parse("\n\n").isBound)
        #expect(!OVSInterfaceBinding.parse("[]\n[]").isBound)
        #expect(!OVSInterfaceBinding.parse("0\n[]").isBound)
    }
}
