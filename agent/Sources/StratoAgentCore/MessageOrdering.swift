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

    /// Shared lane joined by every operation that reads or mutates the *set* of networks
    /// (create/delete and the global list query), so a `network_list` observes any
    /// create/delete that arrived before it. Distinct from the `network:<name>` namespace so
    /// it can't collide with a real network name.
    public static let networkVisibilityLane = "__strato_networks__"

    /// The serial lanes used to order this inbound frame relative to others.
    ///
    /// Frames acting on the same resource share a lane and are therefore applied in the order
    /// they arrived; frames for unrelated resources get independent lanes and may proceed
    /// concurrently. VM ids are normalized so a VM's `create` frame (which carries the id under
    /// `vmData.id`) and its later operation frames (which carry it under `vmId`) land together.
    /// Most frames yield a single lane; operations spanning two resources (e.g. volume clone)
    /// yield both so they serialize against each participating lane.
    public var serializationKeys: [String] {
        Self.serializationKeys(type: type, payload: payload)
    }

    /// Compute the serial lanes for a frame of `type` with the given raw JSON `payload`.
    static func serializationKeys(type: MessageType, payload: Data) -> [String] {
        let fields = try? WireProtocol.makeDecoder().decode(RoutingFields.self, from: payload)

        let raws: [String?]
        switch type {
        case .vmCreate:
            // Creation also wires up the VM's configured networks (find-or-create of the
            // logical switch), so serialize against those network lanes too. Fall back to
            // "default" for an entry with no network reference.
            var keys: [String?] = [fields?.vmData?.id.uuidString]
            for net in fields?.vmSpec?.networks ?? [] {
                keys.append("network:\(net.network ?? "default")")
            }
            raws = keys
        case .volumeClone:
            // A clone reads a source volume and writes a target volume; serialize against both
            // so it can't race a delete/resize/info on either resource.
            raws = [fields?.sourceVolumeId, fields?.targetVolumeId]
        case .volumeAttach, .volumeDetach:
            // Hot-plug/unplug acts on both the volume and the target VM (the handler drives
            // QEMU with vmId), so serialize against the VM's lifecycle lane too.
            raws = [fields?.volumeId, fields?.vmId]
        case .volumeCreate, .volumeDelete, .volumeResize, .volumeSnapshot, .volumeSnapshotDelete, .volumeInfo:
            raws = [fields?.volumeId]
        case .networkAttach:
            // Attaching a VM to a network acts on both the VM and the named network (the
            // handler may find-or-create the logical switch), so serialize against both.
            raws = [fields?.vmId, fields?.networkName.map { "network:\($0)" }]
        case .networkCreate, .networkDelete:
            // Named-network lane orders same-network operations; the shared visibility lane
            // orders these mutations against a global `network_list` read (and each other).
            raws = [fields?.networkName.map { "network:\($0)" }, Self.networkVisibilityLane]
        case .networkList:
            // Reads the whole set of networks, so serialize after any pending create/delete.
            raws = [Self.networkVisibilityLane]
        case .networkInfo:
            // Reads a single named network; the per-name lane already orders it after that
            // network's create/delete.
            raws = [fields?.networkName.map { "network:\($0)" }]
        default:
            // VM lifecycle, console, network detach, and info/status queries all carry vmId.
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

    /// Minimal projection of the possible resource-identifying fields across frame payloads,
    /// decoded once for routing without paying for a full message decode.
    private struct RoutingFields: Decodable {
        struct VMDataID: Decodable { let id: UUID }
        struct NetStub: Decodable { let network: String? }
        struct VMSpecStub: Decodable { let networks: [NetStub]? }
        let vmData: VMDataID?
        let vmSpec: VMSpecStub?
        let vmId: String?
        let volumeId: String?
        let sourceVolumeId: String?
        let targetVolumeId: String?
        let networkName: String?
    }
}
