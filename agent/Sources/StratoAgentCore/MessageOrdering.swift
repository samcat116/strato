import Foundation
import StratoShared

/// Serializes asynchronous work by key: items submitted with the same key run in strict
/// FIFO submission order, while items with different keys run concurrently.
///
/// Inbound live streams and reconciliation work share this queue, so related work remains
/// ordered without globally serializing unrelated resources.
public actor SerialTaskQueue {
    /// The most recently enqueued task for each key. A newly enqueued item awaits the current
    /// tail before running, chaining items for a key into a FIFO.
    private var tails: [String: Task<Void, Never>] = [:]
    /// Identifies the current tail per key so a finishing task only evicts its own bookkeeping,
    /// never a successor that has since taken the slot.
    private var tailIDs: [String: UInt64] = [:]
    private var nextID: UInt64 = 0

    public init() {}

    /// Submit `operation` to run once all previously enqueued work for *every* key in `keys`
    /// has completed; `operation` then blocks all of those keys until it finishes.
    ///
    /// Deadlock-free: the predecessor tails are snapshotted atomically inside the actor, so a
    /// task only ever waits on tasks submitted before it — dependencies form a DAG that
    /// respects submission order.
    public func enqueue(keys rawKeys: [String], operation: @escaping @Sendable () async -> Void) {
        let keys = rawKeys.isEmpty ? [""] : Array(Set(rawKeys))
        nextID += 1
        let id = nextID
        let predecessors = keys.compactMap { tails[$0] }
        let task = Task {
            // Wait for the previous item on each involved lane, preserving arrival order.
            for predecessor in predecessors { await predecessor.value }
            await operation()
            self.retireTails(keys: keys, id: id)
        }
        for key in keys {
            tails[key] = task
            tailIDs[key] = id
        }
    }

    /// Drop each key's bookkeeping once this task (identified by `id`) is still its tail, so
    /// idle keys don't accumulate while never evicting a successor that took the slot.
    private func retireTails(keys: [String], id: UInt64) {
        for key in keys where tailIDs[key] == id {
            tails.removeValue(forKey: key)
            tailIDs.removeValue(forKey: key)
        }
    }
}

// MARK: - Inbound frame routing

extension MessageEnvelope {
    /// Shared lane for frames that don't act on a specific resource (registration, acks).
    /// They still run in arrival order relative to one another.
    public static let unkeyedSerializationLane = "__strato_unkeyed__"

    /// Lane for desired-state syncs (reconciliation phase 2). Successive syncs diff and
    /// enqueue in arrival order; the per-VM work they fan out runs on the VM lanes, so a
    /// sync is never blocked behind a long convergence action.
    public static let reconcileLane = "__strato_reconcile__"

    /// The serial lanes used to order this inbound frame relative to others.
    public var serializationKeys: [String] {
        Self.serializationKeys(type: type, payload: payload)
    }

    /// Compute the serial lanes for a frame of `type` with the given raw JSON `payload`.
    static func serializationKeys(type: MessageType, payload: Data) -> [String] {
        switch type {
        case .desiredState:
            return [Self.reconcileLane]
        case .consoleConnect, .consoleDisconnect, .consoleData:
            return routingKey(in: payload, field: \.vmId, prefix: "console:")
        case .guestExecStart, .guestExecInput, .guestExecResize, .guestExecClose,
            .guestExecRecordedAck:
            return routingKey(in: payload, field: \.sessionId, prefix: "exec:")
        default:
            return [unkeyedSerializationLane]
        }
    }

    private static func routingKey(
        in payload: Data,
        field: KeyPath<RoutingFields, String?>,
        prefix: String
    ) -> [String] {
        guard
            let fields = try? WireProtocol.makeDecoder().decode(RoutingFields.self, from: payload),
            let value = fields[keyPath: field],
            !value.isEmpty
        else { return [unkeyedSerializationLane] }
        return [prefix + value]
    }

    /// Minimal projection decoded for the live-stream frames that need routing.
    private struct RoutingFields: Decodable {
        let vmId: String?
        let sessionId: String?
    }
}
