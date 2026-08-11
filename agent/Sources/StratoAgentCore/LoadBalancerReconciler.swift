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
                var switches = Set(desired.backends.compactMap(\.networkId).map {
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
                results.append(
                    ObservedLoadBalancerState(
                        id: ownerID,
                        observedGeneration: placement.desired.generation,
                        status: .active,
                        backends: placement.desired.backends.map {
                            ObservedLoadBalancerBackend(id: $0.id, healthStatus: .unknown)
                        }))
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
