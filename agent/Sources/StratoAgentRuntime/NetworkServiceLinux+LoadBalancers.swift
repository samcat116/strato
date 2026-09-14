import Foundation
import Logging
import StratoShared
import StratoAgentCore

#if os(Linux)
import SwiftOVN
#endif

#if os(Linux)
// MARK: - Native OVN Load Balancers (STR-28)

extension NetworkServiceLinux: LoadBalancerActuator {
    static var loadBalancerIDKey: String { "strato-load-balancer-id" }
    static var loadBalancerNetworkIDKey: String { "strato-network-id" }
    static var loadBalancerGenerationKey: String { "strato-generation" }
    static var loadBalancerDisplayNameKey: String { "strato-display-name" }
    static var loadBalancerListenerIDKey: String { "strato-listener-id" }

    func observeManagedLoadBalancers() async throws -> [ManagedLoadBalancerObservation] {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let loadBalancers = try await ovnManager.getLoadBalancers()
        let switches = try await ovnManager.getLogicalSwitches()
        let routers = try await ovnManager.getLogicalRouters()
        var observations: [ManagedLoadBalancerObservation] = []
        for row in loadBalancers {
            guard Self.isManaged(row.external_ids),
                let rowUUID = row.uuid,
                let rawID = row.external_ids?[Self.loadBalancerIDKey],
                let ownerID = UUID(uuidString: rawID)
            else { continue }
            observations.append(
                ManagedLoadBalancerObservation(
                    rowUUID: rowUUID,
                    ownerID: ownerID,
                    networkID: row.external_ids?[Self.loadBalancerNetworkIDKey].flatMap {
                        UUID(uuidString: $0)
                    },
                    switchNames: Set(
                        switches.filter { ($0.loadBalancer ?? []).contains(rowUUID) }.map(\.name)),
                    routerNames: Set(
                        routers.filter { ($0.load_balancer ?? []).contains(rowUUID) }.map(\.name))))
        }
        return observations
    }

    func ensureLoadBalancer(
        _ desired: DesiredLoadBalancer,
        networkID: UUID,
        routerName: String,
        switchNames: Set<String>,
        existing: ManagedLoadBalancerObservation?
    ) async throws -> String {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }

        let externalIDs = Self.loadBalancerExternalIDs(desired, networkID: networkID)
        let initialRow = Self.makeLoadBalancerRow(
            desired, healthChecks: [], externalIDs: externalIDs)
        let rowUUID: String
        var current: OVNLoadBalancer?
        if let existing {
            current = try await ovnManager.getLoadBalancers().first {
                $0.uuid == existing.rowUUID
            }
            if current != nil {
                rowUUID = existing.rowUUID
            } else {
                rowUUID = try await ovnManager.createLoadBalancer(initialRow)
            }
        } else {
            rowUUID = try await ovnManager.createLoadBalancer(initialRow)
        }

        let healthCheckUUIDs = try await reconcileHealthChecks(
            for: desired, loadBalancerUUID: rowUUID, manager: ovnManager)
        let wanted = Self.makeLoadBalancerRow(
            desired, healthChecks: healthCheckUUIDs, externalIDs: externalIDs)
        if current == nil {
            current = try await ovnManager.getLoadBalancers().first { $0.uuid == rowUUID }
        }
        if let current, !Self.loadBalancerRow(current, matches: wanted) {
            try await ovnManager.updateLoadBalancer(uuid: rowUUID, wanted)
        }

        let currentSwitches = existing?.switchNames ?? []
        let currentRouters = existing?.routerNames ?? []
        for name in switchNames.subtracting(currentSwitches).sorted() {
            try await ovnManager.attachLoadBalancer(uuid: rowUUID, toSwitch: name)
        }
        if !currentRouters.contains(routerName) {
            try await ovnManager.attachLoadBalancer(uuid: rowUUID, toRouter: routerName)
        }
        for name in currentSwitches.subtracting(switchNames).sorted() {
            try await ovnManager.detachLoadBalancer(uuid: rowUUID, fromSwitch: name)
        }
        for name in currentRouters.subtracting([routerName]).sorted() {
            try await ovnManager.detachLoadBalancer(uuid: rowUUID, fromRouter: name)
        }
        return rowUUID
    }

    func observeBackendHealth(
        for desired: DesiredLoadBalancer
    ) async throws -> [ObservedLoadBalancerBackend] {
        guard desired.healthCheck.enabled else {
            return desired.backends.map {
                ObservedLoadBalancerBackend(id: $0.id, healthStatus: .unknown)
            }
        }
        guard let ovnSouthboundManager else {
            throw NetworkError.notConnected(
                "OVN Southbound manager is not connected; cannot read Service_Monitor")
        }
        let monitors = try await ovnSouthboundManager.getServiceMonitors()
        return LoadBalancerBackendHealthMapper.map(
            desired: desired,
            monitors: monitors.map {
                LoadBalancerServiceMonitorObservation(
                    monitorType: $0.monitorType,
                    ipAddress: $0.ip,
                    port: $0.port,
                    protocolName: $0.protocolType,
                    logicalPort: $0.logical_port,
                    sourceIP: $0.src_ip,
                    status: $0.status)
            },
            observedAt: Date())
    }

    func removeLoadBalancer(_ observed: ManagedLoadBalancerObservation) async throws {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        for name in observed.switchNames.sorted() {
            if try await ovnManager.getLogicalSwitch(named: name) != nil {
                try await ovnManager.detachLoadBalancer(
                    uuid: observed.rowUUID, fromSwitch: name)
            }
        }
        for name in observed.routerNames.sorted() {
            if try await ovnManager.getLogicalRouter(named: name) != nil {
                try await ovnManager.detachLoadBalancer(
                    uuid: observed.rowUUID, fromRouter: name)
            }
        }
        try await ovnManager.deleteLoadBalancer(uuid: observed.rowUUID)
    }

    func reconcileHealthChecks(
        for desired: DesiredLoadBalancer,
        loadBalancerUUID: String,
        manager: OVNManager
    ) async throws -> [String] {
        let existing = try await manager.getLoadBalancerHealthChecks().filter {
            Self.isManaged($0.external_ids)
                && $0.external_ids?[Self.loadBalancerIDKey] == desired.id.uuidString
        }
        guard desired.healthCheck.enabled else {
            for check in existing {
                if let uuid = check.uuid {
                    try await manager.deleteLoadBalancerHealthCheck(uuid: uuid)
                }
            }
            return []
        }

        let byListener = Dictionary(grouping: existing) {
            $0.external_ids?[Self.loadBalancerListenerIDKey] ?? ""
        }
        let options = [
            "interval": String(desired.healthCheck.intervalSeconds),
            "timeout": String(desired.healthCheck.timeoutSeconds),
            "success_count": String(desired.healthCheck.successThreshold),
            "failure_count": String(desired.healthCheck.failureThreshold),
        ]
        var retained: [String] = []
        for listener in desired.listeners {
            let listenerID = listener.id.uuidString
            let externalIDs = [
                Self.managedKey: Self.managedValue,
                Self.loadBalancerIDKey: desired.id.uuidString,
                Self.loadBalancerListenerIDKey: listenerID,
            ]
            let wanted = OVNLoadBalancerHealthCheck(
                vip: "\(desired.vip):\(listener.port)",
                options: options,
                external_ids: externalIDs)
            let candidates = (byListener[listenerID] ?? []).sorted {
                ($0.uuid ?? "") < ($1.uuid ?? "")
            }
            if let keep = candidates.first, let uuid = keep.uuid {
                if keep.vip != wanted.vip || keep.options != options
                    || keep.external_ids != externalIDs
                {
                    try await manager.updateLoadBalancerHealthCheck(uuid: uuid, wanted)
                }
                retained.append(uuid)
            } else {
                retained.append(
                    try await manager.createLoadBalancerHealthCheck(
                        wanted, onLoadBalancer: loadBalancerUUID))
            }
        }

        let retainedSet = Set(retained)
        for stale in existing where stale.uuid.map({ !retainedSet.contains($0) }) ?? false {
            if let uuid = stale.uuid {
                try await manager.deleteLoadBalancerHealthCheck(uuid: uuid)
            }
        }
        return retained.sorted()
    }

    static func loadBalancerExternalIDs(
        _ desired: DesiredLoadBalancer,
        networkID: UUID
    ) -> [String: String] {
        [
            managedKey: managedValue,
            loadBalancerIDKey: desired.id.uuidString,
            loadBalancerNetworkIDKey: networkID.uuidString,
            loadBalancerGenerationKey: String(desired.generation),
            loadBalancerDisplayNameKey: desired.name,
        ]
    }

    static func makeLoadBalancerRow(
        _ desired: DesiredLoadBalancer,
        healthChecks: [String],
        externalIDs: [String: String]
    ) -> OVNLoadBalancer {
        var vips: [String: String] = [:]
        for listener in desired.listeners {
            vips["\(desired.vip):\(listener.port)"] = desired.backends
                .map { "\($0.ipAddress):\(listener.backendPort)" }
                .joined(separator: ",")
        }
        var mappings: [String: String] = [:]
        for backend in desired.backends {
            guard let vmID = backend.vmId,
                let nicIndex = backend.nicIndex,
                let sourceIP = backend.healthCheckSourceIP
            else { continue }
            mappings[backend.ipAddress] =
                "\(OVNNaming.vmPortName(vmId: vmID.uuidString, nicIndex: nicIndex)):\(sourceIP)"
        }
        return OVNLoadBalancer(
            name: "strato-lb-\(desired.id.uuidString.lowercased())",
            vips: vips,
            protocolType: desired.protocolName,
            health_check: healthChecks,
            ip_port_mappings: desired.healthCheck.enabled ? mappings : [:],
            external_ids: externalIDs)
    }

    static func loadBalancerRow(
        _ current: OVNLoadBalancer, matches wanted: OVNLoadBalancer
    ) -> Bool {
        current.name == wanted.name
            && current.vips == wanted.vips
            && current.protocolType == wanted.protocolType
            && Set(current.health_check ?? []) == Set(wanted.health_check ?? [])
            && (current.ip_port_mappings ?? [:]) == (wanted.ip_port_mappings ?? [:])
            && (current.selection_fields ?? []) == (wanted.selection_fields ?? [])
            && (current.options ?? [:]) == (wanted.options ?? [:])
            && current.external_ids == wanted.external_ids
    }
}
#endif
