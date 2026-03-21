import Foundation

public struct OVSQoS: Codable {
    public let uuid: String?
    public let qosType: String
    public let queues: [Int: String]?
    public let other_config: [String: String]?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case queues, other_config, external_ids
        case qosType = "type"
    }
    
    public init(qosType: String, queues: [Int: String]? = nil, other_config: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.qosType = qosType
        self.queues = queues
        self.other_config = other_config
        self.external_ids = external_ids
    }
}