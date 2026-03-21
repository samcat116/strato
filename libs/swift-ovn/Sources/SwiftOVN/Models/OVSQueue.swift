import Foundation

public struct OVSQueue: Codable {
    public let uuid: String?
    public let other_config: [String: String]?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case other_config, external_ids
    }
    
    public init(other_config: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.other_config = other_config
        self.external_ids = external_ids
    }
}