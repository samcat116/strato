import Foundation
import Logging
import StratoShared
import StratoAgentCore

#if os(Linux)
import SwiftOVN
#endif

#if os(Linux)
extension NetworkServiceLinux {
    /// Create a router port and its peering `type=router` switch port in an
    /// idempotent pair (both, or neither, so the switch never has a dangling
    /// router peer). Shared by tenant ports and the external gateway port.
    /// `ipv6_ra_configs` is always written as a concrete map (empty when nil)
    /// so removing IPv6 from a network clears the port's RA config — the row
    /// encoder omits nil fields, which would otherwise leave it stale.
    func ensureRouterPort(
        name: String, mac: String, cidrs: [String], ipv6RAConfigs: [String: String]? = nil,
        switchName: String, switchPortName: String, router: String
    ) async throws {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let raConfigs = ipv6RAConfigs ?? [:]
        let desiredPort = OVNLogicalRouterPort(
            name: name, mac: mac, networks: cidrs,
            ipv6_ra_configs: raConfigs,
            external_ids: ["strato-managed": "true"])
        if let existing = try await ovnManager.getLogicalRouterPort(named: name) {
            // Re-address in place when the network's gateway/subnet (either
            // family) or RA config changed: the port name is stable (derived
            // from the network), so without this an edit would leave a stale
            // CIDR/MAC/RA and break L3.
            let drifted =
                Set(existing.networks) != Set(cidrs)
                || existing.mac != mac
                || (existing.ipv6_ra_configs ?? [:]) != raConfigs
            if drifted, let uuid = existing.uuid {
                try await ovnManager.updateLogicalRouterPort(uuid: uuid, desiredPort)
                logger.info(
                    "Updated logical router port addressing",
                    metadata: ["port": .string(name), "cidrs": .string(cidrs.joined(separator: " "))])
            }
        } else {
            _ = try await ovnManager.createLogicalRouterPort(desiredPort, onRouter: router)
        }
        if try await ovnManager.getLogicalSwitchPort(named: switchPortName) == nil {
            let switchPort = OVNLogicalSwitchPort(
                name: switchPortName,
                portType: "router",
                options: ["router-port": name],
                addresses: ["router"],
                external_ids: ["strato-managed": "true"])
            _ = try await ovnManager.createLogicalSwitchPort(switchPort, onSwitch: switchName)
        }
    }

    /// The SNAT/DNAT rules attached to a router, resolved from its `nat` refs.
    func snatRules(onRouter routerName: String) async throws -> [OVNNAT] {
        guard let ovnManager,
            let router = try await ovnManager.getLogicalRouter(named: routerName),
            let natUUIDs = router.nat
        else { return [] }
        let byUUID = Dictionary(
            uniqueKeysWithValues: try await ovnManager.getNATRules().compactMap { nat in
                nat.uuid.map { ($0, nat) }
            })
        return natUUIDs.compactMap { byUUID[$0] }
    }

    /// Ensure the external provider bridge exists, mirroring `ensureIntegrationBridge`.
    func ensureProviderBridge(_ bridgeName: String) async throws {
        guard let ovsManager else {
            throw NetworkError.notConnected("OVS manager not connected")
        }
        if try await ovsManager.getBridge(named: bridgeName) == nil {
            let bridge = OVSBridge(
                name: bridgeName,
                external_ids: ["description": "Strato OVN external/provider bridge"])
            do {
                _ = try await ovsManager.createBridge(bridge)
                logger.info("Created provider bridge", metadata: ["bridge": .string(bridgeName)])
            } catch {
                if try await ovsManager.getBridge(named: bridgeName) == nil { throw error }
            }
        }
        try await ensureBridgeLocalPort(bridgeName)
        await warnIfBridgeNetdevMissing(bridgeName)
    }

    /// Ensure the bridge-named internal `Port`/`Interface` pair exists.
    /// SwiftOVN's `createBridge` inserts only the `Bridge` row; without this
    /// pair `ovs-vswitchd` never instantiates the bridge's Linux netdev, so
    /// the bridge has no host presence and no localnet datapath (issue #371).
    /// `ovs-vsctl add-br` creates all three rows in one transaction — this
    /// repairs both freshly created bridges and ones from older agents.
    func ensureBridgeLocalPort(_ bridgeName: String) async throws {
        guard let ovsManager else {
            throw NetworkError.notConnected("OVS manager not connected")
        }
        if try await ovsManager.getPort(named: bridgeName) != nil { return }
        do {
            _ = try await ovsManager.createPort(
                OVSPort(name: bridgeName, interfaces: []),
                withInterface: OVSInterface(name: bridgeName, interfaceType: "internal"),
                onBridge: bridgeName)
            logger.info("Created bridge internal port", metadata: ["bridge": .string(bridgeName)])
        } catch {
            // Tolerate a concurrent creator that won the check→insert race.
            if try await ovsManager.getPort(named: bridgeName) == nil { throw error }
        }
    }

    /// Log loudly when the bridge netdev hasn't materialized shortly after its
    /// OVSDB rows converged — the rows committing does not prove that
    /// `ovs-vswitchd` realized the datapath (issue #371's silent failure mode,
    /// where the operator cannot address the bridge or attach the physical
    /// NIC). Warning-only: OVSDB is the desired state and vswitchd may just be
    /// catching up; usually the first probe succeeds and this costs one exec.
    fileprivate func warnIfBridgeNetdevMissing(_ bridgeName: String) async {
        for _ in 0..<10 {
            if let probe = try? await runProcess("ip", ["link", "show", "dev", bridgeName]),
                probe.status == 0
            {
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let message =
            "Provider bridge exists in OVSDB but its netdev did not appear; "
            + "host-side uplink wiring (addressing the bridge, attaching the external NIC) will fail"
        logger.warning("\(message)", metadata: ["bridge": .string(bridgeName)])
    }

    /// Bind the router's external gateway port to the local chassis (the OVS
    /// `system-id` that `ovn-controller` registers southbound). Only the
    /// uplink-authoring agent — the site's network controller — reaches this,
    /// so the local chassis is the site's designated SNAT gateway; stale
    /// Strato-managed bindings to other chassis (host re-provisioned, role
    /// moved) are removed, operator-authored rows are left alone.
    func ensureGatewayChassis(onPort portName: String) async throws {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let chassisName = try await localChassisSystemID()
        guard let port = try await ovnManager.getLogicalRouterPort(named: portName) else {
            throw NetworkError.ovnError(
                "external router port \(portName) not found while binding its gateway chassis")
        }
        let refs = Set(port.gateway_chassis ?? [])
        let bindings: [GatewayChassisBinding] = try await ovnManager.getGatewayChassis().compactMap { row in
            guard let uuid = row.uuid, refs.contains(uuid) else { return nil }
            return GatewayChassisBinding(
                uuid: uuid, chassisName: row.chassis_name, managed: Self.isManaged(row.external_ids))
        }
        let actions = GatewayChassisPlan.plan(localChassis: chassisName, existing: bindings)
        for uuid in actions.deleteUUIDs {
            try await ovnManager.deleteGatewayChassis(uuid: uuid)
            logger.info("Removed stale gateway chassis binding", metadata: ["port": .string(portName)])
        }
        if actions.createForLocalChassis {
            let binding = OVNGatewayChassis(
                name: OVNNaming.gatewayChassisName(portName: portName, chassis: chassisName),
                chassis_name: chassisName, priority: 1,
                external_ids: [Self.managedKey: Self.managedValue])
            _ = try await ovnManager.createGatewayChassis(binding, onRouterPort: portName)
            logger.info(
                "Bound external router port to gateway chassis",
                metadata: ["port": .string(portName), "chassis": .string(chassisName)])
        }
    }

    /// The chassis `system-id` of the local OVS — the name `ovn-controller`
    /// registers in the southbound `Chassis` table (set or verified by
    /// `ensureChassisConfiguration` at connect time).
    fileprivate func localChassisSystemID() async throws -> String {
        let result = try await runProcess(
            "ovs-vsctl",
            ["--timeout=\(Self.ovsCommandTimeoutSeconds)", "get", "open_vswitch", ".", "external_ids"])
        guard result.status == 0 else {
            throw NetworkError.ovsError(
                "cannot read chassis external_ids (exit \(result.status)): "
                    + result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let systemID = OVNChassisBootstrap.parseExternalIDs(result.output)["system-id"],
            !systemID.isEmpty
        else {
            throw NetworkError.invalidConfiguration(
                "the local OVS has no external_ids:system-id, so the SNAT gateway cannot be "
                    + "bound to this chassis. Enable ovn_bootstrap_chassis in the agent "
                    + "configuration or set external_ids:system-id on the OVS.")
        }
        return systemID
    }

    /// Ensure the local OVS carries `ovn-bridge-mappings=<physnet>:<bridge>` for
    /// the provider network, merged with any mappings already present.
    func ensureBridgeMapping(physnet: String, bridge: String) async throws {
        let current = try await runProcess(
            "ovs-vsctl",
            ["--timeout=\(Self.ovsCommandTimeoutSeconds)", "get", "open_vswitch", ".", "external_ids"])
        let existing = OVNChassisBootstrap.parseExternalIDs(current.output)["ovn-bridge-mappings"]
        guard let merged = OVNBridgeMappings.merged(existing: existing, physnet: physnet, bridge: bridge) else {
            return  // already mapped
        }
        try await run(
            "ovs-vsctl",
            [
                "--timeout=\(Self.ovsCommandTimeoutSeconds)", "set", "open_vswitch", ".",
                "external_ids:ovn-bridge-mappings=\(merged)",
            ])
        logger.info("Set OVN bridge mapping", metadata: ["mapping": .string(merged)])
    }

    /// Install (or update) the logical router's default route to the uplink next
    /// hop, so SNAT'd traffic to addresses outside the provider subnet has a
    /// route out. Uses SwiftOVN's `Logical_Router_Static_Route` API directly
    /// against the NB DB — no `ovn-nbctl` dependency on the host.
    ///
    /// `family` is declared by the caller, never sniffed from `nextHop`:
    /// `[ovn_uplink] gateway` is the IPv4 next hop and `gateway6` the IPv6 one,
    /// so an address of the wrong family is an operator error to reject, not a
    /// family to infer. Inferring it would let a v6 address in `gateway` install
    /// a `::/0`, skip `0.0.0.0/0` entirely, and still report the uplink ready —
    /// leaving IPv4 SNAT running over a router with no IPv4 default route.
    func ensureDefaultRoute(
        router routerName: String, nextHop: String, family: DefaultRouteFamily
    ) async throws {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        // The native OVSDB path writes nexthop verbatim, so validate the gateway
        // ourselves — the old `ovn-nbctl lr-route-add` rejected a malformed one.
        // Throwing keeps this a failed uplink instead of committing a broken route
        // and then proceeding to install SNAT over silently dead egress.
        let defaultPrefix = family.defaultPrefix
        let hop: String
        switch family {
        case .v4:
            guard IPFamily.ipv4.matches(nextHop) else {
                throw NetworkError.invalidConfiguration(
                    "OVN uplink gateway '\(nextHop)' is not a valid IPv4 address; cannot install default route")
            }
            hop = nextHop
        case .v6:
            // Canonicalized, so a non-canonical operator spelling
            // (`2001:0db8::1`) doesn't read as drift on every reconcile.
            guard let address6 = IPv6Address(nextHop) else {
                throw NetworkError.invalidConfiguration(
                    "OVN uplink gateway6 '\(nextHop)' is not a valid IPv6 address; cannot install default route"
                )
            }
            hop = address6.description
        }
        // The agent owns L3 on this router (deterministically named, created with
        // the managed external ID), so it owns the router's default route too.
        // Mirrors ensureSNAT's reconcile-in-place stance.
        let route = OVNLogicalRouterStaticRoute(
            ip_prefix: defaultPrefix, nexthop: hop,
            external_ids: [Self.managedKey: Self.managedValue])
        // Only the main-table dst-ip default is the one the agent owns and that the
        // old `ovn-nbctl lr-route-add` (no --policy/--route-table) reconciled. Leave
        // src-ip or named-route-table default routes (operator policy routing)
        // untouched. OVN defaults an unset policy to dst-ip and an unset route_table
        // to the main table, matching the route we create below.
        let defaults = try await staticRoutes(onRouter: routerName).filter {
            $0.ip_prefix == defaultPrefix
                && ($0.policy ?? "dst-ip") == "dst-ip"
                && ($0.route_table ?? "").isEmpty
        }
        // Keep at most one route that already matches the desired tagged route;
        // every other default is stale, drifted, legacy-untagged, or a duplicate
        // from an earlier/concurrent reconcile. Delete them all so exactly one
        // default per family remains and OVN can't fall back to a stale next hop.
        let keep = defaults.first(where: { $0.nexthop == hop && Self.isManaged($0.external_ids) })
        for existing in defaults where existing.uuid != keep?.uuid {
            if let uuid = existing.uuid { try await ovnManager.deleteStaticRoute(uuid: uuid) }
        }
        // Install the desired route only when nothing already matched.
        if keep == nil {
            _ = try await ovnManager.createStaticRoute(route, onRouter: routerName)
        }
        logger.info(
            "Installed default route on logical router",
            metadata: [
                "router": .string(routerName), "prefix": .string(defaultPrefix), "nextHop": .string(hop),
            ])
    }

    /// Delete this agent's own default route for `prefix` on `router`, if one is
    /// there. The counterpart to `ensureDefaultRoute` for the case where the
    /// operator withdrew the config that justified the route; topology teardown
    /// never touches static routes, so without this a withdrawn uplink leaves a
    /// live route behind.
    ///
    /// Only the managed main-table dst-ip route is removed. `ensureDefaultRoute`
    /// also clears untagged duplicates, but that is safe only because it is
    /// replacing them — here there is no replacement, so an operator's own
    /// default (untagged, or policy/named-table) is left alone.
    func removeManagedDefaultRoute(router routerName: String, family: DefaultRouteFamily) async throws {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let prefix = family.defaultPrefix
        for route in try await staticRoutes(onRouter: routerName)
        where route.ip_prefix == prefix
            && (route.policy ?? "dst-ip") == "dst-ip"
            && (route.route_table ?? "").isEmpty
            && Self.isManaged(route.external_ids)
        {
            guard let uuid = route.uuid else { continue }
            try await ovnManager.deleteStaticRoute(uuid: uuid)
            logger.info(
                "Removed stale default route from logical router",
                metadata: ["router": .string(routerName), "prefix": .string(prefix)])
        }
    }

    /// The static routes attached to a router, resolved from its
    /// `static_routes` refs. Mirrors `snatRules(onRouter:)`.
    fileprivate func staticRoutes(onRouter routerName: String) async throws -> [OVNLogicalRouterStaticRoute] {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        guard let routeUUIDs = try await ovnManager.getLogicalRouter(named: routerName)?.static_routes,
            !routeUUIDs.isEmpty
        else { return [] }
        let byUUID = Dictionary(
            uniqueKeysWithValues: try await ovnManager.getStaticRoutes().compactMap { route in
                route.uuid.map { ($0, route) }
            })
        return routeUUIDs.compactMap { byUUID[$0] }
    }
}
#endif
