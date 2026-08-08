import Foundation
import StratoShared

/// Serializes asynchronous work by key: items submitted with the same key run in strict
/// FIFO submission order, while items with different keys run concurrently.
///
/// Inbound control-plane frames are decoded on a single ordered pipeline and then handed
/// here keyed by the resource they act on (VM id, volume id, …). This preserves per-resource
/// ordering — so `create` is applied before `delete`, `attach` before `detach`, and `pause`
/// before `resume` — without globally serializing unrelated operations behind one another.
public actor SerialTaskQueue {
    /// The most recently enqueued task for each key. A newly enqueued item awaits the current
    /// tail before running, chaining items for a key into a FIFO.
    private var tails: [String: Task<Void, Never>] = [:]
    /// Identifies the current tail per key so a finishing task only evicts its own bookkeeping,
    /// never a successor that has since taken the slot.
    private var tailIDs: [String: UInt64] = [:]
    private var nextID: UInt64 = 0

    public init() {}

    /// Submit `operation` to run once all previously enqueued work for `key` has completed.
    /// Work for distinct keys is unordered relative to each other and may run concurrently.
    public func enqueue(key: String, operation: @escaping @Sendable () async -> Void) {
        enqueue(keys: [key], operation: operation)
    }

    /// Submit `operation` to run once all previously enqueued work for *every* key in `keys`
    /// has completed; `operation` then blocks all of those keys until it finishes. Used for
    /// operations that touch more than one resource (e.g. a volume clone reads a source and
    /// writes a target), so they serialize against every lane they participate in.
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
    ///
    /// Frames acting on the same resource share a lane and are therefore applied in the order
    /// they arrived; frames for unrelated resources get independent lanes and may proceed
    /// concurrently. VM ids are normalized so equivalent UUID spellings share
    /// a lane. Most frames yield a single lane; operations spanning two resources
    /// (e.g. volume clone) yield both so they serialize against each participating lane.
    public var serializationKeys: [String] {
        Self.serializationKeys(type: type, payload: payload)
    }

    /// Compute the serial lanes for a frame of `type` with the given raw JSON `payload`.
    static func serializationKeys(type: MessageType, payload: Data) -> [String] {
        let fields = try? WireProtocol.makeDecoder().decode(RoutingFields.self, from: payload)

        let raws: [String?]
        switch type {
        case .desiredState:
            // Full-fleet syncs diff quickly and fan per-VM work out onto the VM lanes, so
            // they get their own lane: ordered among themselves, never stuck behind a VM.
            raws = [Self.reconcileLane]
        case .consoleConnect, .consoleDisconnect, .consoleData:
            // Interactive console I/O is independent of a VM's lifecycle/reconcile work.
            // Keep it on a dedicated per-VM console lane so opening/streaming the console
            // is never serialized behind (or stuck waiting on) a slow VM operation, while
            // still ordering console frames for the same VM among themselves.
            raws = [fields?.vmId.map { "console:\($0)" }]
        case .sandboxExecStart, .sandboxExecInput, .sandboxExecResize, .sandboxExecClose:
            // Interactive exec I/O gets a per-session lane for the same reason as console
            // frames: input/resize/close for a session are applied strictly after its start
            // (which blocks on the guest spawning the process), while unrelated sessions —
            // and the sandbox's own lifecycle work — proceed concurrently.
            raws = [fields?.sessionId.map { "exec:\($0)" }]
        default:
            // Any other frame that names a VM shares that VM's lane. No inbound
            // frame does today — the imperative VM and network messages went by
            // wire v34 (STR-151), and the `success`/`error` ACKs that outlived
            // them carry no resource and stopped being correlated at all
            // (STR-152) — so this arm is currently reached only by frames with
            // no `vmId`, which fall through to the unkeyed lane. It is kept
            // because it is the rule for the *next* such frame, not a leftover
            // of the last one.
            raws = [fields?.vmId]
        }

        // Normalize UUIDs to canonical form so create/operation frames share a lane regardless
        // of the casing the control plane used.
        let keys = raws.compactMap { raw -> String? in
            guard let raw, !raw.isEmpty else { return nil }
            return UUID(uuidString: raw)?.uuidString ?? raw
        }
        return keys.isEmpty ? [unkeyedSerializationLane] : keys
    }

    // The volume lane helper went with the last volume frame (wire v33): no
    // inbound message names a volume any more, so nothing routes to it. The
    // reconciler still uses `volume/<id>` lanes for its own work items — see
    // `ReconcileWorkItem.laneKeys` — but those never come off the wire.

    /// Minimal projection of the possible resource-identifying fields across frame payloads,
    /// decoded once for routing without paying for a full message decode.
    private struct RoutingFields: Decodable {
        let vmId: String?
        let sessionId: String?
    }
}
