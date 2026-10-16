import Foundation
import StratoShared

/// Fluent and SQLKit stringify bound values in debug logging. Prevent that
/// diagnostic path from exposing file contents; the stored JSON is unchanged.
struct StoredGuestConfig: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: GuestConfig
    init(_ value: GuestConfig) { self.value = value }
    init(from decoder: any Decoder) throws { value = try GuestConfig(from: decoder) }
    func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
    var description: String { "<redacted guest configuration>" }
    var debugDescription: String { description }
}
