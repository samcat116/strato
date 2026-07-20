import Foundation

/// How command results are printed: aligned tables for humans (default),
/// JSON for scripts.
public enum OutputFormat: String, Sendable, CaseIterable {
    case table
    case json
}

/// Re-encodes a decoded API model as pretty JSON for `-o json`.
public func renderJSON(_ value: some Encodable) throws -> String {
    let encoder = APIClient.jsonEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    return String(decoding: data, as: UTF8.self)
}
