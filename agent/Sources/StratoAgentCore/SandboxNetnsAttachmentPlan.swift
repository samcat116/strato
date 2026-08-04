import Foundation

/// One `ip`/`tc` invocation in a namespace attachment plan.
///
/// `tolerated` lists substrings of the command's output that mean "the state
/// this command establishes already holds" — that is how the plan stays
/// idempotent across a retried create or a crash-recovered agent without the
/// executor needing to know which command is which.
public struct NetnsCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    /// A non-zero exit whose output contains one of these is not a failure.
    public let tolerated: [String]

    public init(_ executable: String, _ arguments: [String], tolerated: [String] = []) {
        self.executable = executable
        self.arguments = arguments
        self.tolerated = tolerated
    }

    /// True when `output` from a failed run means the command's effect is
    /// already in place. Matching is deliberately locale-free: these are kernel
    /// and iproute2 strings, and a locale-sensitive casing rule has no business
    /// deciding whether an error gets swallowed.
    public func tolerates(_ output: String) -> Bool {
        tolerated.contains { output.range(of: $0, options: .caseInsensitive) != nil }
    }
}

/// The full host-side recipe for attaching one sandbox NIC into a jail's network
/// namespace, and for tearing it back down (issue STR-100).
///
/// Pure by construction so the sequence — which is easy to get subtly and
/// silently wrong — is unit-testable; `NetworkServiceLinux` is only its
/// executor. This mirrors `SandboxJailPlan`, `GatewayChassisPlan`, and
/// `OVNChassisBootstrap`: the decision lives in `StratoAgentCore`, the side
/// effects live in the actor.
///
/// ## Why not just move the TAP into the namespace
///
/// That was the original design, and it was measured on a real `br-int` +
/// `ovn-controller` and **does not work** (STR-99). Within 30ms of
/// `ip link set <tap> netns <ns>` the OVS port is gone in every sense that
/// matters: `ofport: -1`, `error: "could not open network device"`, absent from
/// the datapath and the OpenFlow port list, and `ovn-controller` releases the
/// `Port_Binding`. Worse, the failure is silent at the OVSDB level — the `Port`
/// and `Interface` rows survive untouched, same UUID, `iface-id` still set — so
/// the port still shows up in `ovs-vsctl show` with no packets behind it.
///
/// ## The recipe that does work: tc-redirect-tap
///
/// A veth pair straddles the namespace. Its host end stays on `br-int` and never
/// moves, so OVS never loses the device. Inside the namespace a TAP owned by the
/// jail's uid is spliced to the veth peer by two `tc` `matchall`/`mirred`
/// redirects. Verified end to end: the veth host end bound cleanly
/// (`ofport: 5`, `error: []`, `ovn-installed="true"`, `Port_Binding up=true`),
/// and frames written into the in-netns TAP via `TUNSETIFF` — exactly what
/// Firecracker does — were redirected out the veth and counted as ingress on the
/// OVS port, with byte counts reconciling exactly.
public struct SandboxNetnsAttachmentPlan: Sendable, Equatable {
    /// The device the jailed Firecracker opens by name from inside the jail.
    public let tapName: String
    /// The veth end that stays in the host namespace, on the integration bridge.
    public let vethHostName: String
    /// The veth end that is moved into the sandbox's network namespace.
    public let vethPeerName: String

    /// Namespace creation and the host-side half of the veth pair. Runs before
    /// the OVS attach.
    public let hostSetup: [NetnsCommand]
    /// `ovs-vsctl` arguments binding the veth host end to the logical switch
    /// port. Run through the service's own `ovs-vsctl` helper so OVS command
    /// handling stays in one place.
    public let ovsAttach: [String]
    /// `ovs-vsctl` arguments reading back the port's *real* binding state.
    /// Row existence proves nothing here (see the class doc): only `ofport` and
    /// the `error` column do. Never cache the result — `ofport` is not stable
    /// across a device's disappearance and return (observed 3 -> 4).
    public let ovsVerify: [String]
    /// Moving the peer in, then everything that happens inside the namespace.
    public let namespaceSetup: [NetnsCommand]

    /// `ovs-vsctl` arguments removing the veth host end from the bridge.
    public let ovsDetach: [String]
    /// Host-side teardown. Deliberately needs neither the namespace to exist nor
    /// `ip netns exec`: deleting one end of a veth pair destroys its peer, so the
    /// in-namespace devices go with it. Deleting the namespace here is what stops
    /// it leaking when `prepareAttachments` succeeded but the runtime never ran
    /// (the jail's own `removeJailArtifacts` is not reached on that path); doing
    /// it twice is a no-op.
    public let teardown: [NetnsCommand]

    /// The host-side teardown for one NIC, derivable from the sandbox id alone —
    /// no jailer config, no ownership, no `ip netns exec`, and no requirement
    /// that the namespace still exist.
    ///
    /// Split out from `plan` because cleanup has to work on an agent that can no
    /// longer *create* what it is deleting: an agent whose sandbox runtime was
    /// deconfigured still has jailed leftovers from its previous life to remove,
    /// and falling back to the VM teardown there would delete `vm-<id>` and
    /// `tap<digest>` while leaving the sandbox's `sbx-<id>` port, veth, and
    /// namespace behind — silently, since teardown swallows errors by design.
    ///
    /// `deletesNamespace` scopes the namespace removal to the NIC that owns it.
    /// Namespace lifetime belongs to the *jail*, not to any one NIC: a multi-NIC
    /// sandbox must not have NIC 0's teardown pull the namespace out from under
    /// NIC 1. Only the whole-workload teardown paths (delete, create-rollback)
    /// pass true, and they tear NICs down in index order.
    public static func teardownCommands(
        sandboxId: String,
        nicIndex: Int,
        netnsName: String,
        ipBinaryPath: String,
        bridge: String,
        ovsTimeoutSeconds: Int,
        deletesNamespace: Bool
    ) -> (ovsDetach: [String], commands: [NetnsCommand]) {
        let names = sandboxNICDeviceNames(sandboxId: sandboxId, nicIndex: nicIndex)
        var commands: [NetnsCommand] = [
            // Deleting the host end takes the peer — and therefore the
            // namespace's whole veth, and the `tc` filters hanging off it —
            // with it.
            NetnsCommand(
                ipBinaryPath, ["link", "del", names.vethHost],
                tolerated: ["Cannot find device", "No such"])
        ]
        if deletesNamespace {
            commands.append(
                NetnsCommand(
                    ipBinaryPath, ["netns", "del", netnsName],
                    tolerated: ["No such file or directory", "Cannot remove"]))
        }
        return (
            ovsDetach: [
                "--timeout=\(ovsTimeoutSeconds)", "--if-exists", "del-port", bridge, names.vethHost,
            ],
            commands: commands
        )
    }

    /// Builds the full create-and-teardown plan for one NIC.
    public static func plan(
        sandboxId: String,
        nicIndex: Int,
        netnsName: String,
        owner: JailOwner,
        logicalPortName: String,
        mtu: Int?,
        ipBinaryPath: String,
        tcBinaryPath: String,
        bridge: String,
        ovsTimeoutSeconds: Int,
        deletesNamespaceOnTeardown: Bool = true
    ) -> SandboxNetnsAttachmentPlan {
        let names = sandboxNICDeviceNames(sandboxId: sandboxId, nicIndex: nicIndex)
        let tap = names.tap
        let vethHost = names.vethHost
        let vethPeer = names.vethPeer

        // A non-positive MTU is not a smaller MTU, it is a bad row: skip it
        // rather than fail every create on the network.
        let mtuValue = (mtu ?? 0) > 0 ? mtu.map(String.init) : nil

        let ip = { (args: [String], tolerated: [String]) in NetnsCommand(ipBinaryPath, args, tolerated: tolerated) }
        // `tc` has no `-n` equivalent, so it is entered through `ip netns exec`.
        let tc = { (args: [String], tolerated: [String]) in
            NetnsCommand(ipBinaryPath, ["netns", "exec", netnsName, tcBinaryPath] + args, tolerated: tolerated)
        }

        var hostSetup: [NetnsCommand] = [
            // The namespace normally already exists (the runtime creates it when
            // staging the jail), but this path runs *first* on the create lane, so
            // it cannot assume that. Both are idempotent.
            ip(["netns", "add", netnsName], ["File exists"]),
            ip(["link", "add", vethHost, "type", "veth", "peer", "name", vethPeer], ["File exists"]),
        ]
        if let mtuValue {
            hostSetup.append(ip(["link", "set", vethHost, "mtu", mtuValue], []))
        }
        hostSetup.append(ip(["link", "set", vethHost, "up"], []))

        var namespaceSetup: [NetnsCommand] = [
            // On a retry the peer is already inside: `ip` then reports it missing
            // from the host namespace. Tolerating that is safe because every
            // command below addresses the peer *through* the namespace and fails
            // loudly if it is not actually there.
            ip(["link", "set", vethPeer, "netns", netnsName], ["Cannot find device"])
        ]
        if let mtuValue {
            namespaceSetup.append(ip(["-n", netnsName, "link", "set", vethPeer, "mtu", mtuValue], []))
        }
        namespaceSetup.append(ip(["-n", netnsName, "link", "set", vethPeer, "up"], []))

        // Recreate rather than reuse the TAP: a device left by an older agent may
        // have no owner uid, and a jailed Firecracker's `TUNSETIFF` against a TAP
        // it does not own fails with EPERM once the jailer has dropped
        // CAP_NET_ADMIN. Nothing has the device open at this point — the VMM has
        // not been spawned yet.
        namespaceSetup.append(
            ip(["-n", netnsName, "tuntap", "del", "dev", tap, "mode", "tap"], ["Cannot find device", "No such"]))
        namespaceSetup.append(
            ip(
                [
                    "-n", netnsName, "tuntap", "add", "dev", tap, "mode", "tap",
                    "user", String(owner.uid), "group", String(owner.gid),
                ], []))
        if let mtuValue {
            namespaceSetup.append(ip(["-n", netnsName, "link", "set", tap, "mtu", mtuValue], []))
        }
        namespaceSetup.append(ip(["-n", netnsName, "link", "set", tap, "up"], []))

        // `replace` rather than `add` for idempotency. It also clears the qdisc's
        // filters, which is why both qdiscs are established before either filter
        // is installed.
        namespaceSetup.append(tc(["qdisc", "replace", "dev", vethPeer, "clsact"], []))
        namespaceSetup.append(tc(["qdisc", "replace", "dev", tap, "clsact"], []))
        // Both filters sit on the **ingress** hook. The TAP's ingress is where
        // frames written by the VMM appear, and the TAP's egress is what the VMM
        // reads; getting this backwards is the easy mistake and produces a NIC
        // that looks wired and carries nothing.
        //
        // guest -> world
        namespaceSetup.append(
            tc(
                [
                    "filter", "add", "dev", tap, "ingress", "protocol", "all", "prio", "1",
                    "matchall", "action", "mirred", "egress", "redirect", "dev", vethPeer,
                ], []))
        // world -> guest
        namespaceSetup.append(
            tc(
                [
                    "filter", "add", "dev", vethPeer, "ingress", "protocol", "all", "prio", "1",
                    "matchall", "action", "mirred", "egress", "redirect", "dev", tap,
                ], []))

        let timeout = "--timeout=\(ovsTimeoutSeconds)"
        // One implementation of teardown, shared with the config-free path, so
        // the two can never derive different device names.
        let removal = teardownCommands(
            sandboxId: sandboxId, nicIndex: nicIndex, netnsName: netnsName,
            ipBinaryPath: ipBinaryPath, bridge: bridge, ovsTimeoutSeconds: ovsTimeoutSeconds,
            deletesNamespace: deletesNamespaceOnTeardown)
        return SandboxNetnsAttachmentPlan(
            tapName: tap,
            vethHostName: vethHost,
            vethPeerName: vethPeer,
            hostSetup: hostSetup,
            ovsAttach: [
                timeout, "--may-exist", "add-port", bridge, vethHost,
                "--", "set", "Interface", vethHost, "external_ids:iface-id=\(logicalPortName)",
            ],
            ovsVerify: [timeout, "get", "Interface", vethHost, "ofport", "error"],
            namespaceSetup: namespaceSetup,
            ovsDetach: removal.ovsDetach,
            teardown: removal.commands
        )
    }
}

/// Parses `ovs-vsctl get Interface <dev> ofport error` output into the two
/// facts that actually prove a port is bound.
///
/// The row existing proves nothing: after a device disappears from the bridge's
/// namespace OVS keeps the `Port`/`Interface` rows with `iface-id` intact and
/// only `ofport`/`error` tell the truth (STR-99).
public struct OVSInterfaceBinding: Sendable, Equatable {
    public let ofport: Int?
    /// The `error` column, empty when OVS reports none (`[]`).
    public let error: String?

    public var isBound: Bool { (ofport ?? -1) > 0 && error == nil }

    public init(ofport: Int?, error: String?) {
        self.ofport = ofport
        self.error = error
    }

    /// `ovs-vsctl get` prints one line per requested column, in order.
    public static func parse(_ output: String) -> OVSInterfaceBinding {
        let lines =
            output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let ofport = lines.first.flatMap { Int($0) }
        var error: String?
        if lines.count > 1 {
            let raw = lines[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            // `[]` is OVS for "no error".
            if raw != "[]" && !raw.isEmpty {
                error = raw
            }
        }
        return OVSInterfaceBinding(ofport: ofport, error: error)
    }
}
