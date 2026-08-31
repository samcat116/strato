import Foundation
import Logging
import StratoShared
import StratoAgentCore

#if os(Linux)
import SwiftOVN
#endif

/// Owns logical-switch, TAP, namespace, and OVS binding plumbing.
extension NetworkServiceLinux {
    // MARK: - Private Helper Methods

    #if os(Linux)
    func ensureIntegrationBridge() async throws {
        guard let ovsManager = ovsManager else {
            throw NetworkError.notConnected("OVS manager not connected")
        }

        let bridgeName = "br-int"

        // Idempotent: br-int persists in OVSDB across agent restarts, so on
        // every reconnect it already exists. Bridge names are uniquely indexed,
        // so blindly inserting it aborts the whole transaction with a
        // constraint violation — check for it first. A fresh host has none.
        if try await ovsManager.getBridge(named: bridgeName) != nil {
            logger.debug("Integration bridge already present", metadata: ["bridge": .string(bridgeName)])
        } else {
            let integrationBridge = OVSBridge(
                name: bridgeName,
                protocols: ["OpenFlow13"],
                fail_mode: "secure",
                external_ids: ["description": "OVN integration bridge"]
            )

            do {
                let _ = try await ovsManager.createBridge(integrationBridge)
                logger.info("Created integration bridge", metadata: ["bridge": .string(bridgeName)])
            } catch {
                // A concurrent creator may have won the race between the check
                // above and this insert; tolerate that, but surface anything else.
                if try await ovsManager.getBridge(named: bridgeName) != nil {
                    logger.debug(
                        "Integration bridge created concurrently", metadata: ["bridge": .string(bridgeName)])
                } else {
                    throw error
                }
            }
        }

        try await ensureBridgeLocalPort(bridgeName)
    }

    /// Ensures the local OVS carries the chassis `external_ids` that
    /// `ovn-controller` needs (`ovn-remote`, `ovn-encap-type`, `ovn-encap-ip`,
    /// and a `system-id`). Idempotent: explicit agent config is reapplied on
    /// every connect, values an operator already set are left alone, and
    /// missing values get defaults (encap IP auto-detected from the default
    /// route). Without these a fresh host looks fully wired but programs no
    /// flows, ever.
    func ensureChassisConfiguration() throws {
        guard chassisConfig.bootstrapEnabled else {
            logger.info("OVN chassis bootstrap disabled by configuration; assuming operator-managed external_ids")
            return
        }

        let current = try runProcess(
            "ovs-vsctl",
            ["--timeout=\(Self.ovsCommandTimeoutSeconds)", "get", "open_vswitch", ".", "external_ids"])
        guard current.status == 0 else {
            throw NetworkError.ovsError(
                "cannot read chassis external_ids (exit \(current.status)): "
                    + current.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let existing = OVNChassisBootstrap.parseExternalIDs(current.output)

        var detectedEncapIP: String?
        if chassisConfig.encapIP == nil, existing["ovn-encap-ip"] == nil {
            detectedEncapIP = detectEncapIP()
        }

        let plan = OVNChassisBootstrap.plan(
            config: chassisConfig,
            existing: existing,
            detectedEncapIP: detectedEncapIP,
            generatedSystemID: UUID().uuidString.lowercased())

        if plan.encapIPUnresolved {
            throw NetworkError.invalidConfiguration(
                "cannot determine this host's tunnel endpoint IP: the chassis has no ovn-encap-ip, none is "
                    + "configured, and auto-detection from the default route failed. Set ovn_encap_ip in the "
                    + "agent configuration.")
        }

        guard !plan.settings.isEmpty else {
            logger.debug("OVN chassis external_ids already configured")
            return
        }

        let arguments =
            ["--timeout=\(Self.ovsCommandTimeoutSeconds)", "set", "open_vswitch", "."]
            + plan.settings.map(\.vsctlArgument)
        let result = try runProcess("ovs-vsctl", arguments)
        guard result.status == 0 else {
            throw NetworkError.ovsError(
                "failed to set chassis external_ids (exit \(result.status)): "
                    + result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        logger.info(
            "Bootstrapped OVN chassis configuration",
            metadata: [
                "applied": .string(plan.settings.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            ])
    }

    /// The IP the kernel would use as the source for off-host traffic — the
    /// sensible default tunnel endpoint on single-NIC hosts. Multi-homed
    /// hosts must set `ovn_encap_ip` explicitly.
    func detectEncapIP() -> String? {
        guard let result = try? runProcess("ip", ["-j", "route", "get", "1.1.1.1"]), result.status == 0 else {
            return nil
        }
        return OVNChassisBootstrap.parseRouteSourceIP(result.output)
    }

    /// Confirms `ovn-controller` has an active southbound connection, polling
    /// briefly to ride out a controller that is still dialing after the
    /// chassis was (re)configured. Throwing here keeps `connect()` failed, so
    /// the agent reports no overlay support for a host whose ports would never
    /// get flows; the background retry loop picks it up when the controller
    /// comes up. A missing `ovn-appctl` only logs — we don't gate the typed
    /// network report on a diagnostic tool (preflight reports it separately).
    func verifyOVNControllerConnected() async throws {
        let attempts = 5
        var lastDetail = "unknown"

        for attempt in 1...attempts {
            let result: CommandResult
            do {
                result = try runProcess("ovn-appctl", ["-t", "ovn-controller", "connection-status"])
            } catch {
                logger.warning(
                    "Cannot verify ovn-controller connection status: \(error.localizedDescription)")
                return
            }
            if result.status == 127 {
                logger.warning(
                    "ovn-appctl not found; skipping ovn-controller connection verification (install ovn-host to enable it)"
                )
                return
            }

            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.status == 0, output == "connected" {
                logger.info("ovn-controller is connected to the southbound database")
                return
            }

            lastDetail = output.isEmpty ? "exit \(result.status)" : output
            if attempt < attempts {
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }

        throw NetworkError.ovnError(
            "ovn-controller is not connected to the southbound database (last status: \(lastDetail)) — "
                + "check that ovn-controller is running and that external_ids:ovn-remote on the local OVS "
                + "points at the right southbound database. VM ports would come up with no dataplane, so "
                + "OVN networking is not being advertised.")
    }

    /// The `addresses` entry for a VM port: the MAC followed by its per-family
    /// IPs (`"<mac> <ip4> <ip6>"`), or just the MAC when nothing is allocated.
    static func portAddressEntry(mac: String, ips: [String]) -> String {
        ([mac] + ips).joined(separator: " ")
    }

    /// The `port_security` entry for a VM port: the addresses entry plus —
    /// when the port carries any IPv6 address — the EUI-64 link-local address
    /// derived from the MAC. Port security with explicit IPs restricts ND/NA
    /// and DHCPv6-client traffic to the listed sources, and guests source
    /// those from their link-local address: omit it and IPv6 silently dies.
    /// (Guests are configured with `ipv6-address-generation: eui64` so their
    /// link-local matches this derivation.)
    static func portSecurityEntry(mac: String, ips: [String]) -> String {
        var entries = [mac] + ips
        let hasIPv6 = ips.contains { IPv6Address($0) != nil }
        if hasIPv6, let linkLocal = IPv6Address.linkLocalEUI64(fromMAC: mac) {
            entries.append(linkLocal.description)
        }
        return entries.joined(separator: " ")
    }

    /// Creates the VM NIC's logical switch port attached to its switch in one
    /// OVSDB transaction (`ovn-nbctl lsp-add` semantics) — the two steps must
    /// never diverge or the port is an orphan ovn-northd ignores.
    func createAttachedLogicalSwitchPort(
        portName: String, vmId: String, placement: NICPlacement, switchName: String, networkId: UUID,
        networkName: String,
        macAddress: String,
        ipAddresses: [String], dhcpOptionsUUID: String? = nil, dhcpV6OptionsUUID: String? = nil
    ) async throws -> String? {
        // Which kind of workload owns the port, for humans reading
        // `ovn-nbctl list` and for anyone correlating a port back to a resource.
        let (ownerKey, description): (String, String) = {
            switch placement {
            case .hostNamespace: return ("vm-id", "VM network interface")
            case .sandboxNetns: return ("sandbox-id", "Sandbox network interface")
            }
        }()
        let logicalPort = OVNLogicalSwitchPort(
            name: portName,
            addresses: [Self.portAddressEntry(mac: macAddress, ips: ipAddresses)],
            port_security: [Self.portSecurityEntry(mac: macAddress, ips: ipAddresses)],
            dhcpv4_options: dhcpOptionsUUID,
            dhcpv6_options: dhcpV6OptionsUUID,
            // The name is a label for humans reading `ovn-nbctl list`; the id is
            // what identifies the network (issue #765). Ports are found by port
            // name, so neither is ever matched on.
            external_ids: [
                ownerKey: vmId,
                DHCPRowIdentity.networkIDKey: networkId.uuidString.lowercased(),
                DHCPRowIdentity.networkNameKey: networkName,
                "description": description,
            ]
        )
        return try await ovnManager?.createLogicalSwitchPort(logicalPort, onSwitch: switchName)
    }

    /// Adds a freshly created/reused LSP to its security groups' port groups
    /// plus the drop group. Throws `DependencyPendingError` when a group's
    /// port group doesn't exist — or exists without its generation stamp,
    /// i.e. its ACLs aren't realized yet (rows and ACLs commit in separate
    /// transactions) — the authority's sync realizes it and the VM create
    /// retries, so a managed NIC can never come up filtered by nothing. The
    /// drop group joins first: if a later add fails, the port is already
    /// default-deny rather than allow-only.
    func joinSecurityGroups(
        portName: String, portUUID: String?, groupIds: [UUID], metadataDenied: Bool
    ) async throws {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        // Deny groups first, for the reason the call site gives and in the
        // order `SecurityGroupReconciler.additionRank` uses: whatever this loop
        // gets through before a `DependencyPendingError` parks it must never be
        // the permissive half.
        let denyGroups =
            [OVNNaming.dropPortGroupName] + (metadataDenied ? [OVNNaming.metadataDenyPortGroupName] : [])
        let groups = denyGroups + groupIds.map { OVNNaming.portGroupName(securityGroupId: $0) }.sorted()
        for group in groups {
            guard let portGroup = try await ovnManager.getPortGroup(named: group) else {
                throw DependencyPendingError(
                    "port group \(group) does not exist yet; waiting for the site's network controller to realize it"
                )
            }
            guard portGroup.external_ids?[Self.generationKey] != nil else {
                throw DependencyPendingError(
                    "port group \(group) exists but its ACLs are not realized yet; waiting for the site's network controller"
                )
            }
            guard let portUUID else { continue }
            if !(portGroup.ports ?? []).contains(portUUID) {
                try await ovnManager.addPorts([portUUID], toPortGroup: group)
            }
        }
        logger.debug(
            "Workload port joined security groups",
            metadata: [
                "portName": .string(portName),
                "groups": .stringConvertible(groups.count),
            ])
    }

    func findOrCreateLogicalSwitch(name: String, subnet: String) async throws -> UUID {
        guard let ovnManager = ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }

        // Reuse an existing switch to avoid duplicate switches on VM re-attach.
        if let existing = try await ovnManager.getLogicalSwitch(named: name),
            let existingUUIDString = existing.uuid,
            let existingUUID = UUID(uuidString: existingUUIDString)
        {
            logger.debug("Reusing existing logical switch", metadata: ["name": .string(name)])
            return existingUUID
        }

        let logicalSwitch = OVNLogicalSwitch(
            name: name,
            external_ids: [
                "subnet": subnet,
                "description": "Auto-created network for VM",
            ]
        )

        let uuidString = try await ovnManager.createLogicalSwitch(logicalSwitch)
        guard let uuid = UUID(uuidString: uuidString) else {
            throw NetworkError.invalidConfiguration("Invalid UUID returned from OVN: \(uuidString)")
        }
        return uuid
    }

    func createTAPInterface(vmId: String, nicIndex: Int, mtu: Int?) async throws -> String {
        let tapName = tapInterfaceName(for: vmId, nicIndex: nicIndex)
        logger.debug(
            "Creating TAP interface",
            metadata: [
                "tapName": .string(tapName),
                "strato.vm.id": .string(vmId),
            ])

        // Idempotent: reuse the device if it already exists (crash recovery, re-attach).
        if tapDeviceExists(tapName) {
            logger.debug("TAP interface already exists, reusing", metadata: ["tapName": .string(tapName)])
        } else {
            // Create a persistent single-queue TAP device. It must exist before QEMU
            // opens it (QEMU is launched with `script=no,ifname=<tap>`), and persistence
            // is what lets QEMU attach to the pre-created device.
            try run("ip", ["tuntap", "add", "dev", tapName, "mode", "tap"])
            logger.info("Created TAP interface", metadata: ["tapName": .string(tapName)])
        }

        // Match the host device to the MTU the guest is configured with. A
        // non-positive value is a bad row rather than a smaller MTU: skip it
        // rather than fail every create on that network.
        //
        // Two things to know about the blast radius (issue STR-100). This runs
        // on every reconcile, not just create, so it reaches VMs that have been
        // up since before it existed — a stale or wrong stored MTU surfaces
        // here. And OVS derives a bridge's internal-port MTU from the minimum
        // over its non-internal ports, so the first VM on a lowered-MTU network
        // pulls `br-int`'s own MTU down host-wide. That is inert in a standard
        // OVN deployment (nothing routes via the br-int internal port), but it
        // is a host-scoped effect of a per-VM setting.
        if let mtu, mtu > 0 {
            try run("ip", ["link", "set", tapName, "mtu", String(mtu)])
        }

        // Bring the interface up (idempotent).
        try run("ip", ["link", "set", tapName, "up"])

        return tapName
    }

    /// Realizes one sandbox NIC into a jailed VMM's network namespace and binds
    /// it to `portName` on the integration bridge, returning the name of the TAP
    /// the jailed Firecracker will open (issue STR-100).
    ///
    /// The recipe (`SandboxNetnsAttachmentPlan`) is a veth pair straddling the
    /// namespace with `tc` redirects splicing the in-namespace end to a TAP,
    /// *not* the obvious "move the TAP in" — that was measured to silently kill
    /// the OVS port while leaving its OVSDB rows intact (STR-99).
    func attachSandboxNICIntoNetns(
        sandboxId: String, nicIndex: Int, netnsName: String, owner: JailOwner,
        portName: String, mtu: Int?
    ) async throws -> String {
        guard let ipBinaryPath else {
            throw NetworkError.invalidConfiguration(
                "sandbox networking needs the iproute2 `ip` tool, which was not found on this host "
                    + "(looked in \(SandboxJailerResolver.ipBinaryCandidates.joined(separator: ", ")))")
        }
        guard let tcBinaryPath else {
            throw NetworkError.invalidConfiguration(
                "sandbox networking needs the iproute2 `tc` tool, which was not found on this host "
                    + "(looked in \(SandboxJailerResolver.tcBinaryCandidates.joined(separator: ", ")))")
        }

        let started = ContinuousClock.now
        let plan = SandboxNetnsAttachmentPlan.plan(
            sandboxId: sandboxId, nicIndex: nicIndex, netnsName: netnsName,
            owner: owner, logicalPortName: portName, mtu: mtu,
            ipBinaryPath: ipBinaryPath, tcBinaryPath: tcBinaryPath,
            bridge: Self.ovnIntegrationBridge, ovsTimeoutSeconds: Self.ovsCommandTimeoutSeconds)

        for command in plan.hostSetup {
            try await runNetnsCommand(command)
        }
        try run("ovs-vsctl", plan.ovsAttach)

        _ = try await verifyOVSBinding(
            verify: plan.ovsVerify, device: plan.vethHostName, portName: portName, stage: "attach")

        for command in plan.namespaceSetup {
            try await runNetnsCommand(command)
        }

        // Re-read after the namespace work. The veth host end never leaves the
        // host namespace, so in theory nothing above can have disturbed it —
        // but "moving a device out from under OVS silently kills its port while
        // the rows survive" is precisely what STR-99 measured, and proving the
        // binding *after* the move is what actually closes that loop. One
        // `ovs-vsctl get` against ~15 other spawns.
        let binding = try await verifyOVSBinding(
            verify: plan.ovsVerify, device: plan.vethHostName, portName: portName,
            stage: "namespace-setup")

        // Sandboxes are churn-heavy and cold start is a headline property, so
        // the cost of this path is measured rather than assumed.
        let elapsed = ContinuousClock.now - started
        let elapsedMs =
            elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        logger.info(
            "Sandbox NIC attached into namespace",
            metadata: [
                "strato.sandbox.id": .string(sandboxId),
                "nicIndex": .stringConvertible(nicIndex),
                "netns": .string(netnsName),
                "portName": .string(portName),
                "tap": .string(plan.tapName),
                "vethHost": .string(plan.vethHostName),
                "ofport": .string(binding.ofport.map(String.init) ?? "unset"),
                "elapsedMs": .stringConvertible(elapsedMs),
            ])

        return plan.tapName
    }

    /// Proves the veth host end is really bound on the integration bridge.
    ///
    /// Row existence is not evidence: OVS keeps the `Port` and `Interface` rows
    /// — same UUID, `iface-id` still set — even when the device behind them is
    /// unusable, so a check that looks the port up by name sees health where
    /// there are no packets. `ofport` and the `error` column are the only honest
    /// signals, and the result is never cached: `ofport` is not stable across a
    /// device's disappearance and return, observed 3 -> 4 (STR-99).
    ///
    /// `ovs-vsctl` waits for `ovs-vswitchd` to catch up before returning, so
    /// `ofport` should already be populated; the bounded retry covers the case
    /// where it isn't, because failing there would unwind an otherwise healthy
    /// create.
    ///
    /// Shared by the sandbox NIC path and the metadata namespace path (STR-49):
    /// both move a device that OVS has a port for, and both fail the same silent
    /// way, so they check the same way.
    func verifyOVSBinding(
        verify: [String], device: String, portName: String, stage: String
    ) async throws -> OVSInterfaceBinding {
        var binding = OVSInterfaceBinding(ofport: nil, error: nil)
        for attempt in 1...Self.ovsBindingReadbackAttempts {
            binding = OVSInterfaceBinding.parse(try run("ovs-vsctl", verify))
            if binding.isBound { return binding }
            // An `error` is a verdict, not a race — retrying cannot clear it.
            if binding.error != nil { break }
            if attempt < Self.ovsBindingReadbackAttempts {
                try await Task.sleep(for: Self.ovsBindingReadbackDelay)
            }
        }
        throw NetworkError.ovsError(
            "OVS did not bind \(device) on \(Self.ovnIntegrationBridge) for port \(portName) "
                + "after \(stage) (ofport=\(binding.ofport.map(String.init) ?? "unset"), "
                + "error=\(binding.error ?? "none")) — the interface would report healthy and carry no packets")
    }

    /// Removes the host-side half of a sandbox NIC. Needs neither the namespace
    /// nor anything inside it: deleting the host veth end destroys its peer, and
    /// the peer's death takes the `tc` filters with it.
    ///
    /// Derived from the sandbox id alone — no jailer config, no ownership — so
    /// cleanup works on an agent that can no longer create what it is deleting.
    /// `deletesNamespace` is false for any NIC but the first: namespace lifetime
    /// belongs to the jail, not to one NIC.
    func detachSandboxNICFromNetns(
        sandboxId: String, nicIndex: Int, netnsName: String, portName: String
    ) async throws {
        // Teardown must work on a host whose iproute2 has since been removed, or
        // was never resolved because the network service came up before the
        // probe. Falling back to the PATH-resolved name re-introduces a `PATH`
        // dependency the create path deliberately avoids — the right trade for
        // cleanup, which must attempt something rather than refuse.
        let usingPATHFallback = ipBinaryPath == nil
        let removal = SandboxNetnsAttachmentPlan.teardownCommands(
            sandboxId: sandboxId, nicIndex: nicIndex, netnsName: netnsName,
            ipBinaryPath: ipBinaryPath ?? "ip",
            bridge: Self.ovnIntegrationBridge, ovsTimeoutSeconds: Self.ovsCommandTimeoutSeconds,
            deletesNamespace: nicIndex == 0)

        do {
            try run("ovs-vsctl", removal.ovsDetach)
        } catch {
            logger.warning(
                "Failed to remove OVS port",
                metadata: [
                    "strato.sandbox.id": .string(sandboxId),
                    "error": .string(error.localizedDescription),
                ])
        }

        // Each remaining step is independently tolerant so a partial teardown
        // still removes everything it can.
        for command in removal.commands {
            do {
                try await runNetnsCommand(command)
            } catch {
                logger.warning(
                    "Failed to tear down sandbox NIC device",
                    metadata: [
                        "strato.sandbox.id": .string(sandboxId),
                        "command": .string(command.arguments.joined(separator: " ")),
                        "error": .string(error.localizedDescription),
                        // Without an absolute path this ran through `PATH`, which
                        // a service manager may have stripped — the likeliest
                        // cause of a failure that says only "not found".
                        "resolvedVia": .string(usingPATHFallback ? "PATH" : "absolute path"),
                    ])
            }
        }
    }

    /// Runs one planned `ip`/`tc` invocation, swallowing exactly the failures the
    /// plan declared benign (the state it establishes already holds).
    ///
    /// Uses the async `ProcessRunner` rather than this file's blocking `Process`
    /// shim: a sandbox attach spawns ~15 children, and blocking a cooperative
    /// thread for each would serialize the whole actor against a path whose
    /// latency *is* sandbox cold start. It also matches
    /// `FirecrackerSandboxRuntime.createNetns`, which creates the same namespace.
    func runNetnsCommand(_ command: NetnsCommand) async throws {
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: command.executable),
            arguments: command.arguments,
            timeout: Self.netnsCommandTimeout)
        guard result.terminationStatus != 0 else { return }
        let detail = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.tolerates(detail) {
            logger.debug(
                "Namespace command already satisfied",
                metadata: [
                    "command": .string(command.arguments.joined(separator: " ")),
                    "output": .string(detail),
                ])
            return
        }
        throw NetworkError.tapError(
            networkCommandFailure(
                command.executable, command.arguments,
                CommandResult(status: result.terminationStatus, output: detail)))
    }

    func attachTAPToBridge(tapInterface: String, portName: String) async throws {
        // Attach the TAP to the OVN integration bridge and bind it to the logical
        // switch port. OVN's `ovn-controller` binds a port when the OVS Interface has
        // `external_ids:iface-id` set to the logical switch port name — the previous
        // implementation set `ovn-port-name` on the Port, which OVN ignores.
        // `ovs-vsctl` performs the port + interface insert and the external_ids set
        // atomically and idempotently (`--may-exist`).
        try run(
            "ovs-vsctl",
            [
                "--timeout=\(Self.ovsCommandTimeoutSeconds)",
                "--may-exist", "add-port", Self.ovnIntegrationBridge, tapInterface,
                "--", "set", "Interface", tapInterface, "external_ids:iface-id=\(portName)",
            ])
        logger.debug(
            "Attached TAP interface to bridge",
            metadata: [
                "tap": .string(tapInterface),
                "port": .string(portName),
                "bridge": .string(Self.ovnIntegrationBridge),
            ])
    }

    func removeTAPInterface(_ tapInterface: String) async throws {
        logger.debug("Removing TAP interface", metadata: ["tapName": .string(tapInterface)])

        // Tolerate an already-absent device (double cleanup, crash recovery).
        guard tapDeviceExists(tapInterface) else {
            logger.debug(
                "TAP interface already absent, nothing to remove", metadata: ["tapName": .string(tapInterface)])
            return
        }

        // Best-effort down, then delete.
        _ = try? runProcess("ip", ["link", "set", tapInterface, "down"])
        try run("ip", ["tuntap", "del", "dev", tapInterface, "mode", "tap"])
        logger.info("Removed TAP interface", metadata: ["tapName": .string(tapInterface)])
    }
    #endif
}
