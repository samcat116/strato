import Foundation

public struct OVNLogicalFlow: Codable {
    public let uuid: String?
    public let logical_datapath: String?
    public let logical_dp_group: String?
    public let pipeline: String
    public let table_id: Int
    public let priority: Int
    public let match: String
    public let actions: String
    public let tags: [String: String]?
    public let controller_meter: String?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case logical_datapath, logical_dp_group, pipeline, table_id, priority, match, actions, tags, controller_meter, external_ids
    }
}