import Foundation
import Logging
import StratoShared
import StratoAgentCore

#if os(Linux)
import SwiftOVN
#endif

// MARK: - L3 Network Reconciliation (issue #342)

extension NetworkServiceLinux {
    /// Converge this host's OVN L3 topology (per-project routers, router ports,
    /// SNAT uplinks) toward the control plane's desired network set. Delegates
    /// the diff to the pure `NetworkReconciler`, driving the OVSDB side effects
    /// through `self` as the actuator. No-op until the service is connected.
    ///
    /// `authoritative: false` means another agent (the site's network
    /// controller) authors the shared NB this agent writes its ports to
    /// (issue #343): topology is left entirely alone — reconciling here, even
    /// with an empty list, would tear down the controller's objects.
    func reconcileNetworks(
        _ networks: [DesiredNetworkState], authoritative: Bool,
        securityGroups: [DesiredSecurityGroup]?, portMemberships: [DesiredPortMembership],
        metadataNetworks: [UUID]?, resolverNetworks: [ResolverNetworkConfig]?,
        dnsZones: [DesiredDNSZone]?
    ) async {
        topologyAuthority = authoritative

        #if os(Linux)
        guard isConnected else {
            logger.debug("Network service not connected; skipping network reconciliation")
            return
        }
        #endif

        // The chassis half of the link-local services — instance metadata
        // (STR-49) and the network's resolver (STR-40) — converged before the
        // authority guard because it is per-host state this agent owns even when
        // it may not author topology, the `portMemberships` pattern. A sited
        // non-controller agent gets an empty `networks` list by design, yet its
        // guests need those addresses materialized locally just the same, so the
        // input is its own workloads' NIC specs.
        await reconcileChassisServicePorts(metadataNetworks)

        // The resolver's own host-namespace feet and the CoreDNS that binds
        // them, converged here for the chassis ports' reason and immediately
        // after them. Also before the authority guard — a resolver serves the
        // guests on *this* host, so it runs wherever they do. It does not
        // depend on the chassis namespace above: since ADR 0008 the two
        // services have separate ports and separate namespaces.
        await reconcileResolvers(resolverNetworks, dnsZones: dnsZones)

        guard authoritative else {
            lastObservedLoadBalancers = nil
            logger.debug("Not the site's network topology authority; skipping network reconciliation")
            // Membership is per-VM state this host owns even without topology
            // authority — its ports join the port groups the site's
            // controller authors (the LSP-binding pattern, issue #343).
            await SecurityGroupReconciler.reconcileMembership(
                memberships: portMemberships, actuator: self, logger: logger)
            return
        }

        // Generation guard: apply only entries at least as new as what we last
        // applied for each network, so a reordered stale sync can't re-address
        // ports or re-add/remove SNAT with an outdated spec. A network skipped as
        // stale is still present, so its live objects are protected from teardown
        // (left exactly as-is); current networks are governed by the plan, so
        // their dropped objects — e.g. SNAT after externalAccess is turned off —
        // are still torn down. Only networks absent from the sync are torn down.
        var current: [DesiredNetworkState] = []
        var stale: [DesiredNetworkState] = []
        for network in networks {
            if let applied = networkGenerations[network.networkId], network.generation < applied {
                logger.debug(
                    "Skipping stale network desired state",
                    metadata: [
                        "network": .string(network.name),
                        "generation": .stringConvertible(network.generation),
                        "applied": .stringConvertible(applied),
                    ])
                stale.append(network)
                continue
            }
            networkGenerations[network.networkId] = network.generation
            current.append(network)
        }
        var protected = NetworkReconciler.protectedTopology(forStale: stale)
        // A control plane that predates `metadataEnabled` says nothing about
        // metadata ports, and teardown is a set difference — so without this a
        // rollback would delete every live port on the next sync. See
        // `serviceLocalPortProtection(for:)`.
        protected.formUnion(NetworkReconciler.serviceLocalPortProtection(for: current))

        do {
            try await NetworkReconciler.reconcile(
                networks: current, actuator: self, logger: logger, protected: protected)
        } catch {
            // observeTopology failed (can't compute teardown safely); the
            // periodic level-triggered sync retries. Ensures already applied.
            logger.error(
                "Network reconciliation could not complete",
                metadata: ["error": .string(error.localizedDescription)])
        }

        #if os(Linux)
        lastObservedLoadBalancers = await LoadBalancerReconciler.reconcile(
            networks: current, actuator: self, logger: logger)
        #else
        lastObservedLoadBalancers = nil
        #endif

        // Converge each network's DHCP_Options rows here, level-triggered,
        // not only when a NIC is realized: DHCP edits don't bump VM or
        // network generations, and converged VMs never re-run createVMNetwork,
        // so this is the only path that reaches a live network whose DHCP
        // config changed — including deleting its rows when DHCP is turned
        // off (their weak refs clear every port's binding). A nil dhcpEnabled
        // means the control plane predates the field; leave the rows to the
        // NIC-driven path exactly as before.
        for network in current {
            guard let dhcpEnabled = network.dhcpEnabled else { continue }
            await attemptDHCPConvergence(for: network, dhcpEnabled: dhcpEnabled)
        }

        // DNS zones (STR-39), converged here for the DHCP rows' reason and on
        // the same terms: records change when a VM anywhere in the site is
        // created, renamed, or deleted, none of which bumps this network's
        // generation, so the level-triggered network reconcile is the only path
        // that reaches them. After the topology pass, because a zone attaches
        // to switches that pass is what creates. Nil means the control plane
        // has no DNS opinion — leave every managed row alone, exactly like a
        // nil `dhcpEnabled`.
        if let dnsZones {
            do {
                try await DNSZoneReconciler.reconcile(zones: dnsZones, actuator: self, logger: logger)
            } catch {
                // The row snapshot couldn't be read, so teardown can't be
                // computed safely; the next full desired-state payload retries.
                logger.error(
                    "DNS zone reconciliation could not complete",
                    metadata: ["error": .string(error.localizedDescription)])
            }
        }

        // Security groups (authority side): converge port groups + ACLs, then
        // this host's own ports' membership. Nil means the control plane has
        // no security-group opinion (predates the feature, or omits the field
        // for this pre-v20-registered agent — impossible here, but the
        // contract stands): touch nothing, exactly like the `networks` list's
        // absence semantics.
        var securityGroupTiersReady = false
        if let securityGroups {
            do {
                securityGroupTiersReady = try await SecurityGroupReconciler.reconcile(
                    securityGroups: securityGroups, actuator: self, logger: logger)
            } catch {
                logger.error(
                    "Security-group reconciliation could not complete",
                    metadata: ["error": .string(error.localizedDescription)])
            }
        }

        // Network ACLs (authority side) run only after every managed security-
        // group port group has migrated to tier 2. An old tier-0
        // `allow-related` ACL is terminal and would bypass the tier-1 NACL.
        // Per-network nil remains no opinion; an explicit [] tears the policy
        // down. Stale networks are protected from the global observed-minus-
        // desired reap just like their topology is above.
        if current.contains(where: { $0.networkACLs != nil }) {
            if securityGroupTiersReady {
                do {
                    try await NetworkACLReconciler.reconcile(
                        networks: current,
                        protectedSwitchNames: Set(
                            stale.map { OVNNaming.switchName(networkId: $0.networkId) }),
                        actuator: self,
                        logger: logger)
                } catch {
                    logger.error(
                        "Network ACL reconciliation could not complete",
                        metadata: ["error": .string(error.localizedDescription)])
                }
            } else {
                logger.warning(
                    "Network ACL reconciliation deferred until every managed security group uses the tiered ACL schema")
            }
        }
        await SecurityGroupReconciler.reconcileMembership(
            memberships: portMemberships, actuator: self, logger: logger)
    }

    func observedLoadBalancers() async -> [ObservedLoadBalancerState]? {
        lastObservedLoadBalancers
    }

    /// Converge this chassis's metadata namespaces toward `desired` — the
    /// networks this host runs a metadata-enabled NIC on (STR-49).
    ///
    /// Level-triggered like everything else here: create what's missing, remove
    /// what's no longer wanted. Nil means the control plane predates the field
    /// and has no opinion; converging an empty set against it would tear down
    /// every live namespace on a rollback, so nil touches nothing — the
    /// `dhcpEnabled` contract.
    ///
    /// Observation keys off external-ids rather than the `mdp` name prefix, so
    /// an operator's own internal ports on `br-int` are never candidates for
    /// removal.
    func reconcileResolvers(
        _ resolverNetworks: [ResolverNetworkConfig]?, dnsZones: [DesiredDNSZone]?
    ) async {
        #if os(Linux)
        guard let resolverNetworks else { return }
        guard let resolverSupervisor else {
            if !resolverNetworks.isEmpty {
                logger.debug(
                    "Networks want a resolver but this host has no usable CoreDNS; skipping",
                    metadata: ["networks": .stringConvertible(resolverNetworks.count)])
            }
            return
        }

        // The host-namespace foot for each network, converged before the
        // process: CoreDNS binds these addresses, and `bind` naming one that
        // does not exist makes it refuse to start — for every network at once,
        // now that one process serves them all.
        await reconcileResolverHostPorts(resolverNetworks)

        let zones = dnsZones ?? []
        let ipv6 = ResolverSupervisionPolicy.supportsIPv6()
        let networks = resolverNetworks.map { network in
            CoreDNSZoneRenderer.Network(
                networkId: network.networkId,
                bindAddresses: ResolverSupervisionPolicy.bindable(
                    network.addresses, ipv6Available: ipv6),
                zones: zones.filter { $0.networkIds.contains(network.networkId) },
                upstreams: network.upstreams,
                searchDomain: network.searchDomain)
        }
        await resolverSupervisor.reconcile(ResolverRenderRequest(networks: networks))
        #endif
    }

    /// Converge the host-namespace interface that terminates each network's
    /// resolver localport, plus its policy routing.
    func reconcileResolverHostPorts(_ desired: [ResolverNetworkConfig]) async {
        #if os(Linux)
        guard let ovsManager, let ipBinaryPath, let sysctlBinaryPath else { return }
        let observed: [ObservedResolverHostPort]
        do {
            observed = try await observedResolverHostPorts(ovsManager)
        } catch {
            logger.error(
                "Could not read resolver host ports; skipping this pass",
                metadata: ["error": .string(error.localizedDescription)])
            return
        }
        let wanted = Dictionary(
            desired.map { ($0.networkId, $0) }, uniquingKeysWith: { first, _ in first })

        for action in ResolverHostPortReconciler.actions(
            desired: wanted.mapValues(\.addresses), observed: observed)
        {
            switch action {
            case .realize(let networkId, let addresses):
                await attemptResolverHostPortSetup(
                    networkId: networkId, addresses: addresses, ipBinaryPath: ipBinaryPath,
                    sysctlBinaryPath: sysctlBinaryPath)
            case .remove(let networkId, let interfaceName, let addresses):
                await removeResolverHostPort(
                    networkId: networkId, interfaceName: interfaceName, addresses: addresses,
                    ipBinaryPath: ipBinaryPath)
            }
        }
        #endif
    }

    #if os(Linux)
    func observedResolverHostPorts(_ ovsManager: OVSManager) async throws
        -> [ObservedResolverHostPort]
    {
        var found: [ObservedResolverHostPort] = []
        for interface in try await ovsManager.getInterfaces() {
            guard let ids = interface.external_ids,
                ids[ChassisServicePlan.managedKey] == ChassisServicePlan.managedValue,
                ids[ChassisServicePlan.roleKey] == ResolverHostPortPlan.roleValue,
                let raw = ids[ChassisServicePlan.networkIDKey],
                let networkId = UUID(uuidString: raw)
            else { continue }
            found.append(
                ObservedResolverHostPort(
                    networkId: networkId,
                    interfaceName: interface.name,
                    addresses: ResolverHostPortPlan.parseAddresses(
                        ids[ResolverHostPortPlan.addressesKey])))
        }
        return found
    }

    func attemptResolverHostPortSetup(
        networkId: UUID, addresses: [String], ipBinaryPath: String, sysctlBinaryPath: String
    ) async {
        // A missing `tc` costs the policer, not the resolver: an unlimited but
        // working resolver beats no resolver, and the host preflight already
        // reports the tool as absent.
        let plan = ResolverHostPortPlan.plan(
            networkId: networkId, addresses: addresses, ipBinaryPath: ipBinaryPath,
            sysctlBinaryPath: sysctlBinaryPath,
            tcBinaryPath: tcBinaryPath ?? "tc",
            bridge: Self.ovnIntegrationBridge, ovsTimeoutSeconds: Self.ovsCommandTimeoutSeconds,
            ratePPS: tcBinaryPath == nil ? 0 : linkLocalServiceRatePPS)
        do {
            try await run("ovs-vsctl", plan.ovsAttach)
            _ = try await verifyOVSBinding(
                verify: plan.ovsVerify, device: plan.interfaceName, portName: plan.logicalPortName,
                stage: "attach")
            for command in plan.setup {
                try await runNetnsCommand(command)
            }
            logger.info(
                "Realized resolver host port",
                metadata: [
                    "networkId": .string(networkId.uuidString),
                    "interface": .string(plan.interfaceName),
                    "addresses": .string(addresses.joined(separator: ",")),
                ])
        } catch {
            logger.error(
                "Failed to realize resolver host port",
                metadata: [
                    "networkId": .string(networkId.uuidString),
                    "error": .string(error.localizedDescription),
                ])
            // Roll back so the next pass observes an honest "not built". A
            // half-built foot is worse here than elsewhere: CoreDNS binds these
            // addresses, so one that exists without its routing answers queries
            // whose replies go nowhere.
            await removeResolverHostPort(
                networkId: networkId, interfaceName: plan.interfaceName, addresses: addresses,
                ipBinaryPath: ipBinaryPath, quiet: true)
        }
    }

    func removeResolverHostPort(
        networkId: UUID, interfaceName: String, addresses: [String], ipBinaryPath: String,
        quiet: Bool = false
    ) async {
        let removal = ResolverHostPortPlan.teardownPlan(
            networkId: networkId, interfaceName: interfaceName, addresses: addresses,
            ipBinaryPath: ipBinaryPath, bridge: Self.ovnIntegrationBridge,
            ovsTimeoutSeconds: Self.ovsCommandTimeoutSeconds)
        // Rules first: they outlive the interface, which the OVS detach
        // destroys. Removing the device first would strand every rule that named
        // its address, and those accumulate in the host's policy table.
        for command in removal.commands {
            try? await runNetnsCommand(command)
        }
        do {
            try await run("ovs-vsctl", removal.ovsDetach)
        } catch {
            if !quiet {
                logger.warning(
                    "Failed to remove resolver host port",
                    metadata: [
                        "networkId": .string(networkId.uuidString),
                        "error": .string(error.localizedDescription),
                    ])
            }
            return
        }
        if !quiet {
            logger.info(
                "Removed resolver host port", metadata: ["networkId": .string(networkId.uuidString)])
        }
    }
    #endif

    func reconcileChassisServicePorts(_ desired: [UUID]?) async {
        #if os(Linux)
        guard let desired else { return }
        guard let ovsManager else { return }

        let observed: [ObservedChassisServicePort]
        do {
            observed = try await observedChassisServicePorts(ovsManager)
        } catch {
            // Without a trustworthy snapshot, removals can't be computed safely.
            // Creates are idempotent, so skip the whole pass and let the next
            // full desired-state payload retry rather than guess.
            logger.error(
                "Could not read chassis service ports; skipping this pass",
                metadata: ["error": .string(error.localizedDescription)])
            return
        }

        for action in ChassisServiceReconciler.actions(desired: desired, observed: observed) {
            switch action {
            case .realize(let networkId):
                await attemptChassisServiceSetup(networkId: networkId)
            case .remove(let networkId, let interfaceName):
                await removeChassisServicePort(networkId: networkId, interfaceName: interfaceName)
            }
        }
        #endif
    }

    #if os(Linux)
    /// Every metadata interface this chassis currently owns, read from the
    /// interfaces' external-ids — never a name prefix, so an operator's own
    /// internal port on `br-int` is never a removal candidate.
    ///
    /// The namespace is probed alongside the row because the two have different
    /// lifetimes (see `ObservedChassisServicePort.namespacePresent`). A `stat` per
    /// network, no subprocess.
    func observedChassisServicePorts(_ ovsManager: OVSManager) async throws
        -> [ObservedChassisServicePort]
    {
        var found: [ObservedChassisServicePort] = []
        for interface in try await ovsManager.getInterfaces() {
            guard let ids = interface.external_ids,
                ids[ChassisServicePlan.managedKey] == ChassisServicePlan.managedValue,
                ids[ChassisServicePlan.roleKey] == ChassisServicePlan.roleValue,
                let raw = ids[ChassisServicePlan.networkIDKey],
                let networkId = UUID(uuidString: raw)
            else { continue }
            found.append(
                ObservedChassisServicePort(
                    networkId: networkId,
                    interfaceName: interface.name,
                    namespacePresent: FileManager.default.fileExists(
                        atPath: ChassisServicePlan.netnsPath(networkId: networkId))))
        }
        return found
    }

    /// Realize one network's metadata namespace, logging and swallowing failure
    /// so one bad network can't stall the sync.
    ///
    /// The logical switch port this binds to may not exist yet: on a
    /// non-controller agent the site's network controller writes it, and the two
    /// syncs are independent. That needs no retry logic — `ovn-controller`
    /// simply leaves the port unbound until the row appears, and the next full
    /// desired-state payload re-verifies.
    func attemptChassisServiceSetup(networkId: UUID) async {
        guard let ipBinaryPath else {
            let message =
                "Link-local services need the iproute2 `ip` tool, which was not found on this host; "
                + "guests on this network will not reach the metadata or resolver addresses"
            logger.warning(
                "\(message)",
                metadata: [
                    "networkId": .string(networkId.uuidString),
                    "searched": .string(SandboxJailerResolver.ipBinaryCandidates.joined(separator: ", ")),
                ])
            return
        }
        // A missing `tc` costs the policer, not the service: an unlimited but
        // working resolver beats no resolver, and the host preflight already
        // reports the tool as absent.
        let ratePPS = tcBinaryPath == nil ? 0 : linkLocalServiceRatePPS
        let plan = ChassisServicePlan.plan(
            networkId: networkId,
            ipBinaryPath: ipBinaryPath, tcBinaryPath: tcBinaryPath ?? "tc",
            bridge: Self.ovnIntegrationBridge, ovsTimeoutSeconds: Self.ovsCommandTimeoutSeconds,
            ratePPS: ratePPS)
        do {
            // Ordering is forced from both sides: the device cannot be moved
            // into a namespace that does not exist, and it cannot be moved
            // before the OVS attach creates it. Hence the attach between the two
            // halves of setup.
            for command in plan.namespaceSetup {
                try await runNetnsCommand(command)
            }
            try await run("ovs-vsctl", plan.ovsAttach)
            _ = try await verifyOVSBinding(
                verify: plan.ovsVerify, device: plan.interfaceName, portName: plan.logicalPortName,
                stage: "attach")
            for command in plan.interfaceSetup {
                try await runNetnsCommand(command)
            }
            // Re-read after the move. Moving a TAP out from under OVS silently
            // kills its port while the rows survive (STR-99); an internal port
            // is a different animal and should be fine, but "should be fine" is
            // exactly what that bug looked like, so prove it.
            let binding = try await verifyOVSBinding(
                verify: plan.ovsVerify, device: plan.interfaceName, portName: plan.logicalPortName,
                stage: "namespace-setup")
            logger.info(
                "Realized chassis service namespace",
                metadata: [
                    "networkId": .string(networkId.uuidString),
                    "netns": .string(plan.netnsName),
                    "interface": .string(plan.interfaceName),
                    "port": .string(plan.logicalPortName),
                    "ofport": .string(binding.ofport.map(String.init) ?? "unset"),
                ])
        } catch {
            logger.error(
                "Failed to realize chassis service namespace",
                metadata: [
                    "networkId": .string(networkId.uuidString),
                    "error": .string(error.localizedDescription),
                ])
            // Roll the namespace back so the next pass observes an honest
            // "not built" and rebuilds from scratch. Without this a setup that
            // died between `netns add` and the addresses would leave a namespace
            // that looks realized to every future observation while carrying no
            // addresses — the same silent half-built state the reboot case
            // produces, just reached a different way.
            await removeChassisServicePort(
                networkId: networkId, interfaceName: plan.interfaceName, quiet: true)
        }
    }

    /// Remove one network's metadata namespace and its OVS port. Each step is
    /// independently tolerant so a partial teardown still removes what it can.
    ///
    /// `interfaceName` is the device observed on the bridge rather than one
    /// rederived here, so teardown removes what it actually found.
    ///
    /// `quiet` marks the rollback path, where a failure is the *expected* shape
    /// (there may be nothing to remove yet) and the real error has already been
    /// logged by the caller.
    func removeChassisServicePort(
        networkId: UUID, interfaceName: String, quiet: Bool = false
    ) async {
        // Like sandbox teardown, cleanup falls back to the PATH-resolved name:
        // it must attempt something on a host whose iproute2 was never resolved,
        // rather than refuse and leak a namespace forever.
        let removal = ChassisServicePlan.teardownPlan(
            networkId: networkId, interfaceName: interfaceName, ipBinaryPath: ipBinaryPath ?? "ip",
            bridge: Self.ovnIntegrationBridge, ovsTimeoutSeconds: Self.ovsCommandTimeoutSeconds)
        var failures = 0
        do {
            try await run("ovs-vsctl", removal.ovsDetach)
        } catch {
            failures += 1
            if !quiet {
                logger.warning(
                    "Failed to remove chassis service OVS port",
                    metadata: [
                        "networkId": .string(networkId.uuidString),
                        "interface": .string(interfaceName),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }
        for command in removal.commands {
            do {
                try await runNetnsCommand(command)
            } catch {
                failures += 1
                if !quiet {
                    logger.warning(
                        "Failed to remove metadata namespace",
                        metadata: [
                            "networkId": .string(networkId.uuidString),
                            "command": .string(command.arguments.joined(separator: " ")),
                            "error": .string(error.localizedDescription),
                        ])
                }
            }
        }
        // Only claim what actually happened: a partial teardown leaves state
        // behind, and logging success over it is how a leak stays invisible.
        guard failures == 0, !quiet else { return }
        logger.info(
            "Removed chassis service namespace",
            metadata: [
                "networkId": .string(networkId.uuidString), "interface": .string(interfaceName),
            ])
    }
    #endif

    /// Best-effort per-network DHCP row convergence; a failing network is
    /// logged and left for the next full desired-state payload, like other
    /// reconcile steps.
    func attemptDHCPConvergence(for network: DesiredNetworkState, dhcpEnabled: Bool) async {
        #if os(Linux)
        do {
            if !dhcpEnabled {
                try await removeDHCPOptions(networkId: network.networkId, networkName: network.name)
                return
            }
            if let gateway = network.gateway, let cidr = IPv4CIDR(network.subnet) {
                // Masked, so the row key matches what the NIC path derives
                // from ip+netmask (the stored subnet may carry host bits).
                _ = try await ensureDHCPOptions(
                    networkId: network.networkId,
                    networkName: network.name,
                    subnet: "\(cidr.networkAddress)/\(cidr.prefix)",
                    gateway: gateway,
                    dnsServers: network.dnsServers ?? [], domainName: network.domainName,
                    leaseTime: network.leaseTime,
                    // `== true`, matching how the topology plan reads these
                    // fields: a control plane with no opinion advertises no
                    // route rather than one to an address it never asked to
                    // have published — and, for the resolver, leaves the guest
                    // pointed at the configured servers rather than at an
                    // address that may terminate nothing.
                    metadataEnabled: network.metadataEnabled == true,
                    resolverAddresses: network.resolverEnabled == true
                        ? (network.resolverAddresses ?? []) : [])
            }
            if let subnet6 = network.subnet6 {
                _ = try await ensureDHCPOptions6(
                    networkId: network.networkId, networkName: network.name, subnet6: subnet6,
                    dnsServers: network.dnsServers ?? [], domainName: network.domainName,
                    resolverAddresses: network.resolverEnabled == true
                        ? (network.resolverAddresses ?? []) : [])
            }
        } catch {
            logger.error(
                "DHCP options convergence failed for network",
                metadata: [
                    "network": .string(network.name),
                    "networkId": .string(network.networkId.uuidString),
                    "error": .string(error.localizedDescription),
                ])
        }
        #endif
    }
}
