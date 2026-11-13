import Foundation

// Explicit JSON compatibility for diagnostic/persisted registration records.
// The live negotiation and workload transport use the generated binary messages.
extension Strato_Agent_V1_ProtocolOffer: Codable {
    private enum CodingKeys: String, CodingKey { case major, capabilities }
    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(UInt32.self, forKey: .major) { major = value }
        capabilities = try container.decode([String].self, forKey: .capabilities)
    }
    public func encode(to encoder: any Swift.Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(hasMajor ? major : nil, forKey: .major)
        try container.encode(capabilities, forKey: .capabilities)
    }
}

extension Strato_Agent_V1_ProtocolAgreement: Codable {
    private enum CodingKeys: String, CodingKey { case major, capabilities, inventorySessionID }
    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(UInt32.self, forKey: .major) { major = value }
        capabilities = try container.decode([String].self, forKey: .capabilities)
        if let value = try container.decodeIfPresent(String.self, forKey: .inventorySessionID) {
            inventorySessionID = value
        }
    }
    public func encode(to encoder: any Swift.Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(hasMajor ? major : nil, forKey: .major)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(hasInventorySessionID ? inventorySessionID : nil, forKey: .inventorySessionID)
    }
}
