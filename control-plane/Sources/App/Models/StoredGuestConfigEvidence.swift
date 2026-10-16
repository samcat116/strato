import Foundation
import StratoShared

/// Reports include guest-chosen strings and sysctl values. Diagnostic logging
/// must never stringify those values, including SQL-bound JSON.
struct StoredGuestConfigEvidence: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let observation: GuestConfigObservation
    let agentID: String
    let receivedAt: Date
    var available: Bool
    var description: String { "<redacted guest configuration evidence>" }
    var debugDescription: String { description }
}
