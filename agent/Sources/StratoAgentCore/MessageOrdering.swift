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
    private var isClosed = false

    public init() {}

    /// Submit `operation` to run once all previously enqueued work for *every* key in `keys`
    /// has completed; `operation` then blocks all of those keys until it finishes.
    ///
    /// Deadlock-free: the predecessor tails are snapshotted atomically inside the actor, so a
    /// task only ever waits on tasks submitted before it — dependencies form a DAG that
    /// respects submission order.
    public func enqueue(keys rawKeys: [String], operation: @escaping @Sendable () async -> Void) {
        guard !isClosed else { return }
        let keys = rawKeys.isEmpty ? [""] : Array(Set(rawKeys))
        nextID += 1
        let id = nextID
        let predecessors = keys.compactMap { tails[$0] }
        let task = Task {
            // Wait for the previous item on each involved lane, preserving arrival order.
            for predecessor in predecessors { await predecessor.value }
            if !self.isClosed { await operation() }
            self.retireTails(keys: keys, id: id)
        }
        for key in keys {
            tails[key] = task
            tailIDs[key] = id
        }
    }

    /// Refuse new work and prevent queued operations from starting.
    public func close() { isClosed = true }

    /// Fence submission and join active mutations before releasing their dependencies.
    /// Call outside a queued operation so it cannot wait for itself.
    public func closeAndDrain() async {
        close()
        let pending = Array(tails.values)
        for task in pending { await task.value }
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
        let key: String?
        let prefix: String
        switch type {
        case .desiredState:
            return [Self.reconcileLane]
        case .consoleConnect:
            key = try? decode(as: ConsoleConnectMessage.self).vmID
            prefix = "console:"
        case .consoleDisconnect:
            key = try? decode(as: ConsoleDisconnectMessage.self).vmID
            prefix = "console:"
        case .consoleData:
            key = try? decode(as: ConsoleDataMessage.self).vmID
            prefix = "console:"
        case .guestExecStart:
            key = try? decode(as: GuestExecStartMessage.self).sessionID
            prefix = "exec:"
        case .guestExecInput:
            key = try? decode(as: GuestExecInputMessage.self).sessionID
            prefix = "exec:"
        case .guestExecResize:
            key = try? decode(as: GuestExecResizeMessage.self).sessionID
            prefix = "exec:"
        case .guestExecClose:
            key = try? decode(as: GuestExecCloseMessage.self).sessionID
            prefix = "exec:"
        case .guestExecRecordedAck:
            key = try? decode(as: GuestExecRecordedAckMessage.self).sessionID
            prefix = "exec:"
        default:
            return [Self.unkeyedSerializationLane]
        }
        guard let key, !key.isEmpty else { return [Self.unkeyedSerializationLane] }
        return [prefix + key]
    }
}
