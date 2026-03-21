import Foundation

public struct OVNPortBinding: Codable {
    public let uuid: String?
    public let logical_port: String
    public let bindingType: String
    public let mac: [String]?
    public let chassis: String?
    public let datapath: String?
    public let tunnel_key: Int?
    public let parent_port: String?
    public let tag: Int?
    public let gateway_chassis: [String]?
    public let ha_chassis_group: String?
    public let up: Bool?
    public let external_ids: [String: String]?
    public let options: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case logical_port, mac, chassis, datapath, tunnel_key, parent_port, tag, gateway_chassis, ha_chassis_group, up, external_ids, options
        case bindingType = "type"
    }
}