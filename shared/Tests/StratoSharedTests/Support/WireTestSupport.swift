import Foundation
import StratoShared

// The wire protocol routes every message through WireProtocol.makeEncoder()/
// makeDecoder() on both sides (see MessageEnvelope); tests must use the same
// coders so they exercise the real contract — including the pinned date
// strategy and its tolerant decode.
func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
    try WireProtocol.makeEncoder().encode(value)
}

func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try WireProtocol.makeDecoder().decode(type, from: data)
}

func decodeJSON<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    try WireProtocol.makeDecoder().decode(type, from: Data(json.utf8))
}

/// Encode a value and decode it back with the protocol's default coders.
func roundTrip<T: Codable>(_ value: T) throws -> T {
    try decodeJSON(T.self, from: encodeJSON(value))
}

/// Wrap a message in a `MessageEnvelope`, push it through JSON both at the
/// envelope layer and the payload layer, and hand back the decoded message —
/// the exact path a message takes between control plane and agent.
func throughEnvelope<T: WebSocketMessage>(_ message: T) throws -> T {
    let envelope = try MessageEnvelope(message: message)
    let decodedEnvelope = try decodeJSON(MessageEnvelope.self, from: encodeJSON(envelope))
    return try decodedEnvelope.decode(as: T.self)
}

/// Top-level JSON keys of the encoded value, for asserting fields actually
/// reach the wire (a round trip alone can't catch a field dropped by encoding).
func encodedKeys<T: Encodable>(_ value: T) throws -> Set<String> {
    let object = try JSONSerialization.jsonObject(with: encodeJSON(value))
    guard let dictionary = object as? [String: Any] else { return [] }
    return Set(dictionary.keys)
}

// Deterministic fixtures. Whole-second dates survive JSON's double encoding
// exactly, so field comparisons can use plain equality.
enum Fixtures {
    static let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    static let laterDate = Date(timeIntervalSince1970: 1_700_000_060)
    static let uuidA = UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444")!
    static let uuidB = UUID(uuidString: "BBBBBBBB-5555-6666-7777-888888888888")!
    static let requestId = "req-0001"

    static let imageInfo = ImageInfo(
        imageId: uuidA,
        projectId: uuidB,
        filename: "debian-12.qcow2",
        checksum: "sha256:abcdef",
        size: 2_147_483_648,
        downloadURL: "/api/projects/\(uuidB)/images/\(uuidA)/download"
    )

    static let resources = AgentResources(
        totalCPU: 16,
        availableCPU: 12,
        totalMemory: 68_719_476_736,
        availableMemory: 34_359_738_368,
        totalDisk: 1_099_511_627_776,
        availableDisk: 549_755_813_888
    )
}
