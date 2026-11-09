import Foundation
import SwiftProtobuf

/// A read-only Strato vsock ping, independent of desired opt-in and QEMU's qga.
public typealias GuestAgentObservation = Strato_Agent_V1_GuestAgentObservation
extension Strato_Agent_V1_GuestAgentObservation: Codable {

    public init(reachable: Bool, checkedAt: Date) {
        self.init()
        self._jsonReachable = reachable
        self._jsonCheckedAt = checkedAt
    }

    private enum CodingKeys: String, CodingKey { case reachable; case checkedAt }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonReachable = try container.decode(Bool.self, forKey: .reachable)
        self._jsonCheckedAt = try container.decode(Date.self, forKey: .checkedAt)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonReachable, forKey: .reachable)
        try container.encode(_jsonCheckedAt, forKey: .checkedAt)
    }

    var _jsonReachable: Bool {
        get { reachable }
        set { let value = newValue; reachable = value }
    }
    var _jsonCheckedAt: Date {
        get { checkedAt.date }
        set { let value = newValue; checkedAt = Google_Protobuf_Timestamp(date: value) }
    }
}
