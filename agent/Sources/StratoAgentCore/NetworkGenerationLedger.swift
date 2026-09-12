import Foundation

/// Separates replay protection from observed convergence for network desired
/// state. Accepting a newer generation must immediately make older payloads
/// stale even when a later reconciliation step fails, while reports must keep
/// advertising only the last generation that completed every required write.
public struct NetworkGenerationLedger: Sendable {
    private var accepted: [UUID: Int64] = [:]
    private var observed: [UUID: Int64] = [:]

    public init() {}

    /// Records the highest desired generation seen and returns whether this
    /// payload may reconcile. Equal generations remain eligible because the
    /// network loop is deliberately level-triggered.
    public mutating func accept(networkID: UUID, generation: Int64) -> Bool {
        if let previous = accepted[networkID], generation < previous {
            return false
        }
        accepted[networkID] = max(accepted[networkID] ?? generation, generation)
        return true
    }

    public mutating func recordObserved(networkID: UUID, generation: Int64) {
        observed[networkID] = max(observed[networkID] ?? generation, generation)
    }

    public func acceptedGeneration(for networkID: UUID) -> Int64? {
        accepted[networkID]
    }

    public func observedGeneration(for networkID: UUID) -> Int64 {
        observed[networkID] ?? 0
    }
}
