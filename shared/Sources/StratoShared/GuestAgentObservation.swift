import Foundation

/// A read-only Strato vsock ping, independent of desired opt-in and QEMU's qga.
public struct GuestAgentObservation: Codable, Equatable, Sendable {
    public let reachable: Bool
    public let checkedAt: Date

    public init(reachable: Bool, checkedAt: Date) {
        self.reachable = reachable
        self.checkedAt = checkedAt
    }
}
