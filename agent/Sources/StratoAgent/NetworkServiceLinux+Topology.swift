import Foundation
import Logging
import StratoShared
import StratoAgentCore

#if os(Linux)
import SwiftOVN
#endif

extension NetworkServiceLinux: NetworkActuator {
    func observeTopology() async throws -> ObservedNetworkTopology {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let routers = try await ovnManager.getLogicalRouters()
        let routerPorts = try await ovnManager.getLogicalRouterPorts()
        let switchPorts = try await ovnManager.getLogicalSwitchPorts()
        let switches = try await ovnManager.getLogicalSwitches()
        let nats = try await ovnManager.getNATRules()

        // Only consider objects this reconciler owns, keyed off the
        // `strato-managed` external-id it stamps on everything it creates — never
        // a name prefix, so an operator's or another feature's `lr-*`/`ls-ext-*`
        // objects are never mistaken for Strato's and torn down.
        let managedRouters = routers.filter { Self.isManaged($0.external_ids) }
        let natByUUID = Dictionary(uniqueKeysWithValues: nats.compactMap { nat in nat.uuid.map { ($0, nat) } })
        var snatRules = Set<SNATRuleKey>()
        var dnatRules = Set<DNATRuleKey>()
        for router in managedRouters {
            for uuid in router.nat ?? [] {
                guard let nat = natByUUID[uuid], Self.isManaged(nat.external_ids) else { continue }
                if nat.natType == "snat" {
                    snatRules.insert(SNATRuleKey(router: router.name, logicalIP: nat.logical_ip))
                } else if nat.natType == "dnat_and_snat" {
                    dnatRules.insert(DNATRuleKey(router: router.name, externalIP: nat.external_ip))
                }
            }
        }

        return ObservedNetworkTopology(
            routerNames: Set(managedRouters.map(\.name)),
            routerPortNames: Set(routerPorts.filter { Self.isManaged($0.external_ids) }.map(\.name)),
            switchRouterPortNames: Set(
                switchPorts.filter { $0.portType == "router" && Self.isManaged($0.external_ids) }.map(\.name)),
            externalSwitchNames: Set(
                switches.filter { $0.external_ids?[Self.externalRoleKey] == Self.externalRoleValue }.map(
                    \.name)),
            snatRules: snatRules,
            dnatRules: dnatRules,
            // Metadata localports get their own set rather than joining
            // `switchRouterPortNames`, which is filtered to `type=router`. That
            // filter is also why an agent predating this field never swept a
            // localport it didn't understand — the ports were simply invisible
            // to its teardown diff.
            serviceLocalPortNames: Set(
                switchPorts.filter { $0.portType == Self.localPortType && Self.isManaged($0.external_ids) }
                    .map(\.name)))
        #else
        return ObservedNetworkTopology()
        #endif
    }

    /// Create or re-address a network's metadata `localport`.
    ///
    /// Deliberately without `port_security`, matching the localnet port: port
    /// security on a localport filters the agent's own replies to the guest.
    func ensureServiceLocalPort(_ port: DesiredServiceLocalPort) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let desired = OVNLogicalSwitchPort(
            name: port.name,
            portType: Self.localPortType,
            addresses: port.addresses,
            external_ids: [
                Self.managedKey: Self.managedValue,
                "description": "Strato instance metadata localport",
            ])
        if let existing = try await ovnManager.getLogicalSwitchPort(named: port.name) {
            // Re-write in place on drift: the port name is derived from the
            // network, so the row is stable across edits and a stale
            // type/address set would otherwise persist forever. Addresses
            // compared as a set — OVN's column is unordered.
            //
            // The switch the port sits on is deliberately not compared. Both the
            // port name and the switch name derive from the same network id, so
            // they can only disagree if an operator moved the port by hand —
            // and re-homing it would mean a delete and recreate, not an update,
            // which is a heavier repair than an unreachable case earns.
            let drifted =
                existing.portType != Self.localPortType
                || Set(existing.addresses ?? []) != Set(port.addresses)
            if drifted, let uuid = existing.uuid {
                try await ovnManager.updateLogicalSwitchPort(uuid: uuid, desired)
                logger.info(
                    "Updated metadata localport",
                    metadata: [
                        "port": .string(port.name),
                        "addresses": .string(port.addresses.joined(separator: ", ")),
                    ])
            }
            return
        }
        do {
            _ = try await ovnManager.createLogicalSwitchPort(desired, onSwitch: port.switchName)
        } catch {
            // Tolerate a concurrent creator that won the check→insert race.
            if try await ovnManager.getLogicalSwitchPort(named: port.name) == nil { throw error }
        }
        #endif
    }

    func removeServiceLocalPort(name: String) async throws {
        #if os(Linux)
        try? await ovnManager?.deleteLogicalSwitchPort(named: name)
        #endif
    }

    /// The managed `DNS` rows and the switches referencing each (STR-39).
    ///
    /// Ownership keys off the `strato-managed` + `dns-zone-id` external-ids
    /// this agent stamps, never the row's contents: the `DNS` table is a root
    /// table shared with whatever else runs against this northbound database,
    /// and an operator's own rows must be invisible to the teardown diff.
    func observeDNSZones() async throws -> [ObservedDNSZone] {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let rows = try await ovnManager.getDNS()
        // The attachment lives on the switch, so the reverse index is built
        // from the switch side. Unmanaged switches are included deliberately:
        // a managed row attached to a switch this agent doesn't author is
        // still an attachment it has to be able to see (and detach).
        var switchesByRow: [String: Set<String>] = [:]
        for logicalSwitch in try await ovnManager.getLogicalSwitches() {
            for uuid in logicalSwitch.dnsRecords ?? [] {
                switchesByRow[uuid, default: []].insert(logicalSwitch.name)
            }
        }
        return rows.compactMap { row in
            guard let uuid = row.uuid, let zoneId = DNSRowIdentity.ownedZoneID(row.external_ids) else {
                return nil
            }
            return ObservedDNSZone(
                uuid: uuid,
                zoneId: zoneId,
                recordsHash: row.external_ids?[DNSRowIdentity.recordsHashKey],
                zoneName: row.external_ids?[DNSRowIdentity.zoneNameKey],
                records: row.records,
                switchNames: switchesByRow[uuid] ?? [])
        }
        #else
        return []
        #endif
    }

    /// Apply one zone's decided convergence. The write says what changed, so a
    /// zone whose records are unchanged costs no OVSDB transaction at all —
    /// which is the whole point of the stamp, since a zone's record map is
    /// O(VMs on its networks) and ships on every sync.
    func ensureDNSZone(_ write: DNSZoneWrite) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let desired = OVNDNS(records: write.plan.records, external_ids: write.plan.externalIDs)
        let uuid: String
        if let existing = write.existingUUID {
            uuid = existing
            if write.rewriteRecords {
                try await ovnManager.updateDNS(uuid: existing, desired)
                logger.info(
                    "Updated DNS zone records",
                    metadata: [
                        "zone": .string(write.plan.zoneName),
                        "records": .stringConvertible(write.plan.records.count),
                    ])
            }
        } else {
            uuid = try await ovnManager.createDNS(desired)
            logger.info(
                "Realized DNS zone",
                metadata: [
                    "zone": .string(write.plan.zoneName),
                    "records": .stringConvertible(write.plan.records.count),
                ])
        }

        // Per-switch tolerance: the switch may not exist yet (its network's
        // reconcile step failed this pass), and one unattachable switch must
        // not cost the zone its other attachments. Retried by the next
        // level-triggered sync, which recomputes the diff from observation.
        for switchName in write.attach {
            do {
                try await ovnManager.attachDNS(uuid: uuid, toSwitch: switchName)
            } catch {
                logger.warning(
                    "Could not attach DNS zone to switch (retried next sync)",
                    metadata: [
                        "zone": .string(write.plan.zoneName),
                        "switch": .string(switchName),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }
        for switchName in write.detach {
            do {
                try await ovnManager.detachDNS(uuid: uuid, fromSwitch: switchName)
            } catch {
                logger.warning(
                    "Could not detach DNS zone from switch (retried next sync)",
                    metadata: [
                        "zone": .string(write.plan.zoneName),
                        "switch": .string(switchName),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }
        #endif
    }

    func removeDNSZone(uuid: String) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        try await ovnManager.deleteDNS(uuid: uuid)
        logger.info("Removed DNS zone row", metadata: ["row": .string(uuid)])
        #endif
    }

    func ensureSwitch(_ desired: DesiredSwitch) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        // Already on the UUID scheme.
        if try await ovnManager.getLogicalSwitch(named: desired.name) != nil { return }

        _ = try await findOrCreateLogicalSwitch(name: desired.name, subnet: desired.subnet)
        #endif
    }

    func ensureRouter(_ router: DesiredRouter) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        if try await ovnManager.getLogicalRouter(named: router.name) != nil { return }
        let logicalRouter = OVNLogicalRouter(
            name: router.name,
            external_ids: ["strato-managed": "true", "router-key": router.routerKey])
        do {
            _ = try await ovnManager.createLogicalRouter(logicalRouter)
        } catch {
            // Tolerate a concurrent creator that won the check→insert race.
            if try await ovnManager.getLogicalRouter(named: router.name) == nil { throw error }
        }
        #endif
    }

    func ensureRouterPort(_ port: DesiredRouterPort, onRouter routerName: String) async throws {
        #if os(Linux)
        try await ensureRouterPort(
            name: port.name, mac: port.mac, cidrs: port.cidrs,
            ipv6RAConfigs: port.ipv6RAConfigs,
            switchName: port.switchName, switchPortName: port.switchPortName, router: routerName)
        #endif
    }

    func ensureUplink(for router: DesiredRouter) async throws -> Bool {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        // SNAT requires an operator-configured dedicated external IP: the OVN
        // router port claims this address on the provider network, so it must be
        // one the host itself does not own (otherwise host and router conflict).
        // Without it we realize the router + east-west but no uplink/SNAT.
        guard let uplink = uplinkConfig else {
            logger.info(
                "No OVN uplink configured; realizing router without SNAT egress",
                metadata: ["router": .string(router.name)])
            return false
        }
        guard let externalIP = uplink.externalIP,
            let uplinkMAC = OVNNaming.routerPortMAC(gateway: externalIP)
        else {
            logger.error(
                "OVN uplink external_cidr is not a valid ip/prefix; skipping SNAT",
                metadata: ["externalCIDR": .string(uplink.externalCIDR)])
            return false
        }

        // Provider bridge + physnet mapping. The operator connects the bridge to
        // the external network out of band; the agent only wires the OVN side.
        try await ensureProviderBridge(uplink.bridge)
        try await ensureBridgeMapping(physnet: uplink.physnet, bridge: uplink.bridge)

        // External logical switch + localnet port (the provider attachment).
        // Created with the external role marker so observeTopology can tell it
        // apart from tenant switches and no operator switch is a candidate.
        if try await ovnManager.getLogicalSwitch(named: router.externalSwitchName) == nil {
            let externalSwitch = OVNLogicalSwitch(
                name: router.externalSwitchName,
                external_ids: [
                    Self.managedKey: Self.managedValue,
                    Self.externalRoleKey: Self.externalRoleValue,
                    "description": "Strato external/provider switch",
                ])
            do {
                _ = try await ovnManager.createLogicalSwitch(externalSwitch)
            } catch {
                if try await ovnManager.getLogicalSwitch(named: router.externalSwitchName) == nil { throw error }
            }
        }
        if try await ovnManager.getLogicalSwitchPort(named: router.localnetPortName) == nil {
            let localnet = OVNLogicalSwitchPort(
                name: router.localnetPortName,
                portType: "localnet",
                options: ["network_name": uplink.physnet],
                addresses: ["unknown"],
                external_ids: [Self.managedKey: Self.managedValue])
            _ = try await ovnManager.createLogicalSwitchPort(localnet, onSwitch: router.externalSwitchName)
        }

        // Gateway router port on the external switch, at the configured
        // dedicated external address. Dual-stack when the operator supplied an
        // `external_cidr6`: the same port then also claims the v6 external
        // address that IPv6 SNAT translates to (issue #519). A malformed
        // `external_cidr6` degrades the uplink to v4 rather than failing it —
        // mirroring how a bad tenant v6 config degrades a tenant router port.
        var uplinkCIDRs = [uplink.externalCIDR]
        if let externalCIDR6 = uplink.externalCIDR6 {
            // Canonical form, so a non-canonical operator spelling doesn't read
            // as port drift on every reconcile. `base`, not `networkAddress`:
            // this is the port's own host address, not the prefix.
            if let cidr6 = IPv6CIDR(externalCIDR6) {
                uplinkCIDRs.append("\(cidr6.base)/\(cidr6.prefix)")
            } else {
                logger.error(
                    "OVN uplink external_cidr6 is not a valid ip/prefix; realizing a v4-only uplink",
                    metadata: ["externalCIDR6": .string(externalCIDR6)])
            }
        }
        try await ensureRouterPort(
            name: router.externalRouterPortName, mac: uplinkMAC, cidrs: uplinkCIDRs,
            switchName: router.externalSwitchName, switchPortName: router.externalSwitchRouterPortName,
            router: router.name)

        // Pin the gateway port to this chassis. OVN only programs centralized
        // SNAT on the chassis holding the router's distributed gateway port,
        // so without a Gateway_Chassis binding the NAT rule sits in the NB
        // unprogrammed and VM traffic egresses un-NAT'd (issue #372).
        try await ensureGatewayChassis(onPort: router.externalRouterPortName)

        // Default route out the uplink, so SNAT'd traffic to off-subnet
        // destinations actually has a route (the NAT rule alone is not enough).
        if let nextHop = uplink.gateway {
            try await ensureDefaultRoute(router: router.name, nextHop: nextHop, family: .v4)
        } else {
            let message =
                "OVN uplink has no gateway; skipping the router default route "
                + "(SNAT egress limited to the external subnet)"
            logger.warning("\(message)", metadata: ["router": .string(router.name)])
        }

        // The v6 sibling. Independent of the v4 route: each reconciles only its
        // own family's default prefix, so one family's absence never disturbs
        // the other. Only meaningful once the port carries a v6 address.
        var installedIPv6Default = false
        if uplinkCIDRs.count > 1 {
            if let nextHop6 = uplink.gateway6 {
                // Validate here rather than letting ensureDefaultRoute throw: a
                // throw escapes ensureUplink, reconcile records the uplink as
                // not ready, and it then skips *every* SNAT rule on the router —
                // so a typo in the optional v6 next hop would take IPv4 egress
                // down with it. Degrade to a v4 uplink instead.
                if IPv6Address(nextHop6) != nil {
                    try await ensureDefaultRoute(router: router.name, nextHop: nextHop6, family: .v6)
                    installedIPv6Default = true
                } else {
                    logger.error(
                        "OVN uplink gateway6 is not a valid IPv6 address; skipping the IPv6 default route",
                        metadata: ["router": .string(router.name), "gateway6": .string(nextHop6)])
                }
            } else {
                let message =
                    "OVN uplink has no gateway6; skipping the router IPv6 default route "
                    + "(IPv6 SNAT egress limited to the external subnet)"
                logger.warning("\(message)", metadata: ["router": .string(router.name)])
            }
        }
        // Every path that does NOT install a `::/0` must also drop one we
        // installed earlier — a removed `external_cidr6`, a removed or now
        // malformed `gateway6`. Topology teardown covers switches, ports,
        // routers, and SNAT, never static routes, so nothing else would: the
        // router would keep steering v6 traffic at a next hop the config no
        // longer names. Never let this throw — it would escape ensureUplink and
        // cost the router its IPv4 SNAT, the very coupling fixed above.
        if !installedIPv6Default {
            do {
                try await removeManagedDefaultRoute(router: router.name, family: .v6)
            } catch {
                logger.error(
                    "Failed to remove the stale IPv6 default route",
                    metadata: ["router": .string(router.name), "error": .string("\(error)")])
            }
        }

        return true
        #else
        return false
        #endif
    }

    func ensureSNAT(router routerName: String, logicalIP: String) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        // SNAT to the configured dedicated external IP of the rule's own address
        // family (reconcile only calls this after ensureUplink returned true, so
        // the v4 uplink config is present/valid).
        let externalIP: String
        if IPv6CIDR(logicalIP) != nil {
            // An IPv6 uplink is optional and additive, so a dual-stack tenant
            // network on a v4-only uplink is a normal configuration, not an
            // error. Skip the rule rather than throw: reconcile catches per
            // subnet, so throwing wouldn't break v4 egress, but it would log an
            // error every pass for a site that simply has no IPv6 uplink.
            guard let externalIP6 = uplinkConfig?.externalIP6 else {
                logger.warning(
                    "IPv6 SNAT skipped: no external_cidr6 configured on the OVN uplink",
                    metadata: ["router": .string(routerName), "logicalIP": .string(logicalIP)])
                // Drop any rule an earlier, since-removed v6 uplink left behind.
                // Teardown can't: the plan still *wants* this rule (planning is
                // pure and can't see the uplink config), so the stale rule is
                // desired-and-observed and never classified as extra. It would
                // otherwise keep translating to an external address the port no
                // longer claims — worse than having no IPv6 egress at all.
                //
                // Managed-only, unlike the teardown path's `removeSNAT`: that
                // one is fed logical IPs `observeTopology` already filtered to
                // managed rules, whereas this runs on every pass against a
                // logical IP straight from the plan. A site that wires its own
                // IPv6 egress — plausible precisely because Strato lacked it —
                // would otherwise have its hand-authored rule deleted on every
                // reconcile.
                try await removeManagedSNAT(router: routerName, logicalIP: logicalIP)
                return
            }
            externalIP = externalIP6
        } else {
            guard let externalIP4 = uplinkConfig?.externalIP else {
                throw NetworkError.invalidConfiguration(
                    "SNAT for \(logicalIP) requested without a configured uplink external IP")
            }
            externalIP = externalIP4
        }
        // Idempotent: reuse a matching rule; re-point one whose external IP drifted.
        for rule in try await snatRules(onRouter: routerName)
        where rule.natType == "snat" && rule.logical_ip == logicalIP {
            if rule.external_ip == externalIP { return }
            if let uuid = rule.uuid { try await ovnManager.deleteNATRule(uuid: uuid) }
        }
        let nat = OVNNAT(
            natType: "snat", external_ip: externalIP, logical_ip: logicalIP,
            external_ids: [Self.managedKey: Self.managedValue])
        _ = try await ovnManager.createNATRule(nat, onRouter: routerName)
        #endif
    }

    func removeSNAT(router routerName: String, logicalIP: String) async throws {
        #if os(Linux)
        guard let ovnManager else { return }
        for rule in try await snatRules(onRouter: routerName)
        where rule.natType == "snat" && rule.logical_ip == logicalIP {
            if let uuid = rule.uuid { try await ovnManager.deleteNATRule(uuid: uuid) }
        }
        #endif
    }

    /// Remove only *this agent's* SNAT rule for `logicalIP`. The counterpart to
    /// `removeSNAT` for callers that haven't already filtered to managed rules:
    /// teardown acts on logical IPs `observeTopology` narrowed to the
    /// `strato-managed` set, but a withdrawn-config cleanup works from the plan
    /// and would otherwise delete an operator's own rule for the same subnet.
    func removeManagedSNAT(router routerName: String, logicalIP: String) async throws {
        #if os(Linux)
        guard let ovnManager else { return }
        for rule in try await snatRules(onRouter: routerName)
        where rule.natType == "snat" && rule.logical_ip == logicalIP && Self.isManaged(rule.external_ids) {
            if let uuid = rule.uuid { try await ovnManager.deleteNATRule(uuid: uuid) }
        }
        #endif
    }

    func ensureDNAT(router routerName: String, rule: DesiredDNATRule) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        // Idempotent by external IP (the rule's identity): reuse a matching
        // rule; re-point one whose attachment (logical IP/port) drifted —
        // that's a floating IP moving to another VM, which must update in
        // place rather than delete/recreate.
        for existing in try await snatRules(onRouter: routerName)
        where existing.natType == "dnat_and_snat" && existing.external_ip == rule.externalIP {
            if existing.logical_ip == rule.logicalIP
                && existing.logical_port == rule.logicalPort
                && existing.external_mac == rule.externalMAC
            {
                return
            }
            if let uuid = existing.uuid { try await ovnManager.deleteNATRule(uuid: uuid) }
        }
        let nat = OVNNAT(
            natType: "dnat_and_snat", external_ip: rule.externalIP, logical_ip: rule.logicalIP,
            external_mac: rule.externalMAC, logical_port: rule.logicalPort,
            external_ids: [Self.managedKey: Self.managedValue])
        _ = try await ovnManager.createNATRule(nat, onRouter: routerName)
        logger.info(
            "Ensured floating IP NAT",
            metadata: [
                "router": .string(routerName),
                "externalIP": .string(rule.externalIP),
                "logicalIP": .string(rule.logicalIP),
            ])
        #endif
    }

    func removeDNAT(router routerName: String, externalIP: String) async throws {
        #if os(Linux)
        guard let ovnManager else { return }
        for rule in try await snatRules(onRouter: routerName)
        where rule.natType == "dnat_and_snat" && rule.external_ip == externalIP {
            if let uuid = rule.uuid { try await ovnManager.deleteNATRule(uuid: uuid) }
        }
        #endif
    }

    func ensureDynamicRouting(for router: DesiredRouter, uplinkReady: Bool) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        guard let lr = try await ovnManager.getLogicalRouter(named: router.name), let lrUUID = lr.uuid
        else { return }

        // Enabling needs a realized uplink (the gateway port is what faces
        // the fabric); everything else — disabled, absent, or an uplink that
        // went away — converges to stripped options.
        if let config = dynamicRoutingConfig, config.enabled, uplinkReady {
            // Router: enable + what to redistribute. `withoutDynamicRouting()`
            // first, so an option removed from the config (e.g. vrf_name) is
            // dropped rather than lingering.
            let redistribute = Set(
                config.redistribute.compactMap { OVNDynamicRoutingRedistribute(rawValue: $0) })
            let desired = lr.withoutDynamicRouting().withDynamicRouting(
                enabled: true, redistribute: redistribute, vrfName: config.vrfName)
            if (lr.options ?? [:]) != (desired.options ?? [:]) {
                try await ovnManager.updateLogicalRouter(uuid: lrUUID, desired)
                logger.info(
                    "Enabled OVN dynamic routing on router",
                    metadata: [
                        "router": .string(router.name),
                        "redistribute": .string(config.redistribute.joined(separator: ",")),
                    ])
            }
            // Gateway port: VRF maintenance + which protocol traffic to punt
            // to the local FRR. Only meaningful on the uplink port — it is the
            // port facing the fabric.
            if let port = try await ovnManager.getLogicalRouterPort(named: router.externalRouterPortName),
                let portUUID = port.uuid
            {
                let protocols = Set(config.routingProtocols.compactMap { OVNRoutingProtocol(rawValue: $0) })
                let desiredPort = port.withoutDynamicRoutingOverrides().withDynamicRouting(
                    maintainVRF: config.maintainVRF, routingProtocols: protocols)
                if (port.options ?? [:]) != (desiredPort.options ?? [:]) {
                    try await ovnManager.updateLogicalRouterPort(uuid: portUUID, desiredPort)
                }
            }
        } else {
            // Converge off: strip any dynamic-routing options this agent set
            // earlier. The row encoder omits nil maps (which would leave the
            // stale options in place), so an empty result is written as an
            // explicit `[:]` via a minimal model.
            let strippedOptions = lr.withoutDynamicRouting().options
            if (lr.options ?? [:]) != (strippedOptions ?? [:]) {
                try await ovnManager.updateLogicalRouter(
                    uuid: lrUUID, OVNLogicalRouter(name: lr.name, options: strippedOptions ?? [:]))
                logger.info(
                    "Disabled OVN dynamic routing on router", metadata: ["router": .string(router.name)])
            }
            if let port = try await ovnManager.getLogicalRouterPort(named: router.externalRouterPortName),
                let portUUID = port.uuid
            {
                let strippedPortOptions = port.withoutDynamicRoutingOverrides().options
                if (port.options ?? [:]) != (strippedPortOptions ?? [:]) {
                    try await ovnManager.updateLogicalRouterPort(
                        uuid: portUUID,
                        OVNLogicalRouterPort(
                            name: port.name, mac: port.mac, networks: port.networks,
                            options: strippedPortOptions ?? [:]))
                }
            }
        }
        #endif
    }

    func removeSwitchRouterPort(name: String) async throws {
        #if os(Linux)
        try? await ovnManager?.deleteLogicalSwitchPort(named: name)
        #endif
    }

    func removeRouterPort(name: String) async throws {
        #if os(Linux)
        try? await ovnManager?.deleteLogicalRouterPort(named: name)
        #endif
    }

    func removeExternalSwitch(name: String) async throws {
        #if os(Linux)
        guard let ovnManager else { return }
        // Delete the switch's localnet port first (deleting the switch alone can
        // orphan it); its name is derived from the switch's router key.
        if name.hasPrefix("ls-ext-") {
            let key = String(name.dropFirst("ls-ext-".count))
            try? await ovnManager.deleteLogicalSwitchPort(named: OVNNaming.localnetPortName(routerKey: key))
        }
        try? await ovnManager.deleteLogicalSwitch(named: name)
        #endif
    }

    func removeRouter(name: String) async throws {
        #if os(Linux)
        try? await ovnManager?.deleteLogicalRouter(named: name)
        #endif
    }
}

#if os(Linux)
/// Which address family a router's default route belongs to. Each family owns
/// its own default prefix and reconciles only that prefix, so a v4 and a v6
/// default coexist on one router without disturbing each other.
enum DefaultRouteFamily {
    case v4
    case v6

    var defaultPrefix: String {
        switch self {
        case .v4: "0.0.0.0/0"
        case .v6: "::/0"
        }
    }
}
#endif
