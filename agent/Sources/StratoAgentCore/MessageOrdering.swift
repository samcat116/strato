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
        nextID += 1
        let id = nextID
        let predecessor = tails[key]
        tailIDs[key] = id
        let task = Task {
            // Wait for the previous item on this key, preserving arrival order.
            await predecessor?.value
            await operation()
            self.retireTail(key: key, id: id)
        }
        tails[key] = task
    }

    /// Drop a key's bookkeeping once its last task finishes, so idle keys don't accumulate.
    private func retireTail(key: String, id: UInt64) {
        guard tailIDs[key] == id else { return }
        tails.removeValue(forKey: key)
        tailIDs.removeValue(forKey: key)
    }
}

// MARK: - Inbound frame routing

extension MessageEnvelope {
    /// Shared lane for frames that don't act on a specific resource (registration, acks,
    /// list queries). They still run in arrival order relative to one another.
    public static let unkeyedSerializationLane = "__strato_unkeyed__"

    /// The serial lane used to order this inbound frame relative to others.
    ///
    /// Frames acting on the same resource share a lane and are therefore applied in the order
    /// they arrived; frames for unrelated resources get independent lanes and may proceed
    /// concurrently. VM ids are normalized so a VM's `create` frame (which carries the id under
    /// `vmData.id`) and its later operation frames (which carry it under `vmId`) land together.
    public var serializationKey: String {
        Self.serializationKey(type: type, payload: payload)
    }

    /// Compute the serial lane for a frame of `type` with the given raw JSON `payload`.
    static func serializationKey(type: MessageType, payload: Data) -> String {
        let fields = try? JSONDecoder().decode(RoutingFields.self, from: payload)

        let raw: String?
        switch type {
        case .vmCreate:
            raw = fields?.vmData?.id.uuidString
        case .volumeCreate, .volumeDelete, .volumeAttach, .volumeDetach,
             .volumeResize, .volumeSnapshot, .volumeClone, .volumeInfo, .volumeStatus:
            raw = fields?.volumeId
        case .networkCreate, .networkDelete, .networkInfo:
            // Networks are keyed by name; prefix so a name can never collide with a VM/volume id.
            raw = fields?.networkName.map { "network:\($0)" }
        default:
            // VM lifecycle, console, network attach/detach, and info/status queries all carry vmId.
            raw = fields?.vmId
        }

        guard let raw, !raw.isEmpty else { return unkeyedSerializationLane }
        // Normalize UUIDs to canonical form so create/operation frames share a lane regardless
        // of the casing the control plane used.
        return UUID(uuidString: raw)?.uuidString ?? raw
    }

    /// Minimal projection of the possible resource-identifying fields across frame payloads,
    /// decoded once for routing without paying for a full message decode.
    private struct RoutingFields: Decodable {
        struct VMDataID: Decodable { let id: UUID }
        let vmData: VMDataID?
        let vmId: String?
        let volumeId: String?
        let networkName: String?
    }
}
