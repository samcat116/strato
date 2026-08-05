import Foundation

/// How command results are printed: aligned tables for humans (default),
/// JSON for scripts.
public enum OutputFormat: String, Sendable, CaseIterable {
    case table
    case json
}

/// Re-encodes a decoded API model as pretty JSON for `-o json`. The generated
/// schema types keep the wire field names in their coding keys, so the field
/// names match what the server sent. Values are re-rendered rather than echoed:
/// timestamps come back in this encoder's ISO8601 form, which drops the
/// fractional seconds the runtime's decoder accepts.
public func renderJSON(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    return String(decoding: data, as: UTF8.self)
}
