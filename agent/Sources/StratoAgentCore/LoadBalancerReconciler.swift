import Foundation
import Logging
import StratoShared

/// An owner-tagged OVN Load_Balancer row and the parents that currently
/// reference it. Names are observations only; resource identity is always the
/// Strato UUID in `ownerID`.
public struct ManagedLoadBalancerObservation: Sendable, Equatable {
    public let rowUUID: String
    public let ownerID: UUID
    public let switchNames: Set<String>
    public let routerNames: Set<String>

    public init(
        rowUUID: String,
        ownerID: UUID,
        switchNames: Set<String> = [],
        routerNames: Set<String> = []
    ) {
        self.rowUUID = rowUUID
        self.ownerID = ownerID
        self.switchNames = switchNames
        self.routerNames = routerNames
    }
}

/// The subset of an OVN Southbound `Service_Monitor` row needed to identify
/// and report one native load-balancer backend. Keeping this representation in
/// core makes the status mapping testable without linking SwiftOVN or running
/// an OVSDB server.
public struct LoadBalancerServiceMonitorObservation: Sendable, Equatable {
    public let monitorType: String?
    public let ipAddress: String
    public let port: Int
    public let protocolName: String?
    public let logicalPort: String?
    public let sourceIP: String?
    public let status: String?

    public init(
        monitorType: String? = nil,
        ipAddress: String,
        port: Int,
        protocolName: String? = nil,
        logicalPort: String? = nil,
        sourceIP: String? = nil,
        status: String?
    ) {
        self.monitorType = monitorType
        self.ipAddress = ipAddress
        self.port = port
        self.protocolName = protocolName
        self.logicalPort = logicalPort
        self.sourceIP = sourceIP
        self.status = status
    }
}

public enum LoadBalancerBackendHealthMapper {
    /// Map materialized OVN service monitors to stable Strato backend ids. One
    /// backend can have a monitor per listener; any error/offline listener
    /// makes the backend unhealthy, while it is online only when every
    /// materialized listener monitor is online.
    public static func map(
        desired: DesiredLoadBalancer,
        monitors: [LoadBalancerServiceMonitorObservation],
        observedAt: Date
    ) -> [ObservedLoadBalancerBackend] {
        guard desired.healthCheck.enabled else {
            return desired.backends.map {
                ObservedLoadBalancerBackend(id: $0.id, healthStatus: .unknown)
            }
        }
        let backendPorts = Set(desired.listeners.map(\.backendPort))
        return desired.backends.map { backend in
            let logicalPort = backend.vmId.flatMap { vmID in
                backend.nicIndex.map {
                    OVNNaming.vmPortName(vmId: vmID.uuidString, nicIndex: $0)
                }
            }
            let matching = monitors.filter { monitor in
                (monitor.monitorType == nil || monitor.monitorType == "load-balancer")
                    && monitor.ipAddress == backend.ipAddress
                    && backendPorts.contains(monitor.port)
                    && (monitor.protocolName == nil
                        || monitor.protocolName == desired.protocolName)
                    && (logicalPort == nil || monitor.logicalPort == logicalPort)
                    && (backend.healthCheckSourceIP == nil
                        || monitor.sourceIP == backend.healthCheckSourceIP)
            }
            guard !matching.isEmpty else {
                // ovn-northd has not materialized a monitor yet (or this is an
                // off-platform endpoint with no logical-port mapping).
                return ObservedLoadBalancerBackend(
                    id: backend.id, healthStatus: .unknown)
            }
            let statuses = matching.compactMap { $0.status?.lowercased() }
            let health: ObservedLoadBalancerBackendHealth
            if statuses.contains("error") {
                health = .error
            } else if statuses.contains("offline") {
                health = .offline
            } else if backendPorts.allSatisfy({ backendPort in
                let portMonitors = matching.filter { $0.port == backendPort }
                return !portMonitors.isEmpty
                    && portMonitors.allSatisfy { $0.status?.lowercased() == "online" }
            }) {
                health = .online
            } else {
                health = .unknown
            }
            return ObservedLoadBalancerBackend(
                id: backend.id, healthStatus: health, lastCheckedAt: observedAt)
        }
    }
}

/// Native-library boundary for the pure authoritative LB reconciler. Linux
/// implements it with SwiftOVN; tests use an in-memory fake without linking
/// OVN or requiring an OVSDB daemon.
public protocol LoadBalancerActuator: Sendable {
    func observeManagedLoadBalancers() async throws -> [ManagedLoadBalancerObservation]
    func ensureLoadBalancer(
        _ desired: DesiredLoadBalancer,
        routerName: String,
        switchNames: Set<String>,
        existing: ManagedLoadBalancerObservation?
    ) async throws -> String
    /// Read Southbound `Service_Monitor` and map its endpoint rows back to the
    /// stable backend resource ids in this desired LB.
    func observeBackendHealth(
        for desired: DesiredLoadBalancer
    ) async throws -> [ObservedLoadBalancerBackend]
    func removeLoadBalancer(_ observed: ManagedLoadBalancerObservation) async throws
}

public enum LoadBalancerReconciler {
    private struct Placement: Sendable {
        let desired: DesiredLoadBalancer
        let routerName: String
        let switchNames: Set<String>
    }

    /// Reconcile every LB carried by an authoritative network list. If any
    /// network has a nil collection, the sender is pre-v43 and has no opinion:
    /// leave all owner-tagged rows alone rather than interpreting silence as
    /// deletion.
    public static func reconcile(
        networks: [DesiredNetworkState],
        actuator: any LoadBalancerActuator,
        logger: Logger
    ) async -> [ObservedLoadBalancerState]? {
        guard networks.allSatisfy({ $0.loadBalancers != nil }) else { return nil }

        var placements: [UUID: Placement] = [:]
        for network in networks {
            for desired in network.loadBalancers ?? [] {
                var switches = Set(
                    desired.backends.compactMap(\.networkId).map {
                        OVNNaming.switchName(networkId: $0)
                    })
                // Attach to the VIP switch even before the first backend is
                // registered; clients on that switch must be able to reach it.
                switches.insert(OVNNaming.switchName(networkId: network.networkId))
                placements[desired.id] = Placement(
                    desired: desired,
                    routerName: OVNNaming.routerName(routerKey: network.routerKey),
                    switchNames: switches)
            }
        }

        let observed: [ManagedLoadBalancerObservation]
        do {
            observed = try await actuator.observeManagedLoadBalancers()
        } catch {
            logger.error(
                "Cannot observe managed OVN load balancers; skipping destructive reconciliation",
                metadata: ["error": .string(error.localizedDescription)])
            return placements.values.map {
                failure(for: $0.desired, error: error.localizedDescription)
            }.sorted { $0.id.uuidString < $1.id.uuidString }
        }

        let observedByOwner = Dictionary(grouping: observed, by: \.ownerID)
        var results: [ObservedLoadBalancerState] = []
        var retainedRows: Set<String> = []

        for ownerID in placements.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let placement = placements[ownerID] else { continue }
            let candidates = (observedByOwner[ownerID] ?? []).sorted {
                $0.rowUUID < $1.rowUUID
            }
            do {
                let retained = try await actuator.ensureLoadBalancer(
                    placement.desired,
                    routerName: placement.routerName,
                    switchNames: placement.switchNames,
                    existing: candidates.first)
                retainedRows.insert(retained)
                for duplicate in candidates where duplicate.rowUUID != retained {
                    try await actuator.removeLoadBalancer(duplicate)
                }
                let backendHealth: [ObservedLoadBalancerBackend]
                var healthError: String?
                do {
                    backendHealth = try await actuator.observeBackendHealth(
                        for: placement.desired)
                } catch {
                    healthError = "Backend health observation failed: \(error.localizedDescription)"
                    backendHealth = placement.desired.backends.map {
                        ObservedLoadBalancerBackend(id: $0.id, healthStatus: .error)
                    }
                }
                results.append(
                    ObservedLoadBalancerState(
                        id: ownerID,
                        observedGeneration: placement.desired.generation,
                        status: .active,
                        lastError: healthError,
                        backends: backendHealth))
            } catch {
                logger.error(
                    "Native OVN load-balancer reconciliation failed",
                    metadata: [
                        "loadBalancerId": .string(ownerID.uuidString),
                        "error": .string(error.localizedDescription),
                    ])
                results.append(failure(for: placement.desired, error: error.localizedDescription))
            }
        }

        // Owner-tagged rows omitted from the authoritative desired set are
        // stale. Untagged/operator rows are absent from `observed` by contract.
        for stale in observed.sorted(by: { $0.rowUUID < $1.rowUUID })
        where placements[stale.ownerID] == nil && !retainedRows.contains(stale.rowUUID) {
            do {
                try await actuator.removeLoadBalancer(stale)
            } catch {
                logger.error(
                    "Could not remove stale managed OVN load balancer",
                    metadata: [
                        "loadBalancerId": .string(stale.ownerID.uuidString),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }
        return results
    }

    private static func failure(for desired: DesiredLoadBalancer, error: String)
        -> ObservedLoadBalancerState
    {
        ObservedLoadBalancerState(
            id: desired.id,
            observedGeneration: desired.generation,
            status: .error,
            lastError: error,
            backends: desired.backends.map {
                ObservedLoadBalancerBackend(id: $0.id, healthStatus: .error)
            })
    }
}
